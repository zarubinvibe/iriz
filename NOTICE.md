# Происхождение кода

Проект стоит на чужой работе и говорит об этом прямо. Три источника, все с разрешающими
лицензиями; условие, под которым код вообще разрешено брать, - атрибуция, и она здесь.

| Что | Источник | Лицензия | Текст | Как попадает к пользователю |
|---|---|---|---|---|
| переключение раскладки | `rashn/RuSwitcher` | MIT | `THIRD-PARTY/RuSwitcher-LICENSE` | код в дереве |
| диктовка | `shlgd/SuperDictate` | MIT | `THIRD-PARTY/SuperDictate-LICENSE` | код в дереве |
| распознавание речи | `FluidInference/FluidAudio` | Apache-2.0 | `THIRD-PARTY/FluidAudio-LICENSE` | компилируется в приложение |
| модель речи | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | CC-BY-4.0 | `THIRD-PARTY/parakeet-CC-BY-4.0` | качается на машину при установке |
| движок Whisper | `ggml-org/whisper.cpp` v1.9.2 | MIT | `THIRD-PARTY/whisper.cpp-LICENSE` | **бинарный `whisper.framework` внутри `.app`** |
| иерархическая кластеризация | fastcluster (Daniel Muellner, Google) | BSD-3 | `THIRD-PARTY/fastcluster-LICENSE` | через FluidAudio, разбор говорящих |
| кластеризация VBx | VBx | Apache-2.0 | `THIRD-PARTY/VBx-LICENSE` | через FluidAudio, разбор говорящих |

Три последние строки добавлены 06.09.2026 после сверки того, что РЕАЛЬНО едет
пользователю, а не того, что записано в зависимостях.

Whisper пропускался: `whisper.framework` кладётся внутрь `.app` собранным
бинарником, а MIT требует нести уведомление об авторстве вместе с бинарной
формой. Зависимость видна в `Package.swift`, но лицензия не ехала.

fastcluster и VBx появились вместе с разбором записи по говорящим: он поднимает
офлайн-диаризатор FluidAudio, а под ним лежат `AHCClustering.swift` и
`VBxClustering.swift` - производные чужой работы со своими условиями. Пока
диаризатор не использовался, обязательства не было; с ним оно появилось.

Правило, по которому этот список ведётся, названо владельцем прямо: взяли идею и
написали свой код - никому ничего не должны и никого не указываем. Несём чужой
код или чужие наработки - указываем. Ниже перечислено только второе.

GPL-код не вендорится: он заразил бы весь продукт. Проприетарные данные Punto Switcher
(`triggers.dat`, `ps.dat`) не переносились ни в каком виде - форматы изучались ради понимания
подхода, файлы остались у Яндекса. Проприетарные CoreML-конвертации Argmax
(`argmaxinc/parakeetkit-pro`, лежит на диске владельца рядом) не использовались: они под NDA.

---

## 1. RuSwitcher - переключение раскладки

Часть исходников smltlk происходит из проекта RuSwitcher.

- Источник: https://github.com/rashn/RuSwitcher
- Коммит: 8c45253d2b63b3efd6aeff7ab6c73cc9593f112a (03.08.2026)
- Лицензия: MIT, Copyright (c) 2025 Rashns
- Полный текст лицензии: THIRD-PARTY/RuSwitcher-LICENSE

Код взят, изменен и распространяется на условиях MIT. Файлы, происходящие от донора,
несут отметку в шапке. Список перенесенных файлов и внесенных изменений - ниже.

## Сверка 06.09.2026

Список проверен построчным сравнением с донорами на заявленных коммитах, а не по
отметкам в шапках. Что нашла сверка:

- файлов, где отметка стоит, а кода донора уже нет, - НОЛЬ. Снимать нечего;
- 23 файла несут узнаваемый код донора, местами дословно: `LayoutSwitcher.swift`,
  `SpotlightAX.swift`, `KeyCodes.swift`, `ShortWords.swift` совпадают полностью,
  `TextConverter.swift` на 99% одним куском в 315 строк;
- 7 файлов переписаны своим кодом, но держат наработки донора: подобранные им
  числовые константы плашки и формулы дыхания и синтетического уровня голоса.
  Это не бойлерплейт AppKit, а подобранные автором параметры, и отметка остаётся;
