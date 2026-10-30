# 应用图标

深蓝陶瓷底板、居中的立体金属手机与白瓷鼠标指针，表达在 Mac 上操控真实 iPhone。手机包含侧边厚度与玻璃反光，指针使用薄荷绿侧面、倒角与投影；透明边距适配 macOS Dock。

- `AppIcon.png`：1024 × 1024 的透明背景预览图片。
- `../Sources/iPhoneUse/Resources/AppIcon.icns`：包含 16–1024 像素多分辨率图像的应用图标。
- `../scripts/generate-icon.swift`：可编辑的原生 Core Graphics 绘图源文件，无需第三方依赖。

在仓库根目录重新生成：

```sh
swift scripts/generate-icon.swift
```

SwiftPM 将 ICNS 作为资源随可执行文件构建，主程序启动时加载到 Dock。`scripts/build-app.sh` 将同一图标复制到 `.app/Contents/Resources`，并通过 `Info.plist` 供 Finder 和 Dock 使用。
