# Experimental USB touch acceptance

This is a scoped evidence summary, not a compatibility or release-readiness claim.
PR #14 remains Draft. Raw device logs, identifiers, screenshots, DDI payloads and
source rollback records stay local. Source/licensing review is incomplete; no
child-directory license is added. Earlier step-by-step development history has
been consolidated here; injected fixtures and hardware observations remain distinct.

## Tested configuration

- arm64 macOS; native Swift application and its own isolated USB worker.
- Host CoreDevice private ABI `397.24`; MobileDevice `1827.100.17.100.1`.
- iPhone 12, iOS `26.5` / `23F77`, DDI `27B52` / CoreDevice `651.32`, active
  portrait `1170 × 2532`. Other combinations are not accepted by this record.
- Bluetooth manager disabled, no connected BLE hosts; explicit target USB route.
- A second captured phone retained its own route and received no input. This is
  single-target isolation, not simultaneous dual-device input acceptance.
- AssistiveTouch remained enabled. Its necessity has not been established; the
  user explicitly deferred changing it.

## Touch, desktop and routing

| Hardware observation | Accepted scope |
| --- | --- |
| HTTP/native MCP tap/swipe, OCR `tap_text` and `act` navigated General/About with reviewed frames | Selected USB route works without Bluetooth input |
| Foreground/owner-guarded existing AppKit control window clicked, held for 0.8 seconds, dragged through 24 steps, released and scrolled by wheel | Existing desktop mouse path, no separate DDI test GUI |
| A window click during an admitted two-second HTTP hold was refused; a fresh later click worked | One hardware busy-input case; no delayed replay |
| Explicit backend switch interrupted long touch/keyboard work, returned uncertain delivery and retired the worker | Release/exit gating and no automatic fallback/replay; not physical unplug |
| Owned app SIGTERM during a five-second hold exited about 0.62 seconds later with confirmed release/worker-exit barrier and exit 0 | One normal signal shutdown, not crash-time release or failed-release hardware proof |
| Unsupported iPhone SE 2 / iOS 15.4 was unavailable to read-only CoreDevice discovery; explicit BLE reselection completed | Route recovery only; neither USB nor connected-BLE input acceptance for that device |
| Eleven malformed coordinate requests and oversized duration/path requests returned 400 with the same ready worker, followed by valid navigation | Parameter refusal before worker input, not fault injection into the phone |

Settled frames were inspected when immediate captures still showed transitions;
requests were not replayed to compensate for capture delay. No setting, iOS,
AssistiveTouch or host framework was changed during these input checks.

## Keyboard and text

The dynamic keyboard surface is recognized by its original HID usage page 1 /
usage 6 and virtual-service metadata, not its observed numeric ID or zero-valued
public usage fields. Reports are 31-byte CoreDevice bitmap reports with modifier
usages E0–E7 and explicit release, not eight-byte boot-keyboard reports. Touch and
keyboard share one worker/serial sender; missing keyboard capability does not
silently use BLE.

- HTTP `/type`, `/key`, native MCP text/key and desktop key events produced
  visually checked ASCII/editing results. Examples include `USB-input`, `native`,
  `safe`, `Gu`, and Backspace deletion. Named keys and Command/Shift modifiers
  were exercised; transport acknowledgement alone is not a text assertion.
- With the observed full-pinyin keyboard, default USB text requests produced
  committed `蓝牙`, switched to English for exact ASCII, and switched back for
  committed Chinese. A request for homophonic `栏牙` stopped with partial-input
  409 when the visible first candidate was `蓝牙`; no extra Space or submit followed.
- Unknown/hidden/wrong/stale mode evidence refused destructive edits. A mode
  toggle could already have occurred when text was refused. These are constrained
  screenshot heuristics, not authoritative IME identity or general Unicode support.
- Desktop physical pinyin keys produced marked composition; a separate observed
  Space committed the candidate. Cmd-A/Backspace sometimes affected only marked
  composition, **not the whole field**. Host-IME forwarding, arbitrary Unicode,
  whole-field clear and Universal Clipboard remain unaccepted.
- A single initialized native MCP connection completed 20 RPCs (19 tool calls)
  over 664 seconds, including navigation, text/deletion, Chinese, busy refusal and
  unsupported Home refusal, with the same app/worker and Bluetooth disabled.
- USB Search/Paste/Enter sidebar buttons were enabled only with keyboard support;
  Home/Power/Volume stayed disabled. Search/Enter received USB acknowledgements
  without an accepted phone-side shortcut effect. Paste was not pressed.

Current `/type` safety gates: complete stroke preflight; known initial mode;
one optional toggle with post-ACK retained-frame evidence; maximum two-second
frame age; exact requested first candidate before each Han run's planned Space;
and one shared four-second **cooperative observation budget**. Synchronous Vision
is checked on return, not forcibly interrupted. Missing evidence withholds remaining
keys and reports structured partial-input flags. Raw `/key` and window keys remain
explicit raw input. ASCII requests skip only the unused candidate-region detail
pass, not mode recognition or freshness checks. No diagnostics run on video publish.

## Bounded sessions and resources

| Run | Observations | Limit |
| --- | --- | --- |
| 12 alternating 15-second swipes; 180 seconds requested contact, 619.788-second observation window | Every result reviewed; same app/worker; sampled FD 21/6; app RSS 233680–333408 KiB, worker 5968–6416 KiB | Not ten minutes of continuous contact or a no-leak claim |
| 24 alternating two-second swipes over approximately 15 minutes | HTTP 200; reviewed frame groups; same worker; worker FD 6; worker RSS 8720–8848 KiB, app RSS 287536–311568 KiB | Not a memory plateau, high-load or long-term soak |
| 30-second idle after input | Matching list positions, no further scrolling observed | Full-frame hashes differed; byte identity is not claimed |

