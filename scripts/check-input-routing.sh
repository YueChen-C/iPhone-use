#!/bin/sh
# Opt-in native routing matrix; simulated capture/BLE/RemoteXPC only, no phone.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ "$#" -gt 1 ]; then
    echo "Usage: check-input-routing.sh [NEW_OUTPUT_DIRECTORY]" >&2
    exit 64
fi
if [ "$#" -eq 1 ]; then
    mkdir -m 700 "$1"
    OUTPUT=$(CDPATH= cd -- "$1" && pwd -P)
else
    OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/iphone-use-input-routing.XXXXXX")
    OUTPUT=$(CDPATH= cd -- "$OUTPUT" && pwd -P)
    trap 'rm -rf "$OUTPUT"' EXIT HUP INT TERM
fi
cd "$ROOT"
swiftc Tests/NativeInputRouting/Support.swift \
    Sources/iPhoneUse/Localization/AppLanguage.swift Sources/iPhoneUse/Localization/StringsAPI.swift \
    Sources/iPhoneUse/Bluetooth/HIDReports.swift Sources/iPhoneUse/Bluetooth/HIDConnectionState.swift \
    Sources/iPhoneUse/Devices/RelativePointerScreenMatcher.swift \
    Sources/iPhoneUse/Input/LegacyPointer/RelativePointerCalibration.swift \
    Sources/iPhoneUse/Input/LegacyPointer/PointerMotionObservation.swift \
    Sources/iPhoneUse/Input/LegacyPointer/AutomaticPointerCalibration.swift \
    Sources/iPhoneUse/Input/DeviceInput.swift Sources/iPhoneUse/Input/KeyboardMap.swift \
    Sources/iPhoneUse/Input/InputBackend.swift Sources/iPhoneUse/Input/TextEntry.swift \
    Sources/iPhoneUse/Capture/ScreenOCR.swift Sources/iPhoneUse/Input/USB/USBKeyboard.swift \
    Sources/iPhoneUse/Input/USB/USBPreparationFailure.swift Sources/iPhoneUse/Input/USB/USBInputFailure.swift \
    Sources/iPhoneUse/Input/USB/USBTouchSession.swift Sources/iPhoneUse/Input/USB/USBTouchClient.swift \
    Sources/iPhoneUse/Input/USB/USBTouchWorker.swift Sources/iPhoneUse/Input/USB/USBInputController.swift \
    Tests/NativeInputRouting/main.swift -o "$OUTPUT/input-routing-check"
for mode in normal backpressure held-pointer queued-key usb-release-failure buttons without-buttons button-release-failure; do
    mkdir -m 700 "$OUTPUT/$mode"
    INPUT_ROUTING_FIXTURE_ROOT="$OUTPUT/$mode" "$OUTPUT/input-routing-check" "$mode"
done
