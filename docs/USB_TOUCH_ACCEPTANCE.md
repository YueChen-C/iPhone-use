# Experimental USB touch acceptance

This is an evidence record, not a general compatibility or release-readiness
claim. PR #14 remains Draft. No Apple DDI payload, personal device identifier,
raw device log or screenshot is included here. Source and licensing review is
not completed; no child-directory license is added in this stage.

## Tested configuration

- Runtime source: `460237b79649c42553bde0d5e00c27c9b157d96a`.
- Native Swift application and its own isolated USB worker on arm64 macOS.
- Host CoreDevice private ABI `397.24`; Apple-installed MobileDevice
  `1827.100.17.100.1`.
- One iPhone 12, iOS `26.5` / build `23F77`, DDI `27B52` / CoreDevice `651.32`,
  active portrait display at `1170 × 2532`.
- Bluetooth manager explicitly disabled, no Bluetooth hosts, USB explicitly
  selected for the target. A second captured phone retained its BLE selection
  and disconnected state; it received no input.
- AssistiveTouch remained enabled. Nothing in this record proves it unnecessary.

## Bounded prolonged native acceptance — 2026-11-13

Twelve alternating MCP swipes were sent to the exact target phone, one at a time,
with **15 seconds requested duration per gesture**. Requested contact duration
totaled **180 seconds**. The observation window from the first intent to the last
resource sample was **619.788 seconds**, including screenshot review and gaps;
this is not a claim of ten minutes of uninterrupted contact.

Each step initialized the application-native MCP, listed devices, sent one
gesture and returned a fresh frame. Each resulting frame was individually viewed
before the next step. The General settings list alternated between the expected
two scroll positions and ended at its initial top position. No setting was
changed and no request failed, timed out or required replay.

| Observation | Result |
| --- | --- |
| Native MCP gesture calls | 12 completed, process exit 0, empty stderr, no tool error |
| Application and USB worker | Same two processes throughout; no restart or worker replacement |
| Sampled numeric file descriptors | Application 21; worker 6, unchanged at every pre/post sample |
| Application RSS | 233680–333408 KiB; first 290608, last 258896 KiB |
| Worker RSS | 5968–6416 KiB; first 6064, last 6320 KiB |
| Target route and readiness | USB ready throughout; Bluetooth manager disabled |
| Second captured phone | No input sent; before/after PNG bytes exactly identical |
| Mounted-image readback | Native inspection exit 0; still 27B52 / 651.32 |

RSS fluctuated and the window is bounded. These samples do **not** prove no memory
leak, an end-to-end latency SLA, all-day stability or concurrent dual-USB input.
Both phones being captured is not equivalent to both phones receiving input.
Each fresh MCP process also does not prove a single persistent MCP session soak.

Only documentation changed after this run; there was no rebuild, binary
replacement, DDI mutation or local unit-test rerun in this stage. Device-specific
commands, literal stdout/stderr, exit statuses, frame hashes and process/resource
samples are retained in the local verification ledger, not the public PR.

## Native USB keyboard acceptance — 2026-11-14

The same arm64 Swift application was rebuilt with Bluetooth disabled and the target explicitly
selected over USB. Read-only `universalhidservice` discovery returned a dynamic `Keyboard`
surface (observed ID 512) whose public usage fields are zero; the implementation matches the
original HID usage pair (page 1, usage 6) and refuses ambiguity. The exact CoreDevice keyboard
report is a 31-byte report (ID 1, usage bitmap, modifier usages E0–E7, flags byte); no boot-keyboard
8-byte report or Python/runtime helper is used.

- HTTP `/type` entered `USB-input` in the iOS Settings search field; the following screenshot showed
  the exact text. HTTP `/key` sent Backspace and the following screenshot showed the deletion.
- HTTP `/key` sent Command-A and Enter; iOS showed the native selection/commit behavior. A later
  `/type` request with Chinese `蓝牙` produced the exact Chinese result and the screenshot/OCR read
  `蓝牙`; this records the observed IME state, not a universal candidate-selection guarantee.
- MCP `type_text` and `press_key` reached the same `/type` and `/key` routes; the MCP response and
  final screenshot/OCR were successful. The desktop window sent Cmd-A, Backspace, letters and
  Backspace through the USB keyboard capability; no HTTP input was used for that check.
- `/status` remained `bluetooth=disabled`, target USB `ready`, capabilities `tap/swipe/drag/text/key`,
  and the other captured phone stayed on BLE with no input. Shutdown logged a confirmed USB
  release/worker-exit barrier.

This is acceptance of the tested iPhone 12 / iOS 26.5 / DDI 27B52 combination only. It does not
claim every iOS IME, keyboard surface layout, rotation, reconnect, or alternate CoreDevice ABI.
In particular, `clear_before` uses native Cmd-A/Backspace: with an uncommitted marked-text
candidate, iOS can apply it only to the current composition, leaving preceding text intact.
Commit/cancel the composition explicitly before replacing the whole field. This limitation was
observed in Settings search; it is not treated as successful full-field replacement.

## Unsupported-device fallback

Runtime `80908a47314a6626e2459e95dca32d339b3251ed` was deployed after the owned
previous application confirmed USB release and worker exit. With Bluetooth
disabled, a second phone (iPhone SE 2, iOS 15.4, existing legacy developer image)
was absent from a read-only CoreDevice check-in performed before any usage
assertion. Explicit USB selection reported unavailable; subsequent explicit BLE
selection completed and the failed worker exited. This proves route recovery,
not connected-BLE input or USB support for that phone.

No touch input, DDI mutation or AssistiveTouch change occurred. Both phones'
before/after PNGs were byte-identical; the supported phone retained the same ready
USB worker. Existing focused tests were not rerun, and latest-build GUI and
whole-product DDI recovery acceptance remain open.

## Acceptance boundary

Prior stages established native HTTP/MCP touch, explicit USB/BLE routing and
retirement, normal native cancellation, shutdown release barriers, and historical
GUI click/held-drag/release/wheel behavior. Focused injected-transport tests cover
several failure branches; they are not hardware-failure observations.

The current run does not close these remaining gates:

- Latest-build interactive GUI mouse/wheel and DDI review acceptance on an
  unlocked desktop. The desktop was at the login window; no mouse event was sent.
- Product-native authorized DDI switching and complete/interrupted recovery after
  clean closure of all input owners. Discovery or historical experiment calls
  are not this acceptance. Other tasks' processes must not be killed or bypassed.
- Connected-BLE regression, physical rotation/unplug/reconnect, concurrent
  multi-device input isolation, and longer-duration stability coverage.
- AssistiveTouch-disabled validation was not performed. The user explicitly
  requested that AssistiveTouch remain unchanged; do not toggle it for acceptance
  or infer disabled-mode compatibility from the existing enabled-mode results.
- Authenticated source policy, licensing and distribution review. Integrity
  hashes and source-risk acknowledgement do not constitute these approvals.

See [product plan](USB_TOUCH_PRODUCT_PLAN.md),
[native DDI management](USB_DDI_MANAGEMENT.md), and
[user guide](user-guide.md) for implementation and operating boundaries.