Peer before/after PNG bytes matched in scoped single-target runs. Resource point
samples and persistent MCP acceptance do not establish concurrent dual-USB input,
all-day stability, absence of leaks or a latency SLA.

## Native deterministic verification

Focused Swift tests exercise the actual production structures, with transport,
capture or clock injection where needed. Previous source-copy comparisons and
byte-exact rollback records are local, not device-operation rollback proof.

| Boundary | Verified with fixtures / focused tests |
| --- | --- |
| Surface/display discovery | Reject Boolean/fractional/negative/colliding IDs, ambiguous primary displays, coerced flags, invalid orientation/backlight/dimensions; valid touch survives absent keyboard |
| Admission/cancellation | Window click cannot queue behind API/key/wheel/release; stale completions cannot clear new barriers; key repeat bounded to 32 strokes and 0.5 seconds; continuous move/up cannot bypass display/60-second checks |
| Release/shutdown | Failed contact/key release gates new input; capture removal/remapping/revoked identity retires workers without window polling; shutdown includes preparing/retiring owners and registered transitions |
| Text evidence | Stale/missing/future frames, post-toggle/candidate boundaries, shared budget, exact candidate and final lease freshness, contradictory mode evidence and complete edit preflight |
| Native OCR | Saved frames reproduce compact A/拼 legends; exactly one substitution allowed only in a complete ordered keyboard row; unrelated/missing/reordered rows remain rejected |
| Delivery metadata | Pre-dispatch refusal vs uncertain ACK/write, earlier input in `/act`/keyboard sequences, no replay and no false UI-success assertion |
| Preparation/UI | Typed reasons survive worker/client/status; localized overlay/sidebar never grant readiness or show BLE repair controls in USB mode; offscreen rendering is not interactive hardware acceptance |
| DDI | Snapshot integrity/path/identity, durable phases, explicit recovery, admission and non-mutating discovery; see management guide |

`scripts/check-input-routing.sh` compiles production BLE FIFO and USB
controller/client/session/worker sources with simulated boundaries. Its five
subprocess modes cover normal switching, BLE backpressure, held-pointer stale
motion, queued keys and USB release failure, including peer isolation and no
replay. `scripts/check-ddi-recovery.sh` uses production transaction/store/lease
sources and six persisted interruption boundaries with a file-backed fake device.
Neither process matrix accesses a phone or the global DDI barrier. Both run in CI;
local tests are focused on changed behavior, not repeated full-suite runs.

## Product-native DDI hardware acceptance — 2026-11-15

After explicit authorization, the idle legacy MCP was normally closed and the
owned application confirmed USB release/worker exit and exited 0. The unchanged
product-native executable and pinned candidate/baseline plans were used; no Python,
external mounter, host replacement or iOS upgrade was involved.

1. Native `ddi apply` switched baseline `27B52 / 651.32` to `16B40 / 397.24`;
   independent metadata confirmed it. The old-image worker refused unavailable
   universal HID before input (exit 70). Explicit native `ddi restore` returned
   exit 0 with the exact baseline build/version/signature; the worker again
   reported touch/keyboard readiness and confirmed release.
2. In a separate transaction, a process sample showed
   `AMDeviceMountPersonalizedBundle` while the journal persisted `mounting`.
   SIGTERM interrupted only the owned manager child. The phone later reported
   the old candidate mounted: **process termination did not cancel the device operation**.
3. Pending recovery survived. Fresh GUI/MCP/worker entries all exited 78. Explicit
   native restore reached `restored` and cleared pending; final inspection JSON
   was byte-identical to the initial inspection. After explicit app restart,
   reviewed USB taps opened About and returned to General with Bluetooth disabled.
   The peer received no input and its before/after PNG bytes matched.

This accepts one normal product-native cycle and **one sampled in-call mount
interruption**, not power loss, physical unplug, all-phase hardware faults or
crash-time touch release. No SIGKILL or AssistiveTouch change occurred in this
hardware run. Source rollback does not restore the phone's DDI or clear pending.
The third-party image's pins are integrity evidence, not authenticated Apple
provenance or license/distribution clearance. See [DDI management](USB_DDI_MANAGEMENT.md).

## Acceptance boundary

Still open: connected-BLE input regression; real rotation/unplug/reconnect;
concurrent dual-device input; longer stability; AssistiveTouch-off (user deferred);
interactive DDI plan/review window; other DDI interruption/fault phases; and
source/licensing/distribution/release review. Unsupported capability remains an
explicit error, not implicit BLE fallback. No current evidence closes these gates.

## Native phone buttons (2026-11-16)

Home, short Power/Lock and Volume Up/Down are now routed through optional
`com.apple.coredevice.hid.indigo`, using consumer page `0x0C` and usages
`0x40`, `0x30`, `0xE9`, `0xEA`. This corrects the earlier integration limitation,
not a platform prohibition. Desktop buttons, HTTP `/home`, `/power`, `/volume_up`,
`/volume_down`, matching MCP tools and `act` steps share the same native worker.
`press_key(home)` remains keyboard navigation Home. Older observations above
predate this implementation and are not evidence of successful button control.

236 focused Swift tests, 37 stdio MCP tests and eight native routing scenarios
passed. They cover request mapping, down/up/cancel, partial failures, release
barriers, settling, bounded window expiry and missing-service isolation. Actual phone UI effects and
state-dependent Power/wake behavior still require device acceptance. No DDI,
AssistiveTouch or Bluetooth fallback changes are required by this implementation.
