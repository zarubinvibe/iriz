# Speech recognition models

[Русский](MODELS.ru.md) · [简体中文](MODELS.zh.md) · [README](../README.md)

<p align="center"><img src="assets/pantheon/doc-onboarding.png" alt="Iris guides a gold voice ribbon into a marble tablet beside the family column" width="100%"></p>

iriz currently supports exactly three speech recognition profiles. It installs only Parakeet automatically. The two Whisper profiles work after you place their exact model files on disk yourself.

**Result:** I use Whisper large-v3-turbo for Russian speech with English technical terms. It fits my M3 MacBook Air with 24 GB of memory. The repository has no direct Turbo benchmark, so the figures below belong to full Whisper large-v3.

## What I use

I chose Whisper large-v3-turbo because it recognizes Russian and its `.bin` file is 1.5 GiB. Full Whisper large-v3 handled mixed Russian and English technical speech well in my test, so I stayed with that model family but picked the smaller Turbo for my hardware. Full large-v3 uses a 2.9 GiB `.bin`. The benchmark does not measure Turbo.

A fresh iriz installation still offers Parakeet because it is the only model with an automatic installer. If you install Whisper large-v3-turbo manually, select it under **iriz > Settings > Dictation**.

## What the benchmark actually tested

On 3 September 2026 I compared Parakeet with whisper.cpp running full Whisper large-v3. The Russian Whisper rows used a clean style prompt. The English row did not use a prompt. Lower word error rate is better; a higher real-time multiplier is faster.

| Test | Parakeet | whisper.cpp full large-v3 |
|---|---:|---:|
| All Russian WER | 23.70% | 28.61% |
| Mixed Russian and English WER | 44.05% | 19.05% |
| Russian WER, excluding numeral-format cases | 31.42% | 21.24% |
| English WER | 18.75% | 14.06% |
| Short Russian recording speed | 21-29x real time | 1.3x real time, Core ML encoder on ANE |

Parakeet won the unfiltered Russian row. Full large-v3 won the mixed-language row, the row without numeral-format cases and the English row. On one joined 134.4-second Russian file, full large-v3 reached 1.9x real time.

This is evidence for my choice of the Whisper family for mixed technical speech. It is not a Turbo versus Parakeet test. I have no equivalent Turbo WER or speed result in this repository.

The corpus contains 30 Russian and 10 English personal voice recordings, so neither it nor the private benchmark note is published. The [WER comparator](../scripts/bench_compare.py) records the method. The English prompt run was discarded because its prompt leaked test terms.

## Models supported now

| Profile in iriz | Installation | Size | Model artifact |
|---|---|---:|---|
| Whisper large-v3-turbo | Manual | about 1.5 GiB | `ggml-large-v3-turbo.bin` |
| Whisper large-v3 | Manual | about 2.9 GiB | `ggml-large-v3.bin` |
| Parakeet TDT v3 | Automatic | about 0.5 GB | Managed by iriz |

## Install a supported Whisper model manually

Quit iriz. Create this folder if it does not exist:

```text
~/Library/Application Support/iriz/Models/whisper/
```

Download either [ggml-large-v3-turbo.bin](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin?download=true) or [ggml-large-v3.bin](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin?download=true). Keep the filename unchanged and move the file into that folder. Open iriz, then select the matching profile under **Settings > Dictation**.

Those links are pinned to whisper.cpp model revision `5359861c739e955e79d9a303bcbc70fb988958b1`. Before loading a supported Whisper file, iriz verifies its SHA-256 and refuses a mismatch.

| File | Exact bytes | SHA-256 |
|---|---:|---|
| `ggml-large-v3-turbo.bin` | 1,624,555,275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| `ggml-large-v3.bin` | 3,095,033,483 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` |

These downloads cover only the `.bin` files. My Mac also has an optional matching Core ML encoder directory, `ggml-large-v3-turbo-encoder.mlmodelc`, which takes about 1.2 GiB. My full Turbo setup therefore takes about 2.7 GiB. iriz does not download or verify that sidecar. Without it, the current build falls back to Metal. The 1.5 GiB versus 2.9 GiB comparison applies only to the `.bin` files.

The [official whisper.cpp model list](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md) explains the available model families. iriz does not download Whisper models for you.

Quantized and differently sized files are not tested or supported by iriz today. Keep their original filenames; renaming one does not make it an officially supported profile.

## 10 downloads to compare

This is a download shortlist, not a list of ten models that work in iriz today. Only the first three entries are selectable in the current app.

### Supported profiles and close alternatives

| # | Download | Approximate size | Current iriz status |
|---:|---|---:|---|
| 1 | [Whisper large-v3-turbo](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin?download=true) | 1.5 GiB | Supported, manual install |
| 2 | [Whisper large-v3](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin?download=true) | 2.9 GiB | Supported, manual install |
| 3 | [Parakeet TDT v3 Core ML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce) | 0.5 GB | Supported, automatic install |
| 4 | [Whisper large-v3-turbo q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin?download=true) | 547 MiB | Candidate only, not selectable |
| 5 | [Whisper large-v3 q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin?download=true) | 1.1 GiB | Candidate only, not selectable |

### More candidates

| # | Download | Approximate size | Current iriz status |
|---:|---|---:|---|
| 6 | [Whisper medium](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-medium.bin?download=true) | 1.5 GiB | Candidate only, not selectable |
| 7 | [Whisper small](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin?download=true) | 466 MiB | Candidate only, not selectable |
| 8 | [Whisper base](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin?download=true) | 142 MiB | Candidate only, not selectable |
| 9 | [Whisper tiny](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.bin?download=true) | 75 MiB | Candidate only, not selectable |
| 10 | [Whisper large-v2 q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v2-q5_0.bin?download=true) | 1.1 GiB | Candidate only, not selectable |

Whisper files with `.en` in their model name are English-only. They do not recognize Russian, so they are not included here.

## Official sources

- [whisper.cpp model list](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md)
- [Pinned whisper.cpp model files](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1)
- [OpenAI Whisper large-v3-turbo model card](https://huggingface.co/openai/whisper-large-v3-turbo/blob/main/README.md)
- [Parakeet TDT v3 Core ML files](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce)

Next: choose one of the three supported profiles above. The other seven files are for comparison only.
