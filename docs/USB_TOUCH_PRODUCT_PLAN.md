# Native USB control integration plan

PR #14 adds experimental USB touch **and keyboard** control to this application.
Bluetooth remains the default; selection is explicit per full physical device ID.
The PR stays Draft until the remaining acceptance and release gates are resolved.

## Product contract

- Swift native implementation, with an isolated worker in the application's own
  executable. No Python, third-party runtime mounter or bundled Apple DDI.
- USB tap/hold/swipe, desktop down/drag/up and bounded wheel-to-swipe. Hover never
  sends a contact. Portrait only; changed/invalid display state stops input.
- USB keyboard surface discovery, text, named keys and modifiers share the same
  worker. Desktop Search/Paste/Enter use that surface. Home, short Power/Lock
  and Volume use the optional native `com.apple.coredevice.hid.indigo` service,
  never keyboard Home or BLE reports. Relative-pointer operations remain unsupported.
  Button release/PING is followed by a 0.8-second settle interval; transport ACK
  is not visible UI proof. Missing Indigo leaves touch/keyboard available.
  No long Power press, button combinations, automatic retries or wake guarantee.
- HTTP/MCP names and screenshot coordinate conventions remain compatible. Input
  is converted to bounded fractions once; malformed requests fail before dispatch.
- Successful transport acknowledgement is not observed UI completion. Uncertain
  delivery is never replayed, automatically retried or sent through another backend.
- No iOS upgrade, host-framework replacement or AssistiveTouch setting change.
  No child-directory license resource is added in this stage; attribution and the
  root license remain intact. Source/licensing/distribution review is deferred.

## Implemented architecture

```text
Desktop / HTTP / MCP / OCR tap_text / act
    -> USBInputController: per-device selection, generation and retirement
        -> BLE: existing DeviceInput -> HIDPeripheral
        -> USBDeviceInput: capture binding, admission and serial queue
            -> own --usb-touch-worker -> CoreDevice broker -> RemoteXPC
                -> DDI universalhidservice / dtuhidd -> touch + keyboard
                -> optional hid.indigo -> Home / Power short press / Volume

Local ddi CLI -> native MobileDevice -> durable plan/journal + explicit recovery
Capture -> existing ScreenCaptureManager, independent of input transport
```

| Component | Responsibility |
| --- | --- |
| `InputBackend.swift` | Production selection/generation gate and readiness vocabulary; no parallel test-only routing model |
| `USBInputController` / `USBDeviceInput` | Explicit selection, capture identity, serial dispatch, bounded window admission, cancellation and worker retirement |
| `DeviceRegistry` / `DeviceInput` | Existing BLE behavior; generation-bound input, stale queue invalidation and release/drain before switching |
| `CoreDeviceTouchBroker` / `USBTouchWire` | Verified private host ABI, exact USB UDID-to-CoreDevice identity and bounded native socket/codec |
| `USBTouchSession` / `USBKeyboard` | Dynamically discovered unique surfaces, validated reports, contact/key release and transport PING |
| `TextEntry` / `USBKeyboardModeOCR` | Complete edit preflight, fresh retained-frame mode/candidate evidence and one shared observation budget |
| `ControlAPI` / `MCPServer` / `PhoneControlView` | Existing entry points routed to the selected backend, with typed readiness/delivery errors and localized guidance |
| `DDIManagementCLI` / transaction/store/lease | Offline explicit management, staged snapshots, durable phases and persistent recovery admission barrier |

Full physical identity, capture association and worker lifetime are fixed for an
input session. There is no fuzzy device matching, first-device fallback or
independent USB-keyboard/BLE-touch route. Missing keyboard capability leaves
valid USB touch usable but rejects keyboard requests.

## Safety and performance boundaries

1. Backend selection invalidates the old generation and closes both routes.
   Previous USB release/PING **and worker exit**, plus BLE release/drain, must be
   confirmed before enabling the next route. Failure remains gated until explicit
   selection/recovery; process exit alone is not release proof.
2. API gestures, keyboard batches and wheel work share one dispatch-admission
   boundary. A window press cannot queue behind them or a pending release. Old
   completions cannot reopen newer barriers; stale repeat/motion work is dropped.
3. Display state is rechecked during continuous input, at most every 0.5 seconds;
   a held contact has a monotonic 60-second limit. Capture invalidation retires
   the owner even without a control window. Shutdown also drains preparation and
   registered transitions, failing closed on unconfirmed release.
4. `/type` confirms a known mode before destructive edits. One optional toggle
   requires a post-ACK frame; Han input requires the exact requested first
   candidate before its planned Space. Freshness and a shared four-second
   cooperative observation budget apply throughout. Raw keys remain raw keys;
   OCR is not an authoritative IME or text-result API.
5. Workers and serial queues are reused per device. No extra logging, hashing or
   broker probing runs in the video hot path. IPC, native IO and queued window
   input remain bounded. Tests run locally only for relevant changes; CI retains
   its normal suite and native process matrices.

## DDI lifecycle

Normal input never mounts, downloads or updates a DDI. Local `inspect/preflight`
are read-only; `plan` stages private pinned candidate/baseline snapshots after
checking the exact device/OS/current signature. Only offline `apply/restore` with
an exact plan hash and explicit source-risk acknowledgement can mutate a phone.
A shared lifetime lease covers every non-management entry; exclusive management
also conservatively rejects legacy app/MCP/AX processes. A persistent pending
barrier survives interruption and blocks input until explicit verified recovery.

The native review window only inspects/plans/reviews and copies commented mutation
templates; it does not mount or restore. Receipt hashes verify integrity, **not**
Apple provenance, licensing or distribution clearance. The current experimental
image is from a pinned third-party mirror. See
[DDI management](USB_DDI_MANAGEMENT.md) for commands and recovery rules.

## Milestones and current status

| Stage | Implemented / observed | Remaining gate |
| --- | --- | --- |
| M0 design | Draft PR, explicit scope, recoverable local evidence | Keep Draft until accepted |
| M1 routing | Production selection/generation gates; no silent fallback/replay | Connected-BLE hardware regression |
| M2 native backend | Own Swift worker, exact identity, dynamic touch/keyboard discovery | Other host ABI/device combinations |
| M3 API/MCP | Touch, OCR/act, text/keys, structured partial-delivery errors; persistent MCP acceptance | Broader IME/layout compatibility |
| M4 desktop | Backend selector, click/held drag/release/wheel, keys and localized readiness | DDI review-window interactive acceptance |
| M5 DDI | Product-native normal apply/restore and one sampled in-call interrupted mount recovered | Other fault phases; authenticated source/license policy |
| M6 resilience/release | Native routing/recovery matrices, bounded hardware sessions, single-target isolation | Rotation, unplug/reconnect, concurrent dual-device input, longer stability, release cleanup |

AssistiveTouch-off validation is explicitly deferred by the user. Existing
hardware acceptance covers iPhone 12 / iOS 26.5, DDI 27B52 / 651.32, arm64 host
CoreDevice 397.24 and MobileDevice 1827.100.17.100.1 only. It does not imply broad
compatibility, no leaks or all-phase hardware recovery.

The current results and exact evidence limits are consolidated in
[USB touch acceptance](USB_TOUCH_ACCEPTANCE.md); raw identifiers, logs, screenshots,
payloads and source rollback records stay local. Continue on the existing feature
branch and commit once per completed phase, not once per individual fix.
