// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Лог в stderr + ~/Library/Logs/iriz-dictate.log (0600), приватная запись файлов.
import Foundation
import IrizCore

// MARK: - Logger
//
// All output goes to stderr (line-buffered, so we don't lose lines
// across an abrupt exit) and to ~/Library/Logs/iriz-dictate.log.

final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private let url: URL
    private let q = DispatchQueue(label: "IrizDictateLogger")

    var fileURL: URL { url }

    /// Куда писать вместо журнала владельца. Нужен потому, что тесты, поднимающие
    /// настоящий `DictationController` или `AudioCapture`, зовут живой `log()` —
    /// и дописывают строки в `~/Library/Logs/iriz-dictate.log`, где лежит
    /// диагностика живой работы владельца. Замерено: один полный `swift test` добавил туда
    /// четыре строки от сюиты про зависшее распознавание.
    ///
    /// Запрет «тесты не пишут в журнал владельца» и требование «прогони весь
    /// `swift test`» иначе исключают друг друга.
    static let redirectEnvironmentKey = "SMLTLK_LOG_FILE"

    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env[Self.redirectEnvironmentKey], !override.isEmpty {
            url = URL(fileURLWithPath: override)
            return
        }
        // В журнал владельца пишет ТОЛЬКО настоящий бандл приложения. Признак —
        // его идентификатор, и это единственная проверка, которая выдержала замер:
        //   · переменные XCTest под `swift test` не выставлены ни одна
        //     (проверено: XCTestConfigurationFilePath, XCTestBundlePath, SWIFT_TESTING);
        //   · путь исполняемого файла тоже не годится — хост-процесс тестов это
        //     раннер `xctest` из Xcode, и `/.build/` в его пути нет.
        // Разрешительный признак вместо запретительного: незнакомый способ запуска
        // получает временный файл, а не журнал владельца. Ошибаться надо в эту сторону.
        let isProductBundle = Bundle.main.bundleIdentifier == IRIZ_BUNDLE_IDENTIFIER
        guard isProductBundle else {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("iriz-dictate-nonproduct.log")
            return
        }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        url = logs.appendingPathComponent("iriz-dictate.log")
    }

    func log(_ msg: String) {
        let stamp = ISO8601DateFormatter.timeOnly.string(from: Date())
        let line = "[\(stamp)] \(msg)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        q.async { [url] in
            do {
                try appendPrivateLogData(data, to: url)
            } catch {
                let fallback = "Logger: file write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(fallback.utf8))
            }
        }
    }
}

func log(_ msg: String) { Logger.shared.log(msg) }

func irizApplicationSupportDirectory() throws -> URL {
    try IrizCore.irizApplicationSupportDirectory()
}

func appendPrivateLogData(_ data: Data, to url: URL) throws {
    try IrizCore.appendPrivateLogData(data, to: url)
}

extension ISO8601DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
