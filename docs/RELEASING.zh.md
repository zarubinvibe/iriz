# 构建 macOS 发行版

[English](RELEASING.md) · [Русский](RELEASING.ru.md) · [简体中文](RELEASING.zh.md)

用户安装请从[下载页面](DOWNLOAD.zh.md)开始。本页供项目维护者使用。发行版构建器不会停止或替换已安装的应用。

## 一个版本，两个文件名

`RELEASE_VERSION` 是本地安装和发行版构建共用的版本来源。请使用数字形式的 `major.minor.patch`，例如 `0.2.1`，并把审核过的说明添加到 `docs/releases/v<version>.md`。

默认构建面向运行 macOS 14+ 的 Apple Silicon，输出以下文件：

| 文件 | 用途 |
|---|---|
| `iriz-<version>-arm64.dmg` | 带版本号的下载文件，用于归档和回退 |
| `iriz-macos-arm64.dmg` | README 下载按钮使用的稳定文件名 |
| `SHA256SUMS.txt` | 磁盘映像和清单的 SHA-256 |
| `release-manifest.json` | 源代码提交、工作树是否有未提交改动、版本、签名状态和映像哈希 |

两个映像按字节完全相同。GitHub 支持[最新发行版资源链接](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)，所以每个已发布的发行版都必须保留采用稳定文件名的资源。所有资源齐备前，不要把草稿标为 Latest。

## 在本机构建并检查

请使用 Xcode 26.6（build 17F113）、其中的 macOS 26 SDK 和 Swift 6.3.3，与发行版工具链保持一致。应用仍以 macOS 14+ 为目标，但编译带可用性保护的 macOS 26 界面需要新版 SDK。Xcode 26.3 无法对两个提示表达式完成类型检查；只检查 Swift 6 版本并不足够。依赖项来自 `Package.resolved`。

如果构建时不使用签名证书和 Finder 自动化，请运行：

```bash
swift test --no-parallel
bash scripts/make_release_test.sh --selftest
bash scripts/build_app_test.sh --selftest
ruby scripts/macos_release_workflow_test.rb --selftest
SMLTLK_SIGN_IDENTITY=- IRIZ_DMG_HEADLESS=1 bash scripts/make_release.sh
cd release/dist
shasum -a 256 -c SHA256SUMS.txt
```

`-` 表示 ad hoc 签名，不代表经过验证的发行者。常规本机构建模式使用已有的自签名证书，并生成带安装箭头的 Finder 窗口。该模式需要 Pillow 来绘制背景；无界面模式不需要。两种模式都包含同一个应用和 Applications 快捷方式。

完整测试套件会检查俄语界面文案，以及英语和俄语键盘布局的原生映射。它们需要相应的测试语言和已启用的 Apple 输入源，不是与区域设置无关的单元测试。CI 会在一次性运行器上准备这些条件。不要在自己的账户上运行其设置模式。

构建文件位于 `release/build`，输出位于 `release/dist`。两处都不会进入 Git。不要同时运行发行版构建器和本地安装器：两者共用图标渲染器。临时目录和输出目录的覆盖路径必须留在本 checkout 的 `release/` 或 `.build/` 内，并且不能使用符号链接。

构建器会检查应用和框架的架构、部署目标、语言资源、内置依赖项、代码签名和已挂载映像。新映像通过检查前，旧输出会保留。构建失败后，日志和暂存目录会留下用于诊断；构建器只会卸载由它自己挂载的映像。

会议模板是必需的运行时资源，不是仅供开发者阅读的文档。两个应用构建器都会检查完整资源包和模板哈希，包括已挂载 DMG 内的副本。如果发行版修改了会议功能，还要运行 DOCX、转写、生成器和归档测试套件，并用复制后的应用测试一次导出。参见 [MEETING-RESOURCES.zh.md](MEETING-RESOURCES.zh.md)。以前成功的 CI 运行无法验证新加入的模板或导出路径。

如需实验性的通用构建，请设置 `IRIZ_RELEASE_VARIANTS='arm64 universal'`。额外的 `x86_64` 切片只检查打包，不能证明识别功能可在 Intel Mac 上运行。不要把它宣传为经过测试的 Intel 支持。

## GitHub Actions

**macOS release draft** 工作流可在这个公共仓库中手动运行，也会由 `v*` 标签触发。它不会在 fork 和私有工作仓库中运行。有标签时，标签必须与 `RELEASE_VERSION` 一致。

