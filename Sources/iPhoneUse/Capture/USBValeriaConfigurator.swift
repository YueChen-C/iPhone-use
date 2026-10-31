import CoreFoundation
import Darwin
import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib
import SystemConfiguration

/// Activates a dormant USB "Valeria" screen-capture configuration on a connected iOS device.
///
/// Safety, lock-order & network preservation contract:
/// - `USBValeriaConfigurator.queue` may invoke `shouldProceed` (which acquires manager locks),
///   so callers MUST NEVER invoke `USBValeriaConfigurator` while holding manager locks.
/// - Only Apple iOS devices (`idVendor == 0x05AC` and `SupportsIPhoneOS == true`) are eligible.
/// - `USBDeviceOpenSeize` is permitted only when `UsbExclusiveOwner` is absent or names Apple's
///   built-in USB host composite driver; user-space owners (`pid ...`) or third-party drivers
///   are never preempted.
/// - Replacing a configuration that carries (or might carry, when descriptor/string parsing is
///   incomplete) USB network interfaces is refused by default whenever the device carries the
///   host's IPv4 or IPv6 primary route, when a virtual tunnel's physical underlay is unknown,
///   or when no non-device physical default route is confirmed.
/// - Every `SetConfiguration` that returns `kIOReturnSuccess` is recorded immediately in
///   `USBSwitchLedger` (even if subsequent readback fails) and retained across transient
///   restore errors until readback confirms restoration, an external owner supersedes it,
///   or the physical `IORegistryEntry` detaches.
enum USBValeriaConfigurator {
    enum NetworkCapability: Equatable {
        case carriesNetwork
        case noNetwork
        case unknown
    }

    struct ConfigurationDescriptorInfo: Equatable {
        let value: UInt8
        let name: String?
        let nameReadSucceeded: Bool
        /// `nil` indicates incomplete, truncated, oversized, or mismatched interface parsing.
        let interfaceClasses: [UInt8]?

        init(
            value: UInt8,
            name: String?,
            nameReadSucceeded: Bool = true,
            interfaceClasses: [UInt8]? = []
        ) {
            self.value = value
            self.name = name
            self.nameReadSucceeded = nameReadSucceeded
            self.interfaceClasses = interfaceClasses
        }

        var advertisesValeria: Bool {
            guard nameReadSucceeded, let name else { return false }
            return name.range(of: "Valeria", options: .caseInsensitive) != nil
        }

        var networkCapability: NetworkCapability {
            if let interfaceClasses,
                interfaceClasses.contains(where: { $0 == 0x02 || $0 == 0x0A || $0 == 0xE0 })
            {
                return .carriesNetwork
            }
            if let name,
                name.range(of: "Ethernet", options: .caseInsensitive) != nil
                    || name.range(of: "NCM", options: .caseInsensitive) != nil
                    || name.range(of: "RNDIS", options: .caseInsensitive) != nil
            {
                return .carriesNetwork
            }
            guard nameReadSucceeded,
                let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty,
                interfaceClasses != nil
            else {
                return .unknown
            }
            return .noNetwork
        }
    }

    struct HostNetworkRouteSnapshot: Equatable {
        enum FamilyRoute: Equatable {
            case none
            case physicalPrimary(String)
            case unresolvedPrimary
        }

        let ipv4: FamilyRoute
        let ipv6: FamilyRoute
    }

    struct ObservedBSDInterface: Equatable {
        let name: String
        /// `true` only when the IORegistry entry conforms to macOS's kernel-restricted
        /// `AppleUSBHostNCMRestrictedEthernetInterface` (`anri*` internal CoreDevice link).
        let isAppleRestrictedInternal: Bool
        /// `IOLinkActiveCount` property from IORegistry (`nil` if absent).
        let ioLinkActiveCount: Int?
        /// `State:/Network/Interface/<bsd>/Link["Active"]` from `SCDynamicStore` (`nil` if absent).
        let storeLinkActive: Bool?
        let hasIPv4Address: Bool
        let hasNonLinkLocalIPv6Address: Bool
        let hasAnyIPv6Address: Bool
    }

    enum DeviceBSDNetworkState: Equatable {
        /// Failed to inspect IORegistry BSD children, `getifaddrs`, or carrier metadata (fail closed).
        case unknown
        /// Inspected successfully; holds every device BSD interface capable of carrying host IP,
        /// network-service, or VPN outer-tunnel traffic.
        case inspected(activeHostInterfaces: Set<String>)
    }

    struct DeviceCandidate: Equatable {
        let registryEntryID: UInt64
        let vendorID: Int?
        let supportsIPhoneOS: Bool
        let serial: String?

        init(
            registryEntryID: UInt64 = 0,
            vendorID: Int?,
            supportsIPhoneOS: Bool,
            serial: String?
        ) {
            self.registryEntryID = registryEntryID
            self.vendorID = vendorID
            self.supportsIPhoneOS = supportsIPhoneOS
            self.serial = serial
        }
    }

    /// Physical USB identity captured outside manager locks when a single CoreMediaIO
    /// capture source is discovered or during empty-discovery dormant Valeria activation.
    struct PinnedUSBDevice: Equatable {
        let registryEntryID: UInt64
        let serial: String?
    }

    struct ConnectedIOSUSBTopology: Equatable {
        let attachedEntryIDs: Set<UInt64>
        /// Non-nil only when exactly one iOS USB device is attached and has a non-zero registry entry ID.
        let singleDevice: PinnedUSBDevice?
    }

    enum IOSUSBTopologyObservation: Equatable {
        case unavailable
        case observed(ConnectedIOSUSBTopology)
    }

    enum USBServicePropertyObservation: Equatable {
        case unreadable
        case nonIOSDevice
        case iosDevice(PinnedUSBDevice)
    }

    struct ActivatedSwitch: Equatable {
        let registryEntryID: UInt64
        let previousConfiguration: UInt8
        let requestedConfiguration: UInt8
        var lastObservedConfiguration: UInt8?
        var readbackConfirmed: Bool

        init(
            registryEntryID: UInt64,
            previousConfiguration: UInt8,
            requestedConfiguration: UInt8,
            lastObservedConfiguration: UInt8? = nil,
            readbackConfirmed: Bool = true
        ) {
            self.registryEntryID = registryEntryID
            self.previousConfiguration = previousConfiguration
            self.requestedConfiguration = requestedConfiguration
            self.lastObservedConfiguration =
                lastObservedConfiguration ?? (readbackConfirmed ? requestedConfiguration : nil)
            self.readbackConfirmed = readbackConfirmed
        }
    }

