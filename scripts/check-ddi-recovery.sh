#!/bin/sh
# Opt-in native process-level check; no phone or global DDI state is accessed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ "$#" -gt 1 ]; then
    echo "Usage: check-ddi-recovery.sh [NEW_OUTPUT_DIRECTORY]" >&2
    exit 64
fi
if [ "$#" -eq 1 ]; then
    mkdir -m 700 "$1"
    OUTPUT=$(CDPATH= cd -- "$1" && pwd -P)
else
    OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/iphone-use-ddi-recovery.XXXXXX")
    OUTPUT=$(CDPATH= cd -- "$OUTPUT" && pwd -P)
    trap 'rm -rf "$OUTPUT"' EXIT HUP INT TERM
fi
cd "$ROOT"
swiftc Sources/iPhoneUse/Input/USB/DDIBundlePreflight.swift \
    Sources/iPhoneUse/Input/USB/NativeDDIInspection.swift \
    Sources/iPhoneUse/Input/USB/DDIProcessLease.swift \
    Sources/iPhoneUse/Input/USB/DDITransactionStore.swift \
    Sources/iPhoneUse/Input/USB/DDITransaction.swift \
    Tests/NativeDDIRecovery/main.swift -o "$OUTPUT/recovery-check"
"$OUTPUT/recovery-check" matrix "$OUTPUT"
