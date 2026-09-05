// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Распознавание: TranscriptionWorker над FluidAudio (Parakeet TDT v3, CoreML/ANE).
// ОФЛАЙН-ХАРДЕНИНГ (отличия от донора):
//  1. Модель грузится ТОЛЬКО через AsrModels.loadFromCache() — никогда через download.
//  2. Путь донора с AsrModels.download(force: true) при провале проверки целостности
//     заменён на жёсткий отказ с понятным сообщением — сетевой путь физически
//     недостижим. Дополнительно DictationController первой строкой выставляет
//     DownloadUtils.enforceOffline = true (рубильник на уровне библиотеки).
import CryptoKit
import Darwin
import FluidAudio
import Foundation

// MARK: - Язык диктовки → Language FluidAudio

/// Публичный: тот же выбор языка нужен подкоманде расшифровки файлов
/// (`smltlk transcribe --language ru`), а второй такой список был бы враньём
/// про поддерживаемые языки при первом же расхождении.
public enum DictationLanguage: String, CaseIterable, Sendable {
    case auto
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case romanian = "ro"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case bosnian = "bs"
    case russian = "ru"
    case ukrainian = "uk"
    case belarusian = "be"
    case bulgarian = "bg"
    case serbian = "sr"

    /// Map to FluidAudio's `Language` enum. Returns nil for `.auto` so the
    /// caller passes no hint and the decoder script filter stays off.
    var fluidLanguage: Language? {
        switch self {
        case .auto:        return nil
        case .english:     return .english
        case .spanish:     return .spanish
        case .french:      return .french
        case .german:      return .german
        case .italian:     return .italian
        case .portuguese:  return .portuguese
        case .romanian:    return .romanian
        case .polish:      return .polish
        case .czech:       return .czech
        case .slovak:      return .slovak
        case .slovenian:   return .slovenian
        case .croatian:    return .croatian
        case .bosnian:     return .bosnian
        case .russian:     return .russian
        case .ukrainian:   return .ukrainian
        case .belarusian:  return .belarusian
        case .bulgarian:   return .bulgarian
        case .serbian:     return .serbian
        }
    }
}

// MARK: - Профиль модели (у донора два, нам нужен один)

public enum SpeechModelProfile: String, CaseIterable, Sendable {
    case multilingualV3 = "multilingual_v3"
    /// Кандидат волны 2. Берет латиницу внутри русской фразы (19,05 процента
    /// против 44,05 у Parakeet на смешанной речи), но в 11-15 раз медленнее -
    /// разбор в `bench/BENCH-CANDIDATES-2026-09-03.md`. Оба живут в одном
    /// бинарнике, выбор за владельцем.
    case whisperLargeV3 = "whisper_large_v3"
    /// Тот же словарь и тот же рычаг, вдвое меньше вес. Канон 25.07.2026 советовал
    /// turbo НЕ брать, но канон уже подтвержденно устарел в двух других местах, а
    /// решает здесь замер, а не совет.
    case whisperTurbo = "whisper_large_v3_turbo"

    public var shortName: String {
        switch self {
        case .multilingualV3: return "Parakeet TDT v3"
        case .whisperLargeV3: return "Whisper large-v3"
        case .whisperTurbo: return "Whisper large-v3 turbo"
        }
    }

    /// Движок продукта по умолчанию. ОДНО место на всё: настройки берут его как
    /// значение по умолчанию, CLI - как значение флага. Иначе приложение и CLI
    /// расходятся, и владелец видит разное качество на одной записи.
    /// ПРЕДПОЧТИТЕЛЬНЫЙ движок. Выбран не по скорости: замер показал, что именно
    /// он берёт термины владельца, а Parakeet их теряет.
    ///
    /// Но предпочтение - это не то же самое, что «взять и запустить». Образ
    /// (`scripts/make_release.sh`) кладёт только parakeet-tdt-0.6b-v3, и свежая
    /// установка искала на диске файл whisper, которого там нет: приложение не
    /// диктовало ВООБЩЕ, молча, без единого сообщения. Найдено разбором путей
    /// пользователей 04.09.2026.
    ///
    /// Поэтому рядом стоит `installedDefault`: он и решает, с чем работать.
    public static let productDefault: SpeechModelProfile = .whisperTurbo

