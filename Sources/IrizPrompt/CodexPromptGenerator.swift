import Darwin
import Foundation

public enum CodexPromptGeneratorError: Error, Sendable, Equatable {
    case invalidExecutable
    case invalidTimeout
    case temporaryDirectoryUnavailable
    case privateFilePreparationFailed
    case launchFailed
    case nonZeroExit(status: Int32, stderr: String)
    case terminated(signal: Int32, stderr: String)
    case timedOut
    case missingResult
    case resultTooLarge
    case invalidResultJSON
    case invalidPromptSpec
    case invalidPromptOutcome
    case renderingFailed
}

extension CodexPromptGeneratorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidExecutable:
            "CLI агента не найден или не исполняем."
        case .invalidTimeout:
            "Таймаут CLI агента должен быть положительным числом."
        case .temporaryDirectoryUnavailable:
            "Не удалось создать защищённый временный каталог."
        case .privateFilePreparationFailed:
            "Не удалось подготовить защищённые файлы агента."
        case .launchFailed:
            "CLI агента не запустился."
        case let .nonZeroExit(status, stderr):
            stderr.isEmpty
                ? "CLI агента завершился с кодом \(status)."
                : "CLI агента завершился с кодом \(status): \(stderr)"
        case let .terminated(signal, stderr):
            stderr.isEmpty
                ? "CLI агента завершён сигналом \(signal)."
                : "CLI агента завершён сигналом \(signal): \(stderr)"
        case .timedOut:
            "CLI агента не успел за отведённое время."
        case .missingResult:
            "CLI агента не вернул результат."
        case .resultTooLarge:
            "Результат CLI агента превышает допустимый размер."
        case .invalidResultJSON:
            "CLI агента вернул некорректный JSON."
        case .invalidPromptSpec:
            "CLI агента вернул PromptSpec, нарушающий контракт."
        case .invalidPromptOutcome:
            "Готовый промпт не прошёл проверку качества."
        case .renderingFailed:
            "Не удалось собрать детерминированный промпт."
        }
    }
}

struct CodexInvocationPlan: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL
    let standardInputURL: URL
    let schemaURL: URL
    let resultURL: URL
    let resultSource: PromptAgentResultSource
}

public struct CodexPromptGenerator: Sendable {
    private static let stderrLimit = 64 * 1024
    private static let resultLimit = 1024 * 1024
    private static let authLimit = 1024 * 1024
    private static let invalidPromptSpecRemediation = """


    Repair the JSON prompt specification. Every evidence value must be a non-empty verbatim substring of the СЫРЬЁ block. Cover every source negation and number with evidence. Use needsClarification if and only if an ambiguity is blocking. Keep passthrough free of expanded fields and modules. Do not duplicate modules or invent protected literals. Preserve all privacy constraints.
    """
    private static let invalidPromptOutcomeRemediation = """


    Repair the rendered prompt outcome by returning a corrected JSON prompt specification. Keep the final prompt concise and actionable. Preserve every explicit field and ambiguity. Discoverable context must not block execution; blocking user choices must remain questions. Obey the selected recipient profile. Return only PromptSpec JSON.
    """

    private let executableURL: URL
    private let adapter: PromptAgentAdapter
    private let model: String
    private let timeoutSeconds: TimeInterval
    private let environment: [String: String]

    public init(
        executableURL: URL,
        adapter: PromptAgentAdapter = PromptAgentCatalog.codex,
        model: String = "",
        timeoutSeconds: TimeInterval = 90
    ) {
        self.executableURL = executableURL
        self.adapter = adapter
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        environment = ProcessInfo.processInfo.environment
    }

    init(
        executableURL: URL,
        adapter: PromptAgentAdapter = PromptAgentCatalog.codex,
        model: String = "",
        timeoutSeconds: TimeInterval = 90,
        environment: [String: String]
    ) {
        self.executableURL = executableURL
        self.adapter = adapter
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
    }

