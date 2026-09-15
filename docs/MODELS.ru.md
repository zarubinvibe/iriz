# Модели распознавания речи

[English](MODELS.md) · [简体中文](MODELS.zh.md) · [README](../README.ru.md)

<p align="center"><img src="assets/pantheon/doc-onboarding.png" alt="Ирида направляет золотую ленту голоса в мраморную табличку рядом с колонной семьи" width="100%"></p>

Сейчас iriz поддерживает ровно три профиля распознавания. Автоматически ставится только Parakeet. Две модели Whisper работают после ручной установки файлов.

**Результат:** я использую Whisper large-v3-turbo для русской речи с английскими техническими терминами. Модель подходит моему MacBook Air M3 с 24 ГБ памяти. Прямого замера Turbo в репозитории нет, поэтому цифры ниже относятся к полной Whisper large-v3.

## Что использую я

Я выбрал Whisper large-v3-turbo, потому что она распознаёт русский, а её файл `.bin` занимает 1,5 ГиБ. Полная Whisper large-v3 хорошо справилась со смешанной русской и английской технической речью в моём тесте. Я остался на этом семействе, но выбрал меньшую Turbo под своё железо. Файл `.bin` полной large-v3 занимает 2,9 ГиБ. Саму Turbo этот замер не проверяет.

При первой установке iriz всё равно предлагает Parakeet, потому что только у него есть автоматический установщик. После ручной установки Whisper large-v3-turbo выбери её в **iriz → Настройки → Диктовка**.

## Что на самом деле мерили

3 сентября 2026 года я сравнил Parakeet с whisper.cpp на полной Whisper large-v3. В русских прогонах Whisper получал чистый промпт о стиле записи. В английском прогоне промпта не было. Чем ниже WER, тем точнее текст. Чем выше множитель скорости, тем быстрее готова расшифровка.

| Проверка | Parakeet | whisper.cpp, полная large-v3 |
|---|---:|---:|
| Вся русская речь, WER | 23,70% | 28,61% |
| Смешанная русская и английская речь, WER | 44,05% | 19,05% |
| Русская речь без случаев с разной записью чисел, WER | 31,42% | 21,24% |
| Английская речь, WER | 18,75% | 14,06% |
| Скорость на короткой русской записи | в 21-29 раз быстрее записи | в 1,3 раза быстрее записи, Core ML-энкодер на ANE |

На общем русском срезе победил Parakeet. Полная large-v3 победила на смешанной речи, русском срезе без числовых случаев и на английской речи. Один склеенный русский файл длиной 134,4 секунды она распознала в 1,9 раза быстрее длительности записи.

Этот замер объясняет мой выбор семейства Whisper для смешанной технической речи. Сравнения Turbo с Parakeet здесь нет. Равноценных цифр WER или скорости Turbo в репозитории тоже нет.

Корпус состоит из 30 русских и 10 английских записей с личным голосом, поэтому не публикуются ни он, ни закрытый отчёт о замере. Метод лежит в [сравнителе WER](../scripts/bench_compare.py). Английский прогон с промптом отброшен: промпт содержал термины из теста.

## Что работает сейчас

| Профиль в iriz | Установка | Размер | Файл модели |
|---|---|---:|---|
| Whisper large-v3-turbo | Вручную | около 1,5 ГиБ | `ggml-large-v3-turbo.bin` |
| Whisper large-v3 | Вручную | около 2,9 ГиБ | `ggml-large-v3.bin` |
| Parakeet TDT v3 | Автоматически | около 0,5 ГБ | Управляет iriz |

## Как установить поддерживаемую модель Whisper

Закрой iriz. Создай папку, если её ещё нет:

```text
~/Library/Application Support/iriz/Models/whisper/
```

Скачай файл [ggml-large-v3-turbo.bin](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin?download=true) или [ggml-large-v3.bin](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin?download=true). Не меняй имя. Перенеси файл в эту папку, открой iriz и выбери совпадающий профиль в **Настройки → Диктовка**.

Ссылки закреплены на ревизии моделей whisper.cpp `5359861c739e955e79d9a303bcbc70fb988958b1`. Перед загрузкой поддерживаемого файла Whisper iriz проверяет его SHA-256 и отказывает при несовпадении.

| Файл | Точный размер, байт | SHA-256 |
|---|---:|---|
| `ggml-large-v3-turbo.bin` | 1 624 555 275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| `ggml-large-v3.bin` | 3 095 033 483 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` |

Эти ссылки скачивают только файлы `.bin`. На моём Маке также стоит необязательная папка Core ML-энкодера `ggml-large-v3-turbo-encoder.mlmodelc`. Она занимает около 1,2 ГиБ, поэтому весь мой комплект Turbo занимает около 2,7 ГиБ. iriz не скачивает и не проверяет эту сопутствующую папку. Без неё текущая сборка переключается на Metal. Сравнение 1,5 и 2,9 ГиБ относится только к файлам `.bin`.

Семейства и размеры перечислены в [официальном списке моделей whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md). Сам iriz модели Whisper не скачивает.

Квантованные файлы и модели другого размера сейчас не проверены и не поддерживаются iriz. Сохраняй их исходные имена: переименование не превращает файл в официально поддерживаемый профиль.

## 10 моделей для сравнения

Это список загрузок, а не обещание, что все десять работают в iriz. Сейчас в приложении выбираются только первые три.

### Поддерживаемые профили и близкие варианты

| № | Модель | Примерный размер | Статус в iriz |
|---:|---|---:|---|
| 1 | [Whisper large-v3-turbo](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin?download=true) | 1,5 ГиБ | Поддерживается, ручная установка |
| 2 | [Whisper large-v3](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin?download=true) | 2,9 ГиБ | Поддерживается, ручная установка |
| 3 | [Parakeet TDT v3 Core ML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce) | 0,5 ГБ | Поддерживается, автоматическая установка |
| 4 | [Whisper large-v3-turbo q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin?download=true) | 547 МиБ | Кандидат, выбрать пока нельзя |
| 5 | [Whisper large-v3 q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin?download=true) | 1,1 ГиБ | Кандидат, выбрать пока нельзя |

### Еще пять кандидатов

| № | Модель | Примерный размер | Статус в iriz |
|---:|---|---:|---|
| 6 | [Whisper medium](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-medium.bin?download=true) | 1,5 ГиБ | Кандидат, выбрать пока нельзя |
| 7 | [Whisper small](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin?download=true) | 466 МиБ | Кандидат, выбрать пока нельзя |
| 8 | [Whisper base](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin?download=true) | 142 МиБ | Кандидат, выбрать пока нельзя |
| 9 | [Whisper tiny](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.bin?download=true) | 75 МиБ | Кандидат, выбрать пока нельзя |
| 10 | [Whisper large-v2 q5_0](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v2-q5_0.bin?download=true) | 1,1 ГиБ | Кандидат, выбрать пока нельзя |

Модели Whisper с `.en` в имени работают только с английской речью. Для русского они не подходят, поэтому их здесь нет.

## Официальные источники

- [Список моделей whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/README.md)
- [Закрепленные файлы моделей whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1)
- [Карточка OpenAI Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo/blob/main/README.md)
- [Файлы Parakeet TDT v3 Core ML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce)

Дальше: выбери один из трех поддерживаемых профилей выше. Остальные семь файлов нужны только для сравнения.
