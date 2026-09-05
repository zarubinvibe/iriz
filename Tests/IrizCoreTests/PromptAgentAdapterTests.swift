import Foundation
@testable import IrizPrompt
import Testing

/// Обобщение вызова обязано быть доказуемо безобидным: Codex запускается тем же
/// argv, что и до него, а чужой CLI не получает ни одного послабления обвязки.
@Suite("Адаптеры агентов", .serialized)
struct PromptAgentAdapterTests {
    private let root = URL(fileURLWithPath: "/private/tmp/adapter-test", isDirectory: true)
    private var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    private var input: URL { root.appendingPathComponent("input.txt") }
    private var promptFile: URL { root.appendingPathComponent("prompt.txt") }
    private var schema: URL { root.appendingPathComponent("schema.json") }
    private var result: URL { root.appendingPathComponent("result.json") }
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }

    private var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/test",
            "TMPDIR": "/private/tmp",
            "LANG": "ru_RU.UTF-8",
            "SAMPLE_SECRET": "must-not-leak",
        ]
    }

    /// ГЛАВНОЕ ДОКАЗАТЕЛЬСТВО. Список ниже набран отдельно от исходника: если
    /// адаптер сдвинет хоть один аргумент Codex, тест упадёт. Проверенный вызов
    /// обобщение менять не имеет права.
    @Test func codexAdapterReproducesCurrentArgumentsByteForByte() {
        let expected = [
            "-a", "never",
            "exec",
            "--ignore-user-config",
            "--ignore-rules",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-C", work.path,
            "--output-schema", schema.path,
            "--output-last-message", result.path,
            "--color", "never",
            "--disable", "shell_tool",
            "--disable", "unified_exec",
            "--disable", "code_mode_host",
            "--disable", "apps",
            "--disable", "plugins",
            "--disable", "browser_use",
            "--disable", "browser_use_external",
            "--disable", "browser_use_full_cdp_access",
            "--disable", "computer_use",
            "--disable", "image_generation",
            "--disable", "multi_agent",
            "--disable", "hooks",
            "--disable", "skill_search",
            "-c", #"web_search="disabled""#,
            "-c", #"history.persistence="none""#,
        ]

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let legacy = CodexPromptGenerator.makeInvocationPlan(
            executableURL: URL(fileURLWithPath: "/opt/tools/codex"),
            workDirectoryURL: work,
            inputURL: input,
            schemaURL: schema,
            resultURL: result,
            isolatedHomeURL: home,
            isolatedCodexHomeURL: codexHome,
            temporaryDirectoryURL: root,
            environment: environment
        )
        let adapted = plan(
            for: PromptAgentCatalog.codex,
            executableURL: URL(fileURLWithPath: "/opt/tools/codex")
        )

        #expect(legacy.arguments == expected)
        #expect(adapted.arguments == expected)
        // План целиком, а не только аргументы: окружение и каталоги тоже.
        #expect(legacy == adapted)
    }

    /// Подстановка поэлементная. `--out={result}` не склеивается: сломанный
    /// вызов честнее молчаливой сборки командной строки.
    @Test func substitutionsReplaceWholeArgumentsOnly() {
        let adapter = testAdapter(
            template: ["{workdir}", "{schema}", "{result}", "--out={result}", "prefix{workdir}"],
            delivery: .stdin
        )

        let arguments = plan(for: adapter).arguments

        #expect(arguments == [
            work.path,
            schema.path,
            result.path,
            "--out={result}",
            "prefix{workdir}",
        ])
    }

    /// Устаревший шаблон не имеет права уронить расшифровку в argv: при доставке
    /// через stdin плейсхолдер выбрасывается, а не подставляется.
    @Test func stdinDeliveryNeverLeaksPromptIntoArguments() {
        let secret = "личная тайна владельца"
        let adapter = testAdapter(template: ["-p", "{prompt}"], delivery: .stdin)

        let arguments = plan(for: adapter, prompt: secret).arguments

        #expect(arguments == ["-p"])
        #expect(!arguments.contains { $0.contains(secret) })
    }

    @Test func argumentDeliveryPassesPromptAsOneWholeElement() {
        let prompt = "первая строка\nвторая строка с пробелами и \"кавычками\""
        let adapter = testAdapter(template: ["-p", "{prompt}"], delivery: .argument)

        let arguments = plan(for: adapter, prompt: prompt).arguments

        #expect(arguments == ["-p", prompt])
    }

    @Test func fileDeliveryPassesPathInsteadOfText() {
        let prompt = "секрет"
        let adapter = testAdapter(template: ["--file", "{prompt}"], delivery: .file)

        let arguments = plan(for: adapter, prompt: prompt).arguments

        #expect(arguments == ["--file", promptFile.path])
        #expect(!arguments.contains(prompt))
    }

    /// Обвязка одинакова для всех: пустой временный HOME, окружение из PATH и
    /// LANG, временный TMPDIR. Своя программа послаблений не получает.
    @Test func everyAdapterGetsTheSameLockedEnvironment() {
        let adapters = PromptAgentCatalog.identifiers.compactMap {
            PromptAgentCatalog.adapter(id: $0, customArguments: ["{prompt}"])
        }
        #expect(adapters.count == PromptAgentCatalog.identifiers.count)

        for adapter in adapters {
            let built = plan(for: adapter)
            var expectedKeys = Set(["PATH", "LANG", "HOME", "TMPDIR"])
            if let name = adapter.homeEnvironmentVariable { expectedKeys.insert(name) }

            #expect(Set(built.environment.keys) == expectedKeys, "\(adapter.id)")
            #expect(built.environment["HOME"] == home.path, "\(adapter.id)")
            #expect(built.environment["TMPDIR"] == root.path, "\(adapter.id)")
            #expect(built.environment["SAMPLE_SECRET"] == nil, "\(adapter.id)")
            #expect(built.currentDirectoryURL == work, "\(adapter.id)")
        }
    }

    /// Неизвестный агент — внятный отказ, а не падение и не молчаливая подмена.
    @Test func unknownAgentIdentifierIsRefused() {
        #expect(PromptAgentCatalog.adapter(id: "не-существует") == nil)
        #expect(PromptAgentCatalog.adapter(id: "") == nil)
        #expect(PromptAgentCatalog.adapter(id: PromptAgentCatalog.ollamaID) != nil)
    }

    /// Несуществующий путь — отказ до запуска, а не падение процесса.
    @Test func missingExecutableIsRefusedBeforeLaunch() async throws {
        let raw = "Собери отчёт."
        let generator = CodexPromptGenerator(
            executableURL: URL(fileURLWithPath: "/no/such/binary-\(UUID().uuidString)"),
            adapter: PromptAgentCatalog.claude,
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "LANG": "ru_RU.UTF-8"]
        )

        do {
            _ = try await generator.generate(
                rawTranscript: raw,
                markup: PromptEnvelopeBuilder().analyze(raw)
            )
            Issue.record("Несуществующий путь приняли за исполняемый файл")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidExecutable)
        }
    }

    /// Относительный путь запрещён: иначе выбор бинарника зависел бы от того,
    /// откуда запущено приложение.
    @Test func relativeExecutablePathIsRefused() async throws {
        let raw = "Собери отчёт."
        let generator = CodexPromptGenerator(
            executableURL: URL(fileURLWithPath: "bin/agent", relativeTo: nil),
            adapter: PromptAgentCatalog.ollama,
            model: "qwen",
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "LANG": "ru_RU.UTF-8"]
        )

        do {
            _ = try await generator.generate(
                rawTranscript: raw,
                markup: PromptEnvelopeBuilder().analyze(raw)
            )
            Issue.record("Относительный путь приняли")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidExecutable)
        }
    }

    @Test func ollamaIsShownFirstAndIsTheOnlyLocalAgent() {
        #expect(PromptAgentCatalog.identifiers.first == PromptAgentCatalog.ollamaID)
        #expect(PromptAgentCatalog.ollama.destination.isLocal)

        let outside = [
            PromptAgentCatalog.codex,
            PromptAgentCatalog.claude,
            PromptAgentCatalog.kimi,
            PromptAgentCatalog.custom(arguments: []),
        ]
        for adapter in outside {
            #expect(!adapter.destination.isLocal, "\(adapter.id)")
            #expect(!adapter.destination.title.isEmpty, "\(adapter.id)")
            #expect(!adapter.destination.shortTitle.isEmpty, "\(adapter.id)")
        }
        #expect(PromptAgentCatalog.ollama.destination.title.contains("на этом Маке"))
        #expect(PromptAgentCatalog.ollama.destination.shortTitle == "на этом Маке")
        #expect(PromptAgentCatalog.codex.destination.shortTitle.contains("OpenAI"))
    }

    /// Флаг схемы есть только у Codex. Остальным контракт просится текстом.
    @Test func onlyCodexDeclaresSchemaFlagSupport() {
        #expect(PromptAgentCatalog.codex.supportsJSONSchema)
        for adapter in [
            PromptAgentCatalog.ollama,
            PromptAgentCatalog.claude,
            PromptAgentCatalog.kimi,
            PromptAgentCatalog.custom(arguments: []),
        ] {
            #expect(!adapter.supportsJSONSchema, "\(adapter.id)")
        }

        let contract = PromptGenerationContract()
        let raw = "Собери отчёт."
        let markup = PromptEnvelopeBuilder().analyze(raw)
        let plain = contract.request(raw: raw, markup: markup, profile: .generic)
        let reminded = contract.request(raw: raw, markup: markup, profile: .generic, jsonOnly: true)

        #expect(!plain.contains(PromptGenerationContract.jsonOnlyReminder))
        #expect(reminded.contains(PromptGenerationContract.jsonOnlyReminder))
        #expect(reminded.contains(PromptGenerationContract.outputSchema))
    }

    /// То, что иначе всплывёт сбоем посреди работы, сказано рядом с выбором:
    /// у Claude — недоступный из песочницы вход, у Kimi — промпт в argv.
    @Test func agentsWithKnownCatchesWarnBeforeTheChoice() throws {
        let claudeNote = try #require(PromptAgentCatalog.claude.configurationNote)
        #expect(claudeNote.contains(".credentials.json"))

        let kimiNote = try #require(PromptAgentCatalog.kimi.configurationNote)
        #expect(kimiNote.contains("аргументом командной строки"))
        #expect(PromptAgentCatalog.kimi.promptDelivery == .argument)

        // Там, где ловушек нет, лишнего текста тоже нет.
        #expect(PromptAgentCatalog.ollama.configurationNote == nil)
        #expect(PromptAgentCatalog.codex.configurationNote == nil)
    }

    @Test func customAdapterChoosesDeliveryByPlaceholder() {
        #expect(PromptAgentCatalog.custom(arguments: ["-p", "{prompt}"]).promptDelivery == .argument)
        #expect(PromptAgentCatalog.custom(arguments: ["run"]).promptDelivery == .stdin)
        #expect(PromptAgentCatalog.custom(arguments: []).promptDelivery == .stdin)
        #expect(PromptAgentCatalog.ollama.requiresModel)
        #expect(!PromptAgentCatalog.codex.requiresModel)
    }

    @Test func modelPlaceholderIsSubstituted() {
        let built = plan(for: PromptAgentCatalog.ollama, model: "qwen2.5-coder:7b")

        #expect(built.arguments == ["run", "qwen2.5-coder:7b"])
    }

    // MARK: - Терпимый разбор ответа

    @Test func firstJSONObjectIgnoresChatterAround() throws {
        let text = """
        Хорошо, вот результат:
        ```json
        {"status":"ready","goal":{"text":"a"}}
        ```
        Надеюсь, помогло.
        """
        let data = try #require(PromptAgentOutput.firstJSONObject(in: text))

        #expect(String(decoding: data, as: UTF8.self) == #"{"status":"ready","goal":{"text":"a"}}"#)
    }

    @Test func firstJSONObjectSurvivesBracesInsideStrings() throws {
        let text = #"шум { не json } потом {"text":"скобка } внутри строки","ok":true} хвост"#
        let data = try #require(PromptAgentOutput.firstJSONObject(in: text))

        #expect(String(decoding: data, as: UTF8.self)
            == #"{"text":"скобка } внутри строки","ok":true}"#)
    }

    @Test func firstJSONObjectReturnsNilWithoutJSON() {
        #expect(PromptAgentOutput.firstJSONObject(in: "нет тут ничего") == nil)
        #expect(PromptAgentOutput.firstJSONObject(in: "") == nil)
        #expect(PromptAgentOutput.firstJSONObject(in: "{незакрытая") == nil)
    }

    // MARK: - Живой прогон чужого CLI

    /// CLI без флага схемы: контракт просится текстом, ответ читается из stdout,
    /// болтовня вокруг JSON игнорируется.
    @Test func stdoutAgentProducesGenerationFromNoisyOutput() async throws {
        let raw = "Собери отчёт."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let fake = try makeFakeExecutable(body: """
        input=$(/bin/cat)
        case "$input" in *"ФОРМАТ ОТВЕТА"*) ;; *) exit 61 ;; esac
        case "$input" in *"СЫРЬЁ"*) ;; *) exit 62 ;; esac
        [ "$#" -eq 1 ] || exit 63
        [ "$1" = "-p" ] || exit 64
        [ -z "${CODEX_HOME:-}" ] || exit 65
        /usr/bin/printf '%s\\n' 'Сейчас соберу.' '\(json)' 'Готово.'
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let generation = try await CodexPromptGenerator(
            executableURL: fake.executable,
            adapter: PromptAgentCatalog.claude,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": fake.directory.path,
                "LANG": "ru_RU.UTF-8",
            ]
        ).generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.spec == spec)
        #expect(generation.prompt == raw)
    }

    /// Доставка аргументом: текст приходит одним элементом argv, а не строкой.
    ///
    /// Ответ фальшивого CLI намеренно записан в NFD — ровно так русский текст и
    /// возвращается оттуда, куда `Process` отдал его аргументом. Наружу обязан
    /// выйти NFC, иначе разложенный текст уедет в историю и в чужое приложение,
    /// где обычный поиск по слову его не найдёт.
    @Test func argumentAgentReceivesPromptAndDecomposedAnswerComesBackComposed() async throws {
        let raw = "Собери отчёт."
        let decomposed = raw.decomposedStringWithCanonicalMapping
        // Swift сравнивает строки канонически, поэтому разница видна в байтах.
        #expect(Array(decomposed.utf8) != Array(raw.utf8),
                "проверка бессмысленна без разложимого символа")
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: decomposed, evidence: decomposed)
        )
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let fake = try makeFakeExecutable(body: """
        [ "$#" -eq 2 ] || exit 61
        [ "$1" = "-p" ] || exit 62
        case "$2" in *"prompt-spec-v2"*) ;; *) exit 63 ;; esac
        [ -z "$(/bin/cat)" ] || exit 64
        /usr/bin/printf '%s' '\(json)'
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let generation = try await CodexPromptGenerator(
            executableURL: fake.executable,
            adapter: PromptAgentCatalog.kimi,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": fake.directory.path,
                "LANG": "ru_RU.UTF-8",
            ]
        ).generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.prompt == raw)
        #expect(Array(generation.spec.goal.text.utf8) == Array(raw.utf8))
        #expect(Array(generation.prompt.utf8) == Array(raw.utf8))
    }

    /// Выдумка чужого CLI отсекается нашим верификатором: гарантия качества
    /// держится на нашей стороне, а не на добросовестности агента.
    @Test func lyingAgentIsRejectedRegardlessOfBrand() async throws {
        let raw = "Собери отчёт."
        let invented = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Удали базу", evidence: "этого в сырье нет")
        )
        let json = String(decoding: try JSONEncoder().encode(invented), as: UTF8.self)
        let fake = try makeFakeExecutable(body: """
        /bin/cat >/dev/null
        /usr/bin/printf '%s' '\(json)'
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        do {
            _ = try await CodexPromptGenerator(
                executableURL: fake.executable,
                adapter: PromptAgentCatalog.claude,
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": fake.directory.path,
                    "LANG": "ru_RU.UTF-8",
                ]
            ).generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Верификатор пропустил выдумку чужого CLI")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidPromptSpec)
        }
    }

    /// Ответ без JSON вовсе — отказ, а не молчаливая вставка болтовни.
    @Test func stdoutWithoutJSONIsRefused() async throws {
        let raw = "Собери отчёт."
        let fake = try makeFakeExecutable(body: """
        /bin/cat >/dev/null
        /usr/bin/printf '%s' 'Извините, не понял задачу.'
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        do {
            _ = try await CodexPromptGenerator(
                executableURL: fake.executable,
                adapter: PromptAgentCatalog.ollama,
                model: "qwen",
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": fake.directory.path,
                    "LANG": "ru_RU.UTF-8",
                ]
            ).generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Болтовню без JSON приняли за ответ")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidResultJSON)
        }
    }

    // MARK: - Помощники

    private func plan(
        for adapter: PromptAgentAdapter,
        prompt: String = "",
        model: String = "",
        executableURL: URL = URL(fileURLWithPath: "/opt/tools/agent")
    ) -> CodexInvocationPlan {
        CodexPromptGenerator.makePlan(
            adapter: adapter,
            model: model,
            executableURL: executableURL,
            workDirectoryURL: work,
            inputURL: input,
            promptFileURL: promptFile,
            schemaURL: schema,
            resultURL: result,
            isolatedHomeURL: home,
            agentHomeURL: adapter.homeSubdirectory.map {
                home.appendingPathComponent($0, isDirectory: true)
            },
            temporaryDirectoryURL: root,
            prompt: prompt,
            environment: environment
        )
    }

    private func testAdapter(
        template: [String],
        delivery: PromptAgentDelivery
    ) -> PromptAgentAdapter {
        PromptAgentAdapter(
            id: "test",
            displayName: "Тестовый",
            executableName: "test",
            knownPaths: [],
            argumentTemplate: template,
            promptDelivery: delivery,
            resultSource: .stdout,
            supportsJSONSchema: false,
            destination: .unknown
        )
    }

    private func makeFakeExecutable(body: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-fake-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let executable = directory.appendingPathComponent("agent")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }
}