    enum ActivationOutcome: Equatable {
        case switched(ActivatedSwitch)
        case unconfirmedSwitch(ActivatedSwitch)
        case blockedByActiveUSBNetwork
        case blockedByUSBResourceShortage
        case notActivated
    }

    enum RestoreOutcome: Equatable {
        case restored
        case alreadyRestored
        case supersededByExternalChange
        case deviceDetached
        case notTracked
        case transientFailure

        var isTerminal: Bool {
            switch self {
            case .restored, .alreadyRestored, .supersededByExternalChange, .deviceDetached, .notTracked:
                true
            case .transientFailure:
                false
            }
        }
    }

    static let appleVendorID = 0x05AC

    /// `kIOUSBDeviceInterfaceID182` (`152FC496-4891-11D5-9D52-000A27801E86`) from
    /// `<IOKit/usb/IOUSBLib.h>`, matching `IOUSBDeviceInterface182`.
    static let deviceInterfaceID182Bytes: [UInt8] = [
        0x15, 0x2F, 0xC4, 0x96, 0x48, 0x91, 0x11, 0xD5,
        0x9D, 0x52, 0x00, 0x0A, 0x27, 0x80, 0x1E, 0x86,
    ]

    private static let queue = DispatchQueue(label: "iphone-use.usb-valeria")
    private static var switchLedger = USBSwitchLedger()

    /// Selects a dormant Valeria descriptor only when the active configuration lacks
    /// Valeria and another exposed configuration explicitly advertises it.
    static func dormantValeriaConfiguration(
        currentConfiguration: UInt8,
        configurations: [ConfigurationDescriptorInfo]
    ) -> ConfigurationDescriptorInfo? {
        if configurations.contains(where: { $0.value == currentConfiguration && $0.advertisesValeria }) {
            return nil
        }
        return configurations.first(where: {
            $0.value != currentConfiguration
                && $0.advertisesValeria
                && $0.networkCapability == .carriesNetwork
        })
            ?? configurations.first(where: {
                $0.value != currentConfiguration && $0.advertisesValeria
            })
    }

    static func dormantValeriaConfigurationValue(
        currentConfiguration: UInt8,
        configurations: [ConfigurationDescriptorInfo]
    ) -> UInt8? {
        dormantValeriaConfiguration(
            currentConfiguration: currentConfiguration, configurations: configurations)?.value
    }

    /// Distinguishes an opaque RFC-4122 `8-4-4-4-12` CoreMediaIO DAL capture UUID
    /// from an Apple USB serial / UDID (`24` or `40` hex digits, or `8-16` hyphenated).
    static func isOpaqueCaptureUUID(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.count == 36
        else { return false }
        return UUID(uuidString: trimmed) != nil
    }

    private static func matchesPinnedDeviceAllowingSameSerialReenumeration(
        _ candidate: DeviceCandidate,
        pinned: PinnedUSBDevice
    ) -> Bool {
        let pinnedSerial = normalizedSerial(pinned.serial)
        let candidateSerial = normalizedSerial(candidate.serial)
        if let pinnedSerial, let candidateSerial {
            return pinnedSerial == candidateSerial
        }
        if pinnedSerial == nil, candidateSerial == nil, pinned.registryEntryID != 0 {
            return candidate.registryEntryID == pinned.registryEntryID
        }
        return false
    }

    private static func matchesExactPinnedEntryAndSerial(
        _ candidate: DeviceCandidate,
        pinned: PinnedUSBDevice
    ) -> Bool {
        guard pinned.registryEntryID != 0,
            candidate.registryEntryID == pinned.registryEntryID
        else { return false }
        return normalizedSerial(candidate.serial) == normalizedSerial(pinned.serial)
    }

    static func selectCandidateIndex(
        devices: [DeviceCandidate],
        preferredSerial: String?,
        allowSingleIOSFallback: Bool,
        pinnedSingleDevice: PinnedUSBDevice? = nil
    ) -> Int? {
        let iosIndices = devices.indices.filter { index in
            devices[index].vendorID == appleVendorID && devices[index].supportsIPhoneOS
        }
        guard !iosIndices.isEmpty else { return nil }
        if let preferredSerial {
            guard let target = normalizedSerial(preferredSerial) else { return nil }
            let exact = iosIndices.filter { normalizedSerial(devices[$0].serial) == target }
            if exact.count == 1 {
                if let pinnedSingleDevice,
                    !matchesPinnedDeviceAllowingSameSerialReenumeration(
                        devices[exact[0]], pinned: pinnedSingleDevice)
                {
                    return nil
                }
                return exact[0]
            }
            if !exact.isEmpty || !isOpaqueCaptureUUID(preferredSerial) {
                return nil
            }
            guard allowSingleIOSFallback,
                iosIndices.count == 1,
                let pinnedSingleDevice,
                matchesPinnedDeviceAllowingSameSerialReenumeration(
                    devices[iosIndices[0]], pinned: pinnedSingleDevice)
            else { return nil }
            return iosIndices[0]
        }
        guard allowSingleIOSFallback, iosIndices.count == 1 else { return nil }
        if let pinnedSingleDevice {
            guard
                matchesExactPinnedEntryAndSerial(
                    devices[iosIndices[0]], pinned: pinnedSingleDevice)
            else { return nil }
        }
        return iosIndices[0]
    }