- ДВА файла несли код донора БЕЗ отметки, и это нарушение в обратную сторону:
  `IrizCore/PrivateFiles.swift` (приватная запись файлов) и
  `IrizDictate/DictationHistoryClipboard.swift` (временный буфер обмена). Код
  выносили в общие модули, а отметка за ним не ехала. Отметки поставлены.

Правило, по которому список ведётся: несём чужой код или чужие наработки -
указываем; взяли идею и написали своё - не указываем. Мелочи вроде семи строк
аргументов системного вызова, которые иначе не написать, в список не идут.

## Проверка изменений апстрима

    gh api repos/rashn/RuSwitcher/compare/8c45253...main --jq '.files[].filename'

## Перенесенные файлы (13)

Список сверен с отметками в шапках; воспроизводится командой

    grep -rl RuSwitcher Sources --include='*.swift' | sort

- `Sources/IrizCore/` (5): Dict.swift · KeyCodes.swift · KeyMapping.swift ·
  LayoutDetector.swift · ShortWords.swift
- `Sources/IrizInput/` (7): AutoSwitchPolicy.swift · DynamicKeyMapping.swift ·
  KeyboardMonitor.swift · LayoutSwitcher.swift · SettingsManager.swift ·
  SpotlightAX.swift · TextConverter.swift
- `Sources/IrizApp/` (1): AppDelegate.swift - несёт двойную отметку, RuSwitcher
  и SuperDictate

Файлов `AutoSwitch.swift` и `main.swift` в дереве нет: что с ними стало - ниже.

## Внесенные изменения

- 03.08.2026 - вендоринг: все 20 файлов скопированы без изменений кода, в шапку каждого
  добавлена одна строка атрибуции (коммит 8c45253).
- 03.08.2026 - удалено 8 файлов как не относящиеся к двум функциям приложения
  (автопереключение раскладки и конвертация выделенного): Localization.swift (локализация
  на 16 языков) · SettingsWindowController.swift (окно настроек) · UpdateChecker.swift
  (автообновление по сети) · CaretIndicator.swift (индикатор у каретки) ·
  ExceptionListEditor.swift (редактор списков исключений) · PerAppLayoutManager.swift
  (память раскладки по приложениям) · ShareIcons.swift (меню шаринга) ·
  AppRelauncher.swift (перезапуск приложения). Все места вызова удаленных классов
  вычищены из оставшихся файлов; русские строки вписаны литералами на месте;
  SettingsManager.swift ужат до поддерживаемых опций.
- 03.08.2026 - пакет разложен на таргеты Core / Input / App (коммит `dbc8ce9`).
  `AutoSwitch.swift` (206 строк) разобран на три файла: `AutoSwitchPolicy.swift` (политика),
  `LayoutDetector.swift` (определение языка) и `Dict.swift` (словарь) - все три несут
  отметку RuSwitcher. `KeyCodes.swift`, `KeyMapping.swift`, `ShortWords.swift` переехали
  в `IrizCore`; `DynamicKeyMapping.swift`, `KeyboardMonitor.swift`, `LayoutSwitcher.swift`,
  `SettingsManager.swift`, `SpotlightAX.swift`, `TextConverter.swift` - в `IrizInput`.
- 04.08.2026 - `main.swift` донора удалён (коммит `113fa91`): оболочка переписана
  на `MenuBarExtra`, точка входа теперь `Sources/IrizApp/SmltlkAppMain.swift` - свой код,
  отметки о происхождении не несёт.

Арифметика итога: 20 файлов вендоринга − 8 удалённых = 12; `AutoSwitch.swift` стал тремя
файлами (+2); `main.swift` удалён (−1). Итого 13 - столько же возвращает `grep` выше.

---

## 2. SuperDictate - диктовка

Конвейер диктовки (захват звука, обёртка распознавания, вставка текста в фокусное поле,
разбор горячих клавиш, починка текста) происходит из SuperDictate - форка Parakey.

