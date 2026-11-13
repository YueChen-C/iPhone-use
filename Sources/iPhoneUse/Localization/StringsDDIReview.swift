import Foundation

struct StringsDDIReview: LocalizedTable {
    let title: String
    let notice: String
    let device: String
    let candidate: String
    let candidateReceipt: String
    let baseline: String
    let baselineReceipt: String
    let transaction: String
    let choose: String
    let inspect: String
    let create: String
    let open: String
    let copy: String
    let working: String
    let offline: String

    static var current: Self { Self(language: AppLanguageStore.shared.language) }
    static let zh = Self(title: "DDI 计划与审阅（实验性）",
        notice: "仅检查、预检及创建本地快照，不更改手机镜像，不启动触控。哈希不代表 Apple 来源认证或分发许可。报告包含设备身份和本地路径，请勿公开上传。",
        device: "完整 USB UDID", candidate: "候选 DDI 目录", candidateReceipt: "候选来源 receipt", baseline: "当前镜像的基线目录",
        baselineReceipt: "基线来源 receipt", transaction: "新的事务目录", choose: "选择…", inspect: "检查设备（只读）",
        create: "创建并审阅计划", open: "打开已有事务…", copy: "复制离线命令",
        working: "正在执行原生检查 / 本地快照，请等待；不会自动重试。",
        offline: "此窗口不执行挂载或恢复。先确认输入已释放并干净退出所有应用/MCP/AX，再在本地终端核对设备、来源、候选/基线和计划哈希，明确确认后执行离线命令。不要删除 pending 门禁或终止其他任务。命令中的来源风险确认不是可信来源认证。")
    static let en = Self(title: "DDI Plan & Review (Experimental)",
        notice: "Inspect, preflight and stage local snapshots only. No phone image changes or touch preparation. Hashes are not Apple provenance authentication or distribution clearance. Reports contain device identity and local paths; do not publish them.",
        device: "Full USB UDID", candidate: "Candidate DDI directory", candidateReceipt: "Candidate source receipt", baseline: "Current-image baseline",
        baselineReceipt: "Baseline source receipt", transaction: "New transaction directory", choose: "Choose…", inspect: "Inspect device (read-only)",
        create: "Create & review plan", open: "Open transaction…", copy: "Copy offline commands",
        working: "Native inspection / local staging in progress. No automatic retry.",
        offline: "This window cannot mount or restore. Confirm clean input release, quit all app/MCP/AX owners, then locally review the device, sources, candidate/baseline and plan hash before explicitly running offline commands. Never delete the pending barrier or terminate another task. Source-risk acknowledgement is not authenticated provenance.")
}