    /// Спросить агента обычным текстом и получить обычный текст.
    ///
    /// Нужен переводу. Контракт промпта тут не годится: он требует схему,
    /// разметку и проверку по четырнадцати пунктам, а переводу нужен ровно
    /// один обмен - строка туда, строка обратно.
    ///
    /// Вся изоляция та же, что у промпта: временный дом, свой каталог, семена
    /// авторизации, таймаут. Разделять эти два пути значило бы завести вторую
    /// песочницу, а песочница - последнее место, где стоит держать копию.
    public func ask(_ body: String) async throws -> String {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw CodexPromptGeneratorError.invalidTimeout
        }
        let resolvedExecutableURL = executableURL.resolvingSymlinksInPath()
        guard resolvedExecutableURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: resolvedExecutableURL.path) else {
            throw CodexPromptGeneratorError.invalidExecutable
        }

        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let workDirectory = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let isolatedHome = temporaryDirectory.appendingPathComponent("home", isDirectory: true)
        let agentHome = adapter.homeSubdirectory.map {
            isolatedHome.appendingPathComponent($0, isDirectory: true)
        }
        let inputURL = temporaryDirectory.appendingPathComponent("input.txt")
        let promptFileURL = temporaryDirectory.appendingPathComponent("prompt.txt")
        let resultURL = temporaryDirectory.appendingPathComponent("result.json")
        let schemaURL = temporaryDirectory.appendingPathComponent("schema.json")

        do {
            try Self.createPrivateDirectory(at: workDirectory)
            try Self.createPrivateDirectory(at: isolatedHome)
            if let agentHome {
                try Self.createPrivateDirectories(at: agentHome, under: isolatedHome)
            }
            try Self.seedAuthentication(adapter: adapter, from: environment,
                                        isolatedAgentHome: agentHome)
            try Self.createPrivateFile(
                at: inputURL,
                data: adapter.promptDelivery == .stdin ? Data(body.utf8) : Data()
            )
            if adapter.promptDelivery == .file {
                try Self.createPrivateFile(at: promptFileURL, data: Data(body.utf8))
            }
            if adapter.resultSource == .file {
                try Self.createPrivateFile(at: resultURL, data: Data())
            }
        } catch let error as CodexPromptGeneratorError {
            throw error
        } catch {
            throw CodexPromptGeneratorError.privateFilePreparationFailed
        }

        let plan = Self.makePlan(
            adapter: adapter,
            model: model,
            executableURL: resolvedExecutableURL,
            workDirectoryURL: workDirectory,
            inputURL: inputURL,
            promptFileURL: promptFileURL,
            schemaURL: schemaURL,
            resultURL: resultURL,
            isolatedHomeURL: isolatedHome,
            agentHomeURL: agentHome,
            temporaryDirectoryURL: temporaryDirectory,
            prompt: body,
            environment: environment
        )
        let exit = try await run(plan)
        switch exit.reason {
        case .exit where exit.status == 0: break
        case .exit:
            throw CodexPromptGeneratorError.nonZeroExit(status: exit.status, stderr: exit.stderr)
        case .signal:
            throw CodexPromptGeneratorError.terminated(signal: exit.status, stderr: exit.stderr)
        }

        let answer: String
        switch adapter.resultSource {
        case .file:
            guard let data = try? Data(contentsOf: resultURL), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                throw CodexPromptGeneratorError.missingResult
            }
            answer = text
        case .stdout:
            guard !exit.standardOutput.isEmpty else {
                throw CodexPromptGeneratorError.missingResult
            }
            answer = exit.standardOutput
        }
        guard answer.utf8.count < Self.resultLimit else {
            throw CodexPromptGeneratorError.resultTooLarge
        }
        return answer
    }

    public func generate(
        rawTranscript: String,
        markup: PromptMarkup,
        profile: PromptRecipientProfile = .generic,
        // Свои инструкции и примеры владельца. Дефолт пустой: путь обычной
        // диктовки эту дорожку не трогает вовсе, а промпт-режим без подсказки
        // собирает ровно тот же запрос, что и раньше.
        guidance: PromptUserGuidance = .none,
        date: Date = Date()
    ) async throws -> PromptGeneration {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw CodexPromptGeneratorError.invalidTimeout
        }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            throw CodexPromptGeneratorError.invalidExecutable
        }
        let resolvedExecutableURL = executableURL.resolvingSymlinksInPath()
        guard resolvedExecutableURL.isFileURL,
              resolvedExecutableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: resolvedExecutableURL.path),
              (try? resolvedExecutableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CodexPromptGeneratorError.invalidExecutable
        }

        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let request = PromptGenerationContract().request(
            raw: rawTranscript,
            markup: markup,
            profile: profile,
            // Флаг схемы есть только у Codex. Остальным контракт просится текстом.
            jsonOnly: !adapter.supportsJSONSchema,
            guidance: guidance
        )
        var attemptRequest = request

        for attempt in 0..<2 {
            try Task.checkCancellation()
            let attemptDirectory = temporaryDirectory.appendingPathComponent(
                "attempt-\(attempt)",
                isDirectory: true
            )
            let workDirectory = attemptDirectory.appendingPathComponent("work", isDirectory: true)
            let isolatedHome = attemptDirectory.appendingPathComponent("home", isDirectory: true)
            let agentHome = adapter.homeSubdirectory.map {
                isolatedHome.appendingPathComponent($0, isDirectory: true)
            }
            let schemaURL = attemptDirectory.appendingPathComponent("schema.json")
            let inputURL = attemptDirectory.appendingPathComponent("input.txt")
            let promptFileURL = attemptDirectory.appendingPathComponent("prompt.txt")
            let resultURL = attemptDirectory.appendingPathComponent("result.json")
            do {
                try Self.createPrivateDirectory(at: attemptDirectory)
                try Self.createPrivateDirectory(at: workDirectory)
                try Self.createPrivateDirectory(at: isolatedHome)
                if let agentHome {
                    try Self.createPrivateDirectories(at: agentHome, under: isolatedHome)
                }
                try Self.seedAuthentication(
                    adapter: adapter,
                    from: environment,
                    isolatedAgentHome: agentHome
                )
                if adapter.supportsJSONSchema {
                    try Self.createPrivateFile(
                        at: schemaURL,
                        data: PromptGenerationContract.outputSchemaData
                    )
                }
                try Self.createPrivateFile(
                    at: inputURL,
                    data: adapter.promptDelivery == .stdin ? Data(attemptRequest.utf8) : Data()
                )
                if adapter.promptDelivery == .file {
                    try Self.createPrivateFile(at: promptFileURL, data: Data(attemptRequest.utf8))
                }
                if adapter.resultSource == .file {
                    try Self.createPrivateFile(at: resultURL, data: Data())
                }
            } catch let error as CodexPromptGeneratorError {
                throw error
            } catch {
                throw CodexPromptGeneratorError.privateFilePreparationFailed
            }
            let plan = Self.makePlan(
                adapter: adapter,
                model: model,
                executableURL: resolvedExecutableURL,
                workDirectoryURL: workDirectory,
                inputURL: inputURL,
                promptFileURL: promptFileURL,
                schemaURL: schemaURL,
                resultURL: resultURL,
                isolatedHomeURL: isolatedHome,
                agentHomeURL: agentHome,
                temporaryDirectoryURL: attemptDirectory,
                prompt: attemptRequest,
                environment: environment
            )
            let exit: ProcessExit
            do {
                exit = try await run(plan)
            } catch let error as CodexPromptGeneratorError {
                guard error == .timedOut, attempt == 0 else {
                    throw error
                }
                continue
            }
            try Task.checkCancellation()

            switch exit.reason {
            case .exit where exit.status == 0:
                break
            case .exit:
                throw CodexPromptGeneratorError.nonZeroExit(status: exit.status, stderr: exit.stderr)
            case .signal:
                throw CodexPromptGeneratorError.terminated(signal: exit.status, stderr: exit.stderr)
            }

            let resultData: Data
            let extractionFailed: Bool
            switch adapter.resultSource {
            case .file:
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
                    guard let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
                        throw CodexPromptGeneratorError.missingResult
                    }
                    guard size.intValue <= Self.resultLimit else {
                        throw CodexPromptGeneratorError.resultTooLarge
                    }
                    resultData = try Data(contentsOf: resultURL, options: [.mappedIfSafe])
                    extractionFailed = false
                } catch let error as CodexPromptGeneratorError {
                    throw error
                } catch {
                    throw CodexPromptGeneratorError.missingResult
                }
            case .stdout:
                // У CLI без флага схемы вокруг ответа бывает болтовня. Берём
                // первый валидный JSON-объект и молчим про остальное.
                guard !exit.standardOutput.isEmpty else {
                    throw CodexPromptGeneratorError.missingResult
                }
                guard exit.standardOutput.utf8.count < Self.resultLimit else {
                    throw CodexPromptGeneratorError.resultTooLarge
                }
                let extracted = PromptAgentOutput.firstJSONObject(in: exit.standardOutput)
                resultData = extracted ?? Data()
                extractionFailed = extracted == nil
            }

            let spec: PromptSpec
            do {
                guard !extractionFailed else {
                    throw CodexPromptGeneratorError.invalidResultJSON
                }
                spec = try Self.decodeResult(resultData)
            } catch let error as CodexPromptGeneratorError {
                guard error == .invalidResultJSON, attempt == 0 else {
                    throw error
                }
                try Task.checkCancellation()
                attemptRequest = request + Self.invalidPromptSpecRemediation
                continue
            }
            do {
                try PromptSpecValidator().validate(spec, raw: rawTranscript)
            } catch {
                guard attempt == 0 else {
                    throw CodexPromptGeneratorError.invalidPromptSpec
                }
                try Task.checkCancellation()
                attemptRequest = request + Self.invalidPromptSpecRemediation
                continue
            }
            let generation: PromptGeneration
            do {
                generation = try PromptRenderer().renderV2(
                    spec: spec,
                    raw: rawTranscript,
                    markup: markup,
                    profile: profile,
                    date: date
                )
            } catch {
                throw CodexPromptGeneratorError.renderingFailed
            }
            let outcome = PromptOutcomeVerifier().verify(
                spec: spec,
                prompt: generation.prompt,
                raw: rawTranscript,
                profile: profile
            )
            guard outcome.isAcceptable else {
                guard attempt == 0 else {
                    throw CodexPromptGeneratorError.invalidPromptOutcome
                }
                try Task.checkCancellation()
                attemptRequest = request + Self.invalidPromptOutcomeRemediation
                continue
            }
            return generation
        }
        throw CodexPromptGeneratorError.invalidPromptSpec
    }

    /// Прежняя точка входа Codex-пути. Оставлена дословно, чтобы доказать:
    /// обобщение не сдвинуло ни одного аргумента.
    static func makeInvocationPlan(
        executableURL: URL,
        workDirectoryURL: URL,
        inputURL: URL,
        schemaURL: URL,
        resultURL: URL,
        isolatedHomeURL: URL,
        isolatedCodexHomeURL: URL,
        temporaryDirectoryURL: URL,
        environment: [String: String]
    ) -> CodexInvocationPlan {
        makePlan(
            adapter: PromptAgentCatalog.codex,
            model: "",
            executableURL: executableURL,
            workDirectoryURL: workDirectoryURL,
            inputURL: inputURL,
            promptFileURL: inputURL,
            schemaURL: schemaURL,
            resultURL: resultURL,
            isolatedHomeURL: isolatedHomeURL,
            agentHomeURL: isolatedCodexHomeURL,
            temporaryDirectoryURL: temporaryDirectoryURL,
            prompt: "",
            environment: environment
        )
    }

    /// Чистая функция «адаптер + промпт → план запуска».
    ///
    /// Shell не используется: исполняемый файл абсолютен, аргументы уходят
    /// массивом, `{prompt}` никогда не склеивается в командную строку.
    /// Окружение урезается одинаково для всех адаптеров — своя программа
    /// послаблений не получает.
    static func makePlan(
        adapter: PromptAgentAdapter,
        model: String,
        executableURL: URL,
        workDirectoryURL: URL,
        inputURL: URL,
        promptFileURL: URL,
        schemaURL: URL,
        resultURL: URL,
        isolatedHomeURL: URL,
        agentHomeURL: URL?,
        temporaryDirectoryURL: URL,
        prompt: String,
        environment: [String: String]
    ) -> CodexInvocationPlan {
        let arguments = adapter.resolvedArguments(
            prompt: prompt,
            promptFileURL: promptFileURL,
            schemaURL: schemaURL,
            resultURL: resultURL,
            workDirectoryURL: workDirectoryURL,
            model: model
        )

        let allowedEnvironment = Set(["PATH", "LANG"])
        var minimalEnvironment = environment.filter { allowedEnvironment.contains($0.key) }
        minimalEnvironment["HOME"] = isolatedHomeURL.path
        if let name = adapter.homeEnvironmentVariable, let agentHomeURL {
            minimalEnvironment[name] = agentHomeURL.path
        }
        minimalEnvironment["TMPDIR"] = temporaryDirectoryURL.path

        return CodexInvocationPlan(
            executableURL: executableURL,
            arguments: arguments,
            environment: minimalEnvironment,
            currentDirectoryURL: workDirectoryURL,
            standardInputURL: inputURL,
            schemaURL: schemaURL,
            resultURL: resultURL,
            resultSource: adapter.resultSource
        )
    }

    /// Ответ приводится к NFC перед разбором.
    ///
    /// ЗАЧЕМ. `Process` на macOS отдаёт аргументы в файловой форме, то есть в
    /// NFD: «Ё» уезжает в «Е»+U+0308, «й» — в «и»+U+0306 (замерено). Агент,
    /// которому промпт достался аргументом (kimi иначе не умеет: у него
    /// `-p <prompt>`), видит разложенный текст и такими же цитатами отвечает.
    ///
    /// Сверку цитат это не ломает — Swift сравнивает строки канонически. Ломает
    /// то, что дальше: разложенный текст уехал бы в `prompt.md`, в историю и в
    /// поле чужого приложения, и обычный поиск по «отчёт» его бы не нашёл.
    /// Владельцу, который ищет по своим же файлам, это стоило бы времени.
    ///
    /// Нормализация не ослабляет проверку: она не делает разные строки
    /// одинаковыми, только записывает одну и ту же строку одинаково. Для
    /// NFC-ответа (весь путь Codex) это тождество.
    static func decodeResult(_ data: Data) throws -> PromptSpec {
        let normalized = Data(
            String(decoding: data, as: UTF8.self)
                .precomposedStringWithCanonicalMapping
                .utf8
        )
        do {
            return try JSONDecoder().decode(PromptSpec.self, from: normalized)
        } catch {
            throw CodexPromptGeneratorError.invalidResultJSON
        }
    }

    private func run(_ plan: CodexInvocationPlan) async throws -> ProcessExit {
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.currentDirectoryURL

        let inputHandle: FileHandle
        do {
            inputHandle = try FileHandle(forReadingFrom: plan.standardInputURL)
        } catch {
            throw CodexPromptGeneratorError.privateFilePreparationFailed
        }
        let errorPipe = Pipe()
        // Codex кладёт ответ в файл, и его stdout сознательно не читается.
        // Труба открывается только там, где ответ приходит потоком.
        let outputPipe = plan.resultSource == .stdout ? Pipe() : nil
        process.standardInput = inputHandle
        process.standardOutput = outputPipe ?? FileHandle.nullDevice
        process.standardError = errorPipe

        let waiter = ProcessExitWaiter()
        process.terminationHandler = { process in
            waiter.complete(
                status: process.terminationStatus,
                reason: process.terminationReason == .exit ? .exit : .signal
            )
        }
        let controller = ProcessController(process: process)
        let stderrCapture = CappedOutputCapture(
            handle: errorPipe.fileHandleForReading,
            limit: Self.stderrLimit,
            label: "ru.smltlk.agent-stderr"
        )
        let stdoutCapture = outputPipe.map {
            CappedOutputCapture(
                handle: $0.fileHandleForReading,
                limit: Self.resultLimit,
                label: "ru.smltlk.agent-stdout"
            )
        }

        func closeWriters() {
            try? inputHandle.close()
            try? errorPipe.fileHandleForWriting.close()
            try? outputPipe?.fileHandleForWriting.close()
        }

        return try await withTaskCancellationHandler {
            do {
                try controller.launch()
            } catch is CancellationError {
                closeWriters()
                _ = stderrCapture.finish()
                _ = stdoutCapture?.finish()
                throw CancellationError()
            } catch {
                closeWriters()
                _ = stderrCapture.finish()
                _ = stdoutCapture?.finish()
                throw CodexPromptGeneratorError.launchFailed
            }

            closeWriters()

            do {
                let processExit = try await waitForExit(waiter, controller: controller)
                let stderr = stderrCapture.finish()
                let stdout = stdoutCapture?.finish() ?? ""
                return ProcessExit(
                    status: processExit.status,
                    reason: processExit.reason,
                    stderr: stderr,
                    standardOutput: stdout
                )
            } catch is CancellationError {
                controller.stop()
                _ = await waiter.wait()
                _ = stderrCapture.finish()
                _ = stdoutCapture?.finish()
                throw CancellationError()
            } catch {
                controller.stop()
                _ = await waiter.wait()
                _ = stderrCapture.finish()
                _ = stdoutCapture?.finish()
                throw error
            }
        } onCancel: {
            controller.stop()
        }
    }

    private func waitForExit(
        _ waiter: ProcessExitWaiter,
        controller: ProcessController
    ) async throws -> ProcessExitStatus {
        try await withThrowingTaskGroup(of: ProcessRace.self) { group in
            group.addTask {
                .finished(await waiter.wait())
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                return .timedOut
            }

            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            switch first {
            case let .finished(exit):
                return exit
            case .timedOut:
                controller.stop()
                _ = await waiter.wait()
                throw CodexPromptGeneratorError.timedOut
            }
        }
    }

    static func makeTemporaryDirectory(
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        var template = Array(base.appendingPathComponent("smltlk-codex.XXXXXX").path.utf8CString)
        guard let pointer = mkdtemp(&template) else {
            throw CodexPromptGeneratorError.temporaryDirectoryUnavailable
        }

        let directory = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        let currentDirectory = currentDirectoryURL.resolvingSymlinksInPath()
        let currentPath = currentDirectory.path.hasSuffix("/") ? currentDirectory.path : currentDirectory.path + "/"
        let isInsideCurrentDirectory = currentDirectory.path != "/"
            && (directory.path == currentDirectory.path || directory.path.hasPrefix(currentPath))
        if isInsideCurrentDirectory {
            try? FileManager.default.removeItem(at: directory)
            throw CodexPromptGeneratorError.temporaryDirectoryUnavailable
        }
        return directory
    }

    private static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    /// Создаёт вложенные каталоги по одному, чтобы каждый получил права 0700:
    /// `withIntermediateDirectories: true` раздаёт атрибуты не всем уровням.
    /// Дальше корня не поднимается — путь всегда внутри временного каталога.
    private static func createPrivateDirectories(at url: URL, under root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        var pending: [URL] = []
        var current = url.standardizedFileURL
        while current.path.count >= rootPath.count {
            if !FileManager.default.fileExists(atPath: current.path) {
                pending.append(current)
            }
            guard current.path != rootPath else { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { break }
            current = parent
        }
        for directory in pending.reversed() {
            try createPrivateDirectory(at: directory)
        }
    }

    /// Переносит в изолированный дом ТОЛЬКО объявленные адаптером файлы
    /// авторизации. Всё остальное — личные конфиги, скиллы, агенты, история —
    /// остаётся снаружи для любого агента, а не только для Codex.
    private static func seedAuthentication(
        adapter: PromptAgentAdapter,
        from environment: [String: String],
        isolatedAgentHome: URL?
    ) throws {
        guard let isolatedAgentHome,
              let subdirectory = adapter.homeSubdirectory,
              !adapter.authenticationFiles.isEmpty else { return }

        let sourceAgentHome: URL?
        if let name = adapter.homeEnvironmentVariable,
           let path = environment[name],
           path.hasPrefix("/") {
            sourceAgentHome = URL(fileURLWithPath: path, isDirectory: true)
        } else if let path = environment["HOME"], path.hasPrefix("/") {
            sourceAgentHome = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
        } else {
            sourceAgentHome = nil
        }
        guard let sourceAgentHome else { return }

        for relativePath in adapter.authenticationFiles {
            let source = sourceAgentHome.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let values = try source.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= authLimit else {
                throw CodexPromptGeneratorError.privateFilePreparationFailed
            }
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            guard !data.isEmpty, data.count <= authLimit else {
                throw CodexPromptGeneratorError.privateFilePreparationFailed
            }
            let destination = isolatedAgentHome.appendingPathComponent(relativePath)
            try createPrivateDirectories(
                at: destination.deletingLastPathComponent(),
                under: isolatedAgentHome
            )
            try createPrivateFile(at: destination, data: data)
        }
    }

    private static func createPrivateFile(at url: URL, data: Data) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CodexPromptGeneratorError.privateFilePreparationFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw CodexPromptGeneratorError.privateFilePreparationFailed
        }
    }

}