    static func canSeizeExclusiveDevice(exclusiveOwner: String?) -> Bool {
        guard let raw = exclusiveOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return true }
        let allowedDrivers: Set<String> = [
            "AppleUSBHostCompositeDevice",
            "AppleUSBHostiOSDevice",
        ]
        return allowedDrivers.contains(raw)
    }

    /// Parses raw USB configuration descriptor bytes strictly. Returns `nil` if the
    /// buffer is truncated, exceeds 4096 bytes, contains malformed sub-descriptors,
    /// has trailing bytes, or fails to account for all `bNumInterfaces` interfaces.
    static func parseInterfaceClassesFromRawDescriptor(
        _ raw: UnsafeRawBufferPointer,
        expectedTotalLength: Int,
        expectedNumInterfaces: Int
    ) -> [UInt8]? {
        let headerLength = 9
        guard raw.count >= headerLength,
            expectedTotalLength >= headerLength,
            expectedTotalLength <= 4096,
            raw.count >= expectedTotalLength,
            expectedNumInterfaces >= 0
        else { return nil }

        let declaredHeaderLength = Int(raw[0])
        let descriptorType = Int(raw[1])
        guard declaredHeaderLength >= headerLength,
            declaredHeaderLength <= expectedTotalLength,
            descriptorType == kUSBConfDesc
        else { return nil }

        var offset = declaredHeaderLength
        var classes: [UInt8] = []
        var distinctInterfaceNumbers: Set<UInt8> = []
        while offset < expectedTotalLength {
            guard offset + 2 <= expectedTotalLength else { return nil }
            let length = Int(raw[offset])
            let subType = Int(raw[offset + 1])
            guard length >= 2, offset + length <= expectedTotalLength else { return nil }
            if subType == kUSBInterfaceDesc {
                guard length >= 9 else { return nil }
                distinctInterfaceNumbers.insert(raw[offset + 2])
                classes.append(raw[offset + 5])
            }
            offset += length
        }
        guard offset == expectedTotalLength,
            distinctInterfaceNumbers.count == expectedNumInterfaces
        else { return nil }
        return classes
    }

    static func isVirtualTunnelOrLoopback(_ name: String) -> Bool {
        name.hasPrefix("utun")
            || name.hasPrefix("lo")
            || name.hasPrefix("ipsec")
            || name.hasPrefix("ppp")
            || name.hasPrefix("gif")
            || name.hasPrefix("stf")
    }

    private static func parseIPv4HostOrder(_ raw: String) -> UInt32? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var addr = in_addr()
        guard inet_pton(AF_INET, trimmed, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func isRoutableIPv4HostOrder(_ ip: UInt32) -> Bool {
        let firstOctet = ip >> 24
        if firstOctet == 0 || firstOctet == 127 {
            return false
        }
        if (ip >> 16) == 0xA9FE {
            return false
        }
        if ip == 0xFFFF_FFFF {
            return false
        }
        return true
    }

    private static func parseIPv6Bytes(_ raw: String) -> [UInt8]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let bare = trimmed.split(separator: "%", maxSplits: 1).first,
            !bare.isEmpty
        else { return nil }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, String(bare), &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func isGlobalOrULAIPv6Bytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        let isMulticast = bytes[0] == 0xFF
        return !isUnspecified && !isLoopback && !isLinkLocal && !isMulticast
    }

    private static func isValidIPv6RouterBytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isBareLinkLocalPrefix =
            bytes[0] == 0xFE && bytes[1] == 0x80 && bytes.dropFirst(2).allSatisfy { $0 == 0 }
        let isMulticast = bytes[0] == 0xFF
        return !isUnspecified && !isLoopback && !isBareLinkLocalPrefix && !isMulticast
    }

    private static func hasActiveDefaultRouter(_ service: [String: Any], isIPv6: Bool) -> Bool {
        if (service["IsNULL"] as? NSNumber)?.boolValue == true {
            return false
        }
        guard
            let router = (service["Router"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !router.isEmpty
        else { return false }
        let addresses = (service["Addresses"] as? [String]) ?? []
        if isIPv6 {
            guard let routerBytes = parseIPv6Bytes(router),
                isValidIPv6RouterBytes(routerBytes)
            else { return false }
            return addresses.contains { addr in
                guard let bytes = parseIPv6Bytes(addr) else { return false }
                return isGlobalOrULAIPv6Bytes(bytes)
            }
        } else {
            guard let routerIP = parseIPv4HostOrder(router),
                isRoutableIPv4HostOrder(routerIP)
            else { return false }
            return addresses.contains { addr in
                guard let ip = parseIPv4HostOrder(addr) else { return false }
                return isRoutableIPv4HostOrder(ip)
            }
        }
    }

    private static func serviceInterfaceName(_ dict: [String: Any]) -> String? {
        let name = (dict["ConfirmedInterfaceName"] as? String) ?? (dict["InterfaceName"] as? String)
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func resolveFamilyRoute(
        global: [String: Any]?,
        servicesByID: [String: [String: Any]],
        isIPv6: Bool
    ) -> HostNetworkRouteSnapshot.FamilyRoute {
        let routedPhysicalInterfaces = Set(
            servicesByID.values.compactMap { dict -> String? in
                guard let iface = serviceInterfaceName(dict),
                    !isVirtualTunnelOrLoopback(iface),
                    hasActiveDefaultRouter(dict, isIPv6: isIPv6)
                else { return nil }
                return iface
            })

        guard let global,
            let primaryIface = (global["PrimaryInterface"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !primaryIface.isEmpty
        else {
            return routedPhysicalInterfaces.isEmpty ? .none : .unresolvedPrimary
        }

        let primaryServiceID = global["PrimaryService"] as? String
        let primaryService = primaryServiceID.flatMap { servicesByID[$0] }
        if (primaryService?["IsNULL"] as? NSNumber)?.boolValue == true {
            return .none
        }

        if !isVirtualTunnelOrLoopback(primaryIface) {
            if let primaryService, hasActiveDefaultRouter(primaryService, isIPv6: isIPv6) {
                return .physicalPrimary(primaryIface)
            }
            if routedPhysicalInterfaces.contains(primaryIface) {
                return .physicalPrimary(primaryIface)
            }
            return .unresolvedPrimary
        }

        // Virtual tunnels (`utun*`, `ipsec*`, `ppp*`, etc.): `SCDynamicStore` `ExcludedRoutes`
        // only describes destination traffic bypassing the tunnel and can be overridden by the
        // kernel routing table or per-socket interface scoping (`IP_BOUND_IF` / `IPV6_BOUND_IF`).
        // Without kernel proof of the tunnel's outer transport socket, treat virtual primaries
        // conservatively as `.unresolvedPrimary`.
        return .unresolvedPrimary
    }

    static func parseHostNetworkRoutes(
        globalIPv4: [String: Any]?,
        globalIPv6: [String: Any]?,
        servicesIPv4: [String: [String: Any]],
        servicesIPv6: [String: [String: Any]]
    ) -> HostNetworkRouteSnapshot {
        HostNetworkRouteSnapshot(
            ipv4: resolveFamilyRoute(
                global: globalIPv4, servicesByID: servicesIPv4, isIPv6: false),
            ipv6: resolveFamilyRoute(
                global: globalIPv6, servicesByID: servicesIPv6, isIPv6: true))
    }

    /// Classifies the iOS USB device's child BSD interfaces strictly fail-closed:
    /// - Any interface referenced in `SCDynamicStore` IPv4/IPv6 services or route tables,
    ///   or holding an IPv4 / global-or-ULA IPv6 address, is treated as active host network.
    /// - Any non-restricted USB Ethernet/NCM interface (`en*`, i.e. not macOS's kernel-restricted
    ///   `AppleUSBHostNCMRestrictedEthernetInterface` `anri*` CoreDevice link) with active carrier
    ///   or any IPv6 address (including link-local) is treated as active host network; if carrier
    ///   state cannot be observed from either `SCDynamicStore` or IORegistry, returns `.unknown`.
    static func classifyDeviceBSDInterfaces(
        observed: [ObservedBSDInterface]?,
        servicesIPv4: [String: [String: Any]],
        servicesIPv6: [String: [String: Any]]
    ) -> DeviceBSDNetworkState {
        guard let observed else { return .unknown }

        var serviceReferencedInterfaces: Set<String> = []
        for serviceDict in Array(servicesIPv4.values) + Array(servicesIPv6.values) {
            for key in ["ConfirmedInterfaceName", "InterfaceName"] {
                if let name = (serviceDict[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !name.isEmpty
                {
                    serviceReferencedInterfaces.insert(name)
                }
            }
            for routeKey in ["AdditionalRoutes", "IncludedRoutes", "ExcludedRoutes"] {
                guard let rawRoutes = serviceDict[routeKey] else { continue }
                guard let routeList = rawRoutes as? [[String: Any]] else {
                    return .unknown
                }
                for route in routeList {
                    if let name = (route["InterfaceName"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !name.isEmpty
                    {
                        serviceReferencedInterfaces.insert(name)
                    }
                }
            }
        }

        var activeHostInterfaces: Set<String> = []
        for iface in observed {
            let name = iface.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .unknown }
            if serviceReferencedInterfaces.contains(name)
                || iface.hasIPv4Address
                || iface.hasNonLinkLocalIPv6Address
            {
                activeHostInterfaces.insert(name)
                continue
            }
            if !iface.isAppleRestrictedInternal {
                if iface.hasAnyIPv6Address
                    || iface.storeLinkActive == true
                    || (iface.ioLinkActiveCount ?? 0) > 0
                {
                    activeHostInterfaces.insert(name)
                } else if iface.storeLinkActive == nil && iface.ioLinkActiveCount == nil {
                    return .unknown
                }
            }
        }
        return .inspected(activeHostInterfaces: activeHostInterfaces)
    }

    /// Protects both IPv4 and IPv6 primary uplinks and scoped/virtual tunnel underlays
    /// before switching away from a configuration that carries (or may carry) USB network.
    static func permitsConfigurationSwitch(
        current: ConfigurationDescriptorInfo,
        target: ConfigurationDescriptorInfo,
        deviceBSDState: DeviceBSDNetworkState,
        routes: HostNetworkRouteSnapshot?,
        allowPrimaryNetworkPreemption: Bool
    ) -> Bool {
        if allowPrimaryNetworkPreemption { return true }
        switch current.networkCapability {
        case .noNetwork:
            return true
        case .unknown:
            return false
        case .carriesNetwork:
            if target.networkCapability == .carriesNetwork {
                return true
            }
        }

        guard let routes else { return false }
        let activeDeviceInterfaces: Set<String>
        switch deviceBSDState {
        case .unknown:
            return false
        case .inspected(let activeHostInterfaces):
            activeDeviceInterfaces = activeHostInterfaces
        }
        if activeDeviceInterfaces.isEmpty {
            return true
        }

        var confirmedNonDevicePrimaries: Set<String> = []
        for family in [routes.ipv4, routes.ipv6] {
            switch family {
            case .unresolvedPrimary:
                return false
            case .physicalPrimary(let iface):
                if activeDeviceInterfaces.contains(iface) {
                    return false
                }
                confirmedNonDevicePrimaries.insert(iface)
            case .none:
                break
            }
        }
        return !confirmedNonDevicePrimaries.isEmpty
    }

    static func normalizedSerial(_ value: String?) -> String? {
        guard let value else { return nil }
        let stripped = value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !stripped.isEmpty else { return nil }
        return String(String.UnicodeScalarView(stripped)).lowercased()
    }

    /// Classifies a single `IOUSBDevice` service's atomically snapshotted property dictionary
    /// without conflating property-read failures or unexpected CoreFoundation types with
    /// confirmed non-iOS peripherals.
    static func parseObservedUSBServiceProperties(
        registryEntryID: UInt64?,
        properties: NSDictionary?
    ) -> USBServicePropertyObservation {
        guard let properties else { return .unreadable }
        guard let rawVendor = properties[kUSBVendorID],
            CFGetTypeID(rawVendor as CFTypeRef) == CFNumberGetTypeID(),
            let vendorNumber = rawVendor as? NSNumber
        else {
            return .unreadable
        }
        let vendorID = vendorNumber.intValue

        let isIOS: Bool
        if let rawSupports = properties["SupportsIPhoneOS"] {
            guard CFGetTypeID(rawSupports as CFTypeRef) == CFBooleanGetTypeID() else {
                return .unreadable
            }
            isIOS = CFBooleanGetValue((rawSupports as! CFBoolean))
        } else {
            isIOS = false
        }

        guard vendorID == appleVendorID, isIOS else {
            return .nonIOSDevice
        }
        guard let entryID = registryEntryID, entryID != 0 else {
            return .unreadable
        }
        let serial: String?
        if let rawSerial = properties[kUSBSerialNumberString] {
            guard let serialString = rawSerial as? String else {
                return .unreadable
            }
            serial = serialString
        } else {
            serial = nil
        }
        return .iosDevice(PinnedUSBDevice(registryEntryID: entryID, serial: serial))
    }

    static func observeIOSUSBTopology<S: Sequence>(
        serviceObservations: S
    ) -> IOSUSBTopologyObservation where S.Element == USBServicePropertyObservation {
        var attachedEntryIDs: Set<UInt64> = []
        var iosDeviceCount = 0
        var firstDevice: PinnedUSBDevice?
        for observation in serviceObservations {
            switch observation {
            case .unreadable:
                return .unavailable
            case .nonIOSDevice:
                continue
            case .iosDevice(let device):
                guard device.registryEntryID != 0 else { return .unavailable }
                iosDeviceCount += 1
                attachedEntryIDs.insert(device.registryEntryID)
                if iosDeviceCount == 1 {
                    firstDevice = device
                }
            }
        }
        let single = (iosDeviceCount == 1) ? firstDevice : nil
        return .observed(
            ConnectedIOSUSBTopology(attachedEntryIDs: attachedEntryIDs, singleDevice: single))
    }

    private static func readObservedUSBServiceProperties(
        of service: io_service_t
    ) -> USBServicePropertyObservation {
        var rawProperties: Unmanaged<CFMutableDictionary>?
        let propsStatus = IORegistryEntryCreateCFProperties(
            service, &rawProperties, kCFAllocatorDefault, 0)
        guard propsStatus == KERN_SUCCESS,
            let dictionary = rawProperties?.takeRetainedValue() as NSDictionary?
        else {
            return .unreadable
        }
        var entryID: UInt64 = 0
        let entryIDResult: UInt64? =
            (IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS && entryID != 0)
            ? entryID
            : nil
        return parseObservedUSBServiceProperties(
            registryEntryID: entryIDResult,
            properties: dictionary)
    }

    /// Queries the currently attached Apple iOS USB device topology without opening any
    /// `IOUserClient` plugin interfaces. MUST be called outside `ScreenCaptureManager`'s
    /// lock so `manager.lock -> USBValeriaConfigurator.queue` edges never exist.
    static func currentIOSUSBTopology() -> IOSUSBTopologyObservation {
        queue.sync {
            guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else {
                return .unavailable
            }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                return .unavailable
            }
            defer { IOObjectRelease(iterator) }

            var observations: [USBServicePropertyObservation] = []
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                defer { IOObjectRelease(service) }
                let observation = readObservedUSBServiceProperties(of: service)
                if observation == .unreadable {
                    return .unavailable
                }
                observations.append(observation)
            }
            return observeIOSUSBTopology(serviceObservations: observations)
        }
    }

    /// Queries the sole connected iOS USB device's identity. MUST be called outside
    /// `ScreenCaptureManager`'s lock so `manager.lock -> USBValeriaConfigurator.queue`
    /// edges never exist.
    static func currentSingleIOSDeviceIdentity() -> PinnedUSBDevice? {
        switch currentIOSUSBTopology() {
        case .unavailable:
            return nil
        case .observed(let topology):
            return topology.singleDevice
        }
    }

    static func activateDormantValeriaConfiguration(
        preferredSerial: String? = nil,
        allowSingleIOSFallback: Bool = true,
        pinnedSingleDevice: PinnedUSBDevice? = nil,
        shouldProceed: () -> Bool = { true }
    ) -> ActivationOutcome {
        queue.sync {
            guard shouldProceed() else { return .notActivated }
            guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else { return .notActivated }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                return .notActivated
            }
            defer { IOObjectRelease(iterator) }

            var services: [io_service_t] = []
            var candidates: [DeviceCandidate] = []
            defer {
                for service in services { IOObjectRelease(service) }
            }

            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                let vid = intProperty(of: service, key: kUSBVendorID)
                let isIOS = boolProperty(of: service, key: "SupportsIPhoneOS")
                guard vid == appleVendorID, isIOS else {
                    IOObjectRelease(service)
                    continue
                }
                var entryID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS {
                    entryID = 0
                }
                let serial = stringProperty(of: service, key: kUSBSerialNumberString)
                services.append(service)
                candidates.append(
                    DeviceCandidate(
                        registryEntryID: entryID,
                        vendorID: vid,
                        supportsIPhoneOS: isIOS,
                        serial: serial))
            }

            guard
                let selected = selectCandidateIndex(
                    devices: candidates,
                    preferredSerial: preferredSerial,
                    allowSingleIOSFallback: allowSingleIOSFallback,
                    pinnedSingleDevice: pinnedSingleDevice),
                shouldProceed()
            else { return .notActivated }

            return activateDormantValeriaOnServiceLocked(
                service: services[selected], shouldProceed: shouldProceed)
        }
    }

    @discardableResult
    static func restorePreviousConfiguration(registryEntryID: UInt64) -> RestoreOutcome {
        queue.sync {
            restoreEntryLocked(registryEntryID: registryEntryID)
        }
    }

    /// Enqueues asynchronous restoration of all tracked USB configuration changes and
    /// waits at most until `deadlineUptime` (`ProcessInfo.processInfo.systemUptime`),
    /// returning `true` only if the queue completed and all tracked entries reached a
    /// terminal restored/detached/superseded state before the deadline.
    @discardableResult
    static func restorePreviousConfigurations(deadlineUptime: TimeInterval? = nil) -> Bool {
        if let deadlineUptime {
            let done = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var succeeded = false
            queue.async {
                let clean = restoreAllEntriesLocked()
                resultLock.withLock { succeeded = clean }
                done.signal()
            }
            let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                return done.wait(timeout: .now()) == .success && resultLock.withLock { succeeded }
            }
            guard done.wait(timeout: .now() + remaining) == .success else {
                return false
            }
            return resultLock.withLock { succeeded }
        }
        return queue.sync {
            restoreAllEntriesLocked()
        }
    }

    private static func restoreAllEntriesLocked() -> Bool {
        let ids = switchLedger.trackedEntryIDs
        guard !ids.isEmpty else { return true }
        var allClean = true
        for id in ids {
            if !restoreEntryLocked(registryEntryID: id).isTerminal {
                allClean = false
            }
        }
        return allClean
    }

    private static func restoreEntryLocked(registryEntryID: UInt64) -> RestoreOutcome {
        guard switchLedger.entry(for: registryEntryID) != nil else { return .notTracked }
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else {
            return .transientFailure
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return .transientFailure
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                entryID == registryEntryID
            else { continue }

            let outcome: RestoreOutcome
            switch withDeviceInterface182(
                service: service,
                body: { device, vtable in
                    let session = IOKitUSBConfigDeviceSession(
                        registryEntryID: entryID, service: service, device: device, vtable: vtable)
                    return switchLedger.restore(registryEntryID: entryID, session: session)
                })
            {
            case .ok(let result):
                outcome = result
            case .resourceShortage, .unavailable:
                return .transientFailure
            }
            if outcome == .restored {
                log("restored USB configuration for entry 0x\(String(entryID, radix: 16))")
            }
            return outcome
        }

        // Enumeration succeeded and the kernel registry entry no longer exists.
        switchLedger.markDeviceDetached(registryEntryID: registryEntryID)
        return .deviceDetached
    }

    private static func intProperty(of service: io_service_t, key: String) -> Int? {
        guard
            let prop = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (prop as? NSNumber)?.intValue
    }

    private static func boolProperty(of service: io_service_t, key: String) -> Bool {
        guard
            let prop = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return false }
        return (prop as? NSNumber)?.boolValue ?? false
    }

    private static func stringProperty(of service: io_service_t, key: String) -> String? {
        guard
            let prop = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return prop as? String
    }

    private static func inspectHostAndDeviceNetworkEnvironment(
        of service: io_service_t
    ) -> (bsdState: DeviceBSDNetworkState, routes: HostNetworkRouteSnapshot?) {
        guard let store = SCDynamicStoreCreate(nil, "iphone-use.usb-valeria" as CFString, nil, nil) else {
            return (.unknown, nil)
        }
        let globalIPv4 =
            SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let globalIPv6 =
            SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]

        guard
            let keys = SCDynamicStoreCopyKeyList(
                store, "State:/Network/Service/[^/]+/IPv[46]" as CFString) as? [String]
        else {
            return (.unknown, nil)
        }
        var servicesIPv4: [String: [String: Any]] = [:]
        var servicesIPv6: [String: [String: Any]] = [:]
        for key in keys {
            let parts = key.split(separator: "/")
            guard parts.count == 5,
                let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
            else {
                return (.unknown, nil)
            }
            let serviceID = String(parts[3])
            if parts[4] == "IPv4" {
                servicesIPv4[serviceID] = dict
            } else if parts[4] == "IPv6" {
                servicesIPv6[serviceID] = dict
            }
        }
        let routes = parseHostNetworkRoutes(
            globalIPv4: globalIPv4,
            globalIPv6: globalIPv6,
            servicesIPv4: servicesIPv4,
            servicesIPv6: servicesIPv6)

        var firstIfaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstIfaddr) == 0 else {
            return (.unknown, routes)
        }
        defer {
            if let firstIfaddr {
                freeifaddrs(firstIfaddr)
            }
        }

        var hasIPv4: Set<String> = []
        var hasNonLinkLocalIPv6: Set<String> = []
        var hasAnyIPv6: Set<String> = []
        var cursor = firstIfaddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let namePtr = current.pointee.ifa_name,
                let sa = current.pointee.ifa_addr
            else { continue }
            let ifName = String(cString: namePtr)
            let family = Int32(sa.pointee.sa_family)
            if family == AF_INET {
                hasIPv4.insert(ifName)
            } else if family == AF_INET6 {
                hasAnyIPv6.insert(ifName)
                guard Int(sa.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { continue }
                var sin6 = UnsafeRawBufferPointer(
                    start: sa, count: MemoryLayout<sockaddr_in6>.size
                ).loadUnaligned(as: sockaddr_in6.self)
                let bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                if isGlobalOrULAIPv6Bytes(bytes) {
                    hasNonLinkLocalIPv6.insert(ifName)
                }
            }
        }

        var iterator: io_iterator_t = 0
        let kr = IORegistryEntryCreateIterator(
            service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
        guard kr == KERN_SUCCESS else {
            return (.unknown, routes)
        }
        defer { IOObjectRelease(iterator) }

        var byName: [String: (isRestricted: Bool, ioLinkActiveCount: Int?)] = [:]
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let rawName = stringProperty(of: entry, key: "BSD Name") else { continue }
            let bsdName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bsdName.isEmpty else { continue }
            let isRestricted =
                IOObjectConformsTo(entry, "AppleUSBHostNCMRestrictedEthernetInterface") != 0
            let linkCount = intProperty(of: entry, key: "IOLinkActiveCount")
            if let existing = byName[bsdName] {
                let mergedLinkCount: Int?
                if let a = existing.ioLinkActiveCount, let b = linkCount {
                    mergedLinkCount = max(a, b)
                } else {
                    mergedLinkCount = existing.ioLinkActiveCount ?? linkCount
                }
                byName[bsdName] = (
                    isRestricted: existing.isRestricted && isRestricted,
                    ioLinkActiveCount: mergedLinkCount
                )
            } else {
                byName[bsdName] = (isRestricted: isRestricted, ioLinkActiveCount: linkCount)
            }
        }

        let observed: [ObservedBSDInterface] = byName.keys.sorted().map { bsdName in
            let meta = byName[bsdName]!
            let linkDict =
                SCDynamicStoreCopyValue(
                    store, "State:/Network/Interface/\(bsdName)/Link" as CFString) as? [String: Any]
            let storeLinkActive = (linkDict?["Active"] as? NSNumber)?.boolValue
            return ObservedBSDInterface(
                name: bsdName,
                isAppleRestrictedInternal: meta.isRestricted,
                ioLinkActiveCount: meta.ioLinkActiveCount,
                storeLinkActive: storeLinkActive,
                hasIPv4Address: hasIPv4.contains(bsdName),
                hasNonLinkLocalIPv6Address: hasNonLinkLocalIPv6.contains(bsdName),
                hasAnyIPv6Address: hasAnyIPv6.contains(bsdName))
        }

        let bsdState = classifyDeviceBSDInterfaces(
            observed: observed,
            servicesIPv4: servicesIPv4,
            servicesIPv6: servicesIPv6)
        return (bsdState, routes)
    }

    private enum DeviceInterfaceResult<T> {
        case ok(T)
        case resourceShortage
        case unavailable
    }

    private static func withDeviceInterface182<T>(
        service: io_service_t,
        body: (UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface182>?>, IOUSBDeviceInterface182) -> T
    ) -> DeviceInterfaceResult<T> {
        let userClientUUID = CFUUIDGetConstantUUIDWithBytes(
            nil,
            0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
            0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
        let plugInUUID = CFUUIDGetConstantUUIDWithBytes(
            nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        let b = deviceInterfaceID182Bytes
        let deviceInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(
            nil,
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])

        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let plugInStatus = IOCreatePlugInInterfaceForService(
            service, userClientUUID, plugInUUID, &plugIn, &score)
        if plugInStatus == kIOReturnNoResources {
            return .resourceShortage
        }
        guard plugInStatus == KERN_SUCCESS, let plugIn else {
            return .unavailable
        }
        defer { _ = plugIn.pointee?.pointee.Release(plugIn) }

        var rawDevice: UnsafeMutableRawPointer?
        let queryResult = withUnsafeMutablePointer(to: &rawDevice) { rawPtr in
            plugIn.pointee?.pointee.QueryInterface(
                plugIn, CFUUIDGetUUIDBytes(deviceInterfaceUUID), rawPtr)
        }
        guard queryResult == S_OK, let rawDevice else { return .unavailable }
        let device = rawDevice.assumingMemoryBound(
            to: UnsafeMutablePointer<IOUSBDeviceInterface182>?.self)
        defer { _ = device.pointee?.pointee.Release(device) }
        guard let vtable = device.pointee?.pointee else { return .unavailable }
        return .ok(body(device, vtable))
    }

    fileprivate static func openDeviceSafely(
        service: io_service_t,
        device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface182>?>,
        vtable: IOUSBDeviceInterface182
    ) -> Bool {
        let openResult = vtable.USBDeviceOpen(device)
        if openResult == kIOReturnSuccess {
            return true
        }
        guard openResult == kIOReturnExclusiveAccess else { return false }
        let owner = stringProperty(of: service, key: "UsbExclusiveOwner")
        guard canSeizeExclusiveDevice(exclusiveOwner: owner) else {
            log("skipping USB Valeria activation: device held by exclusive owner \(owner ?? "unknown")")
            return false
        }
        return vtable.USBDeviceOpenSeize(device) == kIOReturnSuccess
    }

    private static func parseInterfaceClasses(_ configPtr: IOUSBConfigurationDescriptorPtr) -> [UInt8]? {
        let header = configPtr.pointee
        let totalLength = Int(UInt16(littleEndian: header.wTotalLength))
        guard totalLength >= Int(header.bLength), totalLength <= 4096 else { return nil }
        let raw = UnsafeRawBufferPointer(start: configPtr, count: totalLength)
        return parseInterfaceClassesFromRawDescriptor(
            raw,
            expectedTotalLength: totalLength,
            expectedNumInterfaces: Int(header.bNumInterfaces))
    }

    private static func activateDormantValeriaOnServiceLocked(
        service: io_service_t,
        shouldProceed: () -> Bool
    ) -> ActivationOutcome {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            return .notActivated
        }
        let result = withDeviceInterface182(service: service) { device, vtable -> ActivationOutcome in
            var numConfigs: UInt8 = 0
            guard vtable.GetNumberOfConfigurations(device, &numConfigs) == kIOReturnSuccess,
                numConfigs > 1
            else { return .notActivated }

            var descriptors: [ConfigurationDescriptorInfo] = []
            descriptors.reserveCapacity(Int(numConfigs))
            for index in 0..<numConfigs {
                var configPtr: IOUSBConfigurationDescriptorPtr?
                guard vtable.GetConfigurationDescriptorPtr(device, index, &configPtr) == kIOReturnSuccess,
                    let configPtr
                else { return .notActivated }
                let config = configPtr.pointee
                let name: String?
                let nameReadSucceeded: Bool
                if config.iConfiguration != 0 {
                    if let readName = readUSBStringDescriptor(
                        device: device, vtable: vtable, index: config.iConfiguration)
                    {
                        name = readName
                        nameReadSucceeded = true
                    } else {
                        name = nil
                        nameReadSucceeded = false
                    }
                } else {
                    name = nil
                    nameReadSucceeded = true
                }
                let classes = parseInterfaceClasses(configPtr)
                descriptors.append(
                    ConfigurationDescriptorInfo(
                        value: config.bConfigurationValue,
                        name: name,
                        nameReadSucceeded: nameReadSucceeded,
                        interfaceClasses: classes))
            }

            let allowTetherPreemption =
                ProcessInfo.processInfo.environment["IPHONE_USE_ALLOW_USB_TETHER_PREEMPTION"] == "1"
            let session = IOKitUSBConfigDeviceSession(
                registryEntryID: entryID, service: service, device: device, vtable: vtable)
            let outcome = switchLedger.activate(
                session: session,
                descriptors: descriptors,
                allowPrimaryNetworkPreemption: allowTetherPreemption,
                inspectEnvironment: {
                    inspectHostAndDeviceNetworkEnvironment(of: service)
                },
                shouldProceed: shouldProceed)
            switch outcome {
            case .switched(let record):
                log(
                    "activated USB Valeria configuration \(record.requestedConfiguration) (was \(record.previousConfiguration))"
                )
            case .unconfirmedSwitch(let record):
                log(
                    "USB Valeria configuration \(record.requestedConfiguration) set without confirmed readback (was \(record.previousConfiguration))"
                )
            case .blockedByActiveUSBNetwork:
                log("skipping USB Valeria activation: iPhone USB network is protected by active route policy")
            case .blockedByUSBResourceShortage, .notActivated:
                break
            }
            return outcome
        }
        switch result {
        case .ok(let outcome):
            return outcome
        case .resourceShortage:
            log(
                "USB Valeria activation failed: IOCreatePlugInInterfaceForService returned kIOReturnNoResources (0xE00002BE)"
            )
            return .blockedByUSBResourceShortage
        case .unavailable:
            return .notActivated
        }
    }

    private static func readUSBStringDescriptor(
        device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface182>?>,
        vtable: IOUSBDeviceInterface182,
        index: UInt8
    ) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        var transferred: UInt32 = 0
        let status: IOReturn = buffer.withUnsafeMutableBytes { raw in
            var request = IOUSBDevRequest(
                bmRequestType: 0x80,
                bRequest: UInt8(kUSBRqGetDescriptor),
                wValue: (UInt16(kUSBStringDesc) << 8) | UInt16(index),
                wIndex: 0x0409,
                wLength: UInt16(raw.count),
                pData: raw.baseAddress,
                wLenDone: 0)
            let result = vtable.DeviceRequest(device, &request)
            transferred = request.wLenDone
            return result
        }
        guard status == kIOReturnSuccess else { return nil }
        let available = min(Int(transferred), buffer.count)
        guard available >= 2 else { return nil }
        let totalLength = min(Int(buffer[0]), available)
        guard totalLength >= 2, buffer[1] == UInt8(kUSBStringDesc) else {
            return nil
        }
        let payloadCount = (totalLength - 2) & ~1
        guard payloadCount > 0 else { return nil }
        let payload = Data(buffer[2..<(2 + payloadCount)])
        return String(data: payload, encoding: .utf16LittleEndian)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }
}

