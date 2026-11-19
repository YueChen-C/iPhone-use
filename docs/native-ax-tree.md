# Native AX tree: direct capture and verification

## Purpose and interfaces

`GET/POST /ax_tree` and MCP `get_ax_tree` expose Accessibility data from the explicitly selected USB-connected iPhone. The implementation runs on the Mac and does not install a Runner, WDA or XCTest bundle on the phone. Unavailable services produce an error; there is no silent OCR fallback.

- Modern path: USB CoreDeviceProxy → negotiated tunnel/RSD → remote AX service → incremental DTX updates.
- Legacy path: lockdown AX Audit service → Inspector focus traversal and advertised read-only attributes.
- Capture runs in a separate process with a 25-second parent timeout, without creating another GUI, Bluetooth or video-capture owner.
- `--ax-server <device-id> <port>` starts an AX-only loopback listener for diagnostics; `--ax-tree` is the internal worker entry point.

See [Usage in Chinese](#中文使用说明) or the [English request examples](#english-usage) for device prerequisites and invocation. Only iOS 15.4 and 26.5 have been exercised on physical devices. The modern routing condition is not a compatibility guarantee for every iOS 17+ release, particularly the unvalidated iOS 17.0–17.3 USB CoreDeviceProxy path.

## English usage

HTTP `GET/POST /ax_tree` and MCP `get_ax_tree` read the native device AX hierarchy, never an OCR substitute. They require a trusted USB-connected device and available developer services. The iOS 17+ code path uses a CoreDevice tunnel with Developer Mode (the current USB CoreDeviceProxy path has not been validated on iOS 17.0–17.3, which are not promised to work); iOS 15/16 connects directly to the legacy lockdown AX Audit service and requires a matching DeveloperDiskImage already mounted (this feature does not download or mount images). Check UI Automation if the service is unavailable. Verified on iPhone 12 / iOS 26.5 (23F77) and iPhone SE / iOS 15.4; other versions, apps, and controls may differ.

```sh
curl --fail-with-body -sS http://127.0.0.1:7390/ax_tree \
  -H 'Content-Type: application/json' \
  -d '{"device":"<full-device-id>","include_offscreen":false}'
```

MCP example: `get_ax_tree({"device":"<full-device-id>","include_offscreen":false})`. The response includes `elements` (labels, roles, frames, states), application metadata, and orientation. `parent` is the parent's index in the returned array, or `null` for roots. Device-supplied fields may be absent. Coordinates use `coordinate_space: "ax_native"`; **do not use them directly as MCP screenshot pixels**.

`include_offscreen` defaults to `false` and prefers reported visible children, falling back to ordinary children when a visible set is not reported. `true` walks all children already returned by the service; it does not force offscreen content to load. The modern path merges received incremental updates until the quiet window or observation budget described below; `snapshot_complete: false` means this is not a guaranteed complete snapshot. Unavailable services return HTTP 503 / an MCP error without OCR fallback. An isolated worker has a 25-second timeout and starts no second Bluetooth or video session.

**iOS 15/16 limits:** `transport: "lockdown-audit"` and `scope: "inspector-focusable-elements"` identify the legacy result. Reading moves the Inspector focus and may scroll the viewport (`inspector_focus_changed` / `viewport_may_change: true`), without activation, clicks, or typing. Only device-provided partial parent/child relationships are returned; no application root or geometry is invented. `hierarchy_complete` is `false`. The verified legacy samples do not expose geometry (`geometry_available: false`), so they provide no coordinates for clicking. The daemon may truncate text (`text_may_be_truncated: true`); `include_offscreen=true` is rejected explicitly. Normal completion waits for monitoring-disable and cleanup replies (`cleanup_acknowledged: true`), which do not promise restoration of the previous Inspector focus or viewport. Current real-device validation covers some lock/notification and Home screen states, not arbitrary applications.

**Enhanced direct capture (no Runner):** On iOS 17+, merge subsequent updates instead of returning the first usable tree. Capture ends after 600ms without attribute changes or an 8-second observation deadline. Neither is a service snapshot-complete marker: `snapshot_complete` remains `false`. `capture` reports the reason, message count and attribute revisions. `raw_attributes` preserves every received attribute, including unknown IDs; binary values use explicit `$type: data` / base64 objects. Already received nodes outside the selected root/visible traversal are kept in `unreturned_elements`, without inventing parent links. `coverage` reports received/returned/framed counts, `missing_frame_ids`, `unresolved_children`, and nodes whose children were not reported. Unverified active attribute requests are not sent (`active_attribute_query_performed: false`); receiving every server-side node is not guaranteed.

Legacy capture preserves `raw_inspector_focus`, `raw_hierarchy_node` and `raw_attributes`, and reads attributes the device advertises explicitly as non-actions. It skips actions and sends no attribute setters. `attribute_status` distinguishes advertised names, nil values and budget-deferred reads; `coverage.uninspected_ids` identifies hierarchy nodes not inspected in focus. A `frame` is emitted only for a validated, device-advertised Frame/AXFrame/accessibilityFrame value. Otherwise `geometry_capability: not-observed` describes the observation, not an OS capability limit. Even observed per-focus frames have `geometry_simultaneous: false`, because focus traversal may scroll. Attribute reads have a 12-second/4096-query budget, excluding blocking service calls; the outer worker still has a 25-second timeout.

Legacy traversal sets `traversal_complete: true` when focus returns to the first node. A repeated different node returns the observed nodes with `traversal_complete: false` and `termination_reason: "revisited-focus-node"`. Neither outcome guarantees a complete snapshot.

For AX-only debugging, run `.build/debug/iphone-use --ax-server <full-device-id> 7393` and query `/ax_tree` on that port. This AX-only listener does not provide screenshots or input endpoints, but legacy reads can still move focus and scroll the viewport.

## 中文使用说明

HTTP `GET/POST /ax_tree` 与 MCP `get_ax_tree` 可读取真机原生 AX 层级，不使用 OCR 替代。需要通过 USB 连接并信任的设备及可用的开发者服务。iOS 17+ 代码路径使用 CoreDevice 隧道，需开启开发者模式（当前 USB CoreDeviceProxy 路径未验证 iOS 17.0–17.3，不承诺这些版本可用）；iOS 15/16 使用 lockdown 直连旧版 AX Audit 服务，需已挂载匹配的 DeveloperDiskImage（本功能不会自动下载或挂载镜像）。服务未开放时检查 UI Automation 设置。目前已在 iPhone 12 / iOS 26.5（23F77）与 iPhone SE / iOS 15.4 上验证；不保证所有系统版本、应用或控件都能提供完整语义。

```sh
curl --fail-with-body -sS http://127.0.0.1:7390/ax_tree \
  -H 'Content-Type: application/json' \
  -d '{"device":"<完整设备ID>","include_offscreen":false}'
```

MCP 参数示例：`get_ax_tree({"device":"<完整设备ID>","include_offscreen":false})`。返回 `elements`（`label`、`role`、`frame`、状态等）、应用信息和方向；`parent` 是父元素在该数组中的索引，根为 `null`。字段由设备提供，可能缺省。`coordinate_space: "ax_native"` 表示设备 AX 原生坐标，**不能直接当作 MCP 截图像素坐标点击**。

`include_offscreen` 默认为 `false`，优先沿设备报告的可见子节点遍历（未报告可见集合时使用普通子节点）；`true` 遍历服务已返回的全部子节点，但不会强制应用加载屏外内容。新版会合并已收到的后续增量，按下述静默窗口或预算结束；`snapshot_complete` 固定为 `false`，不承诺完整快照。服务不可用返回 HTTP 503 / MCP 错误；不会回退为 OCR。读取在独立进程中运行，25 秒超时，且不启动第二套蓝牙或视频采集。

**iOS 15/16 限制**：旧版返回 `transport: "lockdown-audit"`、`scope: "inspector-focusable-elements"`；读取会移动 Inspector 焦点，设备可能随焦点滚动页面（`inspector_focus_changed` / `viewport_may_change` 为 `true`），不执行激活、点击或输入。返回设备实际提供的局部父子关系，不补造应用根；`hierarchy_complete` 为 `false`；当前已验证的旧版样本没有几何属性，`geometry_available` 为 `false`，不能直接点击定位。旧版服务可能截短字段文字（`text_may_be_truncated: true`），不支持 `include_offscreen=true`，此时明确报错。正常完成后等待关闭监控和清理的回复；`cleanup_acknowledged: true` 仅表示服务确认收到清理，不承诺恢复调用前 Inspector 焦点或页面位置。当前真机验证覆盖部分锁屏／通知界面和主屏幕状态，不代表任意应用均支持。

**直连采集增强（不安装 Runner）**：iOS 17+ 不再在第一份可用树到达时立即返回，而是合并后续增量，在属性变化静默 600ms 后结束，最长采集 8 秒；这不是服务提供的完整快照标记，`snapshot_complete` 仍为 `false`。`capture` 返回结束原因、消息数和属性修订数。所有已收到的节点属性（包括未知编号）保留在 `raw_attributes`；二进制值使用显式 `$type: data` / base64 包装。未沿当前根/可见路径输出的已接收节点在 `unreturned_elements` 中，不能据此补造父关系。`coverage` 列出已接收/已输出/有坐标数量、`missing_frame_ids`、`unresolved_children` 与未报告孩子集合的节点。目前不发送未经验证的主动属性补查，`active_attribute_query_performed` 为 `false`，不保证所有服务端节点都已收到。

旧版对每个焦点保存原始 `raw_inspector_focus`、`raw_hierarchy_node` 和 `raw_attributes`，并读取设备实际声明且明确不是动作的 Inspector 属性，跳过动作属性，不尝试设置。`attribute_status` 区分设备声明属性、返回空值及预算内未读取项；`coverage.uninspected_ids` 列出只在层级中看到、未焦点检查的节点。仅当设备实际声明并返回可验证的屏幕 Frame/AXFrame/accessibilityFrame 时输出 `frame`；否则 `geometry_capability: not-observed`，不是系统不支持几何的结论。即使得到旧版逐焦点 frame，`geometry_simultaneous: false`，因为读取期间可能滚动，不能拼成同时有效的点击坐标。读取预算为 12 秒/4096 次属性查询（不含服务阻塞，外层仍有 25 秒 worker 超时）。

旧版焦点遍历若回到首节点，`traversal_complete` 为 `true`；若重复遇到其他节点则为 `false`，`termination_reason` 为 `revisited-focus-node`，仍返回已观察到的节点；两者均不代表完整快照。

仅调试 AX 时，可运行 `.build/debug/iphone-use --ax-server <完整设备ID> 7393`，再访问该端口的 `/ax_tree`；该 AX 专用监听器不提供点击、截图等接口，但旧版读取仍可能移动焦点和页面。

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
