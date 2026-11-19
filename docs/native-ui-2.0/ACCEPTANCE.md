# 原生 2.0 验证与验收边界

## 软件验证

本 PR 整理既有 2.0 开发分支成果。提交前核对当前源码/测试与最后已验证源码归档一致；不为提交 PR 重跑全量测试，不重启当前服务，不向手机发送动作。

| 范围 | 已执行结果 | 说明 |
| --- | --- | --- |
| 早期工作台集成回归 | Swift 743 项，6 项既有 fixture 跳过，0 失败；Python 95 项通过 | 历史阶段结果，不代表最终全部改动重新全量验收 |
| 样式、分页、按钮、弹窗、文本、设备身份 | 开发各阶段执行对应定向检查 | 与实际修改范围匹配，不用离线 fixture 代替真机验收 |
| 最后 USB 恢复修复 | 27 项定向测试，0 失败 | 下方命令；包含后端默认值、持久化、兼容性和 USB 展示 |
| 最后 Release 编译 | `swift build -c release`，退出 0 | 已应用到本地开发版本，非公证发行包 |
| USB 恢复/回滚 | 相同输入的 BASELINE、MODIFIED、ROLLBACK、重新应用均退出 0；9 个文件原哈希恢复一致 | 在独立副本执行，不回滚运行中的工作区 |

最后一次 USB 定向检查：

```sh
swift test --filter 'USBBackendCompatibilityTests|InputBackendDefaultTests|InputBackendPreferencesTests|ControlUSBPresentationTests'
```

其他模块的定向检查入口：

```sh
swift test --filter Workbench
swift test --filter 'CaptureAssociationIdentityTests|CaptureIdentityVerifierTests'
```

后两条列出复查入口，不声称它们在本次提交 PR 时重新运行。

## USB 恢复的同输入对照

输入为临时 capture 身份未确认到确认，以及旧 capture 失效后出现新 capture。

- **BASELINE**：身份确认前已执行一次检查；后续准备没有恢复；旧失败被锁定。
- **MODIFIED**：确认前不执行检查；确认后准备一次；失效 capture 不锁住后续准备。
- **ROLLBACK**：恢复 BASELINE 行为且原文件哈希一致；重新应用后恢复 MODIFIED 行为。

本项为使用真实 refresh/selection 代码和 capture/selector double 的定向验证，不是手机手势回放。

## 已观察的真机结果

- 已观察设备搜索/清空、独立窗口转移与恢复，以及基础点击、滚动、主屏和搜索路径。
- 已观察原生文本忙碌/成功提示、部分前置校验失败后的草稿保留，以及准确设备的截图导出。
- 最后修复后，一台 iPhone 12 的 USB 状态为 `ready`、`sessionCurrent=true`，原生界面显示“已就绪”，DDI 仍正常挂载。
- 上述 USB 最后一轮只核对准备状态和界面能力，未执行 USB 触控或文本投递验收，未挂载/卸载 DDI。

## 仍需补验

- [ ] 物理断连/重连后的画面稳定性重复回归：相关身份门控已修复，但修复后的完整物理循环尚未观察完成。
- [ ] 真实按下被接收之后的拖动取消、失焦/最小化释放路径。
- [ ] USB 恢复后的真实触控及文本投递完整闭环。
- [ ] 多设备、独立窗口、HTTP/MCP 并行使用的完整最终集成验收。

因此，本 PR 是可评审的产品化改造，不宣称已完成发布级全量真机验收。完整本地日志、个人设备标识和截图不纳入公开 PR。