/// Injectable USB device configuration operations shared by production IOKit `182`
/// interfaces and deterministic failure-injection tests.
protocol USBConfigDeviceSession {
    var registryEntryID: UInt64 { get }
    func getConfiguration() -> UInt8?
    func openSafely() -> Bool
    func close()
    func setConfiguration(_ value: UInt8) -> Bool
}

private struct IOKitUSBConfigDeviceSession: USBConfigDeviceSession {
    let registryEntryID: UInt64
    let service: io_service_t
    let device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface182>?>
    let vtable: IOUSBDeviceInterface182

    func getConfiguration() -> UInt8? {
        var current: UInt8 = 0
        guard vtable.GetConfiguration(device, &current) == kIOReturnSuccess else { return nil }
        return current
    }

    func openSafely() -> Bool {
        USBValeriaConfigurator.openDeviceSafely(service: service, device: device, vtable: vtable)
    }

    func close() {
        _ = vtable.USBDeviceClose(device)
    }

    func setConfiguration(_ value: UInt8) -> Bool {
        vtable.SetConfiguration(device, value) == kIOReturnSuccess
    }
}

/// Tracks every USB configuration switch applied by this process so failed post-set
/// readbacks and transient restore errors never lose the original configuration, while
/// refusing to overwrite any third configuration later selected by an external actor.
struct USBSwitchLedger {
    private(set) var entries: [UInt64: USBValeriaConfigurator.ActivatedSwitch] = [:]

