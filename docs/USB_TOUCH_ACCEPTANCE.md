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
