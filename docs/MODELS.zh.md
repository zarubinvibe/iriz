# 语音识别模型

[English](MODELS.md) · [Русский](MODELS.ru.md) · [README](../README.zh.md)

<p align="center"><img src="assets/pantheon/doc-onboarding.png" alt="伊里斯把金色语音丝带引入家族石柱旁的大理石板" width="100%"></p>

当前版本的 iriz 只认三种配置：Parakeet TDT v3、Whisper large-v3-turbo 和 Whisper large-v3。只有 Parakeet 可以由应用自动下载安装；两个 Whisper 模型都要手动放到指定目录。

**结果：** 我用 Whisper large-v3-turbo 识别夹有英文技术词的俄语。它适合我的 24 GB 内存 M3 MacBook Air。仓库里没有 Turbo 的直接实测，下面的数字属于完整版 Whisper large-v3。

| iriz 中的配置 | 大小 | 安装方式 | 模型文件 |
|---|---:|---|---|
| Whisper large-v3-turbo | 约 1.5 GiB | 手动 | `ggml-large-v3-turbo.bin` |
| Whisper large-v3 | 约 2.9 GiB | 手动 | `ggml-large-v3.bin` |
| Parakeet TDT v3 | 约 0.5 GB | 应用内自动安装 | 由 iriz 管理 |

## 我为什么用 Turbo

我选 Whisper large-v3-turbo，因为它能识别俄语，`.bin` 文件为 1.5 GiB，而且属于 Whisper 系列。在我的测试中，这个系列对俄英混合技术语音表现很好。完整 large-v3 的 `.bin` 文件为 2.9 GiB。Turbo 更适合我的硬件，但我不会把下面的实测数字算在 Turbo 头上。

## 实测到底测了什么

2026 年 9 月 3 日，我比较了 Parakeet 和通过 whisper.cpp 运行的完整版 Whisper large-v3。俄语项给 Whisper 了不含测试术语的格式提示，英语项没用提示。WER 越低越好；实时倍率越高，转写越快。

| 测试 | Parakeet | whisper.cpp 完整 large-v3 |
|---|---:|---:|
| 全部俄语 WER | 23.70% | 28.61% |
| 俄英混合 WER | 44.05% | 19.05% |
| 俄语 WER，排除数字写法差异 | 31.42% | 21.24% |
| 英语 WER | 18.75% | 14.06% |
| 短俄语录音速度 | 21-29 倍实时 | 1.3 倍实时，Core ML 编码器运行于 ANE |

Parakeet 在全部俄语项获胜。完整 large-v3 在俄英混合、排除数字写法差异的俄语以及英语项获胜。对一段合并后长 134.4 秒的俄语录音，完整 large-v3 达到 1.9 倍实时。

这些数据可以解释我为什么在混合技术语音上选择 Whisper 系列。它不是 Turbo 与 Parakeet 的对比。仓库中没有同等条件的 Turbo WER 或速度数据。

语料包含 30 条俄语和 10 条英语个人录音，因此语料和私有实测记录都不公开。[WER 比较脚本](../scripts/bench_compare.py)保留了方法。英语提示版本泄露了测试术语，已丢弃。

## 手动安装 Whisper

退出 iriz。下载 [ggml-large-v3-turbo.bin](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin?download=true) 或 [ggml-large-v3.bin](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin?download=true)，再把文件放到：

```text
~/Library/Application Support/iriz/Models/whisper/
```

Turbo 必须保留文件名 `ggml-large-v3-turbo.bin`，large-v3 必须保留 `ggml-large-v3.bin`。重新打开 iriz，在「iriz → 设置 → 口述」里选择对应配置。

这些链接固定到 whisper.cpp 模型仓库的修订版 `5359861c739e955e79d9a303bcbc70fb988958b1`。加载受支持的 Whisper 文件前，iriz 会检查 SHA-256；不一致时会拒绝加载。

| 文件 | 精确字节数 | SHA-256 |
|---|---:|---|
| `ggml-large-v3-turbo.bin` | 1,624,555,275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| `ggml-large-v3.bin` | 3,095,033,483 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` |

这些链接只下载 `.bin` 文件。我的 Mac 还有一个可选的 Core ML 编码器目录 `ggml-large-v3-turbo-encoder.mlmodelc`，约占 1.2 GiB，所以我的整套 Turbo 配置约占 2.7 GiB。iriz 不会下载或校验这个 sidecar。缺少它时，当前构建会回退到 Metal。1.5 GiB 与 2.9 GiB 的比较只针对 `.bin` 文件。

[whisper.cpp v1.9.2 的官方模型列表](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md)列出了模型系列和大小。iriz 不会自动下载 Whisper 模型。

iriz 目前没有测试或支持量化文件及其他尺寸的模型。请保留原始文件名；改名不会让它成为官方支持的配置。

## 10 个可比较的下载

前三个是 iriz 当前支持的配置。其余项目只是便于比较大小和取舍的候选。

### 已支持配置和近似选项

| # | 模型 | 大小 | iriz 当前状态 |
|---:|---|---:|---|
| 1 | [Whisper large-v3-turbo](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin?download=true) | 约 1.5 GiB | 支持，手动安装 |
| 2 | [Whisper large-v3](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin?download=true) | 约 2.9 GiB | 支持，手动安装 |
| 3 | [Parakeet TDT v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce) | 约 0.5 GB | 支持，自动安装 |
| 4 | [large-v3-turbo-q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin?download=true) | 547 MiB | 候选，不支持 |
| 5 | [large-v3-q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin?download=true) | 1.1 GiB | 候选，不支持 |

### 其他五个候选

| # | 模型 | 大小 | iriz 当前状态 |
|---:|---|---:|---|
| 6 | [medium](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-medium.bin?download=true) | 1.5 GiB | 候选，不支持 |
| 7 | [small](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin?download=true) | 466 MiB | 候选，不支持 |
| 8 | [base](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin?download=true) | 142 MiB | 候选，不支持 |
| 9 | [tiny](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.bin?download=true) | 75 MiB | 候选，不支持 |
| 10 | [large-v2-q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v2-q5_0.bin?download=true) | 1.1 GiB | 候选，不支持 |

Whisper 文件名中带 `.en` 的是英语专用模型，不识别俄语。中文界面也不代表所选语音模型能识别中文。

## 官方来源

- [whisper.cpp 模型列表](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md)
- [固定版本的 whisper.cpp 模型文件](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1)
- [OpenAI Whisper large-v3-turbo 模型卡](https://huggingface.co/openai/whisper-large-v3-turbo/blob/main/README.md)
- [Parakeet TDT v3 Core ML 文件](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce)

下一步：只从上面的三个受支持配置中选择。其余七个文件仅供比较。