    var trackedEntryIDs: [UInt64] {
        Array(entries.keys)
    }

    func entry(for registryEntryID: UInt64) -> USBValeriaConfigurator.ActivatedSwitch? {
        entries[registryEntryID]
    }

    mutating func markDeviceDetached(registryEntryID: UInt64) {
        entries[registryEntryID] = nil
    }

    mutating func activate(
        session: USBConfigDeviceSession,
        descriptors: [USBValeriaConfigurator.ConfigurationDescriptorInfo],
        allowPrimaryNetworkPreemption: Bool,
        inspectEnvironment: () -> (
            bsdState: USBValeriaConfigurator.DeviceBSDNetworkState,
            routes: USBValeriaConfigurator.HostNetworkRouteSnapshot?
        ),
        shouldProceed: () -> Bool
    ) -> USBValeriaConfigurator.ActivationOutcome {
        guard let initialConfig = session.getConfiguration(),
            let precheckCurrent = descriptors.first(where: { $0.value == initialConfig }),
            let precheckTarget = USBValeriaConfigurator.dormantValeriaConfiguration(
                currentConfiguration: initialConfig, configurations: descriptors)
        else { return .notActivated }

        let initialEnv = inspectEnvironment()
        guard
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: precheckCurrent,
                target: precheckTarget,
                deviceBSDState: initialEnv.bsdState,
                routes: initialEnv.routes,
                allowPrimaryNetworkPreemption: allowPrimaryNetworkPreemption)
        else { return .blockedByActiveUSBNetwork }

