// Установка модели распознавания по сети - один раз, руками человека.
//
// Модель больше не едет в образе. Владелец сказал прямо: класть в публичный
// выпуск слепок модели глупо, завтра выйдет свежее, а образ на полгигабайта
// весит как весь остальной продукт вместе взятый. Поэтому образ везёт
// приложение, а модель приезжает после установки - с показанным ходом и
// понятной ценой.
//
// Явная установка получает закреплённые файлы через URLSession. Рубильник
// офлайна распознавателя не меняется даже на время скачивания. Новая копия
// проверяется отдельно; существующий кэш сохраняется при любом отказе.
import Foundation
import IrizCore

public let speechModelDidInstallNotification = Notification.Name("iriz.speechModelDidInstall")
// Сумма 21 файла закреплённого commit: официальный HF tree API, 12.09.2026.
public let speechModelDownloadBytes: Int64 = 483_105_645

/// Что происходит с установкой прямо сейчас.
public enum SpeechModelInstallPhase: Equatable, Sendable {
    /// Идёт скачивание, 0…1.
    case downloading(Double)
    /// Файлы получены, проверяется их целостность перед использованием.
    case compiling
    case finished
    case failed(String)
}

public enum SpeechModelInstallRefusal: String, Equatable, Sendable {
    /// Уже стоит - качать нечего.
    case alreadyInstalled
    /// Установка уже идёт.
    case alreadyRunning
    /// Идёт диктовка: установку не начинаем посреди активного сценария.
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
    case .downloading: return L("speechModel.downloading", "Качаю модель распознавания")
    case .compiling: return L("speechModel.verifying", "Проверяю скачанную модель")
    case .finished: return L("speechModel.ready", "Модель на месте")
    case .failed: return L("speechModel.failed", "Скачать не вышло")
    }
}

public func speechModelInstallFraction(_ phase: SpeechModelInstallPhase) -> Double {
    switch phase {
    case .downloading(let value): return min(1, max(0, value))
    // Все байты получены; проверка не откатывает полосу скачивания назад.
    case .compiling: return 1
    case .finished: return 1
    case .failed: return 0
    }
}

public func speechModelInstallFailureMessage(for error: Error) -> String {
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
        return L("speechModel.error.cancelled", "Скачивание отменено. Его можно запустить снова.")
    }
    switch (error as? URLError)?.code {
    case .notConnectedToInternet:
        return L("speechModel.error.offline", "Нет подключения к интернету. Подключись к сети и повтори скачивание.")
    case .networkConnectionLost:
        return L("speechModel.error.connectionLost", "Соединение прервалось. Проверь интернет и повтори скачивание.")
    case .timedOut:
        return L("speechModel.error.timeout", "Сервер не ответил вовремя. Повтори скачивание чуть позже.")
    default:
        return error.localizedDescription
    }
}

@MainActor
public final class SpeechModelInstaller {
    public static let shared = SpeechModelInstaller()

    private(set) public var isRunning = false
    private var downloadingFile: UUID?

    private init() {}

    /// Поставить модель. `dictating` приходит снаружи: установщик не обязан
    /// знать устройство конвейера, а конвейер - устройство установщика.
    @discardableResult
    public func install(dictating: Bool,
                        progress: @escaping @MainActor (SpeechModelInstallPhase) -> Void)
        async -> SpeechModelInstallRefusal? {
        if let refusal = speechModelInstallRefusal(installed: false,
                                                   running: isRunning,
                                                   dictating: dictating) {
            return refusal
        }
        isRunning = true
        defer {
            isRunning = false
            downloadingFile = nil
        }
        let directory = speechModelCacheDirectory(for: .multilingualV3)
        do {
            let verified = await Task.detached(priority: .userInitiated) {
                (try? ModelIntegrity.verifyParakeetV3Model(at: directory)) != nil
            }.value
            try Task.checkCancellation()
            if verified {
                progress(.finished)
                return .alreadyInstalled
            }

            let manager = FileManager.default
            let staging = directory.deletingLastPathComponent()
                .appendingPathComponent(".iriz-model-download-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            let files = ModelIntegrity.parakeetV3DownloadFiles
            var receivedBytes: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                let completedBytes = receivedBytes
                let token = UUID()
                downloadingFile = token
                progress(.downloading(Double(completedBytes) / Double(speechModelDownloadBytes)))
                let delegate = SpeechModelDownloadProgress { [weak self] currentBytes in
                    Task { @MainActor in
                        guard self?.downloadingFile == token else { return }
                        progress(.downloading(min(1, Double(completedBytes + currentBytes) / Double(speechModelDownloadBytes))))
                    }
                }
                let (temporary, response) = try await URLSession.shared.download(
                    from: speechModelDownloadURL(for: file), delegate: delegate)
                downloadingFile = nil
                defer { try? manager.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let target = staging.appendingPathComponent(file.relativePath)
                try manager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                try manager.moveItem(at: temporary, to: target)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                receivedBytes += Int64(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            progress(.compiling)
            try await Task.detached(priority: .userInitiated) {
                try ModelIntegrity.verifyParakeetV3Model(at: staging)
            }.value
            try Task.checkCancellation()
            try publishSpeechModelCache(from: staging, to: directory)
            progress(.finished)
            return nil
        } catch {
            progress(.failed(speechModelInstallFailureMessage(for: error)))
            return nil
        }
    }
}

private final class SpeechModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let received: @Sendable (Int64) -> Void

    init(received: @escaping @Sendable (Int64) -> Void) { self.received = received }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        received(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

/// Источник зафиксирован тем же commit, что и SHA-256 в загрузчике; ни main,
/// ни переменные окружения с подменённым реестром сюда не попадают.
func speechModelDownloadURL(for file: ModelFileDigest) throws -> URL {
    guard ModelIntegrity.parakeetV3DownloadFiles.contains(file),
          let url = URL(string: "https://huggingface.co/\(ModelIntegrity.parakeetV3Repository)/resolve/\(ModelIntegrity.parakeetV3RepositoryCommit)/\(file.relativePath)"),
          url.scheme == "https", url.host == "huggingface.co" else {
        throw URLError(.badURL)
    }
    return url
}

/// Замена только после проверки новой копии. Предыдущая остаётся рядом;
/// если публикация не удалась, возвращаем её на прежнее место.
func publishSpeechModelCache(from staging: URL, to directory: URL) throws {
    let manager = FileManager.default
    var backup: URL?
    if manager.fileExists(atPath: directory.path) {
        let saved = directory.deletingLastPathComponent()
            .appendingPathComponent(".iriz-model-backup-" + UUID().uuidString, isDirectory: true)
        try manager.moveItem(at: directory, to: saved)
        backup = saved
    }
    do {
        try manager.moveItem(at: staging, to: directory)
    } catch {
        if let backup { try manager.moveItem(at: backup, to: directory) }
        throw error
    }
}