    /// Заводской движок ДЛЯ ЭТОЙ МАШИНЫ: предпочтительный, если его модель на
    /// диске, иначе лучший из установленных.
    ///
    /// Константа тут не годится ни в одну сторону. Поставить whisper - свежая
    /// установка молчит. Поставить Parakeet - владелец, скачавший whisper ради
    /// терминов, получает худшее качество, не заметив подмены. Решает диск.
    ///
    /// `probe` подменяется в тестах: живой диск в тесте - это не проверка, а
    /// гадание по чужой машине.
    public static func installedDefault(
        probe: (SpeechModelProfile) -> Bool = speechModelCacheExists
    ) -> SpeechModelProfile {
        if probe(productDefault) { return productDefault }
        // Порядок падения назван явно: сперва то, что кладётся в образ.
        for fallback in [SpeechModelProfile.multilingualV3, .whisperLargeV3, .whisperTurbo]
        where probe(fallback) {
            return fallback
        }
        // На диске нет ничего. Возвращаем то, что едет в образе: приложение
        // покажет «модель не установлена» про НЕЁ, и человек пойдёт ставить то,
        // что у него и так есть в DMG.
        return .multilingualV3
    }

    /// Есть ли у движка подсказка декодеру. У Parakeet рычага нет, у обоих
    /// whisper он один и тот же: `whisper_full_params.initial_prompt`.
    public var supportsInitialPrompt: Bool { whisperModelFile != nil }

    /// Файл модели на диске. У Parakeet модель - каталог, поэтому nil.
    var whisperModelFile: String? {
        switch self {
        case .multilingualV3: return nil
        case .whisperLargeV3: return "ggml-large-v3.bin"
        case .whisperTurbo: return "ggml-large-v3-turbo.bin"
        }
    }

    var productionProfile: SpeechModelProfile { self }
}

// MARK: - Защита от подмены реестра загрузки
//
// FluidAudio читает REGISTRY_URL / MODEL_REGISTRY_URL и подменяет хост
// загрузки модели. С enforceOffline = true сеть всё равно запрещена, но
// присутствие этих переменных — признак подстроенного окружения: логируем.

let HOSTILE_REGISTRY_ENV_VARS = ["REGISTRY_URL", "MODEL_REGISTRY_URL"]

func detectedHostileRegistryEnvVars(in env: [String: String]) -> [String] {
    HOSTILE_REGISTRY_ENV_VARS.filter { env[$0] != nil }.sorted()
}

// MARK: - Пути кэша модели

func speechModelCacheDirectory(for profile: SpeechModelProfile) -> URL {
    switch profile {
    case .multilingualV3: return AsrModels.defaultCacheDirectory(for: .v3)
    case .whisperLargeV3, .whisperTurbo: return whisperModelCacheDirectory()
    }
}

public func speechModelCacheExists(for profile: SpeechModelProfile) -> Bool {
    switch profile {
    case .multilingualV3:
        return FileManager.default.fileExists(atPath: speechModelCacheDirectory(for: profile).path)
    case .whisperLargeV3, .whisperTurbo:
        // У whisper модель - ОДИН файл, и каталог без него бесполезен: проверяем файл.
        guard let file = profile.whisperModelFile else { return false }
        return FileManager.default.fileExists(atPath: whisperModelURL(file).path)
    }
}

// MARK: - Целостность модели (SHA-256 манифест пиннутой ревизии)

struct ModelFileDigest: Equatable {
    let relativePath: String
    let sha256: String
}