        guard shouldProceed(), session.openSafely() else { return .notActivated }
        defer { session.close() }

        guard let activeConfig = session.getConfiguration(),
            let activeInfo = descriptors.first(where: { $0.value == activeConfig }),
            let targetInfo = USBValeriaConfigurator.dormantValeriaConfiguration(
                currentConfiguration: activeConfig, configurations: descriptors)
        else { return .notActivated }

        let activeEnv = inspectEnvironment()
        guard
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: activeInfo,
                target: targetInfo,
                deviceBSDState: activeEnv.bsdState,
                routes: activeEnv.routes,
                allowPrimaryNetworkPreemption: allowPrimaryNetworkPreemption)
        else { return .blockedByActiveUSBNetwork }

        guard shouldProceed() else { return .notActivated }
        guard session.setConfiguration(targetInfo.value) else { return .notActivated }

        let baselinePrevious: UInt8
        if let existing = entries[session.registryEntryID],
            existing.requestedConfiguration == activeConfig
        {
            baselinePrevious = existing.previousConfiguration
        } else {
            baselinePrevious = activeConfig
        }

        let observed = session.getConfiguration()
        if observed == targetInfo.value {
            let record = USBValeriaConfigurator.ActivatedSwitch(
                registryEntryID: session.registryEntryID,
                previousConfiguration: baselinePrevious,
                requestedConfiguration: targetInfo.value,
                lastObservedConfiguration: observed,
                readbackConfirmed: true)
            entries[session.registryEntryID] = record
            return .switched(record)
        } else {
            let unconfirmed = USBValeriaConfigurator.ActivatedSwitch(
                registryEntryID: session.registryEntryID,
                previousConfiguration: baselinePrevious,
                requestedConfiguration: targetInfo.value,
                lastObservedConfiguration: observed,
                readbackConfirmed: false)
            entries[session.registryEntryID] = unconfirmed
            return .unconfirmedSwitch(unconfirmed)
        }
    }

    mutating func restore(
        registryEntryID: UInt64,
        session: USBConfigDeviceSession
    ) -> USBValeriaConfigurator.RestoreOutcome {
        guard var record = entries[registryEntryID] else { return .notTracked }
        guard let current = session.getConfiguration() else {
            return .transientFailure
        }
        record.lastObservedConfiguration = current
        if current == record.previousConfiguration {
            entries[registryEntryID] = nil
            return .alreadyRestored
        }
        if current != record.requestedConfiguration {
            entries[registryEntryID] = nil
            return .supersededByExternalChange
        }

        guard session.openSafely() else {
            entries[registryEntryID] = record
            return .transientFailure
        }
        defer { session.close() }

        guard let rechecked = session.getConfiguration() else {
            record.lastObservedConfiguration = nil
            entries[registryEntryID] = record
            return .transientFailure
        }
        record.lastObservedConfiguration = rechecked
        if rechecked == record.previousConfiguration {
            entries[registryEntryID] = nil
            return .alreadyRestored
        }
        if rechecked != record.requestedConfiguration {
            entries[registryEntryID] = nil
            return .supersededByExternalChange
        }

        guard session.setConfiguration(record.previousConfiguration) else {
            entries[registryEntryID] = record
            return .transientFailure
        }
        guard let confirmed = session.getConfiguration() else {
            record.lastObservedConfiguration = nil
            record.readbackConfirmed = false
            entries[registryEntryID] = record
            return .transientFailure
        }
        record.lastObservedConfiguration = confirmed
        if confirmed == record.previousConfiguration {
            entries[registryEntryID] = nil
            return .restored
        }
        if confirmed != record.requestedConfiguration {
            entries[registryEntryID] = nil
            return .supersededByExternalChange
        }
        record.readbackConfirmed = true
        entries[registryEntryID] = record
        return .transientFailure
    }
}