- Источник: https://github.com/shlgd/SuperDictate
- Коммит: 83dd7e44ce6621ebc14673affba1316c1a4476ba (релиз v0.2.40, 03.08.2026)
- Лицензия: MIT, Copyright (c) 2026 Richard Courtman
- Полный текст лицензии: `THIRD-PARTY/SuperDictate-LICENSE`
- Апстрим: Parakey, того же автора, та же лицензия

Код взят, изменён и распространяется на условиях MIT. Файлы, происходящие от донора,
несут отметку в шапке.

### Сверка 06.09.2026

Список проверен построчным сравнением с донорами на заявленных коммитах, а не по
отметкам в шапках. Что нашла сверка:

- файлов, где отметка стоит, а кода донора уже нет, - НОЛЬ. Снимать нечего;
- 23 файла несут узнаваемый код донора, местами дословно: `LayoutSwitcher.swift`,
  `SpotlightAX.swift`, `KeyCodes.swift`, `ShortWords.swift` совпадают полностью,
  `TextConverter.swift` на 99% одним куском в 315 строк;
- 7 файлов переписаны своим кодом, но держат наработки донора: подобранные им
  числовые константы плашки и формулы дыхания и синтетического уровня голоса.
  Это не бойлерплейт AppKit, а подобранные автором параметры, и отметка остаётся;
- ДВА файла несли код донора БЕЗ отметки, и это нарушение в обратную сторону:
  `IrizCore/PrivateFiles.swift` (приватная запись файлов) и
  `IrizDictate/DictationHistoryClipboard.swift` (временный буфер обмена). Код
  выносили в общие модули, а отметка за ним не ехала. Отметки поставлены.

Правило, по которому список ведётся: несём чужой код или чужие наработки -
указываем; взяли идею и написали своё - не указываем. Мелочи вроде семи строк
аргументов системного вызова, которые иначе не написать, в список не идут.

## Проверка изменений апстрима

    gh api repos/shlgd/SuperDictate/compare/83dd7e4...main --jq '.files[].filename'

### Что взято

Донор - один файл `main.swift` на 23 205 строк. Перенесено ≈ 2 900 строк конвейера
«нажал клавишу → записал → распознал → вставил», разложенных по отдельным файлам;
каждый несёт отметку в шапке - она и есть карта заимствований.

Всего 19 файлов с отметкой SuperDictate; список воспроизводится командой

    grep -rl 'SuperDictate\|Parakey' Sources --include='*.swift' | xargs grep -l 'Основано на\|адаптирован' | sort

- `Sources/IrizDictate/` (17): AudioCapture.swift · DictationHistoryWindow.swift ·
  DictationHUD.swift · DictationHUDCapsule.swift · DictationHUDExport.swift ·
  DictationHUDWindow.swift · DictationSettings.swift · DictationSupport.swift ·
  DictationText.swift · HotkeyAutomaton.swift · HotkeyChoice.swift · HotkeyListener.swift ·
  Logger.swift · Permissions.swift · Sounds.swift · TextInserter.swift · Transcriber.swift
- `Sources/IrizSettings/` (1): HotkeyRecorderController.swift
- `Sources/IrizApp/` (1): AppDelegate.swift - двойная отметка, RuSwitcher и SuperDictate

`Sources/IrizImport/SuperDictateImporter.swift` в этот список не входит: донорского кода
в нём нет, он лишь читает формат данных SuperDictate при переезде со старого приложения.

**`HotkeyRecorderController`** (донорские строки 3865–4150) взят и переписан: у нас
`Sources/IrizSettings/HotkeyRecorderController.swift`, 212 строк. Панель записи горячей
клавиши, перехват через `CGEventTap` с откатом на локальный монитор и разбор
модификаторов - оттуда; вид панели, тексты и связывание с настройками - код smltlk.

### Что осознанно НЕ взято

- **`UpdateCheck` и `SuperDictateUpdateInstaller`** (854 строки) - проверка обновлений
  и установщик. Это единственные места во всём доноре, где вызывается `URLSession`.
  Продукт обязан быть офлайн, поэтому они не переносились вовсе. То же самое уже сделано
  с `UpdateChecker` RuSwitcher. Отсутствие сети держится машинно:
  `scripts/negative_check.sh` роняет сборку на любом сетевом вызове в `Sources/`.
