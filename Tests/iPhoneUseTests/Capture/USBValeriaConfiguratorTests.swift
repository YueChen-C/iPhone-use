import CoreFoundation
import Foundation
import IOKit.usb
import IOKit.usb.IOUSBLib
import XCTest

@testable import iPhoneUse

final class USBValeriaConfiguratorTests: XCTestCase {
    func testDeviceInterfaceUUID182MatchesOfficialCFUUIDAndRejectsLegacyV100() throws {
        let cfUUID182 = try XCTUnwrap(
            CFUUIDCreateFromString(nil, "152FC496-4891-11D5-9D52-000A27801E86" as CFString))
        let raw = CFUUIDGetUUIDBytes(cfUUID182)
        let expected182Bytes: [UInt8] = [
            raw.byte0, raw.byte1, raw.byte2, raw.byte3,
            raw.byte4, raw.byte5, raw.byte6, raw.byte7,
            raw.byte8, raw.byte9, raw.byte10, raw.byte11,
            raw.byte12, raw.byte13, raw.byte14, raw.byte15,
        ]
        let legacyV100Bytes: [UInt8] = [
            0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
            0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61,
        ]
        XCTAssertEqual(USBValeriaConfigurator.deviceInterfaceID182Bytes, expected182Bytes)
        XCTAssertNotEqual(USBValeriaConfigurator.deviceInterfaceID182Bytes, legacyV100Bytes)
        XCTAssertLessThan(
            MemoryLayout<IOUSBDeviceInterface182>.size,
            MemoryLayout<IOUSBDeviceInterface>.size)
    }

    func testSelectsDormantValeriaConfigurationAndPrefersNetworkRetainingDescriptor() {
        let descriptors: [USBValeriaConfigurator.ConfigurationDescriptorInfo] = [
            .init(value: 1, name: "PTP", interfaceClasses: [0x06]),
            .init(
                value: 5,
                name: "PTP + Apple Mobile Device + Apple USB Ethernet",
                interfaceClasses: [0x02, 0x0A]),
            .init(
                value: 6,
                name: "PTP + Apple Mobile Device + Apple USB Ethernet + NCM",
                interfaceClasses: [0x02, 0x0A]),
            .init(
                value: 7,
                name: "PTP + Apple Mobile Device + Valeria",
                interfaceClasses: [0x06, 0xFF, 0xFF]),
        ]
        XCTAssertEqual(
            USBValeriaConfigurator.dormantValeriaConfigurationValue(
                currentConfiguration: 6, configurations: descriptors),
            7)

        let withNetworkValeria =
            descriptors + [
                .init(
                    value: 8,
                    name: "PTP + Apple Mobile Device + Apple USB Ethernet + Valeria",
                    interfaceClasses: [0x06, 0xFF, 0x02, 0x0A, 0xFF])
            ]
        XCTAssertEqual(
            USBValeriaConfigurator.dormantValeriaConfigurationValue(
                currentConfiguration: 6, configurations: withNetworkValeria),
            8)
    }

    func testDoesNotSwitchWhenValeriaIsAlreadyActiveOrUnavailable() {
        let withValeria: [USBValeriaConfigurator.ConfigurationDescriptorInfo] = [
            .init(value: 6, name: "PTP + Apple Mobile Device + Apple USB Ethernet + NCM"),
            .init(value: 7, name: "ptp + apple mobile device + valeria"),
        ]
        XCTAssertNil(
            USBValeriaConfigurator.dormantValeriaConfigurationValue(
                currentConfiguration: 7, configurations: withValeria))

        let withoutValeria: [USBValeriaConfigurator.ConfigurationDescriptorInfo] = [
            .init(value: 1, name: nil),
            .init(value: 6, name: "PTP + Apple Mobile Device + Apple USB Ethernet + NCM"),
        ]
        XCTAssertNil(
            USBValeriaConfigurator.dormantValeriaConfigurationValue(
                currentConfiguration: 6, configurations: withoutValeria))
    }

