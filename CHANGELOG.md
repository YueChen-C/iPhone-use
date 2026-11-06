# Changelog

本文件记录已发布版本的主要变化。历史安装包与发布说明见 [GitHub Releases](https://github.com/YueChen-C/iPhone-use/releases)。

This file records the main changes in each release. Earlier downloads and release notes are available on [GitHub Releases](https://github.com/YueChen-C/iPhone-use/releases).

## [v1.0.2](https://github.com/YueChen-C/iPhone-use/releases/tag/v1.0.2) — 2026-11-04

相对 [v1.0.1](https://github.com/YueChen-C/iPhone-use/releases/tag/v1.0.1) 的更新。

### 新功能

- 新增原生屏幕 OCR：通过 MCP `ocr_screen` 或 HTTP `/ocr` 读取文字，并使用 `tap_text` 按文字定位点击。
- 新增 MCP `act` 和 HTTP `POST /act`，按顺序执行点击、文字点击、滑动、输入、按键、Home、延迟和等待文字；步骤失败时停止后续操作。
- 中文输入支持汉字转拼音，并根据屏幕键盘文字尝试切换中文输入法；新增 `clear_before`、`commit_ime`、`press_enter`、`ensure_chinese_ime` 和 `use_clipboard` 选项。剪贴板输入通过 Command+V 粘贴，仍需满足 Apple 通用剪贴板的使用条件。
- 新增可选“后台静默常驻”模式，关闭窗口后保留服务，并在后台启动或接入设备时减少自动弹窗；无窗口且空闲 60 秒后暂停采集，收到请求时按需唤醒。
- 新增锁屏状态提示、控制窗口与 HTTP API 的电源按键，以及新的应用图标。

### 修复与改进

- 修复 iOS 26 自适应指针颜色和动态背景下的落点验证，恢复设备控制，并在重新验证成功后清除过期的校准要求。
- 减少设备匹配过程中的指针移动；指针未就绪时，坐标操作返回 HTTP 503，避免执行未经验证的操作。
- 改善 USB 投屏的即插即用激活、异步采集启停、异常退出后的恢复，以及多设备恢复流程；USB 配置调整增加路由保护和恢复记录。
- 改善已配对蓝牙 HID 设备的主动重连、休眠恢复、设备映射和多设备输入隔离，避免无输入需求的重连意外移动指针。
- 通过 OCR 缓存、设备列表短时缓存、动态画面稳定检测，以及 `observe=full|ocr_diff|none` 响应选项，减少重复识别与返回数据。
- MCP 显式归一化坐标统一采用每轴 `0...1000`（`normalized: true`）；普通像素坐标仍按截图尺寸解释。
- 补充 USB、蓝牙、OCR、批量操作、输入和后台模式的自动化测试；PR 合并要求通过 `Unit tests`，发布流程仍执行完整测试与 Universal 包验证。
- 中英文 README 补充后台模式说明与免责声明。

### Added

- Native screen OCR through MCP `ocr_screen` and HTTP `/ocr`, plus `tap_text` for tapping recognized text.
- MCP `act` and HTTP `POST /act` for ordered tap, text tap, swipe, type, key, Home, delay, and text-wait steps, stopping on the first failure.
- Chinese text entry through Hanzi-to-Pinyin conversion and a keyboard OCR heuristic for switching input methods. New options include `clear_before`, `commit_ime`, `press_enter`, `ensure_chinese_ime`, and `use_clipboard`; clipboard paste requires Apple Universal Clipboard to be available.
- Optional Quiet Background Mode keeps the service running after windows close and reduces automatic window opening. With no open windows, capture sleeps after 60 idle seconds and wakes on demand.
- Lock-screen notices, a power-key control in the window and HTTP API, and a new app icon.

### Fixed and improved

- Restored iOS 26 pointer verification across adaptive cursor colors and animated backgrounds, and cleared stale calibration requirements after successful verification.
- Reduced pointer movement during device matching. Coordinate actions return HTTP 503 while the pointer is not ready.
- Improved plug-and-play USB capture activation, asynchronous capture lifecycle, recovery after abnormal exits, and multi-device restoration, with route protection and persistent recovery records.
- Improved bonded Bluetooth HID reconnection, sleep recovery, device mapping, and multi-device input isolation, avoiding incidental pointer movement on reconnect.
- Reduced repeated OCR and response data with OCR caching, short-lived device-list caching, dynamic frame settling, and `observe=full|ocr_diff|none` options.
- Explicit MCP normalized coordinates use `0...1000` per axis with `normalized: true`; regular pixel coordinates continue to use screenshot dimensions.
- Expanded automated coverage for USB, Bluetooth, OCR, action batches, text input, and background mode. PRs require `Unit tests`; releases continue to run the full test and Universal package checks.
- Documented background mode and added disclaimers in both READMEs.

**Full Changelog:** [v1.0.1...v1.0.2](https://github.com/YueChen-C/iPhone-use/compare/v1.0.1...v1.0.2)