enum ModelIntegrityError: LocalizedError {
    case invalidManifestPath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case invalidFileType(String)
    case digestMismatch(path: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidManifestPath(let path):
            return "Speech model integrity manifest contains an unsafe path: \(path)"
        case .missingFile(let path):
            return "Speech model integrity check failed: missing file \(path)"
        case .unexpectedFile(let path):
            return "Speech model integrity check failed: unexpected file \(path)"
        case .invalidFileType(let path):
            return "Speech model integrity check failed: \(path) is not a regular file or directory"
        case .digestMismatch(let path, let expected, let actual):
            return "Speech model integrity check failed for \(path): expected \(expected), got \(actual)"
        }
    }
}

public enum ModelIntegrity {
    static let parakeetV3Repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let parakeetV3RepositoryCommit = "aed02740059203c4a87495924f685de3722ae9ce"
    private static let sha256Characters = Set("0123456789abcdefABCDEF")

    private static let parakeetV3StrictDirectories = [
        "Decoder.mlmodelc",
        "Encoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "Preprocessor.mlmodelc",
    ]

    private static let parakeetV3Files = [
        // BEGIN GENERATED PARAKEET_V3_MODEL_MANIFEST
        ModelFileDigest(relativePath: "Decoder.mlmodelc/analytics/coremldata.bin", sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/coremldata.bin", sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/metadata.json", sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/model.mil", sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/weights/weight.bin", sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/analytics/coremldata.bin", sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/coremldata.bin", sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/metadata.json", sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/model.mil", sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/weights/weight.bin", sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/coremldata.bin", sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/metadata.json", sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/model.mil", sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/weights/weight.bin", sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/analytics/coremldata.bin", sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/coremldata.bin", sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/metadata.json", sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/model.mil", sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/weights/weight.bin", sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        ModelFileDigest(relativePath: "parakeet_vocab.json", sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        // END GENERATED PARAKEET_V3_MODEL_MANIFEST
    ]

    public static func verifyParakeetV3Model(at directory: URL) throws {
        try verifyFiles(root: directory,
                        expectedFiles: parakeetV3Files,
                        strictDirectories: parakeetV3StrictDirectories)
        log("ASR: verified \(parakeetV3Files.count) model files from \(parakeetV3Repository) @ \(parakeetV3RepositoryCommit)")
    }

    static func verifyFiles(root: URL,
                            expectedFiles: [ModelFileDigest],
                            strictDirectories: [String]) throws {
        var expectedByPath: [String: String] = [:]
        var expectedDirectoryPaths = Set<String>()
        for directory in strictDirectories {
            try validateRelativePath(directory)
            expectedDirectoryPaths.insert(directory)
        }

        for file in expectedFiles {
            try validateRelativePath(file.relativePath)
            try validateSHA256(file.sha256, relativePath: file.relativePath)
            if expectedByPath.updateValue(file.sha256.lowercased(),
                                          forKey: file.relativePath) != nil {
                throw ModelIntegrityError.invalidManifestPath("duplicate file path: \(file.relativePath)")
            }
            expectedDirectoryPaths.formUnion(parentDirectories(of: file.relativePath))
        }
        var seenPaths: Set<String> = []

        for file in expectedFiles {
            let fileURL = root.appendingPathComponent(file.relativePath, isDirectory: false)
            try requireRegularFile(fileURL, relativePath: file.relativePath)

            let actual = try sha256Hex(of: fileURL, relativePath: file.relativePath)
            let expected = file.sha256.lowercased()
            guard actual == expected else {
                throw ModelIntegrityError.digestMismatch(path: file.relativePath,
                                                         expected: expected,
                                                         actual: actual)
            }
            seenPaths.insert(file.relativePath)
        }

        guard seenPaths.count == expectedFiles.count else {
            throw ModelIntegrityError.invalidManifestPath("duplicate file path")
        }

        for directory in strictDirectories {
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            try requireDirectory(directoryURL, relativePath: directory)
            guard let enumerator = FileManager.default.enumerator(at: directoryURL,
                                                                  includingPropertiesForKeys: nil)
            else { continue }

            for case let itemURL as URL in enumerator {
                let relativePath = relativePath(of: itemURL, under: root)
                switch try fileSystemNodeType(itemURL, relativePath: relativePath) {
                case .directory:
                    guard expectedDirectoryPaths.contains(relativePath) else {
                        throw ModelIntegrityError.unexpectedFile(relativePath)
                    }
                case .regularFile:
                    guard expectedByPath[relativePath] != nil else {
                        throw ModelIntegrityError.unexpectedFile(relativePath)
                    }
                }
            }
        }
    }

    static func sha256Hex(of url: URL, relativePath: String) throws -> String {
        let handle = try openRegularFileForHashing(url, relativePath: relativePath)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func openRegularFileForHashing(_ url: URL,
                                                  relativePath: String) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { throw ModelIntegrityError.missingFile(relativePath) }
            throw ModelIntegrityError.invalidFileType(relativePath)
        }

        do {
            var st = stat()
            guard Darwin.fstat(fd, &st) == 0 else {
                throw ModelIntegrityError.invalidFileType(relativePath)
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw ModelIntegrityError.invalidFileType(relativePath)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private enum FileSystemNodeType {
        case regularFile
        case directory
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ModelIntegrityError.invalidManifestPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."),
              !components.contains("."),
              !components.contains("") else {
            throw ModelIntegrityError.invalidManifestPath(path)
        }
    }

    private static func validateSHA256(_ digest: String, relativePath: String) throws {
        guard digest.count == 64,
              digest.allSatisfy({ sha256Characters.contains($0) }) else {
            throw ModelIntegrityError.invalidManifestPath("invalid SHA-256 digest for \(relativePath)")
        }
    }

    private static func parentDirectories(of path: String) -> Set<String> {
        var result = Set<String>()
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = String(current[..<slash])
            result.insert(current)
        }
        return result
    }

    private static func requireRegularFile(_ url: URL, relativePath: String) throws {
        guard try fileSystemNodeType(url, relativePath: relativePath) == .regularFile else {
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func requireDirectory(_ url: URL, relativePath: String) throws {
        guard try fileSystemNodeType(url, relativePath: relativePath) == .directory else {
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func fileSystemNodeType(_ url: URL,
                                           relativePath: String) throws -> FileSystemNodeType {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { throw ModelIntegrityError.missingFile(relativePath) }
            throw ModelIntegrityError.invalidFileType(relativePath)
        }

        switch st.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFDIR:
            return .directory
        default:
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}

// MARK: - Метрики транскрипции

struct ASRTimingBreakdown: Codable, Equatable, Sendable {
    let totalSeconds: Double
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double

    init(totalSeconds: Double,
         workerQueueSeconds: Double,
         decoderPreparationSeconds: Double,
         fluidCallSeconds: Double,
         fluidProcessingSeconds: Double) {
        self.totalSeconds = max(0, totalSeconds.isFinite ? totalSeconds : 0)
        self.workerQueueSeconds = max(0, workerQueueSeconds.isFinite ? workerQueueSeconds : 0)
        self.decoderPreparationSeconds = max(0, decoderPreparationSeconds.isFinite ? decoderPreparationSeconds : 0)
        self.fluidCallSeconds = max(0, fluidCallSeconds.isFinite ? fluidCallSeconds : 0)
        self.fluidProcessingSeconds = max(0, fluidProcessingSeconds.isFinite ? fluidProcessingSeconds : 0)
    }

    var frameworkOverheadSeconds: Double {
        max(0, totalSeconds - workerQueueSeconds - decoderPreparationSeconds - fluidProcessingSeconds)
    }
}

// MARK: - Тайминги токенов из результата FluidAudio

/// Перевод в свой тип — единственное место, где мы касаемся `TokenTiming`
/// библиотеки. Санитайзер живёт в `DictationTokenTiming.init`, поэтому
/// нефинитные значения из декодера не доедут до диска.
func dictationTokenTimings(from timings: [TokenTiming]?) -> [DictationTokenTiming] {
    (timings ?? []).map {
        DictationTokenTiming(token: $0.token,
                             start: $0.startTime,
                             end: $0.endTime,
                             confidence: Double($0.confidence))
    }
}

// MARK: - Воркер транскрипции

private enum LoadedSpeechEngine {
    case parakeetV3(AsrManager)
    case whisper(WhisperEngine)
}

struct TranscriptionWorkerResult: Sendable {
    let text: String
    /// Тайминги токенов ровно так, как их отдал распознаватель. Раньше это
    /// поле результата FluidAudio выбрасывалось прямо здесь — и условие
    /// возврата к «абзацам по паузам» (FEATURES.md §3) нельзя было проверить
    /// в принципе. Разрез абзацев по-прежнему не делается: данные просто
    /// доезжают до диска.
    let tokenTimings: [DictationTokenTiming]
    /// Длительность клипа по данным распознавателя, секунды.
    let audioSeconds: Double
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double

    func timing(totalSeconds: Double) -> ASRTimingBreakdown {
        ASRTimingBreakdown(
            totalSeconds: totalSeconds,
            workerQueueSeconds: workerQueueSeconds,
            decoderPreparationSeconds: decoderPreparationSeconds,
            fluidCallSeconds: fluidCallSeconds,
            fluidProcessingSeconds: fluidProcessingSeconds
        )
    }
}

/// actor НЕ защищает от реентранси через точки await (комментарий донора):
/// настоящий барьер — флаг isBusy в DictationController + inFlight здесь.
actor TranscriptionWorker {
    private var engine: LoadedSpeechEngine?
    private var loadedProfile: SpeechModelProfile?
    private(set) var ready = false
    /// Reentrancy backstop — see the comment above. True for the full
    /// duration of transcribe(), including across its await.
    private var inFlight = false

    /// Загрузка модели ИСКЛЮЧИТЕЛЬНО из локального кэша. Сети нет:
    /// enforceOffline выставлен контроллером, а download здесь не вызывается
    /// ни на одной ветке.
    func load(profile requestedProfile: SpeechModelProfile) async throws {
        let profile = requestedProfile.productionProfile
        if ready, engine != nil, loadedProfile == profile {
            log("ASR: \(profile.shortName) already ready")
            return
        }

        if engine != nil {
            await unload()
        }

        log("ASR: verifying + loading cached \(profile.shortName) CoreML weights…")
        let t0 = Date()
        switch profile {
        case .multilingualV3: engine = .parakeetV3(try await loadParakeetV3())
        case .whisperLargeV3, .whisperTurbo:
            engine = .whisper(try WhisperEngine(modelURL: whisperModelURL(profile.whisperModelFile ?? "")))
        }
        loadedProfile = profile
        ready = true
        log("ASR: \(profile.shortName) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    }

    private func loadParakeetV3() async throws -> AsrManager {
        let modelDirectory = speechModelCacheDirectory(for: .multilingualV3)
        guard speechModelCacheExists(for: .multilingualV3) else {
            throw NSError(
                domain: "smltlk.Dictation",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: """
                    Модель распознавания речи не найдена на диске \
                    (\(modelDirectory.path)). Скачайте её из знакомства: \
                    значок в строке меню, «Знакомство», шаг «Скачаем распознавание».
                    """]
            )
        }
        do {
            try ModelIntegrity.verifyParakeetV3Model(at: modelDirectory)
        } catch {
            // Жёсткий отказ вместо force-перекачки донора: сетевой путь
            // физически недостижим.
            throw NSError(
                domain: "smltlk.Dictation",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: """
                    Модель распознавания повреждена (\(error.localizedDescription)). \
                    Скачайте её заново: значок в строке меню, «Знакомство», \
                    шаг «Скачаем распознавание».
                    """]
            )
        }
        let models = try await AsrModels.loadFromCache(version: .v3)
        return AsrManager(config: .default, models: models)
    }

    /// Язык принимается ВЫБОРОМ ВЛАДЕЛЬЦА, а не типом библиотеки: у двух движков
    /// разные представления языка, и перевод делается здесь, чтобы вызывающий не
    /// знал, какой движок стоит.
    /// Подсказка декодеру. Действует только у whisper: у Parakeet рычага нет,
    /// и вызывающий обязан не давать ее ему - CLI отказывает на этом явно.
    func setInitialPrompt(_ prompt: String?) {
        guard case .whisper(let whisper) = engine else { return }
        whisper.initialPrompt = prompt
    }

    func transcribe(samples: [Float],
                    language: DictationLanguage = .auto,
                    requestedAt: TimeInterval) async throws -> TranscriptionWorkerResult {
        let workerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard let engine else {
            throw NSError(domain: "smltlk.Dictation", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Модель распознавания ещё не загружена."])
        }
        guard !inFlight else {
            log("ASR: transcribe re-entered while another transcription is in flight — refusing (DictationController.isBusy should make this impossible)")
            assertionFailure("TranscriptionWorker.transcribe re-entered across a suspension point")
            throw NSError(domain: "smltlk.Dictation", code: -3)
        }
        inFlight = true
        defer { inFlight = false }
        switch engine {
        case .parakeetV3(let asr):
            let decoderPreparationStartedAt = ProcessInfo.processInfo.systemUptime
            var state = try TdtDecoderState()
            let fluidCallStartedAt = ProcessInfo.processInfo.systemUptime
            let result = try await asr.transcribe(samples, decoderState: &state, language: language.fluidLanguage)
            let fluidCallCompletedAt = ProcessInfo.processInfo.systemUptime
            return TranscriptionWorkerResult(
                text: result.text,
                tokenTimings: dictationTokenTimings(from: result.tokenTimings),
                // Считаем сами, а не берём `result.duration`: на клипе длиннее
                // одного окна модели FluidAudio возвращает там 0 (замерено
                // живьём на 23 секундах). Отсчёты у нас на руках — врать
                // в артефакте не из чего.
                audioSeconds: Double(samples.count) / SAMPLE_RATE,
                workerQueueSeconds: workerEnteredAt - requestedAt,
                decoderPreparationSeconds: fluidCallStartedAt - decoderPreparationStartedAt,
                fluidCallSeconds: fluidCallCompletedAt - fluidCallStartedAt,
                fluidProcessingSeconds: result.processingTime
            )
        case .whisper(let whisper):
            let callStartedAt = ProcessInfo.processInfo.systemUptime
            let text = try whisper.transcribe(samples: samples, language: language)
            let callSeconds = ProcessInfo.processInfo.systemUptime - callStartedAt
            return TranscriptionWorkerResult(
                text: text,
                // whisper.cpp отдает время по СЕГМЕНТАМ, а не по токенам. Выдумывать
                // потокенную разметку из сегментной нельзя - лента рисует по ней.
                tokenTimings: [],
                audioSeconds: Double(samples.count) / SAMPLE_RATE,
                workerQueueSeconds: workerEnteredAt - requestedAt,
                // Отдельной стадии подготовки декодера у whisper нет: ноль здесь -
                // факт, а не пропуск замера. Слоты `fluid*` несут вызов движка.
                decoderPreparationSeconds: 0,
                fluidCallSeconds: callSeconds,
                fluidProcessingSeconds: callSeconds
            )
        }
    }

    /// Поток прогресса библиотеки (доля обработанного звука 0…1). Нужен
    /// расшифровке файлов: на записи длиной в заседание это единственный
    /// честный ответ на «сколько ещё ждать». Живая диктовка им не пользуется —
    /// там клип короче 15 с и прогресс библиотека не шлёт.
    func progressStream() async -> AsyncThrowingStream<Double, Error>? {
        guard let engine else { return nil }
        switch engine {
        case .parakeetV3(let asr):
            return await asr.transcriptionProgressStream
        // У whisper.cpp обратного вызова прогресса в нашей обертке нет. nil -
        // честный ответ «мерить нечем»; выдуманная полоска была бы хуже.
        case .whisper: return nil
        }
    }

    func unload() async {
        engine = nil
        loadedProfile = nil
        ready = false
        log("ASR: unloaded")
    }
}