    func testSelectCandidateIndexRejectsNonIOSUnpluggedSerialsAndUnpinnedOpaqueSwaps() {
        let keyboard = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 10, vendorID: 0x05AC, supportsIPhoneOS: false, serial: nil)
        let phoneA = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 101, vendorID: 0x05AC, supportsIPhoneOS: true, serial: "00008150000000000000000A")
        let phoneAReenumerated = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 102, vendorID: 0x05AC, supportsIPhoneOS: true, serial: "00008150000000000000000A")
        let phoneB = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 202, vendorID: 0x05AC, supportsIPhoneOS: true, serial: "00008150000000000000000B")
        let pinnedA = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 101, serial: "00008150000000000000000A")

        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [keyboard], preferredSerial: nil, allowSingleIOSFallback: true))

        for realSerial in [
            "00008150-000000000000000A",
            "00008150000000000000000A",
            "0123456789abcdef0123456789abcdef01234567",
            "---",
        ] {
            XCTAssertNil(
                USBValeriaConfigurator.selectCandidateIndex(
                    devices: [phoneB],
                    preferredSerial: realSerial,
                    allowSingleIOSFallback: true,
                    pinnedSingleDevice: pinnedA),
                "unmatched serial \(realSerial) must not fall back to another phone")
        }

        let opaqueUUID = "11111111-2222-3333-4444-555555555555"
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [keyboard, phoneA],
                preferredSerial: opaqueUUID,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: nil))
        XCTAssertEqual(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [keyboard, phoneAReenumerated],
                preferredSerial: opaqueUUID,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinnedA),
            1)
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [keyboard, phoneB],
                preferredSerial: opaqueUUID,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinnedA))

        XCTAssertEqual(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneA, phoneB],
                preferredSerial: "00008150-000000000000000B",
                allowSingleIOSFallback: false),
            1)
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneA, phoneB],
                preferredSerial: opaqueUUID,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinnedA))
    }

    func testRawDescriptorParsingAndUnknownNetworkCapabilityFailClosed() {
        let validValeria = USBValeriaConfigurator.ConfigurationDescriptorInfo(
            value: 7,
            name: "PTP + Apple Mobile Device + Valeria",
            nameReadSucceeded: true,
            interfaceClasses: [0x06, 0xFF, 0xFF])
        let safeRoutes = USBValeriaConfigurator.HostNetworkRouteSnapshot(
            ipv4: .physicalPrimary("en0"), ipv6: .none)

        // Build a complete 2-interface descriptor (9-byte config header + two 9-byte interface descriptors = 27 bytes).
        let completeBytes: [UInt8] = [
            9, UInt8(kUSBConfDesc), 27, 0, 2, 3, 4, 0xC0, 0xFA,
            9, UInt8(kUSBInterfaceDesc), 0, 0, 3, 0x06, 1, 1, 0,
            9, UInt8(kUSBInterfaceDesc), 1, 0, 2, 0xFF, 0xFE, 2, 0,
        ]
        let parsedComplete = completeBytes.withUnsafeBytes {
            USBValeriaConfigurator.parseInterfaceClassesFromRawDescriptor(
                $0, expectedTotalLength: 27, expectedNumInterfaces: 2)
        }
        XCTAssertEqual(parsedComplete, [0x06, 0xFF])

        // Oversized (> 4096), truncated sub-descriptor, invalid sub-descriptor length (< 2),
        // and partial interface count (only 1 of 2 interfaces present) all return nil.
        completeBytes.withUnsafeBytes { raw in
            XCTAssertNil(
                USBValeriaConfigurator.parseInterfaceClassesFromRawDescriptor(
                    raw, expectedTotalLength: 5000, expectedNumInterfaces: 2))
            XCTAssertNil(
                USBValeriaConfigurator.parseInterfaceClassesFromRawDescriptor(
                    raw, expectedTotalLength: 22, expectedNumInterfaces: 2))
            XCTAssertNil(
                USBValeriaConfigurator.parseInterfaceClassesFromRawDescriptor(
                    raw, expectedTotalLength: 18, expectedNumInterfaces: 2))
        }
        let corruptSubDescriptor: [UInt8] = [
            9, UInt8(kUSBConfDesc), 11, 0, 1, 3, 4, 0xC0, 0xFA,
            1, UInt8(kUSBInterfaceDesc),
        ]
        corruptSubDescriptor.withUnsafeBytes { raw in
            XCTAssertNil(
                USBValeriaConfigurator.parseInterfaceClassesFromRawDescriptor(
                    raw, expectedTotalLength: 11, expectedNumInterfaces: 1))
        }

        // Unknown / unparsed / unnamed / name-read-failed current descriptors MUST fail closed.
        let unknownCurrentCases: [USBValeriaConfigurator.ConfigurationDescriptorInfo] = [
            .init(value: 3, name: nil, nameReadSucceeded: true, interfaceClasses: [0x06, 0xFF]),
            .init(value: 3, name: "", nameReadSucceeded: true, interfaceClasses: [0x06, 0xFF]),
            .init(value: 3, name: nil, nameReadSucceeded: false, interfaceClasses: [0x06, 0xFF]),
            .init(
                value: 3,
                name: "PTP + Apple Mobile Device",
                nameReadSucceeded: true,
                interfaceClasses: nil),
        ]
        for unknownCurrent in unknownCurrentCases {
            XCTAssertEqual(unknownCurrent.networkCapability, .unknown)
            XCTAssertFalse(
                USBValeriaConfigurator.permitsConfigurationSwitch(
                    current: unknownCurrent,
                    target: validValeria,
                    deviceBSDState: .inspected(activeHostInterfaces: ["en8"]),
                    routes: safeRoutes,
                    allowPrimaryNetworkPreemption: false))
        }

        let provenNonNetworkCurrent = USBValeriaConfigurator.ConfigurationDescriptorInfo(
            value: 3,
            name: "PTP + Apple Mobile Device",
            nameReadSucceeded: true,
            interfaceClasses: parsedComplete)
        XCTAssertEqual(provenNonNetworkCurrent.networkCapability, .noNetwork)
        XCTAssertTrue(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: provenNonNetworkCurrent,
                target: validValeria,
                deviceBSDState: .unknown,
                routes: nil,
                allowPrimaryNetworkPreemption: false))
    }

    func testExclusiveOwnerAndDualStackLinkLocalAndTunnelRouteProtection() {
        XCTAssertTrue(USBValeriaConfigurator.canSeizeExclusiveDevice(exclusiveOwner: nil))
        XCTAssertTrue(USBValeriaConfigurator.canSeizeExclusiveDevice(exclusiveOwner: ""))
        XCTAssertTrue(
            USBValeriaConfigurator.canSeizeExclusiveDevice(
                exclusiveOwner: "AppleUSBHostCompositeDevice"))
        XCTAssertTrue(
            USBValeriaConfigurator.canSeizeExclusiveDevice(
                exclusiveOwner: "AppleUSBHostiOSDevice"))
        XCTAssertFalse(
            USBValeriaConfigurator.canSeizeExclusiveDevice(exclusiveOwner: "pid 412, Xcode"))
        XCTAssertFalse(
            USBValeriaConfigurator.canSeizeExclusiveDevice(exclusiveOwner: "ThirdPartyUSBDriver"))

        let tetherCurrent = USBValeriaConfigurator.ConfigurationDescriptorInfo(
            value: 6,
            name: "PTP + Apple Mobile Device + Apple USB Ethernet + NCM",
            interfaceClasses: [0x06, 0xFF, 0x02, 0x0A])
        let valeriaTarget = USBValeriaConfigurator.ConfigurationDescriptorInfo(
            value: 7,
            name: "PTP + Apple Mobile Device + Valeria",
            interfaceClasses: [0x06, 0xFF, 0xFF])
        let activeUSBEn8: USBValeriaConfigurator.DeviceBSDNetworkState = .inspected(
            activeHostInterfaces: ["en8"])

        // 1. Dual-stack with split primary: IPv4 on Wi-Fi en0, IPv6 on iPhone USB en8 -> MUST refuse!
        let dualStackSplitRoutes = USBValeriaConfigurator.parseHostNetworkRoutes(
            globalIPv4: ["PrimaryInterface": "en0", "PrimaryService": "wifi"],
            globalIPv6: ["PrimaryInterface": "en8", "PrimaryService": "usb"],
            servicesIPv4: [
                "wifi": [
                    "InterfaceName": "en0",
                    "Addresses": ["192.0.2.10"],
                    "Router": "192.0.2.1",
                ]
            ],
            servicesIPv6: [
                "usb": [
                    "InterfaceName": "en8",
                    "Addresses": ["2001:db8:1234::2"],
                    "Router": "fe80::1",
                ]
            ])
        XCTAssertEqual(dualStackSplitRoutes.ipv4, .physicalPrimary("en0"))
        XCTAssertEqual(dualStackSplitRoutes.ipv6, .physicalPrimary("en8"))
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: activeUSBEn8,
                routes: dualStackSplitRoutes,
                allowPrimaryNetworkPreemption: false))

        // 2. Single-family default route: IPv6-only on en0 permits; IPv6-only on en8 refuses.
        let ipv6OnlyWiFi = USBValeriaConfigurator.parseHostNetworkRoutes(
            globalIPv4: nil,
            globalIPv6: ["PrimaryInterface": "en0", "PrimaryService": "wifi"],
            servicesIPv4: [:],
            servicesIPv6: [
                "wifi": [
                    "InterfaceName": "en0",
                    "Addresses": ["2001:db8:1234::9"],
                    "Router": "fe80::1",
                ]
            ])
        XCTAssertTrue(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: activeUSBEn8,
                routes: ipv6OnlyWiFi,
                allowPrimaryNetworkPreemption: false))

        let ipv6OnlyUSB = USBValeriaConfigurator.parseHostNetworkRoutes(
            globalIPv4: nil,
            globalIPv6: ["PrimaryInterface": "en8", "PrimaryService": "usb"],
            servicesIPv4: [:],
            servicesIPv6: [
                "usb": [
                    "InterfaceName": "en8",
                    "Addresses": ["2001:db8:1234::2"],
                    "Router": "fe80::1",
                ]
            ])
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: activeUSBEn8,
                routes: ipv6OnlyUSB,
                allowPrimaryNetworkPreemption: false))

        // 3. Link-local-only addresses (169.254.x.x or fe80::/10 without global/ULA address) fail closed.
        let linkLocalOnly = USBValeriaConfigurator.parseHostNetworkRoutes(
            globalIPv4: ["PrimaryInterface": "en0", "PrimaryService": "wifi"],
            globalIPv6: ["PrimaryInterface": "en0", "PrimaryService": "wifi"],
            servicesIPv4: [
                "wifi": [
                    "InterfaceName": "en0",
                    "Addresses": ["169.254.12.34"],
                    "Router": "169.254.0.1",
                ]
            ],
            servicesIPv6: [
                "wifi": [
                    "InterfaceName": "en0",
                    "Addresses": ["fe80::1234"],
                    "Router": "fe80::1",
                ]
            ])
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: activeUSBEn8,
                routes: linkLocalOnly,
                allowPrimaryNetworkPreemption: false))

        // 4. R4-P1-01: Virtual tunnel (utun4) NEVER uses ExcludedRoutes as proof of tunnel underlay.
        // LAN-only ExcludedRoutes pointing to en0, ExcludedRoutes entries missing InterfaceName,
        // and multi-interface hosts (en0 + en8) where tunnel outer socket may be scoped to en8
        // MUST all remain `.unresolvedPrimary` and refuse switching whenever en8 is active.
        let tunnelWithLANExclusionAndActiveUSB = USBValeriaConfigurator.parseHostNetworkRoutes(
            globalIPv4: ["PrimaryInterface": "utun4", "PrimaryService": "vpn"],
            globalIPv6: nil,
            servicesIPv4: [
                "vpn": [
                    "InterfaceName": "utun4",
                    "Addresses": ["198.18.0.1"],
                    "Router": "198.18.0.1",
                    "ExcludedRoutes": [
                        ["DestinationAddress": "192.0.2.0", "InterfaceName": "en0"]
                    ],
                ],
                "wifi": [
                    "ConfirmedInterfaceName": "en0",
                    "Addresses": ["192.0.2.10"],
                    "Router": "192.0.2.1",
                ],
                "usb": [
                    "InterfaceName": "en8",
                    "Addresses": ["198.51.100.2"],
                    "Router": "198.51.100.1",
                ],
            ],
            servicesIPv6: [
                "vpn": ["InterfaceName": "utun4", "Addresses": ["::1"], "Router": "::1", "IsNULL": 1]
            ])
        XCTAssertEqual(tunnelWithLANExclusionAndActiveUSB.ipv4, .unresolvedPrimary)
        XCTAssertEqual(tunnelWithLANExclusionAndActiveUSB.ipv6, .none)
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: activeUSBEn8,
                routes: tunnelWithLANExclusionAndActiveUSB,
                allowPrimaryNetworkPreemption: false))

        let tunnelMissingExclusionInterfaceName = USBValeriaConfigurator.parseHostNetworkRoutes(
            globalIPv4: ["PrimaryInterface": "utun4", "PrimaryService": "vpn"],
            globalIPv6: nil,
            servicesIPv4: [
                "vpn": [
                    "InterfaceName": "utun4",
                    "Addresses": ["198.18.0.1"],
                    "Router": "198.18.0.1",
                    "ExcludedRoutes": [
                        ["DestinationAddress": "192.0.2.0", "InterfaceName": "en0"],
                        ["DestinationAddress": "203.0.113.9"],
                    ],
                ],
                "wifi": [
                    "InterfaceName": "en0",
                    "Addresses": ["192.0.2.10"],
                    "Router": "192.0.2.1",
                ],
            ],
            servicesIPv6: [:])
        XCTAssertEqual(tunnelMissingExclusionInterfaceName.ipv4, .unresolvedPrimary)
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: activeUSBEn8,
                routes: tunnelMissingExclusionInterfaceName,
                allowPrimaryNetworkPreemption: false))

        // 5. Device BSD classification:
        // - Inactive en8 (carrier inactive, zero IP addresses, zero service references) + Apple's
        //   kernel-restricted `anri0` (fe80:: link-local only, zero service references) -> no active
        //   host network interfaces on the device, permitting Valeria under valid host routes while
        //   STILL failing closed if routes == nil.
        // - As soon as en8 has carrier/IP/service (e.g. scoped tunnel socket over en8 without an
        //   SCDynamicStore service), or carrier metadata is missing, it fails closed under utun4.
        let inactiveHotspotState = USBValeriaConfigurator.classifyDeviceBSDInterfaces(
            observed: [
                .init(
                    name: "anri0",
                    isAppleRestrictedInternal: true,
                    ioLinkActiveCount: 1,
                    storeLinkActive: true,
                    hasIPv4Address: false,
                    hasNonLinkLocalIPv6Address: false,
                    hasAnyIPv6Address: true),
                .init(
                    name: "en8",
                    isAppleRestrictedInternal: false,
                    ioLinkActiveCount: 0,
                    storeLinkActive: false,
                    hasIPv4Address: false,
                    hasNonLinkLocalIPv6Address: false,
                    hasAnyIPv6Address: false),
            ],
            servicesIPv4: [
                "vpn": ["InterfaceName": "utun4", "Addresses": ["198.18.0.1"], "Router": "198.18.0.1"],
                "wifi": ["InterfaceName": "en0", "Addresses": ["192.0.2.10"], "Router": "192.0.2.1"],
            ],
            servicesIPv6: [:])
        XCTAssertEqual(inactiveHotspotState, .inspected(activeHostInterfaces: []))
        XCTAssertTrue(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: inactiveHotspotState,
                routes: tunnelMissingExclusionInterfaceName,
                allowPrimaryNetworkPreemption: false))
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: inactiveHotspotState,
                routes: nil,
                allowPrimaryNetworkPreemption: false))

        // Scoped USB interface active at carrier/IP layer even without SCDynamicStore service entry -> refuses under utun4!
        let scopedCarrierOnlyUSBState = USBValeriaConfigurator.classifyDeviceBSDInterfaces(
            observed: [
                .init(
                    name: "en8",
                    isAppleRestrictedInternal: false,
                    ioLinkActiveCount: 1,
                    storeLinkActive: nil,
                    hasIPv4Address: false,
                    hasNonLinkLocalIPv6Address: false,
                    hasAnyIPv6Address: false)
            ],
            servicesIPv4: [:],
            servicesIPv6: [:])
        XCTAssertEqual(scopedCarrierOnlyUSBState, .inspected(activeHostInterfaces: ["en8"]))
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: scopedCarrierOnlyUSBState,
                routes: tunnelMissingExclusionInterfaceName,
                allowPrimaryNetworkPreemption: false))

        // Missing carrier metadata on non-restricted en8 or nil observed list -> `.unknown` -> refuses!
        let missingCarrierMetadataState = USBValeriaConfigurator.classifyDeviceBSDInterfaces(
            observed: [
                .init(
                    name: "en8",
                    isAppleRestrictedInternal: false,
                    ioLinkActiveCount: nil,
                    storeLinkActive: nil,
                    hasIPv4Address: false,
                    hasNonLinkLocalIPv6Address: false,
                    hasAnyIPv6Address: false)
            ],
            servicesIPv4: [:],
            servicesIPv6: [:])
        XCTAssertEqual(missingCarrierMetadataState, .unknown)
        XCTAssertFalse(
            USBValeriaConfigurator.permitsConfigurationSwitch(
                current: tetherCurrent,
                target: valeriaTarget,
                deviceBSDState: missingCarrierMetadataState,
                routes: ipv6OnlyWiFi,
                allowPrimaryNetworkPreemption: false))
    }

    func testSwitchLedgerRecordsUnconfirmedSetRetainsTransientFailuresAndNeverOverwritesExternalConfig() {
        let descriptors: [USBValeriaConfigurator.ConfigurationDescriptorInfo] = [
            .init(
                value: 6,
                name: "PTP + Apple Mobile Device + Apple USB Ethernet + NCM",
                interfaceClasses: [0x06, 0xFF, 0x02, 0x0A]),
            .init(
                value: 7,
                name: "PTP + Apple Mobile Device + Valeria",
                interfaceClasses: [0x06, 0xFF, 0xFF]),
        ]
        let safeRoutes = USBValeriaConfigurator.HostNetworkRouteSnapshot(
            ipv4: .physicalPrimary("en0"), ipv6: .none)
        let activeEn8: USBValeriaConfigurator.DeviceBSDNetworkState = .inspected(
            activeHostInterfaces: ["en8"])

        var ledger = USBSwitchLedger()
        let session = MockUSBConfigDeviceSession(registryEntryID: 901, initialConfiguration: 6)
        // Simulate SetConfiguration(7) succeeding while post-set GetConfiguration readback fails (nil).
        session.failNextPostSetReadback = true
        let outcome = ledger.activate(
            session: session,
            descriptors: descriptors,
            allowPrimaryNetworkPreemption: false,
            inspectEnvironment: { (activeEn8, safeRoutes) },
            shouldProceed: { true })
        XCTAssertEqual(
            outcome,
            .unconfirmedSwitch(
                .init(
                    registryEntryID: 901,
                    previousConfiguration: 6,
                    requestedConfiguration: 7,
                    lastObservedConfiguration: nil,
                    readbackConfirmed: false)))
        XCTAssertEqual(ledger.entry(for: 901)?.previousConfiguration, 6)
        XCTAssertEqual(session.setHistory, [7])

        // 1. Transient open failure keeps record in ledger.
        session.openResults = [false]
        XCTAssertEqual(ledger.restore(registryEntryID: 901, session: session), .transientFailure)
        XCTAssertNotNil(ledger.entry(for: 901))

        // 2. Transient SetConfiguration failure keeps record in ledger.
        session.setResults = [false]
        XCTAssertEqual(ledger.restore(registryEntryID: 901, session: session), .transientFailure)
        XCTAssertNotNil(ledger.entry(for: 901))

        // 3. Post-restore readback still reporting our requested config (7) keeps record for retry.
        session.overrideNextPostSetReadbackValue = 7
        XCTAssertEqual(ledger.restore(registryEntryID: 901, session: session), .transientFailure)
        XCTAssertNotNil(ledger.entry(for: 901))

        // 4. Subsequent clean restore succeeds and removes ledger entry.
        XCTAssertEqual(ledger.restore(registryEntryID: 901, session: session), .restored)
        XCTAssertEqual(session.currentConfiguration, 6)
        XCTAssertNil(ledger.entry(for: 901))

        // 5. Confirmed switch superseded externally (changed to config 3) is cleared with ZERO restore writes.
        let session2 = MockUSBConfigDeviceSession(registryEntryID: 902, initialConfiguration: 6)
        let confirmed = ledger.activate(
            session: session2,
            descriptors: descriptors,
            allowPrimaryNetworkPreemption: false,
            inspectEnvironment: { (activeEn8, safeRoutes) },
            shouldProceed: { true })
        XCTAssertEqual(
            confirmed,
            .switched(
                .init(
                    registryEntryID: 902,
                    previousConfiguration: 6,
                    requestedConfiguration: 7,
                    lastObservedConfiguration: 7,
                    readbackConfirmed: true)))
        session2.currentConfiguration = 3
        let writesBeforeConfirmedSupersede = session2.setHistory.count
        XCTAssertEqual(
            ledger.restore(registryEntryID: 902, session: session2),
            .supersededByExternalChange)
        XCTAssertEqual(session2.setHistory.count, writesBeforeConfirmedSupersede)
        XCTAssertEqual(session2.currentConfiguration, 3)
        XCTAssertNil(ledger.entry(for: 902))

        // 6. R4-P2-01(a): Unconfirmed activation (6 -> 7, readback nil) followed by external set(3)
        // BEFORE restore open MUST perform ZERO writes and preserve external configuration 3.
        let session3 = MockUSBConfigDeviceSession(registryEntryID: 903, initialConfiguration: 6)
        session3.failNextPostSetReadback = true
        _ = ledger.activate(
            session: session3,
            descriptors: descriptors,
            allowPrimaryNetworkPreemption: false,
            inspectEnvironment: { (activeEn8, safeRoutes) },
            shouldProceed: { true })
        XCTAssertEqual(ledger.entry(for: 903)?.readbackConfirmed, false)
        session3.currentConfiguration = 3
        let writesBeforePreOpenSupersede = session3.setHistory.count
        XCTAssertEqual(
            ledger.restore(registryEntryID: 903, session: session3),
            .supersededByExternalChange)
        XCTAssertEqual(session3.setHistory.count, writesBeforePreOpenSupersede)
        XCTAssertEqual(session3.currentConfiguration, 3)
        XCTAssertNil(ledger.entry(for: 903))

        // 7. R4-P2-01(b): Unconfirmed activation (6 -> 7, readback nil) where pre-open readback still
        // sees 7, and an external actor changes configuration to 3 BEFORE post-open recheck ->
        // MUST perform ZERO restore writes and preserve external configuration 3.
        let session4 = MockUSBConfigDeviceSession(registryEntryID: 904, initialConfiguration: 6)
        session4.failNextPostSetReadback = true
        _ = ledger.activate(
            session: session4,
            descriptors: descriptors,
            allowPrimaryNetworkPreemption: false,
            inspectEnvironment: { (activeEn8, safeRoutes) },
            shouldProceed: { true })
        session4.onOpenSafely = { session4.currentConfiguration = 3 }
        let writesBeforePostOpenSupersede = session4.setHistory.count
        XCTAssertEqual(
            ledger.restore(registryEntryID: 904, session: session4),
            .supersededByExternalChange)
        XCTAssertEqual(session4.setHistory.count, writesBeforePostOpenSupersede)
        XCTAssertEqual(session4.currentConfiguration, 3)
        XCTAssertNil(ledger.entry(for: 904))

        // 8. R4-P2-01(c): Post-restore readback observes a third configuration (3) -> MUST NOT
        // claim 3 as owned by this process, clears entry, and subsequent restore performs ZERO writes.
        let session5 = MockUSBConfigDeviceSession(registryEntryID: 905, initialConfiguration: 6)
        _ = ledger.activate(
            session: session5,
            descriptors: descriptors,
            allowPrimaryNetworkPreemption: false,
            inspectEnvironment: { (activeEn8, safeRoutes) },
            shouldProceed: { true })
        session5.overrideNextPostSetReadbackValue = 3
        XCTAssertEqual(
            ledger.restore(registryEntryID: 905, session: session5),
            .supersededByExternalChange)
        XCTAssertEqual(session5.currentConfiguration, 3)
        XCTAssertNil(ledger.entry(for: 905))
        let writesAfterPostRestoreConflict = session5.setHistory.count
        XCTAssertEqual(ledger.restore(registryEntryID: 905, session: session5), .notTracked)
        XCTAssertEqual(session5.setHistory.count, writesAfterPostRestoreConflict)
        XCTAssertEqual(session5.currentConfiguration, 3)
    }

    func testTransientMultiDeviceRestoreFailureDoesNotLoopOnUnchangedRefreshAndSupersedingTokenWins() {
        let descriptors: [USBValeriaConfigurator.ConfigurationDescriptorInfo] = [
            .init(
                value: 6,
                name: "PTP + Apple Mobile Device + Apple USB Ethernet + NCM",
                interfaceClasses: [0x06, 0xFF, 0x02, 0x0A]),
            .init(
                value: 7,
                name: "PTP + Apple Mobile Device + Valeria",
                interfaceClasses: [0x06, 0xFF, 0xFF]),
        ]
        let safeRoutes = USBValeriaConfigurator.HostNetworkRouteSnapshot(
            ipv4: .physicalPrimary("en0"), ipv6: .none)
        let inactiveUSB: USBValeriaConfigurator.DeviceBSDNetworkState = .inspected(
            activeHostInterfaces: [])

        let queue = DispatchQueue(label: "valeria-test.r8-p2-01.recovery")
        let host = MockValeriaRecoveryHost(queue: queue)
        let sourceA = MockValeriaRecoverySource(
            id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            pinnedUSBDevice: .init(registryEntryID: 771, serial: nil))
        let sourceB = MockValeriaRecoverySource(
            id: "11111111-2222-3333-4444-555555555555",
            pinnedUSBDevice: .init(registryEntryID: 772, serial: nil))
        let sourceC = MockValeriaRecoverySource(
            id: "22222222-3333-4444-5555-666666666666",
            pinnedUSBDevice: .init(registryEntryID: 773, serial: nil))

        let ledgerLock = NSLock()
        var ledger = USBSwitchLedger()
        let session = MockUSBConfigDeviceSession(registryEntryID: 771, initialConfiguration: 6)
        _ = ledgerLock.withLock {
            ledger.activate(
                session: session,
                descriptors: descriptors,
                allowPrimaryNetworkPreemption: false,
                inspectEnvironment: { (inactiveUSB, safeRoutes) },
                shouldProceed: { true })
        }
        XCTAssertEqual(session.currentConfiguration, 7)

        host.setSources([sourceA], verificationState: .singleDevice)
        host.recoveryLock.withLock {
            _ = host.withValeriaTrackerLocked {
                $0.begin(sourceInstanceID: sourceA.instanceID, restartRequested: false)
            }
            _ = host.withValeriaTrackerLocked {
                $0.finish(sourceInstanceID: sourceA.instanceID, switchedEntryID: 771)
            }
        }

        // Second device joins -> changed=true schedules 1 passive multi-device restore check.
        host.setSources([sourceA, sourceB], verificationState: .pending)
        let activeAB: [CaptureValeriaRecoveryTracker.RefreshSourceState] = [
            .init(id: sourceA.id, instanceID: sourceA.instanceID, hasFrame: false),
            .init(id: sourceB.id, instanceID: sourceB.instanceID, hasFrame: false),
        ]
        let firstReconcile = host.recoveryLock.withLock {
            host.withValeriaTrackerLocked {
                $0.reconcileAfterRefresh(
                    changed: true,
                    activeSources: activeAB,
                    discoveredDeviceCount: 2)
            }
        }
        XCTAssertEqual(firstReconcile.postSwitchChecks.count, 1)

        var restoreCallCount = 0
        let firstAttemptDone = expectation(description: "first transient multi-device restore attempt")
        session.setResults = [false]
        let restoreClosure: CaptureValeriaRecoveryCoordinator.USBRestorer = { entryID in
            ledgerLock.withLock {
                restoreCallCount += 1
                let outcome = ledger.restore(registryEntryID: entryID, session: session)
                if restoreCallCount == 1 {
                    firstAttemptDone.fulfill()
                }
                return outcome
            }
        }
        CaptureValeriaRecoveryCoordinator.applyRefreshPostSwitchChecks(
            host: host,
            checks: firstReconcile.postSwitchChecks,
            sourcesByID: [sourceA.id: sourceA, sourceB.id: sourceB],
            expectedLifecycle: 1,
            delay: 0.01,
            restoreUSB: restoreClosure)
        wait(for: [firstAttemptDone], timeout: 1.0)
        queue.sync {}

        // `.transientFailure` preserves ledger & activeSwitchEntryID, AND repeated 1Hz `changed == false`
        // refreshes (plus another device joining while already multi-device) schedule ZERO endless retries.
        XCTAssertEqual(ledgerLock.withLock { restoreCallCount }, 1)
        XCTAssertNotNil(ledgerLock.withLock { ledger.entry(for: 771) })
        XCTAssertEqual(
            host.recoveryLock.withLock {
                host.tracker.activeSwitchEntryID(for: sourceA.instanceID)
            },
            771)

        for _ in 0..<5 {
            let unchanged = host.recoveryLock.withLock {
                host.withValeriaTrackerLocked {
                    $0.reconcileAfterRefresh(
                        changed: false,
                        activeSources: activeAB,
                        discoveredDeviceCount: 2)
                }
            }
            XCTAssertTrue(unchanged.postSwitchChecks.isEmpty)
        }
        host.setSources([sourceA, sourceB, sourceC], verificationState: .pending)
        let activeABC: [CaptureValeriaRecoveryTracker.RefreshSourceState] =
            activeAB + [.init(id: sourceC.id, instanceID: sourceC.instanceID, hasFrame: false)]
        let stillMultiChanged = host.recoveryLock.withLock {
            host.withValeriaTrackerLocked {
                $0.reconcileAfterRefresh(
                    changed: true,
                    activeSources: activeABC,
                    discoveredDeviceCount: 3)
            }
        }
        XCTAssertTrue(stillMultiChanged.postSwitchChecks.isEmpty)
        XCTAssertEqual(ledgerLock.withLock { restoreCallCount }, 1)

        // Dropping back to single-device and re-entering multi-device allows 1 bounded retry (up to cap=2),
        // after which further flaps are capped without infinite loops.
        host.setSources([sourceA], verificationState: .singleDevice)
        _ = host.recoveryLock.withLock {
            host.withValeriaTrackerLocked {
                $0.reconcileAfterRefresh(
                    changed: true,
                    activeSources: [.init(id: sourceA.id, instanceID: sourceA.instanceID, hasFrame: false)],
                    discoveredDeviceCount: 1)
            }
        }
        host.setSources([sourceA, sourceB], verificationState: .pending)
        let secondEpisode = host.recoveryLock.withLock {
            host.withValeriaTrackerLocked {
                $0.reconcileAfterRefresh(
                    changed: true,
                    activeSources: activeAB,
                    discoveredDeviceCount: 2)
            }
        }
        XCTAssertEqual(secondEpisode.postSwitchChecks.count, 1)
        let secondAttemptDone = expectation(description: "second bounded passive restore attempt")
        session.setResults = [false]
        CaptureValeriaRecoveryCoordinator.applyRefreshPostSwitchChecks(
            host: host,
            checks: secondEpisode.postSwitchChecks,
            sourcesByID: [sourceA.id: sourceA, sourceB.id: sourceB],
            expectedLifecycle: 1,
            delay: 0.01,
            restoreUSB: { entryID in
                let outcome = restoreClosure(entryID)
                secondAttemptDone.fulfill()
                return outcome
            })
        wait(for: [secondAttemptDone], timeout: 1.0)
        queue.sync {}
        XCTAssertEqual(ledgerLock.withLock { restoreCallCount }, 2)

        // Third single -> multi flap hits `maxPassiveMultiDeviceRestoreChecks == 2` cap.
        host.setSources([sourceA], verificationState: .singleDevice)
        _ = host.recoveryLock.withLock {
            host.withValeriaTrackerLocked {
                $0.reconcileAfterRefresh(
                    changed: true,
                    activeSources: [.init(id: sourceA.id, instanceID: sourceA.instanceID, hasFrame: false)],
                    discoveredDeviceCount: 1)
            }
        }
        host.setSources([sourceA, sourceB], verificationState: .pending)
        let cappedEpisode = host.recoveryLock.withLock {
            host.withValeriaTrackerLocked {
                $0.reconcileAfterRefresh(
                    changed: true,
                    activeSources: activeAB,
                    discoveredDeviceCount: 2)
            }
        }
        XCTAssertTrue(cappedEpisode.postSwitchChecks.isEmpty)

        // Overlapping `supersedeExisting: true` tokens: an earlier shorter timer superseded by a
        // newer longer timer must NOT clear in-flight state or trigger an early restore; only the
        // latest token executes and cleanly restores configuration 6.
        let finalRestoreDone = expectation(description: "superseding token completes clean restore")
        CaptureValeriaRecoveryCoordinator.schedulePostSwitchRestoreIfNeeded(
            host: host,
            source: sourceA,
            trackedSwitchID: 771,
            expectedLifecycle: 1,
            delay: 0.02,
            supersedeExisting: true,
            restoreUSB: { entryID in
                XCTFail("superseded token must not invoke restoreUSB (\(entryID))")
                return .transientFailure
            })
        CaptureValeriaRecoveryCoordinator.schedulePostSwitchRestoreIfNeeded(
            host: host,
            source: sourceA,
            trackedSwitchID: 771,
            expectedLifecycle: 1,
            delay: 0.09,
            supersedeExisting: true,
            restoreUSB: { entryID in
                let outcome = restoreClosure(entryID)
                finalRestoreDone.fulfill()
                return outcome
            })

        let staleTimerPassed = expectation(description: "stale shorter timer elapsed without restore")
        queue.asyncAfter(deadline: .now() + 0.045) {
            staleTimerPassed.fulfill()
        }
        wait(for: [staleTimerPassed], timeout: 1.0)
        XCTAssertEqual(ledgerLock.withLock { restoreCallCount }, 2)

        wait(for: [finalRestoreDone], timeout: 1.0)
        queue.sync {}
        XCTAssertEqual(ledgerLock.withLock { restoreCallCount }, 3)
        XCTAssertEqual(session.currentConfiguration, 6)
        XCTAssertNil(ledgerLock.withLock { ledger.entry(for: 771) })
        XCTAssertNil(
            host.recoveryLock.withLock {
                host.tracker.activeSwitchEntryID(for: sourceA.instanceID)
            })
    }

    func testConcurrentDiscoveryPinResolutionUSBActivationAndStopCannotDeadlock() {
        let recoveryQueue = DispatchQueue(label: "valeria-test.lock-order.recovery")
        let usbQueue = DispatchQueue(label: "valeria-test.lock-order.usb")
        let discoveryQueue = DispatchQueue(label: "valeria-test.lock-order.discovery")
        let stopQueue = DispatchQueue(label: "valeria-test.lock-order.stop")
        let host = MockValeriaRecoveryHost(queue: recoveryQueue)
        let sourceA = MockValeriaRecoverySource(id: "00008150-000000000000000A")
        host.setSources([sourceA], verificationState: .singleDevice)

        let usbEntered = expectation(description: "activateUSB entered usbQueue")
        let releaseUSB = DispatchSemaphore(value: 0)
        var shouldProceedResult: Bool?

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: sourceA,
            restartSource: false,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, shouldProceed in
                usbQueue.sync {
                    usbEntered.fulfill()
                    releaseUSB.wait()
                    shouldProceedResult = shouldProceed()
                    return .notActivated
                }
            },
            restoreUSB: { _ in .notTracked })
        wait(for: [usbEntered], timeout: 1.0)

        // Start discovery AND bounded shutdown concurrently while usbQueue is occupied and about
        // to call shouldProceed() (acquiring recoveryLock). Because neither CaptureDiscoveryPinResolver
        // nor CaptureShutdownCoordinator holds recoveryLock while waiting on usbQueue, zero deadlock occurs.
        let discoveryStarted = expectation(description: "discovery entered prequery")
        let discoveryFinished = expectation(description: "discovery finished without deadlock")
        let stopFinished = expectation(description: "stop finished without deadlock")
        let opaqueIDB = "11111111-2222-3333-4444-555555555555"
        var capturedPin: USBValeriaConfigurator.PinnedUSBDevice?
        discoveryQueue.async {
            let pin = CaptureDiscoveryPinResolver.prequerySingleOpaqueDevicePin(
                discoveredIDs: [opaqueIDB],
                needsNewSourceForID: { id in
                    host.recoveryLock.withLock { !host.stopped && host.sources[id] == nil }
                },
                querySingleIOSDevice: {
                    discoveryStarted.fulfill()
                    return usbQueue.sync {
                        USBValeriaConfigurator.PinnedUSBDevice(
                            registryEntryID: 202, serial: "00008150000000000000000B")
                    }
                })
            capturedPin = pin?.pin
            discoveryFinished.fulfill()
        }
        wait(for: [discoveryStarted], timeout: 1.0)

        // Verify recoveryLock is NOT held while discovery waits on usbQueue, and run stop() concurrently
        // with a deterministic barrier before releasing usbQueue!
        XCTAssertFalse(host.recoveryLock.withLock { host.stopped })
        let stopEnteredUSBRestore = expectation(
            description: "stop drained capture and queued USB restore while usbQueue remained blocked")
        var stopResult: ScreenCaptureStopResult?
        stopQueue.async {
            host.stop()
            stopResult = CaptureShutdownCoordinator.stop(
                waitTimeout: 1.0,
                activeSources: [sourceA],
                notifyQueue: DispatchQueue(label: "valeria-test.lock-order.stop-notify"),
                restoreAllUSB: { _ in
                    stopEnteredUSBRestore.fulfill()
                    return usbQueue.sync { true }
                })
            stopFinished.fulfill()
        }
        wait(for: [stopEnteredUSBRestore], timeout: 1.0)

        releaseUSB.signal()
        wait(for: [discoveryFinished, stopFinished], timeout: 1.0)
        recoveryQueue.sync {}
        XCTAssertEqual(shouldProceedResult, false)
        XCTAssertEqual(
            capturedPin,
            .init(registryEntryID: 202, serial: "00008150000000000000000B"))
        XCTAssertEqual(
            stopResult,
            ScreenCaptureStopResult(initiated: true, captureDrained: true, usbRestored: true))
    }

    func testQueuedRecoveryPlanCancelsBeforeUSBMutationOnSwapTopologyStopOrGenerationChange() {
        enum InvalidationCase: CaseIterable {
            case swapSourceAToB
            case expandSingleToMulti
            case stopHost
            case advanceMultiDeviceGeneration
            case invalidateInsideShouldProceed
        }

        for testCase in InvalidationCase.allCases {
            let queue = DispatchQueue(label: "valeria-test.\(testCase)")
            let host = MockValeriaRecoveryHost(queue: queue)
            let sourceA = MockValeriaRecoverySource(id: "00008150-000000000000000A")
            let sourceB = MockValeriaRecoverySource(id: "00008150-000000000000000B")
            if testCase == .advanceMultiDeviceGeneration {
                host.setSources([sourceA, sourceB], verificationState: .verified)
            } else {
                host.setSources([sourceA], verificationState: .singleDevice)
            }

            let gate = DispatchSemaphore(value: 0)
            if testCase != .invalidateInsideShouldProceed {
                let blocked = expectation(description: "queue blocked \(testCase)")
                queue.async {
                    blocked.fulfill()
                    gate.wait()
                }
                wait(for: [blocked], timeout: 1.0)
            }

            var setConfigurationCount = 0
            var restoredEntries: [UInt64] = []
            CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
                host: host,
                for: sourceA,
                restartSource: false,
                postSwitchRestoreDelay: -1,
                activateUSB: { _, _, _, shouldProceed in
                    if testCase == .invalidateInsideShouldProceed {
                        host.stop()
                    }
                    guard shouldProceed() else { return .notActivated }
                    setConfigurationCount += 1
                    return .switched(
                        .init(registryEntryID: 55, previousConfiguration: 6, requestedConfiguration: 7))
                },
                restoreUSB: {
                    restoredEntries.append($0)
                    return .restored
                })

            switch testCase {
            case .swapSourceAToB:
                host.setSources([sourceB], verificationState: .singleDevice)
                gate.signal()
            case .expandSingleToMulti:
                host.setSources([sourceA, sourceB], verificationState: .pending)
                gate.signal()
            case .stopHost:
                host.stop()
                gate.signal()
            case .advanceMultiDeviceGeneration:
                host.recoveryLock.withLock {
                    host.identityGeneration &+= 1
                }
                gate.signal()
            case .invalidateInsideShouldProceed:
                break
            }

            queue.sync {}
            XCTAssertEqual(
                setConfigurationCount, 0,
                "invalidated plan \(testCase) must perform zero SetConfiguration")
            XCTAssertEqual(
                sourceA.restartCount, 0,
                "invalidated plan \(testCase) must not restart stale source")
            XCTAssertTrue(restoredEntries.isEmpty)
        }
    }

    func testMultiDeviceDelayedRestoreClosesPartiallyVerifiedGateBeforeSetConfigurationAndReverifies() {
        let queue = DispatchQueue(label: "valeria-test.multidevice-delayed-restore")
        let host = MockValeriaRecoveryHost(queue: queue)
        let sourceA = MockValeriaRecoverySource(id: "00008150-000000000000000A")
        let sourceB = MockValeriaRecoverySource(id: "00008150-000000000000000B")
        sourceB.hasFrame = true
        host.setSources([sourceA, sourceB], verificationState: .verified)

        let gate = DispatchSemaphore(value: 0)
        let blocked = expectation(description: "queue held")
        queue.async {
            blocked.fulfill()
            gate.wait()
        }
        wait(for: [blocked], timeout: 1.0)

        var observedFallbackFlag: Bool?
        var gateStateDuringRestore: ScreenCaptureIdentityState?
        var generationBeforeRestore: UInt64 = 0
        let delayedRestoreDone = expectation(description: "delayed multi-device restore executed")

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: sourceA,
            restartSource: false,
            postSwitchRestoreDelay: 0.04,
            activateUSB: { _, allowFallback, _, shouldProceed in
                observedFallbackFlag = allowFallback
                XCTAssertTrue(shouldProceed())
                return .switched(
                    .init(registryEntryID: 88, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                XCTAssertEqual(entryID, 88)
                gateStateDuringRestore = host.recoveryLock.withLock { host.verificationState }
                delayedRestoreDone.fulfill()
                return .restored
            })

        XCTAssertEqual(host.recoveryLock.withLock { host.verificationState }, .pending)
        gate.signal()
        queue.sync {}

        XCTAssertEqual(observedFallbackFlag, false)
        XCTAssertEqual(sourceA.restartCount, 1)
        XCTAssertEqual(host.scheduledVerifications.count, 1)

        // Simulate source B completing partial verification while source A remains frameless.
        host.recoveryLock.withLock {
            host.verificationState = .partiallyVerified
            generationBeforeRestore = host.identityGeneration
        }

        wait(for: [delayedRestoreDone], timeout: 1.0)
        queue.sync {}

        // Gate MUST have been closed (.pending) BEFORE restoreUSB mutated USB configuration,
        // and a fresh verification generation (> generationBeforeRestore) MUST be scheduled afterward.
        XCTAssertEqual(gateStateDuringRestore, .pending)
        XCTAssertEqual(host.recoveryLock.withLock { host.verificationState }, .pending)
        let latestScheduledGen = host.scheduledVerifications.last ?? 0
        XCTAssertGreaterThan(latestScheduledGen, generationBeforeRestore)
    }

    func testNoOpProbeAndInFlightProbePreserveBoundedRuntimeErrorRestart() {
        let queue = DispatchQueue(label: "valeria-test.budget")
        let host = MockValeriaRecoveryHost(queue: queue)
        let source = MockValeriaRecoverySource(id: "00008150-000000000000000A")
        host.setSources([source], verificationState: .singleDevice)

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: source,
            restartSource: false,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { _ in .notTracked })
        queue.sync {}
        XCTAssertEqual(source.restartCount, 0)

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: source,
            restartSource: true,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { _ in .notTracked })
        queue.sync {}
        XCTAssertEqual(source.restartCount, 1)

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: source,
            restartSource: true,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { _ in .notTracked })
        queue.sync {}
        XCTAssertEqual(source.restartCount, 1)

        let source2 = MockValeriaRecoverySource(id: "00008150-000000000000000B")
        host.setSources([source2], verificationState: .singleDevice)
        let inFlightEntered = expectation(description: "probe in flight")
        let releaseProbe = DispatchSemaphore(value: 0)

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: source2,
            restartSource: false,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in
                inFlightEntered.fulfill()
                releaseProbe.wait()
                return .notActivated
            },
            restoreUSB: { _ in .notTracked })
        wait(for: [inFlightEntered], timeout: 1.0)

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: source2,
            restartSource: true,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { _ in .notTracked })

        releaseProbe.signal()
        queue.sync {}
        XCTAssertEqual(source2.restartCount, 1)

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: source2,
            restartSource: true,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { _ in .notTracked })
        queue.sync {}
        XCTAssertEqual(source2.restartCount, 1)
    }

    func testEmptyDiscoveryActivatesOnceClaimsSourceAndCleansUpDetachedUnclaimedSwitches() {
        let queue = DispatchQueue(label: "valeria-test.empty-discovery")
        let host = MockValeriaRecoveryHost(queue: queue)
        let pin1 = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 501,
            serial: "00008150-0000000000000501")

        var activateCalls = 0
        var restoreCalls: [UInt64] = []

        // 1. Cold plug-in on configuration #6 (sources.isEmpty): activates dormant Valeria once.
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: {
                .observed(.init(attachedEntryIDs: [501], singleDevice: pin1))
            },
            activateUSB: { preferredSerial, allowFallback, pinned, shouldProceed in
                activateCalls += 1
                XCTAssertNil(preferredSerial)
                XCTAssertTrue(allowFallback)
                XCTAssertEqual(pinned, pin1)
                XCTAssertTrue(shouldProceed())
                return .switched(
                    .init(registryEntryID: 501, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        XCTAssertEqual(activateCalls, 1)
        XCTAssertEqual(
            host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch },
            .init(registryEntryID: 501, serial: pin1.serial))

        // 2. Subsequent 1Hz empty-discovery ticks while entry 501 stays attached do NOT re-probe USB.
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: {
                .observed(.init(attachedEntryIDs: [501], singleDevice: pin1))
            },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .notActivated
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        XCTAssertEqual(activateCalls, 1)
        XCTAssertTrue(restoreCalls.isEmpty)

        // 3. Non-opaque sourceID with mismatching serial refuses to claim entry 501; matching source claims it.
        let wrongSource = MockValeriaRecoverySource(
            id: "00008150-0000000000000999",
            pinnedUSBDevice: pin1)
        XCTAssertNil(
            host.recoveryLock.withLock {
                host.tracker.claimPendingEmptyDiscoverySwitch(
                    for: wrongSource.instanceID,
                    sourceID: wrongSource.id,
                    pinnedDevice: wrongSource.pinnedUSBDevice)
            })

        let opaqueSource = MockValeriaRecoverySource(
            id: "11111111-2222-3333-4444-555555555555",
            pinnedUSBDevice: pin1)
        host.setSources([opaqueSource], verificationState: .singleDevice)
        XCTAssertEqual(
            host.recoveryLock.withLock {
                host.tracker.claimPendingEmptyDiscoverySwitch(
                    for: opaqueSource.instanceID,
                    sourceID: opaqueSource.id,
                    pinnedDevice: opaqueSource.pinnedUSBDevice)
            },
            501)
        XCTAssertNil(host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch })

        // Claimed source skips redundant 1.5s USB re-probe while keeping its 1 runtime-error restart!
        var sourceActivateCalls = 0
        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: opaqueSource,
            restartSource: false,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in
                sourceActivateCalls += 1
                return .notActivated
            },
            restoreUSB: { _ in .notTracked })
        queue.sync {}
        XCTAssertEqual(sourceActivateCalls, 0)
        XCTAssertEqual(opaqueSource.restartCount, 0)

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: opaqueSource,
            restartSource: true,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in
                sourceActivateCalls += 1
                return .notActivated
            },
            restoreUSB: { _ in .notTracked })
        queue.sync {}
        XCTAssertEqual(sourceActivateCalls, 0)
        XCTAssertEqual(opaqueSource.restartCount, 1)

        // Disconnecting opaqueSource returns entry 501 from tracker.retain for live restoration.
        let removed = host.recoveryLock.withLock {
            host.sources.removeAll()
            return host.tracker.retain(sources: [])
        }
        XCTAssertEqual(removed, [501])

        // 4. Unplugging an unclaimed phone (502) cleans up 502 and immediately activates newly attached 503.
        let pin2 = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 502,
            serial: "00008150-0000000000000502")
        let pin3 = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 503,
            serial: "00008150-0000000000000503")
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [502], singleDevice: pin2)) },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .switched(
                    .init(registryEntryID: 502, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .deviceDetached
            })
        queue.sync {}
        XCTAssertEqual(activateCalls, 2)

        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [503], singleDevice: pin3)) },
            activateUSB: { _, _, pinned, _ in
                activateCalls += 1
                XCTAssertEqual(pinned, pin3)
                return .switched(
                    .init(registryEntryID: 503, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .deviceDetached
            })
        queue.sync {}
        XCTAssertEqual(restoreCalls, [502])
        XCTAssertEqual(activateCalls, 3)
        XCTAssertEqual(
            host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch?.registryEntryID },
            503)
    }

    func testEmptyDiscoveryLifecycleRestartIsolationAndSingleDeviceLockedPreservation() {
        let queue = DispatchQueue(label: "valeria-test.lifecycle-and-locked")
        let host = MockValeriaRecoveryHost(queue: queue)
        let pin = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 601,
            serial: "00008150-0000000000000601")

        // 1. Stale generation topology callback after stop()+start() must not poison new generation.
        let enteredTopology = expectation(description: "entered topology query")
        let releaseTopology = DispatchSemaphore(value: 0)
        var staleActivateCalled = false
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: {
                enteredTopology.fulfill()
                releaseTopology.wait()
                return .observed(.init(attachedEntryIDs: [601], singleDevice: pin))
            },
            activateUSB: { _, _, _, _ in
                staleActivateCalled = true
                return .notActivated
            },
            restoreUSB: { _ in .notTracked })
        wait(for: [enteredTopology], timeout: 1.0)

        host.stop()
        host.recoveryLock.withLock {
            host.stopped = false
            host.lifecycleGeneration &+= 1
        }
        releaseTopology.signal()
        queue.sync {}
        XCTAssertFalse(staleActivateCalled)
        XCTAssertTrue(
            host.recoveryLock.withLock { host.tracker.emptyDiscoveryAttemptedEntries.isEmpty })

        // 2. Single-device healthy locked iPhone (hasFrame == false, hasCaptureError == false)
        // preserves Valeria configuration across postSwitchRestoreDelay, whereas an errored
        // single-device stream (hasCaptureError == true) rolls back after postSwitchRestoreDelay.
        let lockedSource = MockValeriaRecoverySource(id: "11111111-2222-3333-4444-555555555555")
        host.setSources([lockedSource], verificationState: .singleDevice)
        var restoredEntries: [UInt64] = []

        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: lockedSource,
            restartSource: false,
            postSwitchRestoreDelay: 0.03,
            activateUSB: { _, _, _, _ in
                .switched(
                    .init(registryEntryID: 701, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                restoredEntries.append(entryID)
                return .restored
            })
        let noRestoreCheck = expectation(description: "healthy locked phone kept Valeria active")
        queue.asyncAfter(deadline: .now() + 0.06) {
            noRestoreCheck.fulfill()
        }
        wait(for: [noRestoreCheck], timeout: 1.0)
        XCTAssertTrue(
            restoredEntries.isEmpty,
            "a single healthy locked iPhone waiting for unlock must not tear down Valeria after 4s")

        // When a runtime capture error subsequently occurs and remains frameless, delayed restore fires!
        lockedSource.recordRecoveryError("capture runtime error")
        let erroredRestoreDone = expectation(description: "errored frameless stream rolled back Valeria")
        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: lockedSource,
            restartSource: true,
            postSwitchRestoreDelay: 0.03,
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { entryID in
                restoredEntries.append(entryID)
                erroredRestoreDone.fulfill()
                return .restored
            })
        wait(for: [erroredRestoreDone], timeout: 1.0)
        queue.sync {}
        XCTAssertEqual(restoredEntries, [701])

        // 3. IOKit 0xE00002BE resource shortage records explicit diagnostic message.
        let shortageSource = MockValeriaRecoverySource(id: "22222222-3333-4444-5555-666666666666")
        host.setSources([shortageSource], verificationState: .singleDevice)
        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: shortageSource,
            restartSource: false,
            postSwitchRestoreDelay: -1,
            activateUSB: { _, _, _, _ in .blockedByUSBResourceShortage },
            restoreUSB: { _ in .notTracked })
        queue.sync {}
        XCTAssertEqual(
            shortageSource.recordedErrors,
            [CaptureValeriaRecoveryCoordinator.usbResourceShortageMessage])
    }

    func testSelectCandidateIndexAndEmptyDiscoveryEnforcePinnedIdentityOnNilPreferredSerial() {
        let phoneA = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 101,
            vendorID: 0x05AC,
            supportsIPhoneOS: true,
            serial: "00008150000000000000000A")
        let phoneAReenumerated = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 102,
            vendorID: 0x05AC,
            supportsIPhoneOS: true,
            serial: "00008150000000000000000A")
        let phoneB = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 202,
            vendorID: 0x05AC,
            supportsIPhoneOS: true,
            serial: "00008150000000000000000B")
        let nilSerialA = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 101,
            vendorID: 0x05AC,
            supportsIPhoneOS: true,
            serial: nil)
        let nilSerialB = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 202,
            vendorID: 0x05AC,
            supportsIPhoneOS: true,
            serial: nil)
        let zeroEntryNilSerial = USBValeriaConfigurator.DeviceCandidate(
            registryEntryID: 0,
            vendorID: 0x05AC,
            supportsIPhoneOS: true,
            serial: nil)

        let pinA = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 101,
            serial: "00008150-000000000000000A")
        let pinNilA = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 101,
            serial: nil)
        let pinZeroNil = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 0,
            serial: nil)

        // Direct production selector matrix for `preferredSerial == nil` + `pinnedSingleDevice`.
        XCTAssertEqual(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneA],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinA),
            0)
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneB],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinA),
            "nil preferredSerial must not select swapped phone B when pinned to A")
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneAReenumerated],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinA),
            "empty discovery must require the exact authorized registryEntryID for that probe")
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneA, phoneB],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinA))
        XCTAssertEqual(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [nilSerialA],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinNilA),
            0)
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [nilSerialB],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinNilA))
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneA],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinNilA))
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [nilSerialA],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinA))
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [zeroEntryNilSerial],
                preferredSerial: nil,
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinZeroNil))
        XCTAssertNil(
            USBValeriaConfigurator.selectCandidateIndex(
                devices: [phoneB],
                preferredSerial: "00008150-000000000000000B",
                allowSingleIOSFallback: true,
                pinnedSingleDevice: pinA),
            "exact preferredSerial match must still reject conflicting pinnedSingleDevice")

        // End-to-end empty-discovery coordinator wired to production `selectCandidateIndex`
        // and `USBSwitchLedger`: swapping A -> B (or re-enumerating / adding B) between
        // `queryTopology` and `activateUSB` performs ZERO open/SetConfiguration calls.
        let descriptors: [USBValeriaConfigurator.ConfigurationDescriptorInfo] = [
            .init(
                value: 6,
                name: "PTP + Apple Mobile Device",
                nameReadSucceeded: true,
                interfaceClasses: [0x06, 0xFF]),
            .init(
                value: 7,
                name: "PTP + Apple Mobile Device + Valeria",
                nameReadSucceeded: true,
                interfaceClasses: [0x06, 0xFF, 0xFF]),
        ]
        let safeRoutes = USBValeriaConfigurator.HostNetworkRouteSnapshot(
            ipv4: .physicalPrimary("en0"), ipv6: .none)

        for raceCandidates in [[phoneB], [nilSerialB], [phoneAReenumerated], [phoneA, phoneB]] {
            let queue = DispatchQueue(label: "valeria-test.empty-pin-race")
            let host = MockValeriaRecoveryHost(queue: queue)
            var ledger = USBSwitchLedger()
            var openCalls = 0
            let sessions = raceCandidates.map { candidate -> MockUSBConfigDeviceSession in
                let session = MockUSBConfigDeviceSession(
                    registryEntryID: candidate.registryEntryID,
                    initialConfiguration: 6)
                session.onOpenSafely = { openCalls += 1 }
                return session
            }

            CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
                host: host,
                queryTopology: { .observed(.init(attachedEntryIDs: [101], singleDevice: pinA)) },
                activateUSB: { preferredSerial, allowFallback, pinned, shouldProceed in
                    guard shouldProceed(),
                        let idx = USBValeriaConfigurator.selectCandidateIndex(
                            devices: raceCandidates,
                            preferredSerial: preferredSerial,
                            allowSingleIOSFallback: allowFallback,
                            pinnedSingleDevice: pinned),
                        shouldProceed()
                    else { return .notActivated }
                    return ledger.activate(
                        session: sessions[idx],
                        descriptors: descriptors,
                        allowPrimaryNetworkPreemption: false,
                        inspectEnvironment: { (.inspected(activeHostInterfaces: []), safeRoutes) },
                        shouldProceed: shouldProceed)
                },
                restoreUSB: { _ in .notTracked })
            queue.sync {}

            XCTAssertEqual(openCalls, 0)
            XCTAssertTrue(sessions.allSatisfy { $0.setHistory.isEmpty })
            XCTAssertTrue(ledger.trackedEntryIDs.isEmpty)
            XCTAssertNil(host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch })
        }

        // Cross-generation switched activation and `.unconfirmedSwitch` fault injection in empty discovery.
        let queue = DispatchQueue(label: "valeria-test.empty-unconfirmed-and-stale-switch")
        let host = MockValeriaRecoveryHost(queue: queue)
        var ledger = USBSwitchLedger()
        let session = MockUSBConfigDeviceSession(registryEntryID: 101, initialConfiguration: 6)
        session.failNextPostSetReadback = true
        var restoreAttempts: [UInt64] = []

        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [101], singleDevice: pinA)) },
            activateUSB: { preferredSerial, allowFallback, pinned, shouldProceed in
                guard
                    let idx = USBValeriaConfigurator.selectCandidateIndex(
                        devices: [phoneA],
                        preferredSerial: preferredSerial,
                        allowSingleIOSFallback: allowFallback,
                        pinnedSingleDevice: pinned)
                else { return .notActivated }
                XCTAssertEqual(idx, 0)
                return ledger.activate(
                    session: session,
                    descriptors: descriptors,
                    allowPrimaryNetworkPreemption: false,
                    inspectEnvironment: { (.inspected(activeHostInterfaces: []), safeRoutes) },
                    shouldProceed: shouldProceed)
            },
            restoreUSB: { entryID in
                restoreAttempts.append(entryID)
                // Simulate transient restore open failure: ledger must retain entry 101.
                session.openResults = [false]
                return ledger.restore(registryEntryID: entryID, session: session)
            })
        queue.sync {}
        XCTAssertEqual(restoreAttempts, [101])
        XCTAssertNil(host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch })
        XCTAssertEqual(ledger.trackedEntryIDs, [101], "failed rollback of unconfirmed switch must remain tracked")
        XCTAssertEqual(ledger.restore(registryEntryID: 101, session: session), .restored)
        XCTAssertTrue(ledger.trackedEntryIDs.isEmpty)

        // Stale-generation `activateUSB` returning `.switched` after `stop() + start()` rolls back
        // without polluting the new generation's tracker.
        let host2 = MockValeriaRecoveryHost(queue: queue)
        let enteredActivate = expectation(description: "entered empty activateUSB")
        let releaseActivate = DispatchSemaphore(value: 0)
        var staleRollbacks: [UInt64] = []
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host2,
            queryTopology: { .observed(.init(attachedEntryIDs: [101], singleDevice: pinA)) },
            activateUSB: { _, _, _, _ in
                enteredActivate.fulfill()
                releaseActivate.wait()
                return .switched(
                    .init(registryEntryID: 101, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                staleRollbacks.append(entryID)
                return .restored
            })
        wait(for: [enteredActivate], timeout: 1.0)
        host2.stop()
        host2.recoveryLock.withLock {
            host2.stopped = false
            host2.lifecycleGeneration &+= 1
        }
        releaseActivate.signal()
        queue.sync {}
        XCTAssertEqual(staleRollbacks, [101])
        XCTAssertNil(host2.recoveryLock.withLock { host2.tracker.pendingEmptyDiscoverySwitch })
    }

    func testEmptyDiscoveryTopologyUnavailablePreservesAttemptBudgetAndPendingSwitch() {
        let queue = DispatchQueue(label: "valeria-test.topology-unavailable")
        let host = MockValeriaRecoveryHost(queue: queue)
        let pinA = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 901,
            serial: "00008150-0000000000000901")
        let pinB = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 902,
            serial: "00008150-0000000000000902")

        var activateCalls = 0
        var restoreCalls: [UInt64] = []

        // 1. Entry 901 is probed once and hits resource shortage (not switched).
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [901], singleDevice: pinA)) },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .blockedByUSBResourceShortage
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        XCTAssertEqual(activateCalls, 1)

        // 2. Transient topology enumeration failure (`.unavailable`) MUST NOT clear 901's attempt budget.
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .unavailable },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .notActivated
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [901], singleDevice: pinA)) },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .notActivated
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        XCTAssertEqual(
            activateCalls, 1,
            "transient topology `.unavailable` must not reset the 1-probe-per-attach budget")
        XCTAssertTrue(restoreCalls.isEmpty)

        // 3. Confirmed empty bus (`.observed([])`) detaches 901; newly attached 902 switches to Valeria.
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [], singleDevice: nil)) },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .notActivated
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [902], singleDevice: pinB)) },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .switched(
                    .init(registryEntryID: 902, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        XCTAssertEqual(activateCalls, 2)
        XCTAssertEqual(
            host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch?.registryEntryID },
            902)

        // 4. While 902 is pending, `.unavailable` MUST NOT falsely detach/restore 902 or allow oscillation.
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .unavailable },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .notActivated
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [902], singleDevice: pinB)) },
            activateUSB: { _, _, _, _ in
                activateCalls += 1
                return .notActivated
            },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .restored
            })
        queue.sync {}
        XCTAssertTrue(restoreCalls.isEmpty)
        XCTAssertEqual(activateCalls, 2)
        XCTAssertEqual(
            host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch?.registryEntryID },
            902)

        // 5. Confirmed empty bus now detaches and cleans up 902, allowing a fresh attach cycle.
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            queryTopology: { .observed(.init(attachedEntryIDs: [], singleDevice: nil)) },
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { entryID in
                restoreCalls.append(entryID)
                return .deviceDetached
            })
        queue.sync {}
        XCTAssertEqual(restoreCalls, [902])
        XCTAssertNil(host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch })
    }

    func testPendingSwitchReconcilesMultiToSingleSurvivorAmbiguousMultiRollbackAndPinResolver() {
        let pinA = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 801,
            serial: "000081500000000000000801")
        let pinNilSerial = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 801,
            serial: nil)

        // 1. Direct positive & negative tests for `CaptureDiscoveryPinResolver.prequerySingleDevicePin`
        // with real non-opaque Apple USB serials, opaque UUIDs, existing sources, and multi-device lists.
        let matchedReal = CaptureDiscoveryPinResolver.prequerySingleDevicePin(
            discoveredIDs: ["00008150-0000000000000801"],
            needsNewSourceForID: { _ in true },
            querySingleIOSDevice: { pinA })
        XCTAssertEqual(matchedReal?.deviceID, "00008150-0000000000000801")
        XCTAssertEqual(matchedReal?.pin, pinA)

        let mismatchedReal = CaptureDiscoveryPinResolver.prequerySingleDevicePin(
            discoveredIDs: ["00008150-0000000000000999"],
            needsNewSourceForID: { _ in true },
            querySingleIOSDevice: { pinA })
        XCTAssertEqual(mismatchedReal?.deviceID, "00008150-0000000000000999")
        XCTAssertNil(mismatchedReal?.pin)

        let nilUSBSerialReal = CaptureDiscoveryPinResolver.prequerySingleDevicePin(
            discoveredIDs: ["00008150-0000000000000801"],
            needsNewSourceForID: { _ in true },
            querySingleIOSDevice: { pinNilSerial })
        XCTAssertNil(nilUSBSerialReal?.pin)

        var usbQueried = false
        XCTAssertNil(
            CaptureDiscoveryPinResolver.prequerySingleDevicePin(
                discoveredIDs: ["00008150-0000000000000801"],
                needsNewSourceForID: { _ in false },
                querySingleIOSDevice: {
                    usbQueried = true
                    return pinA
                }))
        XCTAssertNil(
            CaptureDiscoveryPinResolver.prequerySingleDevicePin(
                discoveredIDs: ["00008150-0000000000000801", "00008150-0000000000000802"],
                needsNewSourceForID: { _ in true },
                querySingleIOSDevice: {
                    usbQueried = true
                    return pinA
                }))
        XCTAssertFalse(usbQueried)

        // 2. R6-P2-02 counterexample: empty activation A (801) -> simultaneous [A, B] (both unpinned)
        // -> A records frameless runtime error -> B disconnects leaving existing A -> survivor A claims
        // pending 801 via topology query and rolls back 801 after `postSwitchRestoreDelay`.
        let queue = DispatchQueue(label: "valeria-test.survivor-reconcile")
        let host = MockValeriaRecoveryHost(queue: queue)
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: host,
            postSwitchRestoreDelay: 0.03,
            queryTopology: { .observed(.init(attachedEntryIDs: [801], singleDevice: pinA)) },
            activateUSB: { _, _, _, _ in
                .switched(
                    .init(registryEntryID: 801, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { _ in .restored })
        queue.sync {}
        XCTAssertEqual(
            host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch?.registryEntryID },
            801)

        let sourceA = MockValeriaRecoverySource(
            id: "11111111-2222-3333-4444-555555555555",
            pinnedUSBDevice: nil)
        let sourceB = MockValeriaRecoverySource(
            id: "22222222-3333-4444-5555-666666666666",
            pinnedUSBDevice: nil)
        let firstMultiRefresh = host.recoveryLock.withLock {
            host.sources = [sourceA.id: sourceA, sourceB.id: sourceB]
            host.verificationState = .pending
            return host.tracker.reconcileAfterRefresh(
                changed: true,
                activeSources: [
                    .init(id: sourceA.id, instanceID: sourceA.instanceID, hasFrame: sourceA.hasFrame),
                    .init(id: sourceB.id, instanceID: sourceB.instanceID, hasFrame: sourceB.hasFrame),
                ],
                discoveredDeviceCount: 2)
        }
        XCTAssertTrue(firstMultiRefresh.removedUSBEntries.isEmpty)
        XCTAssertFalse(firstMultiRefresh.shouldRecoverEmptyDiscovery)
        XCTAssertTrue(firstMultiRefresh.shouldReconcilePendingSwitch)

        // Even if `sourceA` already exhausted its 1 runtime-error recovery while `[A, B]` were present:
        sourceA.recordRecoveryError("capture runtime error")
        CaptureValeriaRecoveryCoordinator.recoverIfNeeded(
            host: host,
            for: sourceA,
            restartSource: true,
            postSwitchRestoreDelay: 0.03,
            activateUSB: { _, _, _, _ in .notActivated },
            restoreUSB: { _ in .notTracked })
        queue.sync {}

        // Now B disconnects, leaving existing unpinned `sourceA` as sole survivor.
        let survivorRefresh = host.recoveryLock.withLock {
            host.sources = [sourceA.id: sourceA]
            host.verificationState = .singleDevice
            return host.tracker.reconcileAfterRefresh(
                changed: true,
                activeSources: [
                    .init(id: sourceA.id, instanceID: sourceA.instanceID, hasFrame: sourceA.hasFrame)
                ],
                discoveredDeviceCount: 1)
        }
        XCTAssertTrue(survivorRefresh.shouldReconcilePendingSwitch)

        let survivorRestored = expectation(description: "errored survivor rolled back claimed switch 801")
        var survivorRestoreCalls: [UInt64] = []
        CaptureValeriaRecoveryCoordinator.reconcilePendingEmptyDiscoverySwitchIfNeeded(
            host: host,
            postSwitchRestoreDelay: 0.03,
            queryTopology: { .observed(.init(attachedEntryIDs: [801], singleDevice: pinA)) },
            restoreUSB: { entryID in
                survivorRestoreCalls.append(entryID)
                survivorRestored.fulfill()
                return .restored
            })
        queue.sync {}
        XCTAssertNil(host.recoveryLock.withLock { host.tracker.pendingEmptyDiscoverySwitch })
        XCTAssertEqual(
            host.recoveryLock.withLock { host.tracker.activeSwitchEntryID(for: sourceA.instanceID) },
            801)
        wait(for: [survivorRestored], timeout: 1.0)
        queue.sync {}
        XCTAssertEqual(survivorRestoreCalls, [801])
        XCTAssertNil(
            host.recoveryLock.withLock { host.tracker.activeSwitchEntryID(for: sourceA.instanceID) })

        // 3. Sustained multi-device ambiguity `[A, B]` rolls back unclaimed pending switch under `.pending` gate.
        let hostMulti = MockValeriaRecoveryHost(queue: queue)
        let pin802 = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 802,
            serial: "000081500000000000000802")
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: hostMulti,
            postSwitchRestoreDelay: 0.03,
            queryTopology: { .observed(.init(attachedEntryIDs: [802], singleDevice: pin802)) },
            activateUSB: { _, _, _, _ in
                .switched(
                    .init(registryEntryID: 802, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { _ in .restored })
        queue.sync {}
        hostMulti.setSources([sourceA, sourceB], verificationState: .verified)
        let ambiguousRolledBack = expectation(description: "ambiguous multi-device pending rolled back")
        var stateDuringAmbiguousRestore: ScreenCaptureIdentityState?
        CaptureValeriaRecoveryCoordinator.reconcilePendingEmptyDiscoverySwitchIfNeeded(
            host: hostMulti,
            postSwitchRestoreDelay: 0.03,
            queryTopology: {
                .observed(.init(attachedEntryIDs: [802, 899], singleDevice: nil))
            },
            restoreUSB: { entryID in
                XCTAssertEqual(entryID, 802)
                stateDuringAmbiguousRestore = hostMulti.recoveryLock.withLock {
                    hostMulti.verificationState
                }
                ambiguousRolledBack.fulfill()
                return .restored
            })
        wait(for: [ambiguousRolledBack], timeout: 1.0)
        queue.sync {}
        XCTAssertEqual(stateDuringAmbiguousRestore, .pending)
        XCTAssertNil(hostMulti.recoveryLock.withLock { hostMulti.tracker.pendingEmptyDiscoverySwitch })
        XCTAssertFalse(hostMulti.scheduledVerifications.isEmpty)

        // 4. Multi-device `[A, B] -> []` transition drains orphaned pending switch immediately via `reconcileAfterRefresh`.
        let hostDrain = MockValeriaRecoveryHost(queue: queue)
        let pin803 = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 803,
            serial: "000081500000000000000803")
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: hostDrain,
            queryTopology: { .observed(.init(attachedEntryIDs: [803], singleDevice: pin803)) },
            activateUSB: { _, _, _, _ in
                .switched(
                    .init(registryEntryID: 803, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { _ in .restored })
        queue.sync {}
        hostDrain.setSources([sourceA, sourceB], verificationState: .pending)
        let emptyTransition = hostDrain.recoveryLock.withLock {
            hostDrain.sources.removeAll()
            return hostDrain.tracker.reconcileAfterRefresh(
                changed: true,
                activeSources: [],
                discoveredDeviceCount: 0)
        }
        XCTAssertEqual(emptyTransition.removedUSBEntries, [803])
        XCTAssertTrue(emptyTransition.shouldRecoverEmptyDiscovery)
        XCTAssertFalse(emptyTransition.shouldReconcilePendingSwitch)
        XCTAssertNil(hostDrain.recoveryLock.withLock { hostDrain.tracker.pendingEmptyDiscoverySwitch })
    }

    func testPropertyParsingFailuresPreserveTopologyBudgetAndDirectRefreshClaimSchedulesMultiDeviceRollback() {
        // 1. R7-P2-01: Production `parseObservedUSBServiceProperties` + `observeIOSUSBTopology`
        // must classify property-read failures (`nil` dictionary), missing/boolean `idVendor`,
        // non-CFBoolean `SupportsIPhoneOS`, non-String `USB Serial Number`, and zero/nil iOS
        // `registryEntryID` as `.unavailable` — never degrading them into `.observed(empty)` —
        // while still filtering confirmed non-iOS Apple peripherals and accepting confirmed empty bus.
        let validKeyboardProps: NSDictionary = [
            kUSBVendorID: NSNumber(value: 0x05AC)
        ]
        let explicitNonIOSProps: NSDictionary = [
            kUSBVendorID: NSNumber(value: 0x05AC),
            "SupportsIPhoneOS": kCFBooleanFalse!,
        ]
        let validPhoneProps: NSDictionary = [
            kUSBVendorID: NSNumber(value: 0x05AC),
            "SupportsIPhoneOS": kCFBooleanTrue!,
            kUSBSerialNumberString: "00008150-0000000000000911",
        ]
        XCTAssertEqual(
            USBValeriaConfigurator.parseObservedUSBServiceProperties(
                registryEntryID: 10, properties: validKeyboardProps),
            .nonIOSDevice)
        XCTAssertEqual(
            USBValeriaConfigurator.parseObservedUSBServiceProperties(
                registryEntryID: 11, properties: explicitNonIOSProps),
            .nonIOSDevice)
        XCTAssertEqual(
            USBValeriaConfigurator.observeIOSUSBTopology(serviceObservations: []),
            .observed(.init(attachedEntryIDs: [], singleDevice: nil)))
        XCTAssertEqual(
            USBValeriaConfigurator.observeIOSUSBTopology(
                serviceObservations: [
                    USBValeriaConfigurator.parseObservedUSBServiceProperties(
                        registryEntryID: 10, properties: validKeyboardProps),
                    USBValeriaConfigurator.parseObservedUSBServiceProperties(
                        registryEntryID: 911, properties: validPhoneProps),
                ]),
            .observed(
                .init(
                    attachedEntryIDs: [911],
                    singleDevice: .init(
                        registryEntryID: 911,
                        serial: "00008150-0000000000000911"))))

        let corruptPropertyCases: [(UInt64?, NSDictionary?)] = [
            (911, nil),
            (911, [:]),
            (911, [kUSBVendorID: kCFBooleanTrue!]),
            (911, [kUSBVendorID: NSNumber(value: 0x05AC), "SupportsIPhoneOS": "Yes"]),
            (911, [kUSBVendorID: NSNumber(value: 0x05AC), "SupportsIPhoneOS": NSNumber(value: 1)]),
            (
                911,
                [
                    kUSBVendorID: NSNumber(value: 0x05AC),
                    "SupportsIPhoneOS": kCFBooleanTrue!,
                    kUSBSerialNumberString: NSNumber(value: 12345),
                ]
            ),
            (0, validPhoneProps),
            (nil, validPhoneProps),
        ]

        let queue = DispatchQueue(label: "valeria-test.r7-regressions")
        let hostProp = MockValeriaRecoveryHost(queue: queue)
        var propSnapshots: [(UInt64?, NSDictionary?)] = [(911, validPhoneProps)]
        var propActivations = 0
        var propRestores: [UInt64] = []

        let runTopologyDrivenEmptyRecovery = {
            CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
                host: hostProp,
                queryTopology: {
                    let parsed = propSnapshots.map {
                        USBValeriaConfigurator.parseObservedUSBServiceProperties(
                            registryEntryID: $0.0, properties: $0.1)
                    }
                    return USBValeriaConfigurator.observeIOSUSBTopology(serviceObservations: parsed)
                },
                activateUSB: { _, _, _, _ in
                    propActivations += 1
                    return .switched(
                        .init(
                            registryEntryID: 911,
                            previousConfiguration: 6,
                            requestedConfiguration: 7))
                },
                restoreUSB: { entryID in
                    propRestores.append(entryID)
                    return .restored
                })
            queue.sync {}
        }

        runTopologyDrivenEmptyRecovery()
        XCTAssertEqual(propActivations, 1)
        XCTAssertEqual(
            hostProp.recoveryLock.withLock { hostProp.tracker.pendingEmptyDiscoverySwitch?.registryEntryID },
            911)

        for corruptCase in corruptPropertyCases {
            XCTAssertEqual(
                USBValeriaConfigurator.parseObservedUSBServiceProperties(
                    registryEntryID: corruptCase.0, properties: corruptCase.1),
                .unreadable)
            propSnapshots = [(10, validKeyboardProps), corruptCase]
            runTopologyDrivenEmptyRecovery()
            XCTAssertTrue(
                propRestores.isEmpty,
                "corrupt/unreadable service properties must not detach or restore pending entry 911")
            XCTAssertEqual(
                hostProp.recoveryLock.withLock {
                    hostProp.tracker.pendingEmptyDiscoverySwitch?.registryEntryID
                },
                911)
        }
        propSnapshots = [(10, validKeyboardProps), (911, validPhoneProps)]
        runTopologyDrivenEmptyRecovery()
        XCTAssertEqual(propActivations, 1)
        XCTAssertTrue(propRestores.isEmpty)

        // Mismatched `switchedEntryID` guard: if `activateUSB` ever returns an unauthorized entry ID,
        // `recoverEmptyDiscoveryIfNeeded` immediately rolls it back without recording `pending`.
        let hostMismatch = MockValeriaRecoveryHost(queue: queue)
        var mismatchRollbacks: [UInt64] = []
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: hostMismatch,
            queryTopology: {
                USBValeriaConfigurator.observeIOSUSBTopology(
                    serviceObservations: [
                        USBValeriaConfigurator.parseObservedUSBServiceProperties(
                            registryEntryID: 911, properties: validPhoneProps)
                    ])
            },
            activateUSB: { _, _, _, _ in
                .switched(
                    .init(registryEntryID: 999, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { entryID in
                mismatchRollbacks.append(entryID)
                return .restored
            })
        queue.sync {}
        XCTAssertEqual(mismatchRollbacks, [999])
        XCTAssertNil(hostMismatch.recoveryLock.withLock { hostMismatch.tracker.pendingEmptyDiscoverySwitch })

        // 2. R7-P2-02: Direct `refresh()` claim on single locked phone A:
        // (a) Single locked phone A alone (`sources.count == 1`, `hasCaptureError == false`) performs ZERO restores.
        let pin921 = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 921,
            serial: "00008150-0000000000000921")
        let hostSingleLocked = MockValeriaRecoveryHost(queue: queue)
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: hostSingleLocked,
            postSwitchRestoreDelay: 0.04,
            queryTopology: { .observed(.init(attachedEntryIDs: [921], singleDevice: pin921)) },
            activateUSB: { _, _, _, _ in
                .switched(
                    .init(registryEntryID: 921, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { _ in .restored })
        queue.sync {}

        let lockedA = MockValeriaRecoverySource(
            id: "11111111-2222-3333-4444-555555555555",
            pinnedUSBDevice: pin921)
        var singleLockedRestores: [UInt64] = []
        let (singleChecks, singleSnap, singleLife) = hostSingleLocked.recoveryLock.withLock {
            hostSingleLocked.sources = [lockedA.id: lockedA]
            hostSingleLocked.verificationState = .singleDevice
            var claimed: [CaptureValeriaRecoveryTracker.ScheduledPostSwitchCheck] = []
            if let entryID = hostSingleLocked.tracker.claimPendingEmptyDiscoverySwitch(
                for: lockedA.instanceID,
                sourceID: lockedA.id,
                pinnedDevice: lockedA.pinnedUSBDevice)
            {
                claimed.append(
                    .init(
                        sourceID: lockedA.id,
                        sourceInstanceID: lockedA.instanceID,
                        entryID: entryID,
                        supersedeExisting: true))
            }
            let rec = hostSingleLocked.tracker.reconcileAfterRefresh(
                changed: true,
                newlyClaimedSwitches: claimed,
                activeSources: [
                    .init(id: lockedA.id, instanceID: lockedA.instanceID, hasFrame: lockedA.hasFrame)
                ],
                discoveredDeviceCount: 1)
            return (rec.postSwitchChecks, hostSingleLocked.sources, hostSingleLocked.lifecycleGeneration)
        }
        XCTAssertEqual(singleChecks.count, 1)
        CaptureValeriaRecoveryCoordinator.applyRefreshPostSwitchChecks(
            host: hostSingleLocked,
            checks: singleChecks,
            sourcesByID: singleSnap,
            expectedLifecycle: singleLife,
            delay: 0.03,
            restoreUSB: { entryID in
                singleLockedRestores.append(entryID)
                return .restored
            })
        let singleWindowElapsed = expectation(description: "single locked window elapsed")
        queue.asyncAfter(deadline: .now() + 0.06) { singleWindowElapsed.fulfill() }
        wait(for: [singleWindowElapsed], timeout: 1.0)
        XCTAssertTrue(singleLockedRestores.isEmpty)

        // (b) Even AFTER the initial single-device window elapsed, if phone B later joins while A
        // remains frameless, `reconcileAfterRefresh` schedules a gated multi-device rollback for A!
        let activeB = MockValeriaRecoverySource(id: "22222222-3333-4444-5555-666666666666")
        activeB.hasFrame = true
        let lateMultiRestored = expectation(description: "late multi-device join rolled back frameless A")
        var lateStateDuringRestore: ScreenCaptureIdentityState?
        let (lateChecks, lateSnap, lateLife) = hostSingleLocked.recoveryLock.withLock {
            hostSingleLocked.sources = [lockedA.id: lockedA, activeB.id: activeB]
            hostSingleLocked.verificationState = .verified
            let rec = hostSingleLocked.tracker.reconcileAfterRefresh(
                changed: true,
                activeSources: [
                    .init(id: lockedA.id, instanceID: lockedA.instanceID, hasFrame: lockedA.hasFrame),
                    .init(id: activeB.id, instanceID: activeB.instanceID, hasFrame: activeB.hasFrame),
                ],
                discoveredDeviceCount: 2)
            return (rec.postSwitchChecks, hostSingleLocked.sources, hostSingleLocked.lifecycleGeneration)
        }
        XCTAssertEqual(lateChecks.map(\.entryID), [921])
        CaptureValeriaRecoveryCoordinator.applyRefreshPostSwitchChecks(
            host: hostSingleLocked,
            checks: lateChecks,
            sourcesByID: lateSnap,
            expectedLifecycle: lateLife,
            delay: 0.03,
            restoreUSB: { entryID in
                singleLockedRestores.append(entryID)
                lateStateDuringRestore = hostSingleLocked.recoveryLock.withLock {
                    hostSingleLocked.verificationState
                }
                lateMultiRestored.fulfill()
                return .restored
            })
        wait(for: [lateMultiRestored], timeout: 1.0)
        queue.sync {}
        XCTAssertEqual(singleLockedRestores, [921])
        XCTAssertEqual(lateStateDuringRestore, .pending)
        XCTAssertFalse(hostSingleLocked.scheduledVerifications.isEmpty)

        // (c) R7-P2-02 exact counterexample: direct refresh claim on single frameless A, then B joins
        // WITHIN the initial observation window -> restores A exactly once under `.pending` gate + re-verify!
        let pin922 = USBValeriaConfigurator.PinnedUSBDevice(
            registryEntryID: 922,
            serial: "00008150-0000000000000922")
        let hostInWindow = MockValeriaRecoveryHost(queue: queue)
        CaptureValeriaRecoveryCoordinator.recoverEmptyDiscoveryIfNeeded(
            host: hostInWindow,
            postSwitchRestoreDelay: 0.05,
            queryTopology: { .observed(.init(attachedEntryIDs: [922], singleDevice: pin922)) },
            activateUSB: { _, _, _, _ in
                .switched(
                    .init(registryEntryID: 922, previousConfiguration: 6, requestedConfiguration: 7))
            },
            restoreUSB: { _ in .restored })
        queue.sync {}

        let directA = MockValeriaRecoverySource(
            id: "11111111-2222-3333-4444-555555555555",
            pinnedUSBDevice: pin922)
        let inWindowRestored = expectation(description: "in-window multi-device join rolled back direct claim A")
        var inWindowRestores: [UInt64] = []
        var inWindowStateDuringRestore: ScreenCaptureIdentityState?
        let (directChecks, directSnap, directLife) = hostInWindow.recoveryLock.withLock {
            hostInWindow.sources = [directA.id: directA]
            hostInWindow.verificationState = .singleDevice
            var claimed: [CaptureValeriaRecoveryTracker.ScheduledPostSwitchCheck] = []
            if let entryID = hostInWindow.tracker.claimPendingEmptyDiscoverySwitch(
                for: directA.instanceID,
                sourceID: directA.id,
                pinnedDevice: directA.pinnedUSBDevice)
            {
                claimed.append(
                    .init(
                        sourceID: directA.id,
                        sourceInstanceID: directA.instanceID,
                        entryID: entryID,
                        supersedeExisting: true))
            }
            let rec = hostInWindow.tracker.reconcileAfterRefresh(
                changed: true,
                newlyClaimedSwitches: claimed,
                activeSources: [
                    .init(id: directA.id, instanceID: directA.instanceID, hasFrame: directA.hasFrame)
                ],
                discoveredDeviceCount: 1)
            return (rec.postSwitchChecks, hostInWindow.sources, hostInWindow.lifecycleGeneration)
        }
        CaptureValeriaRecoveryCoordinator.applyRefreshPostSwitchChecks(
            host: hostInWindow,
            checks: directChecks,
            sourcesByID: directSnap,
            expectedLifecycle: directLife,
            delay: 0.04,
            restoreUSB: { entryID in
                inWindowRestores.append(entryID)
                inWindowStateDuringRestore = hostInWindow.recoveryLock.withLock {
                    hostInWindow.verificationState
                }
                inWindowRestored.fulfill()
                return .restored
            })

        // B joins BEFORE the 0.04s timer fires; `reconcileAfterRefresh` must NOT duplicate/reset the timer!
        let joinBRec = hostInWindow.recoveryLock.withLock {
            hostInWindow.sources = [directA.id: directA, activeB.id: activeB]
            hostInWindow.verificationState = .verified
            return hostInWindow.tracker.reconcileAfterRefresh(
                changed: true,
                activeSources: [
                    .init(id: directA.id, instanceID: directA.instanceID, hasFrame: directA.hasFrame),
                    .init(id: activeB.id, instanceID: activeB.instanceID, hasFrame: activeB.hasFrame),
                ],
                discoveredDeviceCount: 2)
        }
        XCTAssertTrue(
            joinBRec.postSwitchChecks.isEmpty,
            "an already in-flight post-switch timer must not be duplicated or pushed back on refresh")

        wait(for: [inWindowRestored], timeout: 1.0)
        queue.sync {}
        XCTAssertEqual(inWindowRestores, [922])
        XCTAssertEqual(inWindowStateDuringRestore, .pending)
        XCTAssertFalse(hostInWindow.scheduledVerifications.isEmpty)
        XCTAssertNil(
            hostInWindow.recoveryLock.withLock {
                hostInWindow.tracker.activeSwitchEntryID(for: directA.instanceID)
            })
    }
}

private final class MockUSBConfigDeviceSession: USBConfigDeviceSession {
    let registryEntryID: UInt64
    var currentConfiguration: UInt8
    var openResults: [Bool] = []
    var setResults: [Bool] = []
    var setHistory: [UInt8] = []
    var onOpenSafely: (() -> Void)?
    var failNextPostSetReadback = false
    var overrideNextPostSetReadbackValue: UInt8?
    private var awaitingPostSetReadback = false

    init(registryEntryID: UInt64, initialConfiguration: UInt8) {
        self.registryEntryID = registryEntryID
        self.currentConfiguration = initialConfiguration
    }

    func getConfiguration() -> UInt8? {
        if awaitingPostSetReadback {
            awaitingPostSetReadback = false
            if failNextPostSetReadback {
                failNextPostSetReadback = false
                return nil
            }
            if let override = overrideNextPostSetReadbackValue {
                overrideNextPostSetReadbackValue = nil
                return override
            }
        }
        return currentConfiguration
    }

    func openSafely() -> Bool {
        if !openResults.isEmpty, !openResults.removeFirst() {
            return false
        }
        let hook = onOpenSafely
        onOpenSafely = nil
        hook?()
        return true
    }

    func close() {}

    func setConfiguration(_ value: UInt8) -> Bool {
        if !setResults.isEmpty, !setResults.removeFirst() {
            return false
        }
        setHistory.append(value)
        currentConfiguration = overrideNextPostSetReadbackValue ?? value
        awaitingPostSetReadback = true
        return true
    }
}

private final class MockValeriaRecoverySource: CaptureValeriaRecoverySource, StoppableCaptureSource {
    let id: String
    let instanceID = UUID()
    var pinnedUSBDevice: USBValeriaConfigurator.PinnedUSBDevice?
    private let stateLock = NSLock()
    private var connected = true
    private var frameAvailable = false
    private var restarts = 0
    private var errors: [String] = []

    init(id: String, pinnedUSBDevice: USBValeriaConfigurator.PinnedUSBDevice? = nil) {
        self.id = id
        self.pinnedUSBDevice = pinnedUSBDevice
    }

    var isDeviceConnected: Bool {
        get { stateLock.withLock { connected } }
        set { stateLock.withLock { connected = newValue } }
    }

    var hasFrame: Bool {
        get { stateLock.withLock { frameAvailable } }
        set { stateLock.withLock { frameAvailable = newValue } }
    }

    var hasCaptureError: Bool {
        stateLock.withLock { !errors.isEmpty }
    }

    var recordedErrors: [String] {
        stateLock.withLock { errors }
    }

    var restartCount: Int {
        stateLock.withLock { restarts }
    }

    func restart() {
        stateLock.withLock { restarts += 1 }
    }

    func recordRecoveryError(_ message: String) {
        stateLock.withLock { errors.append(message) }
    }

    func stop(completion: (() -> Void)?) {
        completion?()
    }
}

private final class MockValeriaRecoveryHost: CaptureValeriaRecoveryHost {
    let recoveryLock = NSLock()
    let recoveryQueue: DispatchQueue
    var stopped = false
    var lifecycleGeneration: UInt64 = 1
    var sources: [String: MockValeriaRecoverySource] = [:]
    var identityGeneration: UInt64 = 1
    var verificationState: ScreenCaptureIdentityState = .singleDevice
    var tracker = CaptureValeriaRecoveryTracker()
    var gateNotifications = 0
    var scheduledVerifications: [UInt64] = []

    init(queue: DispatchQueue) {
        self.recoveryQueue = queue
    }

    var isRecoveryStoppedLocked: Bool { stopped }
    var recoveryLifecycleGenerationLocked: UInt64 { lifecycleGeneration }
    var recoverySourcesLocked: [String: MockValeriaRecoverySource] { sources }
    var recoveryIdentityGenerationLocked: UInt64 { identityGeneration }
    var recoveryVerificationStateLocked: ScreenCaptureIdentityState { verificationState }

    func withValeriaTrackerLocked<T>(_ body: (inout CaptureValeriaRecoveryTracker) -> T) -> T {
        body(&tracker)
    }

    func enterMultiDevicePendingForValeriaLocked() {
        identityGeneration &+= 1
        verificationState = .pending
    }

    func notifyScreensChangedAfterValeriaGate() {
        gateNotifications += 1
    }

    func scheduleValeriaIdentityVerification(
        generation: UInt64,
        sources: [String: MockValeriaRecoverySource]
    ) {
        scheduledVerifications.append(generation)
    }

    func setSources(
        _ list: [MockValeriaRecoverySource],
        verificationState: ScreenCaptureIdentityState
    ) {
        recoveryLock.withLock {
            sources = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            _ = tracker.retain(sources: Set(list.map(\.instanceID)))
            identityGeneration &+= 1
            self.verificationState = verificationState
        }
    }

    func stop() {
        recoveryLock.withLock {
            stopped = true
            lifecycleGeneration &+= 1
            sources.removeAll()
            _ = tracker.reset()
            identityGeneration &+= 1
        }
    }
}
