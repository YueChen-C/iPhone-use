# PR 自动测试与合并要求

[Tests 工作流](../.github/workflows/tests.yml)在创建、重新打开或更新目标为 `main` 的 PR 时自动执行，也会在推送 `main`、进入合并队列和手动运行时执行。PR 检查默认测试 GitHub 生成的合并提交，覆盖 PR 与目标分支组合后的代码。

工作流在 GitHub 托管的 `macos-15` runner 上先执行 `swift test`，再使用 Python 3.12 执行全部 Python 测试。Swift 测试会生成 debug 可执行文件，供 Python 的 MCP 集成测试使用。测试不需要连接 iPhone。

任一测试命令返回非零退出码，`Unit tests` 检查即失败。工作流不设置路径过滤，文档修改也会运行，避免必需检查一直停留在等待状态。更新同一 PR 时，旧运行会取消，只保留最新运行。

## 要求测试通过才能合并

工作流文件本身不能禁止合并；需要仓库管理员在 GitHub 配置分支规则：

1. 将工作流推送至 GitHub，等待至少一次运行，让 GitHub 识别 `Unit tests` 检查。
2. 打开仓库 **Settings → Rules → Rulesets → New ruleset → New branch ruleset**。
3. 填写名称（例如 `main requires tests`），将 **Enforcement status** 设置为 **Active**。
4. **Target branches** 选择默认分支 `main`，保持 **Bypass list** 为空，避免管理员或其他角色绕过检查。
5. 勾选 **Require a pull request before merging**，让目标分支的改动通过 PR 提交。
6. 勾选 **Require status checks to pass**，添加 **Unit tests**，检查来源选择 **GitHub Actions**。
7. 勾选 **Require branches to be up to date before merging**，确保检查覆盖当前 `main`；如果使用合并队列，由队列更新合并结果，本工作流也支持 `merge_group` 事件。
8. 保存规则。在 PR 页面确认 `Unit tests` 被标为 required，检查失败或尚未完成时合并被阻止。

现有仓库若使用 **Settings → Branches → Branch protection rules**，也可为 `main` 配置相同的必需检查，并启用 **Do not allow bypassing the above settings**。

外部 fork 首次贡献的 PR 可能需要维护者先批准 Actions 运行；等待批准期间必需检查不能通过。工作流使用 `pull_request` 事件和只读仓库权限，不依赖仓库 Secrets。

启用规则后保持 job 名称 `Unit tests` 稳定；重命名时需同步更新规则，否则 PR 会等待旧名称的检查。
