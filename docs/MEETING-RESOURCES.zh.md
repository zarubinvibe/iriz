# 应用内置的会议纪要模板包

[English](MEETING-RESOURCES.md) · [Русский](MEETING-RESOURCES.ru.md) · [简体中文](MEETING-RESOURCES.zh.md)

**结果：** 打包后的应用包含完整的会议纪要模板包；如果必需内容未通过检查，两个构建脚本都会停止。

原始文件包原样保存在 `Sources/IrizDictate/Resources/MeetingMinutes` 中。`Package.swift` 通过 `.copy("Resources/MeetingMinutes")` 将它加入 `IrizApp_IrizDictate.bundle`。

已安装的应用和 DMG 中的应用都包含同一路径：

```text
iriz.app/Contents/Resources/IrizApp_IrizDictate.bundle/MeetingMinutes/
```

整个文件包会完整复制，包括 DOCX 模板、`fields.json`、`data.schema.json`、manifest、文档、示例、测试、辅助脚本，以及附带 OFL 许可证的 PT Serif。

`scripts/build_app.sh` 和 `scripts/make_release.sh` 保留了原有的处理，会复制所有相邻的 SwiftPM bundle。这个新的必需资源不会取代本地化的 `IrizApp_IrizCore.bundle`。

如果文件包不存在、包含符号链接、必需文件为空或缺失，或者模板已被修改，两个构建脚本都会停止。它们还会在已安装的候选版本和已挂载的 DMG 中重复检查。

如果在替换前检查失败，已安装的应用保持不变。如果在替换后失败，现有的回滚机制会生效。在磁盘映像检查通过之前，发布包不会进入 `dist`。

基准 `template.docx` 的 SHA-256：

```text
8b4ffde7a7d09c6f3450b2de8667334fe79f544157553c3e81d77456b43807ff
```

## 不依赖构建目录运行

`MeetingTemplate` 会相对于应用 bundle 或测试模块查找资源。打包后的应用运行时不需要开发者指向 `.build` 的绝对路径，也不需要 `Bundle.module`。

`Tests/IrizDictateTests/MeetingDOCXTests.swift` 会检查一个单独复制的 `.app`，其文件包只存在于 `Contents/Resources` 中。

DOCX 导出由 Swift 代码完成，并使用系统的 `/usr/bin/ditto` 处理 ZIP 容器。内置的 `scripts/*.py` 和 `tests/*.py` 属于原始文件包，仅用于手动检查；应用不会运行它们。

Python 不是导出功能的运行时依赖。发布构建器本身仍会在开发者的机器或 CI 中使用 Python。

## 打包回归检查

```bash
bash scripts/build_app_test.sh --selftest
bash scripts/make_release_test.sh --selftest
```

Mock 会在各自的临时目录中运行。它们不使用共享的 `.build`，不对真实代码签名，不挂载磁盘映像，也不访问 `/Applications`。

测试会检查文件包是否完整复制，以及文件包缺失或被修改时是否拒绝继续。新文件包的真实打包和从已复制应用中导出仍需单独检查；绿色的 0.2.1 CI baseline 早于这次集成，无法确认这两项。

下一步：打包发布版本前，先运行上面的两个自测命令。
