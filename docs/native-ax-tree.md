# Native AX tree: direct capture and verification

## Purpose and interfaces

`GET/POST /ax_tree` and MCP `get_ax_tree` expose Accessibility data from the explicitly selected USB-connected iPhone. The implementation runs on the Mac and does not install a Runner, WDA or XCTest bundle on the phone. Unavailable services produce an error; there is no silent OCR fallback.

- Modern path: USB CoreDeviceProxy → negotiated tunnel/RSD → remote AX service → incremental DTX updates.
- Legacy path: lockdown AX Audit service → Inspector focus traversal and advertised read-only attributes.
- Capture runs in a separate process with a 25-second parent timeout, without creating another GUI, Bluetooth or video-capture owner.
- `--ax-server <device-id> <port>` starts an AX-only loopback listener for diagnostics; `--ax-tree` is the internal worker entry point.

See the [README](../README.en.md#native-accessibility-tree) for request examples and device prerequisites. Only iOS 15.4 and 26.5 have been exercised on physical devices. The modern routing condition is not a compatibility guarantee for every iOS 17+ release, particularly the unvalidated iOS 17.0–17.3 USB CoreDeviceProxy path.

## Output and completeness

`elements` contains device-provided labels, values, roles, states and geometry where available. `parent` is an index into that array; roots have `null` parents. Fields may be absent. `raw_attributes` preserves received properties, including unknown IDs; binary values are represented explicitly as base64 data objects. Unknown archived classes are decoded into inert values rather than instantiated.

The modern collector merges updates until 600 ms without attribute changes, an 8-second observation budget, or a message limit. `capture` explains termination. `coverage` identifies missing frames, unresolved child references and missing child reports. Received nodes outside the chosen traversal remain in `unreturned_elements` without invented parent links. Active attribute/child requery is not implemented.

**Neither path guarantees a complete or atomic snapshot.** `snapshot_complete` and `hierarchy_complete` remain false. `include_offscreen=true` only follows already received children; it does not load future or virtualized content. Legacy capture explicitly rejects that option.

## Legacy behavior and geometry limits

Legacy reads move the Inspector focus and may scroll the viewport. They do not activate controls, click, type or set attributes. Completion acknowledges disabling monitoring and final cleanup; it does not promise restoration of the previous focus or viewport. Reaching the first focus token again is traversal termination, not proof of a complete AX tree.

The implementation reads only attributes the device explicitly advertises as non-actions and preserves nil/deferred status. It emits an ordinary frame only when an advertised geometry property returns a validated rectangle. Otherwise `geometry_capability: not-observed` describes the observed interface, not a platform-wide inability to represent geometry. Sequential focus traversal is not simultaneous geometry.

A separate local diagnostic on iOS 15.4 obtained **two unique nonzero native rectangles** from audit issues (`AXAuditIssue_v1.ElementRectValue_v1`). A broader audit returned five issue entries: one duplicate and two zero-area entries were excluded. The corrected probe completed with exit 0 and acknowledged cleanup. This is **issue-only geometry**, not every ordinary AX node's frame, and it is **not integrated into the product endpoint in this PR**. Pages without relevant audit issues may provide no rectangles through that approach.

The diagnostic had an initial focus-enrichment timeout on invalid/zero-area issue tokens; skipping those and deduplicating before focus lookup fixed the observed run. Experimental binaries, screenshots, device identifiers, private-framework dumps and raw phone contents are retained locally and are not included in this change.

## Using the data to operate the phone

AX data is suitable for identifying a candidate by label/identifier, role, hierarchy and state. A valid `activation_point`, when available, is preferable to blindly assuming a bounding-box center is actionable; neither guarantees successful input.

Coordinates are marked `ax_native`. They must not be passed directly as screenshot pixels to `tap`. Validate the coordinate space, viewport, orientation and dimensions first; then convert into the input API's screenshot coordinates or per-axis normalized coordinates. Reacquire after scrolling, rotation or navigation, and verify the result after each action. Existing pointer/Bluetooth readiness is still required: this feature adds observation, not an AX-node-ID activation API.

For the tested modern device, AX can guide target selection and candidate positioning with screenshot verification. For the tested legacy device, ordinary frames are absent, so screenshots/OCR remain necessary for general coordinate targeting. AX-guided clicking has not been verified end to end by these capture checks.

## Validation evidence

Physical-device captures used the same Release implementation, without installing a Runner:

| Sample | Returned nodes | Ordinary frames | Notes |
| --- | ---: | ---: | --- |
| iPhone SE / iOS 15.4, earlier capture | 33 | 0 | Advertised Inspector attributes retained |
| iPhone 12 / iOS 26.5, earlier capture | 23 | 23 | Incremental capture with raw attributes |
| iOS 15.4, subsequent capture | 32 | 0 | 250 attribute reads; 7 hierarchy-only/uninspected nodes |
| iOS 26.5, subsequent capture | 15 | 15 | Quiet-window termination; not a complete snapshot |

These are different live pages/states, **not a controlled cross-version coverage comparison**. Device captures were recorded before PR publication and are not claimed to have been rerun during publication.

An existing fixed-input copy/patch/rollback transaction observed the following literal outputs (exit 0 and empty stderr in all three cases):

```text
BASELINE: nodes=2 raw_unknown=false missing_frames=-1 unresolved_children=-1
MODIFIED: nodes=2 raw_unknown=true missing_frames=2 unresolved_children=1
ROLLBACK: nodes=2 raw_unknown=false missing_frames=-1 unresolved_children=-1
```

The rollback restored all 12 recorded baseline hashes, and reapplying the patch reconstructed all 11 changed/new files exactly. This verifies the incremental/raw-attribute change against its earlier implementation, not the entire feature against `main`. These transaction results are reused, not rerun during publication. A later publication-only README correction does not alter runtime code or those historical results.

Unit tests cover incremental merging and deadlines, a single pending read, unknown values, malformed/cyclic archives, strict geometry parsing, legacy focus traversal/cleanup, skipping action attributes, endpoint error propagation and MCP forwarding without screenshot/OCR fallback. A synthetic legacy frame test verifies decoding, not actual iOS 15.4 frame availability.

<!-- publication-validation -->
Publication validation (2026-11-12, native arm64 macOS):

- `/usr/bin/arch -arm64 /usr/bin/swift test --arch arm64`: **482 tests passed**, exit 0.
- `/usr/bin/arch -arm64 /usr/bin/swift build --arch arm64 -c release`: **passed**, exit 0.
- `/usr/bin/python3 -B -m unittest discover -s Tests/PythonTests -v`: **92 tests passed**, exit 0.
- Staged whitespace checks passed; raw device evidence and diagnostic binaries are excluded.

The initial unqualified `swift test` selected x86_64/Rosetta on this arm64 host and was manually interrupted while running an existing calibration test (exit 1). The explicit arm64 full rerun above passed without changing or skipping tests. These are Mac unit/build/integration checks, not new phone captures or an on-device XCTest Runner installation.
<!-- /publication-validation -->

## References and evidence limits

- [Apple accessibilityFrame](https://developer.apple.com/documentation/uikit/uiaccessibilityelement/accessibilityframe): the platform defines screen-coordinate geometry. This does not guarantee that a particular private remote Audit interface exposes it.
- [pymobiledevice3 legacy Audit implementation](https://github.com/doronz88/pymobiledevice3/blob/2c16b68243654479a11d9a80322c469ef3740864/pymobiledevice3/services/accessibilityaudit.py): protocol reference for focus traversal and audit issues, not an Apple wire-protocol guarantee.
- [go-ios real-device geometry observations](https://github.com/danielpaulus/go-ios/blob/794aab7018a053b3be9090930c8dba545abbf317/ios/accessibility/ax_audit.go#L11-L35): corroborates ordinary geometry queries returning nil while audit issues carry rectangles. Its audit-type version assumptions differ from the tested iOS 15.4 response; use actual device-advertised values rather than hard-coding that assumption.

The feature depends on private Apple device services and dynamically resolved system symbols. Availability, fields and wire formats may change. No numeric-coordinate entry in the official Accessibility Inspector GUI, universal full-tree retrieval, arbitrary-version support, or all-node clickability is claimed.
