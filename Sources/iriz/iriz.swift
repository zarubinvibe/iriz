// iriz — CLI-стенд конвертации раскладки (этап 6).
// Контракт: stdin → stdout, без интерактива, без цветов, без логов, без записи на диск.
// Коды возврата: 0 — обработано (независимо от того, изменился ли текст),
// 1 — вход пуст, 2 — ошибка чтения/выполнения.
import ArgumentParser
import FluidAudio
import Foundation
import IrizCore
import IrizDictate
import IrizInput
import IrizPrompt

@main
struct Iriz: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iriz",
        abstract: "Convert text between EN/RU keyboard layouts (stdin → stdout).",
        subcommands: [Convert.self, Fix.self, HUDPresence.self, HUDSize.self, InstallModel.self, Prompt.self, VerifyModel.self, Transcribe.self, Verify.self]
    )
}

struct Prompt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Собрать конверт «речь → промпт».")

    @Option(name: .long, help: "Папка надиктовки.")
    var dir: String?

    mutating func run() async throws {
        let builder = PromptEnvelopeBuilder()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory: URL
        if let dir { directory = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true) }
        else {
            directory = try builder.latestDictation(in: home.appendingPathComponent("Library/Application Support/smltlk/dictations", isDirectory: true))
        }
        let termsURL = home.appendingPathComponent("Library/Application Support/smltlk/terms.json")
        do { writeStdout(try builder.build(for: directory, termsURL: termsURL)) }
        catch { throw ExitCode(2) }
    }
}

/// Размеры плашки в физических пикселях - для ворот натуральной величины.
///
/// Ворота прежде ГРЕПАЛИ строку с константой в исходнике и считали произведение
/// сами. Это вторая копия арифметики: константу переименовали - ворота ослепли и
/// доложили отказ вместо того, чтобы судить кадры. Теперь числа приходят из той
/// самой функции, по которой живёт приложение.
struct HUDSize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hud-size",
        abstract: "Размеры плашки в пикселях, по одному варианту на строку."
    )

    mutating func run() async throws {
        for choice in DictationHUDSizeChoice.allCases {
            let pixels = dictationHUDVerdictPixelSize(choice)
            writeStdout("\(choice.rawValue) \(Int(pixels.width)) \(Int(pixels.height))\n")
        }
    }
}

/// Приговор автомата плашки: видна она или нет при таком состоянии конвейера.
///
/// Для ворот «плашка всегда на экране». Ровно тем же приёмом, что `hud-size`:
/// источник правды - та самая функция, по которой живёт приложение, а не
/// греп по исходнику. Греп ослеп бы на первом же переименовании, а тут ворота
/// читают приговор.
struct HUDPresence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hud-presence",
        abstract: "Видна ли плашка при каждом состоянии конвейера, по строке на пару."
    )

    mutating func run() async throws {
        for line in dictationHUDPresenceReport() { writeStdout(line + "\n") }
    }
}

/// Скачать модель распознавания. Тот же путь, которым это делает знакомство,
/// вынесенный в командную строку: проверить установку на чистом каталоге можно
/// только запуском, а не чтением кода.
struct InstallModel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-model",
        abstract: "Скачать модель распознавания в кэш (или в указанный каталог)."
    )

    @Option(name: .customLong("to"), help: "Куда положить модель.")
    var directory: String?

    mutating func run() async throws {
        let target = directory.map { URL(fileURLWithPath: $0) }
        DownloadUtils.enforceOffline = false
        let url = try await AsrModels.download(to: target, version: .v3) { snapshot in
            writeStdout("\(Int(snapshot.fractionCompleted * 100))%\n")
        }
        DownloadUtils.enforceOffline = true
        writeStdout("модель: \(url.path)\n")
    }
}

/// Проверить каталог модели тем же кодом, которым его проверяет приложение
/// перед каждой загрузкой. Нужно ровно потому, что «скачалось» и «примет
/// приложение» - разные события, и второе проверяется только запуском.
struct VerifyModel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-model",
        abstract: "Проверить каталог модели по манифесту приложения."
    )

    @Option(name: .customLong("at"), help: "Каталог модели.")
    var directory: String

    mutating func run() async throws {
        try ModelIntegrity.verifyParakeetV3Model(at: URL(fileURLWithPath: directory))
        writeStdout("модель принята\n")
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Проверить raw.txt и prompt.md по 14 пунктам.")

    @Argument(help: "Папка с raw.txt и prompt.md.")
    var directory: String

    mutating func run() async throws {
        let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        let rawURL = url.appendingPathComponent("raw.txt")
        let promptURL = url.appendingPathComponent("prompt.md")
        guard FileManager.default.isReadableFile(atPath: rawURL.path) else { throw ExitCode(2) }
        guard FileManager.default.isReadableFile(atPath: promptURL.path) else {
            let builder = PromptEnvelopeBuilder()
            let termsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/smltlk/terms.json")
            if let envelope = try? builder.build(for: url, termsURL: termsURL) { writeStdout(envelope + "\n") }
            throw ExitCode(2)
        }
        do {
            let report = try PromptVerifier().verify(directory: url)
            writeStdout(report.text)
            if report.hasBlockingFailure { throw ExitCode(1) }
        } catch let code as ExitCode { throw code }
        catch { throw ExitCode(2) }
    }
}

/// Механическая конвертация раскладки, без вопросов: направление — по содержимому
/// (есть кириллица → RU→EN, иначе EN→RU), карта — через Carbon.
struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert layout of the input text mechanically."
    )

    mutating func run() async throws {
        let input = try readStdin()
        guard !input.isEmpty else { throw ExitCode(1) }
        writeStdout(DynamicKeyMapping.convertAuto(input))
    }
}

/// Конвертирует слово только если словарь подтверждает, что в другой раскладке оно
/// осмысленнее (тот же LayoutDetector, что решает автопереключение в приложении).
/// Вход бьётся на слова по пробельным символам, разделители сохраняются как есть.
/// Назначение — стенд: прогон по текстам владельца для замера ложных срабатываний.
struct Fix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert only words the dictionary confirms were typed in the wrong layout."
    )

    // @MainActor: Dict (NSSpellChecker) и LayoutDetector.decide главно-акторные.
    @MainActor
    mutating func run() async throws {
        let input = try readStdin()
        guard !input.isEmpty else { throw ExitCode(1) }
        var result = ""
        var word = ""
        for ch in input {
            if ch.isWhitespace {
                result += fixWord(word)
                word = ""
                result.append(ch)
            } else {
                word.append(ch)
            }
        }
        result += fixWord(word)
        writeStdout(result)
    }

    /// Решение по одному токену: convert — как в боевом пути, decide — по скрипту токена.
    @MainActor
    private func fixWord(_ word: String) -> String {
        guard !word.isEmpty else { return word }
        let hasCyrillic = word.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        let converted = DynamicKeyMapping.convertAuto(word)
        guard converted != word else { return word }
        // Тот же never-convert список, что в боевом пути приложения (этап 7):
        // заводские ложные срабатывания («tls» → «еды») + слова пользователя.
        guard !AutoSwitchPolicy.isDeniedWord(word, converted) else { return word }
        let verdict = LayoutDetector.decide(
            typed: word,
            converted: converted,
            currentLang: hasCyrillic ? "ru" : "en",
            otherLang: hasCyrillic ? "en" : "ru",
            capsLock: false
        )
        return verdict == .switchToConverted ? converted : word
    }
}

private func readStdin() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        throw ExitCode(2)
    }
    return text
}

private func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}