private enum ProcessExitReason: Sendable {
    case exit
    case signal
}

private struct ProcessExitStatus: Sendable {
    let status: Int32
    let reason: ProcessExitReason
}

private struct ProcessExit: Sendable {
    let status: Int32
    let reason: ProcessExitReason
    let stderr: String
    let standardOutput: String
}

private enum ProcessRace: Sendable {
    case finished(ProcessExitStatus)
    case timedOut
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProcessExitStatus?
    private var continuations: [CheckedContinuation<ProcessExitStatus, Never>] = []

    func complete(status: Int32, reason: ProcessExitReason) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        let result = ProcessExitStatus(status: status, reason: reason)
        self.result = result
        let continuations = self.continuations
        self.continuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }

    func wait() async -> ProcessExitStatus {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class ProcessController: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stopRequested = false
    private var stopScheduled = false

    init(process: Process) {
        self.process = process
    }

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopRequested else { throw CancellationError() }
        try process.run()
    }

    func stop() {
        lock.lock()
        stopRequested = true
        guard process.isRunning, !stopScheduled else {
            lock.unlock()
            return
        }
        stopScheduled = true
        lock.unlock()

        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [process] in
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) { [process] in
                guard process.isRunning else { return }
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private final class CappedOutputCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private var captured = Data()
    private var finished = false

    init(handle: FileHandle, limit: Int, label: String) {
        self.handle = handle
        self.limit = limit
        queue = DispatchQueue(label: label)
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.resume()
    }

    func finish() -> String {
        queue.sync {
            if !finished {
                drain()
                finished = true
                source.cancel()
                source.setEventHandler {}
                try? handle.close()
            }
            return String(decoding: captured, as: UTF8.self)
        }
    }

    private func drain() {
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let remaining = max(0, limit - captured.count)
                if remaining > 0 {
                    captured.append(contentsOf: buffer.prefix(min(remaining, count)))
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