标准 ARM64 `macos-26` 运行器使用 Xcode 26.6；版本列在 [GitHub 运行器映像清单](https://github.com/actions/runner-images/blob/0af81b6d930d02b52941d584bee9214c4bc228c6/images/macos/macos-26-arm64-Readme.md#xcode)中。预检查会在编译前核对所选的 Xcode、Swift 和 macOS SDK。运行器执行测试，构建无界面的 ad hoc 签名映像，并上传五个发行输入：四个公共文件和生成的发行说明。另一个作业会验证它们，然后创建一个恰好包含四个公共资源的**草稿**发行版。它不会使用有写入权限的令牌执行仓库代码。已有发行版和资源绝不会被覆盖。草稿不会改变下载按钮。

测试前，托管运行器的设置步骤会启用内置的英语和俄语输入源，并把 iriz 自身的语言偏好设为俄语。它不会切换当前键盘布局，不会改变系统语言或授予权限，也不会用测试夹具替代原生键盘映射。设置步骤拒绝在 GitHub 托管的 macOS 运行器之外写入内容；任何先决条件失败，都会在测试开始前停止构建。

要为已经发布的版本检查完整构建，请选择 **Run workflow → build_only: true**。这会运行测试、构建并验证 DMG，再把五个输入文件作为 Actions 构件上传。生成的发行说明只是暂存输入，不是公共发行资源。整个发行版写入作业都会跳过：不会创建草稿、标签或资源，也不会更改 Latest。

默认值为 `false` 时，只有该发行版的精确标签引用能解析到生成本次构建的提交，已经发布的发行版才会成功执行 no-op；附注标签也在检查范围内。作业会记录 `already published, left unchanged`，既不编辑发行版，也不上传资源。这个过程不会验证已有资源；是否验收仍由独立的下载和安装检查决定。

已有草稿、标签引用或源代码提交不匹配、API 响应无效，或者 API 调用失败，都会让作业停止而不写入任何内容。如果发行版不存在，作业仍只创建新草稿，不覆盖资源。

维护者审核草稿和发行说明，在干净的机器上测试安装，运行发布检查，然后再发布。发布是独立操作。此工作流不需要 Apple 凭据，应用也不会安装后台更新器。

发布前，请按顺序完成以下五项检查：

1. 从草稿下载 DMG。
2. 挂载映像并验证其签名。
3. 分别用英语和中文启动复制后的应用。
4. 完整走完权限、模型和首次听写流程。
5. 对照本地输出检查公共资源的哈希。

没有实际测试过麦克风或 Intel，就不要声称测试过。

发布后，**App download** 会检查 README 按钮，并在无需身份验证的情况下下载全部四个公共发行版文件。`main` 上发生相关改动后它也会运行，也可以通过 **Run workflow** 手动启动。使用 Node 22.15 或更新版本可在本机运行相同检查：

```bash
node scripts/check_app_download.mjs --selftest
node scripts/check_app_download.mjs --local
node scripts/check_app_download.mjs
```

在线检查会跟随稳定链接，根据 GitHub 资源的大小和摘要、清单以及 `SHA256SUMS.txt` 验证两个完整 DMG，并将清单中的源代码提交与发行版标签核对。它会拒绝意外文件、HTML 响应、截断的下载和检查期间的 Latest 变更。请求只使用固定的 GitHub 主机，最多跟随五次重定向、尝试两次，总期限为十分钟；DMG 以流式方式计算 SHA-256，不会写入本地文件。

检查通过表示匿名下载的完整性没有问题。安装、签名、权限和首次听写仍需按上面的步骤在 macOS 上检查。

## Developer ID 与公证

当前公共构建未经公证。自签名或 ad hoc 签名都不是 Apple Developer ID 签名，也不能证明 Apple 审核过该应用。

要进行公证，请先取得有效的 **Developer ID Application** 证书，并自行配置 `notarytool` 钥匙串配置文件。不要提交证书、私钥或密码。构建器接受已有的身份和配置文件：

```bash
SMLTLK_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
IRIZ_NOTARY_PROFILE=iriz-notary \
bash scripts/make_release.sh
```

此模式会把应用和映像发送给 Apple。它会为嵌套代码、应用和 DMG 签名，使用安全时间戳，通过 `notarytool` 提交，装订票据并检查 Gatekeeper。任何失败都会停止构建。装订票据后才计算校验和。参见 [Apple 分发签名指南](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)和[软件分发打包指南](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。

把该身份移入 CI 需要单独配置凭据。请遵循 [GitHub 临时钥匙串工作流](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)，限制 secret 的访问范围，并清理钥匙串。不要打印环境变量，也不要在 secret 附近启用 shell 跟踪。

## 本项目采用的做法

审核日期：2026-09-13。

- [VoiceInk](https://github.com/Beingpax/VoiceInk/blob/main/README.md) 把下载放在构建说明前，并保留稳定的 DMG 文件名。iriz 也采用这种区分方式。
- [Handy](https://github.com/cjpais/Handy/blob/main/README.md) 按硬件区分下载，并说明权限和本地模型。iriz 会写明经过测试的平台和独立的模型下载。
- [Whispering v7.11.0 指南](https://github.com/EpicenterHQ/epicenter/blob/v7.11.0/apps/whispering/README.md) 要求先安装模型，再开始录音。这是固定版本的参考资料，不代表其当前 main 分支的内容。

共享视觉形象保持不变。清楚的下载入口、首次运行说明、校验和与回退说明，回答了桌面应用安装者来到本页时最关心的实际问题。
