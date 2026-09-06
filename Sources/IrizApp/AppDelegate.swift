// Основано на RuSwitcher (MIT, © 2025 Rashns), коммит 8c45253.
// Части адаптированы из SuperDictate (форк Parakey), © 2026 Richard Courtman, лицензия MIT.
// Полный текст: THIRD-PARTY/SuperDictate-LICENSE
// Меню переписано с NSStatusItem на SwiftUI MenuBarExtra (этап 5): здесь осталась
// только логика — визард разрешений, мониторинг, авто-конверсия. View — в MenuContentView.
import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Darwin
import ServiceManagement
import IrizCore
import IrizDictate
import IrizImport
import IrizInput
import IrizSettings
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let menuState = MenuState()
    private let keyboardMonitor = KeyboardMonitor()
    private let textConverter = TextConverter()
    /// Конвейер диктовки (правый Cmd → запись → распознавание → вставка).
    /// Модель греется фоновой задачей внутри start().
    private let dictationController = DictationController()
    private var permissionCheckTimer: Timer?
    private var iconRefreshTimer: Timer?
    private var monitoringActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if exportHUDFramesIfRequested() { return }
        if exportUIShotsIfRequested() { return }
        if captureHUDLiveIfRequested() { return }
        if captureUILiveIfRequested() { return }
        if probeGlassIfRequested() { return }
        if measureHUDFirstShowIfRequested() { return }
        exportGlyphSheetIfRequested()
        showFirstRunIfRequested()
        showSettingsIfRequested()
        showHistoryIfRequested()
        showLearningDemoIfRequested()
        showUndeliveredDemoIfRequested()

        // Настройки переезжают из домена прежнего бандла ПЕРВЫМИ - до того, как
        // хоть что-нибудь их прочитает. UserDefaults.standard адресуется
        // идентификатором бандла, и после его смены домен пуст: без переезда
        // владелец увидел бы заводские значения вместо своих сочетаний клавиш,
        // словаря замен и списка приложений.
        migrateDefaultsFromLegacyBundle(
            legacy: UserDefaults(suiteName: LEGACY_BUNDLE_IDENTIFIER),
            into: .standard
        )

        // Переезд каталога данных на новое имя продукта - на СТАРТЕ, а не при
        // первой диктовке. Аксессор зовётся из DictationStore, то есть лениво:
        // владелец открыл бы историю и увидел пустоту, хотя записи лежат рядом
        // по старому адресу. Вызов дешёвый и идемпотентный - если переезжать
        // нечего, он просто возвращает путь.
        _ = try? irizApplicationSupportDirectory()

        // Д1: сцена MenuBarExtra коммитится после возврата из этого метода.
        // Визард разрешений умеет показать МОДАЛЬНЫЙ NSAlert (runModal) — пока он
        // крутит собственный run loop, элемент строки меню не создаётся вообще,
        // а после закрытия алерта может не создаться никогда. Поэтому весь
        // стартап, способный заблокировать run loop, — на следующем проходе,
        // когда сцена уже закоммичена. Порядок шагов внутри не меняется.
        DispatchQueue.main.async { [weak self] in
            self?.finishStartup()
        }
    }

    /// Технический режим рисует HUD вне экрана и завершается до
    /// импорта истории, запроса разрешений и запуска захвата звука.
    /// Снимает поверхности приложения вне экрана и завершается, как и раскадровка HUD.
    private func exportUIShotsIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--export-ui-shots" else { return false }
        guard arguments.count <= 2 else {
            writeHUDExportError("usage: IrizApp --export-ui-shots [shots-directory]")
            Darwin.exit(EXIT_FAILURE)
        }
        let output: URL
        if arguments.count == 2 {
            output = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        } else {
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("ui-shots", isDirectory: true)
        }
        // Съёмка уезжает на оборот цикла событий приложения: дерево SwiftUI
        // собирается там, а не внутри applicationDidFinishLaunching. Сделанный
        // синхронно снимок выходил ПУСТЫМ, и это поймано снимком, а не рассуждением.
        DispatchQueue.main.async { [weak self] in
            guard let self else { Darwin.exit(EXIT_FAILURE) }
            do {
                let shots = try exportUISurfaceShots(to: output, appDelegate: self)
                print("UI_SHOTS files=\(shots.count) directory=\(output.path)")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                self.writeHUDExportError("UI shots failed: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        return true
    }

    /// Живой кадр приговора для стеклянной плашки. Офскрин для стекла
    /// невозможен по построению, поэтому плашка поднимается на экран поверх
    /// известной подложки и снимается захватом области.
    private func captureHUDLiveIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--capture-hud-live" else { return capturePlateIfRequested() }
        guard arguments.count <= 2 else {
            writeHUDExportError("usage: IrizApp --capture-hud-live [frames-directory]")
            Darwin.exit(EXIT_FAILURE)
        }
        let output: URL
        if arguments.count == 2 {
            output = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        } else {
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("hud-live", isDirectory: true)
        }
        guard #available(macOS 26.0, *) else {
            writeHUDExportError("Стекло требует macOS 26 - живой кадр снимать нечем.")
            Darwin.exit(EXIT_FAILURE)
        }
        DispatchQueue.main.async {
            do {
                let frames = try captureDictationHUDLiveFrames(to: output)
                print("HUD_LIVE frames=\(frames.count) directory=\(output.path)")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                self.writeHUDExportError("HUD live capture failed: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        return true
    }

    /// Живой снимок НАСТОЯЩЕЙ плашки во всех формах: покой, раскрытие, запись.
    ///
    /// Отдельно от `--capture-hud-live`: тот собирает стекло и волну руками и
    /// не видит ни кнопок, ни панели, ни размера окна в покое.
    private func capturePlateIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--capture-plate" else { return probePlateGlassIfRequested() }
        let output: URL
        if arguments.count >= 2 {
            output = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        } else {
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("plate", isDirectory: true)
        }
        guard #available(macOS 26.0, *) else {
            writeHUDExportError("Стекло требует macOS 26 - живой кадр снимать нечем.")
            Darwin.exit(EXIT_FAILURE)
        }
        DispatchQueue.main.async {
            do {
                let frames = try captureDictationHUDPlateScenes(to: output)
                print("PLATE frames=\(frames.count) directory=\(output.path)")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                self.writeHUDExportError("Съёмка плашки не удалась: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        return true
    }

    /// `--capture-docs <папка>` - кадры витрины: каждая поверхность на трёх
    /// языках. Требование владельца: «все скриншоты надо добавлять на всех
    /// языках, то есть на русском, английском и китайском».
    private func captureDocShotsIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--capture-docs" else { return false }
        let output = arguments.count >= 2
            ? URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("docs/assets/shots", isDirectory: true)
        DispatchQueue.main.async {
            do {
                let shots = try captureDocShots(to: output, appDelegate: self)
                print("DOC_SHOTS files=\(shots.count) directory=\(output.path)")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                self.writeHUDExportError("Съёмка витрины не удалась: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        return true
    }

    /// `--probe-plate <папка>` - замер стекла ПЛАШКИ над тремя подложками.
    /// Кадры не для разглядывания: их читает scripts/glass_probe.py --plate.
    private func probePlateGlassIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--probe-plate" else { return captureDocShotsIfRequested() }
        let output = arguments.count >= 2
            ? URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("plate-glass", isDirectory: true)
        guard #available(macOS 26.0, *) else {
            writeHUDExportError("Стекло требует macOS 26 - мерить нечего.")
            Darwin.exit(EXIT_FAILURE)
        }
        DispatchQueue.main.async {
            do {
                let frames = try probeDictationHUDPlateGlass(to: output)
                print("PLATE_GLASS files=\(frames.count) directory=\(output.path)")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                self.writeHUDExportError("Замер стекла плашки не удался: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        return true
    }

    /// Живой снимок окна настроек: стекло офскрином не снять.
    private func captureUILiveIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--capture-ui-live" else { return false }
        let output = arguments.count == 2
            ? URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("ui-live", isDirectory: true)
        DispatchQueue.main.async {
            do {
                let shots = try captureSettingsWindowLive(to: output)
                print("UI_LIVE files=\(shots.count) directory=\(output.path)")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                self.writeHUDExportError("UI live capture failed: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        return true
    }

    /// `--glass-probe <папка>` - снять окно над чёрной, белой и полосатой
    /// подложкой. Кадры не для разглядывания: их читает scripts/glass_probe.py
    /// и выносит вердикт числом.
    private func probeGlassIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--glass-probe" else { return false }
        let output = arguments.count == 2
            ? URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("glass-probe", isDirectory: true)
        DispatchQueue.main.async {
            do {
                let shots = try probeSettingsGlass(to: output)
                print("GLASS_PROBE files=\(shots.count) directory=\(output.path)")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                self.writeHUDExportError("Glass probe failed: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        return true
    }

    private func exportHUDFramesIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--export-hud-animation" else { return false }

        // `--scale N` увеличивает кадры разглядывания. Кадры приговора `look-*`
        // он не трогает: их масштаб задан кодом, а не аргументом.
        var rest = Array(arguments.dropFirst())
        var scale = DICTATION_HUD_EXPORT_NATURAL_SCALE
        var only: String?
        if let flag = rest.firstIndex(of: "--only") {
            guard flag + 1 < rest.count else {
                writeHUDExportError("usage: IrizApp --export-hud-animation [dir] [--scale N] [--only <префикс>]")
                Darwin.exit(EXIT_FAILURE)
            }
            only = rest[flag + 1]
            rest.removeSubrange(flag...(flag + 1))
        }
        if let flag = rest.firstIndex(of: "--scale") {
            guard flag + 1 < rest.count, let value = Double(rest[flag + 1]), value >= 1 else {
                writeHUDExportError("usage: IrizApp --export-hud-animation [frames-directory] [--scale N>=1]")
                Darwin.exit(EXIT_FAILURE)
            }
            scale = CGFloat(value)
            rest.removeSubrange(flag...(flag + 1))
        }
        guard rest.count <= 1 else {
            writeHUDExportError("usage: IrizApp --export-hud-animation [frames-directory] [--scale N>=1]")
            Darwin.exit(EXIT_FAILURE)
        }

        let output: URL
        if let directory = rest.first {
            output = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        } else {
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("hud-animation", isDirectory: true)
        }

        do {
            let frames = try exportDictationHUDAnimationFrames(to: output, scale: scale, only: only)
            let timelineFrames = frames.lazy.filter {
                $0.lastPathComponent.hasPrefix("frame-")
            }.count
            // Таймлайнов два — обычная диктовка и промпт-режим: они и различаются
            // на экране, так что смотреть надо оба.
            let promptFrames = frames.lazy.filter {
                $0.lastPathComponent.hasPrefix("prompt-")
            }.count
            let duration = Double(timelineFrames) / 120
            let promptDuration = Double(promptFrames) / 120
            print("HUD_EXPORT frames=\(frames.count) timeline_frames=\(timelineFrames) "
                  + "prompt_frames=\(promptFrames) fps=120 "
                  + "duration=\(String(format: "%.3f", duration)) "
                  + "prompt_duration=\(String(format: "%.3f", promptDuration)) "
                  + "directory=\(output.path)")
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            writeHUDExportError("HUD export failed: \(error.localizedDescription)")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private func writeHUDExportError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Технический режим: замер задержки первого показа плашки. Один запуск —
    /// одно число: холодным первый показ бывает единственный раз за процесс.
    /// Завершается до импорта истории, разрешений и захвата звука.
    private func measureHUDFirstShowIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--measure-hud-first-show" else { return false }
        guard arguments.count <= 2,
              let mode = DictationHUDPrewarmMode(rawValue: arguments.count == 2
                                                 ? arguments[1]
                                                 : DictationHUDPrewarmMode.full.rawValue) else {
            writeHUDExportError("usage: IrizApp --measure-hud-first-show [none|wave|full]")
            Darwin.exit(EXIT_FAILURE)
        }
        // Приложение из строки меню и в замере обязано остаться таким же:
        // ни иконки в Dock, ни отобранного фокуса.
        NSApp.setActivationPolicy(.accessory)
        print(measureDictationHUDFirstShow(mode: mode))
        Darwin.exit(EXIT_SUCCESS)
    }

    /// Тело стартапа, отложенное за коммит сцены MenuBarExtra (см. Д1 выше).
    private func finishStartup() {
        // Разовый перенос клавиш и истории из старого приложения диктовки.
        // Идёт первым: дальше настройки уже читаются как свои.
        _ = SuperDictateImporter().run()
        syncLoginItem()
        // status.json — после async-регистрации login item из syncLoginItem
        // (SettingsManager.launchAtLogin setter диспатчит на main; наш блок
        // встаёт в очередь следом, значит статус уже финальный).
        DispatchQueue.main.async { [weak self] in self?.writeStatusReport() }
        refreshStatus()
        runPermissionWizard()
        // Иконка должна отражать раскладку и при СИСТЕМНОЙ смене (стандартный/
        // переопределённый хоткей), а не только при нашей конверсии.
        // suspensionBehavior: .deliverImmediately — иначе для фонового menu-bar-приложения
        // распределённое уведомление коалесцируется/откладывается (App Nap / suspend), и
        // иконка после переключения меняется с задержкой до нескольких секунд.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemInputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // Диктовка: прогрев модели фоном + слушатель правого Cmd (toggle).
        // Без «Мониторинга ввода» тап не встанет — контроллер сам перейдёт
        // в .unavailable; после выдачи разрешения приложение перезапускается.
        dictationController.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.applyDictationState(state) }
        }
        // Плашка умеет открыть настройки, но своего окна у модуля диктовки нет
        // и быть не должно: окно принадлежит приложению.
        dictationController.onOpenSettings = { [weak self] in self?.openSettings() }
        dictationController.start()
        // Прогрев плашки целиком: панель, её слои, шейдер, первый кадр, шрифты
        // подсказки. Всё это собиралось в момент первого нажатия — ровно та
        // заминка в начале, на которую жаловался владелец. Отдельным проходом
        // цикла, чтобы не задерживать остальной старт; плашка при этом
        // не показывается и фокус не забирает.
        DispatchQueue.main.async { [weak self] in self?.dictationController.prewarmHUD() }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidSave),
            name: DictationController.settingsDidSaveNotification,
            object: DictationSettings.shared
        )
    }

    @objc private func settingsDidSave(_ notification: Notification) {
        guard monitoringActive else {
            startMonitoring()
            return
        }
        guard keyboardMonitor.reconfigure() else {
            monitoringActive = false
            startMonitoring()
            return
        }
        refreshStatus()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        dictationController.prepareForSystemSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        dictationController.resumeAfterSystemWake()
        // За время сна раскладку могли сменить, окно - закрыть, курсор -
        // увести. Всё, что помнил буфер слова, относится к прошлой сессии
        // работы, и перепечатка по нему стёрла бы чужой текст. Диктовка свой
        // сон уже переживает (`resumeAfterSystemWake`), раскладка - нет.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        refreshStatus()
    }

    /// Диагностический снимок для scripts/gate_app.sh — пишется при старте.
    private func writeStatusReport() {
        StatusReport.write(
            ax: AXIsProcessTrusted(),
            listen: CGPreflightListenEventAccess(),
            post: CGPreflightPostEventAccess(),
            loginItem: SettingsManager.shared.loginItemStatus == .enabled
        )
    }

    // MARK: - Learn-from-undo (предложить добавить слово в never-convert)

    /// Последняя авто-конвертация: слово (как было набрано) + время. Если пользователь
    /// сразу откатывает ручным триггером — предлагаем занести слово в исключения.
    private var lastAutoConverted: (word: String, at: Date)?
    /// Анти-наг: за сессию про одно слово спрашиваем один раз.
    private var offeredExceptionWords: Set<String> = []

    private func offerExceptionAfterUndo() {
        guard let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 8 else { return }
        lastAutoConverted = nil
        let word = last.word
        let key = word.lowercased()
        guard !offeredExceptionWords.contains(key) else { return }
        offeredExceptionWords.insert(key)
        guard !SettingsManager.shared.deniedWordsSet.contains(key) else { return }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Всегда оставлять «\(word)» без замены?"
        alert.addButton(withTitle: "Добавить в исключения")
        alert.addButton(withTitle: "Не сейчас")
        if alert.runModal() == .alertFirstButtonReturn {
            var list = SettingsManager.shared.deniedWords
            list.append(word)
            SettingsManager.shared.deniedWords = list
            rslog("learn: added word (len=\(word.count)) to never-convert")
        }
    }

    // MARK: - Login Item Sync

    /// Синхронизирует состояние автозагрузки с системой при старте.
    /// Если галочка включена, но Login Item потерян (переустановка/обновление) — перерегистрирует.
    /// Если галочка выключена, но Login Item есть — снимает.
    private func syncLoginItem() {
        let settings = SettingsManager.shared
        let wanted = settings.launchAtLogin
        let status = settings.loginItemStatus

        rslog("Login item sync: wanted=\(wanted) status=\(status.rawValue)")

        if wanted && status != .enabled {
            rslog("Re-registering login item...")
            settings.launchAtLogin = true  // setter вызовет doUpdateLoginItem
        } else if !wanted && status == .enabled {
            rslog("Unregistering stale login item...")
            settings.launchAtLogin = false
        }
    }

    // MARK: - Permission Wizard

    /// Окно знакомства. Живёт столько же, сколько приложение: закрыть его
    /// крестиком не значит отказаться от продукта.
    /// Запись сочетания. Один экземпляр на приложение: два открытых
    /// перехватчика клавиш дрались бы за один тап.
    private let hotkeyRecorder = HotkeyRecorderController()

    private lazy var firstRun: FirstRunWindowController = {
        let controller = FirstRunWindowController()
        // Проба голосом идёт ТЕМ ЖЕ путём, что и обычная диктовка: кнопка
        // зовёт тот же обработчик, что и клавиша. Иначе знакомство показывало
        // бы не тот продукт, который человеку достанется.
        controller.model.toggleDictation = { [weak self] in
            self?.dictationController.toggleDictationFromUI()
        }
        // Клавишу меняют ПРЯМО В ЗНАКОМСТВЕ. Человек, у которого правый Command
        // занят чужой программой, до настроек не дойдёт: он решит, что продукт
        // не работает, и закроет его.
        controller.model.recordHotkey = { [weak self] done in
            guard let self else { return }
            self.hotkeyRecorder.present(actionTitle: "Диктовка") { choice in
                guard let choice else { done(); return }
                DictationSettings.shared.hotkeyKeycode = choice.keycode
                DictationSettings.shared.hotkeyModifiers = choice.requiredModifiers
                self.dictationController.applySettings()
                done()
            }
        }
        return controller
    }()

    /// Открыть знакомство намеренно: `--first-run`.
    ///
    /// Нужно не для отладки. Знакомство по правилу не показывается тому, у
    /// кого разрешения уже выданы, - иначе оно лезло бы к человеку, который
    /// год пользуется продуктом. Но посмотреть его должен уметь и он: и чтобы
    /// проверить перед выпуском, и чтобы вспомнить, что там написано.
    ///
    /// Тем же путём оно откроется из меню, когда там появится пункт.
    /// `--export-glyphs <файл>` - снять лист значков и выйти. Значок нельзя
    /// утвердить по описанию: он читается или не читается на шестнадцати
    /// пунктах, и видно это только на настоящем рендере.
    private func exportGlyphSheetIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--export-glyphs") else { return }
        let next = arguments.index(after: index)
        let path = next < arguments.count ? arguments[next] : "glyphs.png"
        DispatchQueue.main.async {
            do {
                try irizWriteGlyphSheet(to: URL(fileURLWithPath: path))
                print(path)
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("лист значков не снят: \(error)\n".utf8))
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }

    /// `--settings` - открыть окно настроек сразу. У приложения из строки меню
    /// окно иначе поднимается только мышью по значку, и снять его кадром для
    /// проверки нечем.
    private func showSettingsIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--settings") else { return }
        // Имя страницы за флагом: любая страница обязана подниматься по
        // команде, иначе её нельзя ни снять кадром, ни прогнать прибором.
        let next = arguments.index(after: index)
        let page = next < arguments.count ? SettingsPage(rawValue: arguments[next]) : nil
        DispatchQueue.main.async { [weak self] in self?.openSettings(page: page ?? .keys) }
    }

    /// `--history` - открыть окно истории сразу.
    ///
    /// Без флага окно поднималось только клавишей или из меню, то есть снять
    /// его кадром и прогнать прибором было нечем. Поверхность, которую нельзя
    /// показать по команде, нельзя и судить: окно истории целый круг оставалось
    /// единственной непрозрачной панелью продукта, и заметил это разбор, а не
    /// проверка.
    private func showHistoryIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--history") else { return }
        DispatchQueue.main.async { [weak self] in self?.dictationController.showHistory() }
    }

    /// `--demo-learning` - показать всплывашку обучения словаря.
    ///
    /// Поверхность, которую нельзя поднять по команде, нельзя и судить: она
    /// появляется только после настоящей правки в чужом приложении, и снять
    /// её кадром иначе нечем.
    private func showLearningDemoIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--demo-learning") else { return }
        DispatchQueue.main.async {
            dictationLearningDemoToast()
        }
    }

    /// `--demo-undelivered [текст]` - поднять панель с не доехавшим текстом.
    /// Инструмент для съёмки: судить эту панель можно только живой.
    private func showUndeliveredDemoIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--demo-undelivered") else { return }
        let next = arguments.index(after: index)
        let text = next < arguments.count && !arguments[next].hasPrefix("--")
            ? arguments[next]
            : "Проверка панели: этот текст никуда не доехал, и его можно забрать отсюда целиком."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.dictationController.showUndeliveredDemo(text)
        }
    }

    private func showFirstRunIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--first-run") else { return }
        DispatchQueue.main.async { [weak self] in self?.firstRun.show() }
    }

    private func runPermissionWizard(interactive: Bool = false) {
        let acc = AXIsProcessTrusted()
        let inp = CGPreflightListenEventAccess()
        rslog("Permissions: accessibility=\(acc) inputMonitoring=\(inp)")

        // Первый запуск ведёт СВОЁ окно, а не цепочка системных алертов.
        // Прежний визард не мог ничего объяснить: у алерта нет места под мысль,
        // а самое страшное разрешение - «Мониторинг ввода», где система сама
        // говорит «сможет читать все нажатия клавиш», - объяснением в одну
        // строку не закрывается. По карте путей это была главная точка ухода
        // из продукта у всех, кроме владельца.
        //
        // Приглашение НЕ повторяется тем, кто уже прошёл этот путь руками:
        // решение целиком в firstRunShouldShow.
        if !interactive,
           firstRunShouldShow(defaults: .standard,
                              permissionsGranted: acc && inp,
                              modelInstalled: speechModelCacheExists(for: .multilingualV3)) {
            rslog("First run: showing the welcome window")
            firstRun.show()
            return
        }

        if acc && inp {
            SettingsManager.shared.permissionsWereGranted = true
            if !monitoringActive { startMonitoring() }
            if interactive { showPermissionsOKAlert() }
            else { offerPromptModeIfNeeded() }
            return
        }

        // Разрешения были раньше, а теперь сброшены (обновление)
        if SettingsManager.shared.permissionsWereGranted {
            rslog("Permissions were previously granted — reset detected after update")
            SettingsManager.shared.permissionsWereGranted = false
            showPermissionsResetAlert()
            return
        }

        if acc {
            showStep_InputMonitoring()
            return
        }

        showStep_Accessibility()
    }

    /// Подтверждение при ручной проверке, когда все разрешения уже выданы
    private func showPermissionsOKAlert() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Все разрешения на месте"
        alert.informativeText = "«Универсальный доступ» и «Мониторинг ввода» включены. \(IRIZ_NAME) работает."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Разовое предложение при первичной настройке. Согласие явное: обычная
    /// диктовка остаётся локальной, а отдельный режим отдаёт сырьё выбранному
    /// агенту — и цена этого выбора названа прямо здесь, до согласия.
    private func offerPromptModeIfNeeded() {
        let settings = DictationSettings.shared
        guard !settings.promptOnboardingOffered, !settings.promptModeEnabled else { return }
        settings.promptOnboardingOffered = true

        let adapter = settings.promptAgentAdapter
        let agentURL = settings.detectPromptAgentExecutable()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Подключить режим «Речь → промпт»?"
        alert.informativeText = """
        Этот режим необязателен: обычная диктовка останется локальной. Промпт собирает \
        выбранный агент — сейчас это \(adapter.displayName), \(adapter.destination.title). \
        Агент, путь к нему и профиль исполнителя меняются в настройках; там же есть \
        локальный вариант, который ничего никуда не отправляет. Результат вставляется без отправки. \
        Промпт собирается под тот проект, в котором вы сейчас работаете: агент берёт адрес \
        из рабочей папки своей сессии, поэтому называть проект голосом не нужно — а если \
        назовёте другой, он остановится и переспросит.
        """
        alert.addButton(withTitle: agentURL == nil ? "Открыть настройки" : "Подключить \(adapter.displayName)")
        alert.addButton(withTitle: "Не сейчас")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let agentURL, !adapter.requiresModel || !settings.promptAgentModel.isEmpty else {
            openSettings()
            return
        }
        settings.setPromptAgentPath(agentURL.path, for: adapter.id)
        settings.promptModeEnabled = true
    }

    /// Уведомление о сбросе разрешений после обновления
    private func showPermissionsResetAlert() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Разрешения сброшены после обновления"
        alert.informativeText = "macOS сбросил разрешения из-за обновления программы.\n\n\(IRIZ_NAME) удалит старые записи и запросит разрешения заново.\nВам нужно только включить переключатели."
        alert.addButton(withTitle: "OK")
        alert.runModal()

        resetPermissions()
        showStep_Accessibility()
    }

    /// Сбрасывает старые записи разрешений для нашего bundle ID
    private func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? IRIZ_BUNDLE_IDENTIFIER
        rslog("Resetting TCC entries for \(bundleID)")

        for service in ["Accessibility", "ListenEvent"] {
            let reset = Process()
            reset.launchPath = "/usr/bin/tccutil"
            reset.arguments = ["reset", service, bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }

        rslog("TCC entries reset done")
    }

    private func showStep_Accessibility() {
        // AXIsProcessTrustedWithOptions с prompt=true показывает системный диалог
        // и добавляет программу в список Accessibility автоматически
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    rslog("Accessibility granted!")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.showStep_InputMonitoring()
                }
            }
        }
    }

    private func showStep_InputMonitoring() {
        // CGRequestListenEventAccess() показывает системный диалог и добавляет
        // программу в список Input Monitoring автоматически
        let preflightOK = CGPreflightListenEventAccess()
        rslog("Preflight check = \(preflightOK)")

        if preflightOK {
            SettingsManager.shared.permissionsWereGranted = true
            startMonitoring()
            offerPromptModeIfNeeded()
            return
        }

        rslog("Requesting access...")
        CGRequestListenEventAccess()

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CGPreflightListenEventAccess() {
                    rslog("Input Monitoring granted! Restarting...")
                    SettingsManager.shared.permissionsWereGranted = true
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.restartApp()
                }
            }
        }
    }

    /// Relaunch after Input Monitoring is granted: the grant only takes effect
    /// in a fresh process.
    private func restartApp() {
        rslog("Restarting from: \(Bundle.main.bundlePath)")
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Start Monitoring

    private func startMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil

        if !keyboardMonitor.start(
            onAltTap: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                // Приватность: в защищённом поле (пароль) ничего не делаем.
                guard !AutoSwitchPolicy.secureInputActive else { rslog("trigger: bail secure-input"); return }
                // issue #16: в Spotlight обычный путь оставляет лишнюю букву (серое
                // автодополнение съедает Backspace). Особый путь: Cmd+A + буфер, без
                // Backspace. Гейт isActive() строгий, поэтому здесь мы ТОЧНО в Spotlight —
                // конвертим только своим путём и НЕ проваливаемся в буфер/count-пути,
                // что бы convertSpotlight ни вернул.
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.refreshStatus()
                        self.lastAutoConverted = nil
                    }
                    return
                }
                let keys = self.keyboardMonitor.currentWordKeys
                let prevKeys = self.keyboardMonitor.prevWordKeys
                let bc = self.keyboardMonitor.boundaryCount
                if self.textConverter.convert(wordKeys: keys, prevWordKeys: prevKeys, boundaryCount: bc) {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.refreshStatus()
                    self.lastAutoConverted = nil
                }
            },
            onAltReconvert: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                guard !AutoSwitchPolicy.secureInputActive else { rslog("reconvert: bail secure-input"); return }
                // issue #16: в Spotlight реконверт — тот же путь (Cmd+A + буфер), он
                // реверсивен. НЕ проваливаемся в count-based reconvert() в Spotlight.
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.refreshStatus()
                    }
                    return
                }
                if self.textConverter.reconvert() {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    Counters.shared.bumpUndo()
                    self.refreshStatus()
                    self.offerExceptionAfterUndo()
                }
            }
        ) {
            rslog("Event tap failed - will retry in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startMonitoring()
            }
            return
        }

        monitoringActive = true
        keyboardMonitor.onWordCounted = {
            Counters.shared.bumpWords()
        }
        keyboardMonitor.onWordBoundary = { [weak self] in
            self?.handleAutoConvert()
        }
        // issue #14: хоткей чистого переключения раскладки (без конверсии). Буфер после
        // явной смены раскладки неактуален — тот же паттерн, что и выбор раскладки в меню.
        keyboardMonitor.onSwitchHotkey = { [weak self] in
            guard let self, SettingsManager.shared.autoSwitchEnabled else { return }
            LayoutSwitcher.switchToOpposite()
            self.keyboardMonitor.markConverted()
            self.textConverter.clearState()
            self.refreshStatus()
        }
        // Тап отвалился и не поднялся - знак обязан это показать. Прежде код
        // молча пытался включить его обратно и считал попытку успехом.
        keyboardMonitor.onTapHealthChanged = { [weak self] alive in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.menuState.inputTapOK != alive else { return }
                self.menuState.inputTapOK = alive
                self.refreshStatus()
            }
        }
        refreshStatus()
        // Страховка к issue #9: системное уведомление о смене раскладки ненадёжно,
        // поэтому флаг «застревает». Постоянный лёгкий опрос держит иконку в синхроне с системой.
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        rslog("Monitoring started successfully")
    }

    /// Авто-конвертация на границе слова: детект неправильной раскладки → конверт + смена.
    /// Точность-first: при любой неуверенности ничего не делаем. Ручной триггер не трогаем.
    private func handleAutoConvert() {
        rslog("auto: fired")
        guard SettingsManager.shared.autoSwitchEnabled else { rslog("auto: bail master-off"); return }
        guard SettingsManager.shared.autoConvert else { rslog("auto: bail flag-off"); return }
        guard !AutoSwitchPolicy.secureInputActive else { rslog("auto: bail secure-input"); return }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if AutoSwitchPolicy.isDeniedApp(frontID) { rslog("auto: bail denied-app \(frontID ?? "?")"); return }
        if let captured = keyboardMonitor.prevWordBundleID, captured != frontID {
            rslog("auto: bail focus-changed"); return  // фокус уехал между пробелом и сейчас
        }

        let allKeys = keyboardMonitor.prevWordKeys
        let bc = keyboardMonitor.boundaryCount
        guard !allKeys.isEmpty else { rslog("auto: bail empty-keys"); return }  // курсор уехал — небезопасно
        guard let fullPair = DynamicKeyMapping.convertKeys(allKeys) else { rslog("auto: bail convertKeys-nil"); return }

        // issue #15: слово с прилипшей пунктуацией ("ghbdtn,") — отщепляем хвост, детектим
        // и конвертим ядро, хвост вернётся в поле литералом. Проверка счёта — инвариант
        // «1 клавиша = 1 символ» обоих путей convertKeys; при слиянии графем не отщепляем.
        var keys = allKeys
        var suffix = ""
        let split = LayoutDetector.splitTrailingPunctuation(fullPair.original)
        if !split.suffix.isEmpty, split.coreLength > 0, fullPair.original.count == allKeys.count {
            keys = Array(allKeys.prefix(split.coreLength))
            suffix = split.suffix
        }
        guard let pair = suffix.isEmpty ? fullPair : DynamicKeyMapping.convertKeys(keys) else {
            rslog("auto: bail convertKeys-nil"); return
        }
        if AutoSwitchPolicy.isDeniedWord(pair.original, pair.converted) { rslog("auto: bail denied-word"); return }

        // Язык для детектора — по текущей и противоположной раскладке системы.
        guard let langs = LayoutSwitcher.currentAndOppositeLanguage() else {
            rslog("auto: bail langs-nil"); return
        }

        // Ревью-находка (#15): '.', ',', ';', ':' в EN — клавиши букв ю/б/ж/Ж в ЙЦУКЕН,
        // поэтому начало «хвоста» в целевой раскладке может оказаться буквами, а ядро +
        // эти буквы — словарным словом: «levf.» → «думаю», «levf.!» → «думаю!». Идём по
        // буквенному расширению ядра в полной конверсии и проверяем каждый префикс по
        // словарю: первое словарное расширение = неоднозначность («думаю» vs «дума.») →
        // точность важнее полноты, не делаем НИЧЕГО (ручной триггер конвертирует целиком).
        if !suffix.isEmpty, Dict.isAvailable(langs.opposite) {
            let oth = String(langs.opposite.prefix(2))
            let fullConv = Array(fullPair.converted)
            var candidate = String(fullConv[..<split.coreLength])
            for ch in fullConv[split.coreLength...] {
                guard ch.isLetter else { break }
                candidate.append(ch)
                if Dict.isValidWord(candidate.lowercased(), lang: oth) {
                    rslog("auto: bail ambiguous-suffix")
                    return
                }
            }
        }

        let capsLock = keys.contains { $0.caps }
        // Explicit always-convert override, matched on the converted (target) form.
        // Moved here from LayoutDetector.decide during the module split: the policy
        // lives in IrizInput, and the detector in IrizCore must not depend on it.
        let verdict: LayoutVerdict
        if AutoSwitchPolicy.isAlwaysConvert(pair.converted) {
            verdict = .switchToConverted
        } else {
            verdict = LayoutDetector.decide(typed: pair.original, converted: pair.converted,
                                            currentLang: langs.current, otherLang: langs.opposite,
                                            capsLock: capsLock)
        }
        rslog("auto: len=\(pair.original.count) \(langs.current)/\(langs.opposite) verdict=\(verdict)")  // слова не логируем (приватность)
        guard verdict == .switchToConverted else { return }

        // Теневой режим (этап 7, первый день обкатки): кандидат считается
        // в counters.json как автопереключение, но текст НЕ меняется. Число за
        // день владелец сверяет с привычными ~147 автопереключениями Punto.
        if SettingsManager.shared.shadowMode {
            Counters.shared.bumpAutoswitch()
            rslog("auto: shadow-count len=\(pair.original.count)")
            refreshStatus()
            return
        }

        // issue #16 (авто): в Spotlight стирание по счётчику оставляет лишнюю букву.
        // Выделяем слово по ГРАНИЦЕ (Shift+Option+Left) и печатаем поверх, без Backspace.
        if SpotlightAX.isActive() {
            if suffix.isEmpty,
               textConverter.convertSpotlightWord(converted: pair.converted, boundaryCount: bc) {
                keyboardMonitor.markConverted()
                LayoutSwitcher.switchToOpposite()
                lastAutoConverted = (pair.original, Date())
                Counters.shared.bumpAutoswitch()
                refreshStatus()
            }
            return   // Spotlight: обычный count-путь неприменим
        }

        rslog("auto: convert \(keys.count) keys (+\(suffix.count) punct, +\(bc) sp)")
        if textConverter.convert(wordKeys: [], prevWordKeys: keys, boundaryCount: bc,
                                 passthroughSuffix: suffix) {
            keyboardMonitor.markConverted()
            LayoutSwitcher.switchToOpposite()
            lastAutoConverted = (pair.original, Date())
            Counters.shared.bumpAutoswitch()
            refreshStatus()
        }
    }

    // MARK: - Menu state & actions (вызываются из MenuContentView)

    @objc private func systemInputSourceChanged() {
        // Раскладку сменили СИСТЕМНЫМ способом - значит набранное до этого
        // напечатано в другой раскладке, и буфер слова протух. Перепечатка
        // после конверсии стёрла бы не то число символов: курсор тот же,
        // а длина слова уже неверна.
        //
        // Ровно это уже делает наш собственный хоткей переключения
        // (`onSwitchHotkey`), и обработчик системной смены обязан вести себя
        // так же: одна причина - одно следствие, независимо от того, кто
        // нажал клавишу.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        refreshStatus()
    }

    /// Диктовка победила раскладку в слоте знака (VISUAL_SPEC §4): пока идёт речь,
    /// раскладка клавиатуры значения не имеет, второго слота нет и заводить нельзя.
    /// Запись и распознавание — одно состояние: для владельца это один процесс
    /// «слушает и обрабатывает», а распознавание длится 0,12 с на 7 с речи.
    private func applyDictationState(_ state: DictationController.State) {
        menuState.dictationState = state
        // Знакомство подсвечивает клавишу, пока идёт запись. Состояние берётся
        // из ТОГО ЖЕ источника, что и знак строки меню: две поверхности,
        // рассказывающие про одну запись, обязаны говорить одно и то же.
        firstRun.model.dictationStateChanged(isRecording: state == .recording,
                                             isTranscribing: state == .transcribing)
        switch state {
        case .recording, .transcribing, .generatingPrompt:
            menuState.mark = MarkState(mode: .dictating, alarm: .none)
        case .warmingUp, .ready, .unavailable:
            // Сначала снять dictating — иначе страж в refreshStatus не даст обновить знак,
            // и волна осталась бы висеть после конца записи.
            menuState.mark = MarkState(
                mode: menuState.mode.markMode,
                alarm: menuState.mark.alarm
            )
            refreshStatus()
            // Счётчики вставки накопительные, а status.json писался только при старте —
            // значит провал, случившийся сейчас, попал бы в файл лишь следующим запуском,
            // и «частота провалов вставки» была бы всегда на день позади.
            // Диктовка вернулась в покой — самое время переписать снимок.
            if case .ready = state { writeStatusReport() }
        }
    }

    /// Обновляет MenuState: знак строки меню (раскладка + режим + авария),
    /// список раскладок, режим по осям SettingsManager, счётчики дня.
    func refreshStatus() {
        let settings = SettingsManager.shared
        // Два флага, а не один: меню называет разрешение поимённо, иначе владелец
        // ищет наугад в трёх панелях системных настроек.
        menuState.accessibilityOK = AXIsProcessTrusted()
        menuState.inputMonitoringOK = CGPreflightListenEventAccess()
        let permissionsOK = menuState.permissionsOK
        // Микрофон отваливается независимо от двух других: раскладка без него работает,
        // диктовка — нет. Поэтому флаг отдельный (UI.md §2.2).
        menuState.microphoneOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        menuState.mode = Self.modeFromSettings(settings)
        let isCyrillic = LayoutSwitcher.currentLanguageCode()?.lowercased().hasPrefix("ru") == true
        // Знак обновляется и по таймеру раз в 2 с. Во время диктовки этого делать нельзя:
        // иначе волна гасла бы на следующем тике. Слот принадлежит диктовке, пока она идёт.
        if menuState.mark.mode != .dictating {
            menuState.mark = MarkState(
                mode: menuState.mode.markMode,
                // Аварийный знак поднимает и отвалившийся тап: разрешения на
                // месте, а раскладка уже не исправляется, и молчащий знак тут
                // врал бы «всё в порядке».
                alarm: (permissionsOK && menuState.inputTapOK) ? .none : .noPermission
            )
        }
        let currentID = LayoutSwitcher.currentLayoutID()
        menuState.currentLayoutID = currentID
        menuState.layouts = LayoutSwitcher.installedLayouts().map { source in
            let id = LayoutSwitcher.sourceID(source)
            // TIS отдаёт имя на языке локализации приложения, у нас её нет — приходит
            // «Russian». В русском меню это чужое слово (LayoutNaming).
            let name = LayoutNaming.russianName(LayoutSwitcher.sourceName(source))
            if id == currentID { menuState.currentLayoutName = name }
            return MenuState.LayoutEntry(id: id, name: name, isCurrent: id == currentID)
        }
        let today = Counters.shared.today
        menuState.todayAutoswitches = today.autoswitches
        menuState.todayUndos = today.undos
    }

    /// Три тумблера SettingsManager свёрнуты в одну ось режима (VISUAL_SPEC §6.3):
    /// fixing = autoSwitch on + shadow off · shadow = on + on · paused = master off.
    private static func modeFromSettings(_ settings: SettingsManager) -> AppMode {
        if !settings.autoSwitchEnabled { return .paused }
        return settings.shadowMode ? .shadow : .fixing
    }

    /// Единственная точка смены режима из меню. «Исправляет» и «Только считает»
    /// оба требуют autoConvert=true: без него handleAutoConvert молчит и в теневом
    /// режиме считать было бы нечего.
    func setMode(_ mode: AppMode) {
        let settings = SettingsManager.shared
        switch mode {
        case .fixing:
            settings.autoSwitchEnabled = true
            settings.autoConvert = true
            settings.shadowMode = false
        case .shadow:
            settings.autoSwitchEnabled = true
            settings.autoConvert = true
            settings.shadowMode = true
        case .paused:
            settings.autoSwitchEnabled = false
        }
        refreshStatus()
    }

    func selectLayout(id: String) {
        guard id != LayoutSwitcher.currentLayoutID() else { return }
        LayoutSwitcher.switchTo(layoutID: id)
        // Явная смена раскладки делает набранный буфер неактуальным.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        refreshStatus()
    }

    /// Починка того, о чём кричит аварийная строка.
    ///
    /// Раньше здесь всегда открывался визард разрешений. Для отвалившегося
    /// тапа это неверный ремонт: права на месте, чинить надо слежение, и
    /// визард отправил бы владельца в системные настройки искать несуществующую
    /// проблему. Разные поломки лечатся по-разному - в том числе и кнопкой.
    func recheckPermissions() {
        if menuState.permissionsOK, !menuState.inputTapOK {
            monitoringActive = false
            startMonitoring()
            // Успех определяется тем, поднялось ли слежение, а не тем, что мы
            // его попросили: `startMonitoring` сам ставит `monitoringActive`.
            menuState.inputTapOK = monitoringActive
            refreshStatus()
            return
        }
        runPermissionWizard(interactive: true)
    }

    /// Меню открывает историю той же цепочкой, что и хоткей, — не своей копией.
    func showDictationHistory() {
        dictationController.showHistory()
    }

    // MARK: - Окно настроек

    /// Окно живёт столько же, сколько приложение: пересоздавать его на каждый показ —
    /// значит терять несохранённую запись хоткея и позицию окна.
    private var settingsWindow: NSWindow?

    /// Открыть знакомство заново из меню.
    /// Идёт ли запись встречи. Меню спрашивает, чтобы назвать строку словом
    /// «остановить», а не показывать «записать» поверх идущей записи.
    var isRecordingMeeting: Bool {
        dictationController.isRecordingMeeting
    }

    /// Начать или остановить запись встречи одной строкой меню.
    func toggleMeetingRecording() {
        if dictationController.isRecordingMeeting {
            dictationController.stopMeetingRecording()
        } else {
            dictationController.startMeetingRecording()
        }
    }

    func showWelcome() {
        firstRun.show()
    }

    func openSettings(page: SettingsPage = .keys) {
        if let window = settingsWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Окно собирает общая фабрика: прибор снимает ровно это окно, а не
        // свою копию с другими флагами.
        let window = makeIrizSettingsWindow(page: page)
        window.center()
        settingsWindow = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(
            self,
            name: DictationController.settingsDidSaveNotification,
            object: DictationSettings.shared
        )
        dictationController.stop()
        // Не теряем буфер обмена в 2-секундном окне отложенного восстановления.
        textConverter.flushPendingClipboardRestore()
    }

    func quitApp() {
        textConverter.flushPendingClipboardRestore()
        keyboardMonitor.stop()
        dictationController.stop()
        NSApplication.shared.terminate(nil)
    }
}