- **`ParakeyApp`** (7 758 строк, 33 % файла) не переносился целиком. Меню,
  окна настроек, обновления и слежение HUD за кареткой не взяты. Однако в новой
  плашке адаптированы отдельные блоки донорского HUD; точная карта приведена ниже.
- **Self-тесты донора** (~6 800 строк, 29 % файла) - перечитаны как источник тест-кейсов,
  целиком не переносились.
- **`FocusedInsertionTargetTracker` / `Locator`** (636 строк обхода дерева Accessibility) -
  выяснилось, что к вставке текста он отношения не имеет: им позиционируется HUD донора,
  а вставка идёт через `CGEvent`. Выброшен целиком.
- **LaunchAgent-демон и реестр панели** (254 строки) - у нас один процесс и один `SMAppService`.
- **Мьют системного звука со сторожем** (264 строки), **синхронизация правок через файл**
  (355 строк), диагностика и статистика - балласт для продукта из трёх функций.
- **Иконка `Parakey.icns`** - знак у нас свой.

### Изменения в перенесённом коде

- 05.08.2026 - перенос: домен ошибок `SuperDictate.*` → `smltlk.*`, журнал восстановления
  выброшен, монолит разложен по файлам, в шапку каждого добавлена строка происхождения.
- 05.08.2026 - загрузка модели ужата до `AsrModels.loadFromCache()`. Путь донора
  с `AsrModels.download(force: true)` при провале проверки целостности заменён на жёсткий
  отказ: так сетевой путь физически недостижим. Дополнительно выставляется
  `DownloadUtils.enforceOffline = true` - рубильник на уровне библиотеки.
- 07.08.2026 - плашка диктовки переделана на AppKit. Из зафиксированного `main.swift`
  донора адаптированы только следующие блоки:
  - `DictationHUD.swift`: константы тайминга и фазы, строки 85–97 и 1894–1905;
    сглаживание уровня и сторож залипания, строки 11190–11204;
  - `DictationHUDCapsule.swift`: типы цвета, размера и фона, строки 563–639, и рисование
    пилюли, волны, processing-перехода и фона, строки 8481–8797;
  - `DictationHUDWindow.swift`: идиома hover, строки 9406–9432; показ, скрытие, display link,
    панель и reveal-движок, строки 11225–11494; клэмп и минимальная видимость,
    строки 11780–11820;
  - `DictationHUDExport.swift` и CLI-вход в `AppDelegate.swift`: внеэкранный PNG-рендер и
    разбор `--export-hud-animation`, строки 8799–8925 и 23174–23184.
  Таблица всех стадий, новые глифы, текст подсказок, перетаскивание, хранение позиции
  и привязка к prompt-режиму - код smltlk.

---

## 3. FluidAudio - движок распознавания

Распознавание речи идёт через FluidAudio (Parakeet TDT v3 на Neural Engine).
Подключён как зависимость Swift Package Manager, исходники не вендорятся.

- Источник: https://github.com/FluidInference/FluidAudio
- Пин: `313feb4bd692780a9a5b5fa9048fdb119486dde8` - та же ревизия, что у донора
- Лицензия: Apache-2.0
- Полный текст лицензии: `THIRD-PARTY/FluidAudio-LICENSE`

## 4. Модель речи

- Источник: `FluidInference/parakeet-tdt-0.6b-v3-coreml` (Hugging Face)
- Лицензия: **CC-BY-4.0** - коммерческое использование разрешено при указании авторства
- Полный текст лицензии: `THIRD-PARTY/parakeet-CC-BY-4.0`. CC-BY-4.0 требует передавать
  текст лицензии вместе с материалом, поэтому он лежит в репозитории, а не ссылкой
- Исходная модель: `nvidia/parakeet-tdt-0.6b-v3`
- В репозиторий не входит: берётся из общего кэша
  `~/Library/Application Support/FluidAudio/Models/`, скачивается один раз самой библиотекой

Это **не** проприетарная конвертация Argmax. Файлы `argmaxinc/*kit-pro` лежат на диске
владельца от другого приложения, помечены «Argmax proprietary and confidential. Under NDA»
и в этот проект не попадают ни в каком виде.
