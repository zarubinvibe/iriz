// Установка модели распознавания по сети - один раз, руками человека.
//
// Модель больше не едет в образе. Владелец сказал прямо: класть в публичный
// выпуск слепок модели глупо, завтра выйдет свежее, а образ на полгигабайта
// весит как весь остальной продукт вместе взятый. Поэтому образ везёт
// приложение, а модель приезжает после установки - с показанным ходом и
// понятной ценой.
//
// Правило «сеть в диктовке запрещена» при этом остаётся. `enforceOffline`
// снимается ТОЛЬКО на время явной установки, которую начал человек, и
// возвращается назад в `defer` - в том числе на ошибке и на отмене. Пока идёт
// диктовка, установка не начинается вовсе: снятый рубильник при работающем
// конвейере означал бы, что распознавание может молча полезть в сеть.
import FluidAudio
import Foundation

/// Что происходит с установкой прямо сейчас.
public enum SpeechModelInstallPhase: Equatable, Sendable {
    /// Идёт скачивание, 0…1.
    case downloading(Double)
    /// Файлы получены, CoreML собирает модель под это железо.
    case compiling
    case finished
    case failed(String)
}

public enum SpeechModelInstallRefusal: String, Equatable, Sendable {
    /// Уже стоит - качать нечего.
    case alreadyInstalled
    /// Установка уже идёт.
    case alreadyRunning
    /// Идёт диктовка: рубильник сети при работающем конвейере не снимаем.
    case dictationBusy
}

/// Можно ли начинать установку. Чистая функция: решение принимается по трём
/// фактам, и проверять его надо без сети и без диска.
public func speechModelInstallRefusal(installed: Bool,
                                      running: Bool,
                                      dictating: Bool) -> SpeechModelInstallRefusal? {
    if running { return .alreadyRunning }
    if dictating { return .dictationBusy }
    if installed { return .alreadyInstalled }
    return nil
}

/// Ход установки, как его показывает окно: доля и подпись.
public func speechModelInstallTitle(_ phase: SpeechModelInstallPhase) -> String {
    switch phase {
    case .downloading: return "Качаю модель распознавания"
    case .compiling: return "Готовлю модель под твой Мак"
    case .finished: return "Модель на месте"
    case .failed: return "Скачать не вышло"
    }
}

public func speechModelInstallFraction(_ phase: SpeechModelInstallPhase) -> Double {
    switch phase {
    case .downloading(let value): return min(1, max(0, value))
    // Сборка идёт без хода: показываем почти полную полосу, а не откат назад.
    case .compiling: return 0.97
    case .finished: return 1
    case .failed: return 0
    }
}

@MainActor
public final class SpeechModelInstaller {
    public static let shared = SpeechModelInstaller()

    private(set) public var isRunning = false

    private init() {}

    /// Поставить модель. `dictating` приходит снаружи: установщик не обязан
    /// знать устройство конвейера, а конвейер - устройство установщика.
    @discardableResult
    public func install(dictating: Bool,
                        progress: @escaping @MainActor (SpeechModelInstallPhase) -> Void)
        async -> SpeechModelInstallRefusal? {
        let installed = speechModelCacheExists(for: .multilingualV3)
        if let refusal = speechModelInstallRefusal(installed: installed,
                                                   running: isRunning,
                                                   dictating: dictating) {
            if refusal == .alreadyInstalled { progress(.finished) }
            return refusal
        }
        isRunning = true
        DownloadUtils.enforceOffline = false
        defer {
            DownloadUtils.enforceOffline = true
            isRunning = false
        }
        do {
            _ = try await AsrModels.download(version: .v3) { snapshot in
                Task { @MainActor in
                    switch snapshot.phase {
                    case .compiling: progress(.compiling)
                    default: progress(.downloading(snapshot.fractionCompleted))
                    }
                }
            }
            progress(.finished)
            return nil
        } catch {
            progress(.failed(error.localizedDescription))
            return nil
        }
    }
}
