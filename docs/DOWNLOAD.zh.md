# 在 macOS 上安装 iriz

[English](DOWNLOAD.md) · [Русский](DOWNLOAD.ru.md) · [README](../README.zh.md)

[![下载 macOS 版](https://img.shields.io/badge/下载%20macOS%20版-111111?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/zarubinvibe/iriz/releases/latest/download/iriz-macos-arm64.dmg)

需要 Apple Silicon Mac（M1 或更新）和 macOS 14 或更新版本。此下载不支持 Intel Mac。应用采用 MIT 许可证，免费使用，不需要账号、API 密钥、Xcode 或终端。语音模型另行下载，约 500 MB；还需为下载和安装的临时文件留出空间。

## 首次启动

<img src="assets/pantheon/doc-onboarding.png" alt="伊里斯引导金色语音丝带落在大理石板上，旁边矗立着家族石柱" width="100%">

1. 打开 DMG，将 **iriz** 拖入 **Applications**，然后推出磁盘映像。请从 Applications 启动，不要从已挂载的映像运行。
2. 此版本使用自签名，**尚未通过 Apple 公证**，macOS 无法验证发布者。如果你信任此仓库并已核对文件，尝试打开应用后，可前往“系统设置 → 隐私与安全性 → 仍要打开”。请阅读 [Apple 的说明](https://support.apple.com/en-us/102445)。不要关闭 Gatekeeper，也不要绕过恶意软件警告。
3. 欢迎页之后，在模型步骤点击**下载并安装 Parakeet**。Parakeet 通过网络下载，约 500 MB；iriz 会自动安装并选用它。界面显示进度，失败后可点击**重试**。保持联网直到模型就绪；DMG 不包含模型。
4. 继续按引导授予麦克风、辅助功能和输入监控权限，分别用于收音、插入文字和响应听写快捷键。若 macOS 要求，请重新启动应用。模型下载期间可以完成授权，开始听写前请等待模型就绪。
5. 将光标放入空白文本框。按引导中显示的听写键（默认右侧 Command），说一句话，再按一次，文字应出现在该文本框中。

如果跳过模型步骤，键盘布局修正仍可使用，但听写需要模型。打开 **iriz → 设置 → 口述 → 下载 Parakeet 模型…**，即可返回模型安装页。已有模型时，按钮显示为**设置语音识别…**。应用只提供 Parakeet 的自动安装。识别引擎列表也有其他选项，但需要另行安装对应模型，本指南不介绍该过程。Parakeet 不识别中文语音。界面语言与语音语言是两项独立设置。

## 遇到问题

模型缺失或下载失败：回到**设置 → 口述**，重新打开模型安装页并重试，同时检查网络和磁盘空间。没有声音：检查麦克风权限及输入设备。文字未粘贴：检查辅助功能权限，转写仍可从浮窗或历史中取出。快捷键无响应：检查输入监控权限，或选择另一个键。

需要帮助时，提交 [issue](https://github.com/zarubinvibe/iriz/issues)，附上应用版本、macOS 版本、芯片和复现步骤。检查内容后再附日志，不要公开私人录音或转写。

## 更新与回退

阅读[更新说明](https://github.com/zarubinvibe/iriz/releases/latest)，下载新 DMG，退出 iriz 后再替换 Applications 中的应用。保留旧应用或旧 DMG，直到确认新版可用。模型、偏好设置和历史保存在应用包之外，替换应用不会删除它们。签名变化后，macOS 可能再次要求授权。

应用没有后台更新器。下载按钮指向最新正式发布的版本，草稿不会改变此链接。回退时先退出 iriz，再恢复旧应用。运行旧版本前请备份数据，因为未来版本可能改变存储格式。

## 核对下载文件

每个版本附带 **SHA256SUMS.txt** 和 **release-manifest.json**，记录版本、架构及签名状态。运行以下命令，将结果与校验文件中完全相同的文件名对应的值比较：

```bash
shasum -a 256 ~/Downloads/iriz-macos-arm64.dmg
```

哈希一致可以检查文件是否损坏，但不能替代 Apple 对发布者的验证。从源码构建见 [RELEASING.md](RELEASING.md)，其他界面的介绍见[完整引导](ONBOARDING.zh.md)。
