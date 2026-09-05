import Foundation

/// Как промпт попадает в CLI.
public enum PromptAgentDelivery: Sendable, Equatable {
    /// Текст пишется в stdin. Предпочтительный способ: расшифровка не попадает
    /// в argv, который на macOS виден любому процессу того же пользователя.
    case stdin
    /// Текст подставляется отдельным элементом массива аргументов.
    ///
    /// Цена этого способа замерена: `Process` на macOS отдаёт аргументы в NFD,
    /// поэтому русский текст доезжает разложенным (см. `decodeResult`), а argv
    /// виден процессам того же пользователя. Годится только там, где CLI не
    /// умеет иначе.
    case argument
    /// Текст кладётся в приватный файл, в аргумент идёт путь к нему.
    case file
}

/// Откуда читается ответ агента.
public enum PromptAgentResultSource: Sendable, Equatable {
    case stdout
    case file
}

/// Куда уходит расшифровка. Цена выбора обязана стоять рядом с самим выбором,
/// а не в документации, которую никто не открывает в момент решения.
public enum PromptAgentDestination: Sendable, Equatable {
    case localMachine
    case openAI
    case anthropic
    case moonshot
    case unknown

    /// Строка под выбором. Меняется вместе с выбором агента.
    public var title: String {
        switch self {
        case .localMachine: "расшифровка остаётся на этом Маке"
        case .openAI: "расшифровка уходит в OpenAI"
        case .anthropic: "расшифровка уходит в Anthropic"
        case .moonshot: "расшифровка уходит в Moonshot"
        case .unknown: "куда уйдёт расшифровка — решает выбранная программа"
        }
    }

    /// Короткая форма — для строки самого списка, чтобы цена была видна ещё до
    /// выбора, а не только после него.
    public var shortTitle: String {
        switch self {
        case .localMachine: "на этом Маке"
        case .openAI: "в OpenAI"
        case .anthropic: "в Anthropic"
        case .moonshot: "в Moonshot"
        case .unknown: "куда решит программа"
        }
    }

    public var isLocal: Bool { self == .localMachine }
}

/// Описание запуска CLI данными, а не кодом.
///
/// Обвязка безопасности к адаптеру не относится и послаблений не знает: пустой
/// временный `HOME`, окружение из `PATH`+`LANG`, временный рабочий каталог,
/// таймаут и убийство процесса при отмене применяются ко ВСЕМ адаптерам
/// одинаково — их ставит рантайм, а не эта структура.
public struct PromptAgentAdapter: Sendable, Equatable, Identifiable {
    public static let promptPlaceholder = "{prompt}"
    public static let schemaPlaceholder = "{schema}"
    public static let resultPlaceholder = "{result}"
    public static let workdirPlaceholder = "{workdir}"
    public static let modelPlaceholder = "{model}"

    public let id: String
    public let displayName: String
    /// Имя для автопоиска в `PATH`. Пусто — автопоиска нет, путь задаёт владелец.
    public let executableName: String
    /// Известные места установки. `~/` разворачивается в домашний каталог.
    public let knownPaths: [String]
    /// Шаблон аргументов с подстановками. Склейки строк нет: массив есть массив.
    public let argumentTemplate: [String]
    public let promptDelivery: PromptAgentDelivery
    public let resultSource: PromptAgentResultSource
    /// Флаг схемы ответа есть только у Codex. Остальным контракт просится текстом.
    public let supportsJSONSchema: Bool
    public let destination: PromptAgentDestination
    /// Переменная окружения с собственным домом CLI (`CODEX_HOME` у Codex).
    public let homeEnvironmentVariable: String?
    /// Каталог внутри изолированного `HOME`, который создаётся заранее.
    public let homeSubdirectory: String?
    /// Единственное, что переносится из настоящего профиля: файлы авторизации.
    /// Пути относительно `homeSubdirectory`. Личные конфиги, скиллы и агенты
    /// не переносятся — иначе чужой CLI утащил бы в контекст рабочие файлы.
    public let authenticationFiles: [String]
    /// Честное предупреждение рядом с выбором: то, что владелец иначе узнает
    /// только по сбою посреди работы.
    public let configurationNote: String?

    public init(
        id: String,
        displayName: String,
        executableName: String,
        knownPaths: [String],
        argumentTemplate: [String],
        promptDelivery: PromptAgentDelivery,
        resultSource: PromptAgentResultSource,
        supportsJSONSchema: Bool,
        destination: PromptAgentDestination,
        homeEnvironmentVariable: String? = nil,
        homeSubdirectory: String? = nil,
        authenticationFiles: [String] = [],
        configurationNote: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.knownPaths = knownPaths
        self.argumentTemplate = argumentTemplate
        self.promptDelivery = promptDelivery
        self.resultSource = resultSource
        self.supportsJSONSchema = supportsJSONSchema
        self.destination = destination
        self.homeEnvironmentVariable = homeEnvironmentVariable
        self.homeSubdirectory = homeSubdirectory
        self.authenticationFiles = authenticationFiles
        self.configurationNote = configurationNote
    }

    /// Агенту нужна модель (`ollama run <модель>`): без неё запускать нечего.
    public var requiresModel: Bool {
        argumentTemplate.contains(Self.modelPlaceholder)
    }

    /// Подстановка поэлементная и только при полном совпадении элемента с
    /// плейсхолдером. `--out={result}` останется literal-ом: сломанный вызов
    /// лучше молчаливой склейки, из которой рождается shell-инъекция.
    ///
    /// `{prompt}` при доставке через stdin ВЫБРАСЫВАЕТСЯ, а не подставляется:
    /// устаревший шаблон не имеет права уронить расшифровку в argv.
    public func resolvedArguments(
        prompt: String,
        promptFileURL: URL,
        schemaURL: URL,
        resultURL: URL,
        workDirectoryURL: URL,
        model: String = ""
    ) -> [String] {
        argumentTemplate.compactMap { argument in
            switch argument {
            case Self.promptPlaceholder:
                switch promptDelivery {
                case .stdin: return nil
                case .argument: return prompt
                case .file: return promptFileURL.path
                }
            case Self.schemaPlaceholder: return schemaURL.path
            case Self.resultPlaceholder: return resultURL.path
            case Self.workdirPlaceholder: return workDirectoryURL.path
            case Self.modelPlaceholder: return model
            default: return argument
            }
        }
    }
}

/// Заводские адаптеры. Порядок намеренный: локальный агент первым, потому что
/// все остальные отправляют речь владельца третьей стороне.
public enum PromptAgentCatalog {
    public static let ollamaID = "ollama"
    public static let codexID = "codex"
    public static let claudeID = "claude"
    public static let kimiID = "kimi"
    public static let customID = "custom"

    public static let defaultID = codexID

    /// Порядок показа в настройках.
    public static let identifiers = [ollamaID, codexID, claudeID, kimiID, customID]

    /// Codex запускается ровно так же, как до обобщения. Ни один флаг не изменён:
    /// он выверен и работает, а обобщение не имеет права ухудшить готовое.
    private static let codexDisabledFeatures = [
        "shell_tool",
        "unified_exec",
        "code_mode_host",
        "apps",
        "plugins",
        "browser_use",
        "browser_use_external",
        "browser_use_full_cdp_access",
        "computer_use",
        "image_generation",
        "multi_agent",
        "hooks",
        "skill_search",
    ]

    static let codexArgumentTemplate: [String] = {
        var arguments = [
            "-a", "never",
            "exec",
            "--ignore-user-config",
            "--ignore-rules",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-C", PromptAgentAdapter.workdirPlaceholder,
            "--output-schema", PromptAgentAdapter.schemaPlaceholder,
            "--output-last-message", PromptAgentAdapter.resultPlaceholder,
            "--color", "never",
        ]
        for feature in codexDisabledFeatures {
            arguments.append(contentsOf: ["--disable", feature])
        }
        arguments.append(contentsOf: [
            "-c", #"web_search="disabled""#,
            "-c", #"history.persistence="none""#,
        ])
        return arguments
    }()

    public static let codex = PromptAgentAdapter(
        id: codexID,
        displayName: "Codex",
        executableName: "codex",
        knownPaths: [
            "~/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "~/.local/bin/codex",
        ],
        argumentTemplate: codexArgumentTemplate,
        promptDelivery: .stdin,
        resultSource: .file,
        supportsJSONSchema: true,
        destination: .openAI,
        homeEnvironmentVariable: "CODEX_HOME",
        homeSubdirectory: ".codex",
        authenticationFiles: ["auth.json"]
    )

    /// Единственный агент, который не нарушает офлайн-обещание.
    /// `ollama run <модель>` читает промпт из stdin, поэтому речь не попадает в argv.
    public static let ollama = PromptAgentAdapter(
        id: ollamaID,
        displayName: "Ollama",
        executableName: "ollama",
        knownPaths: [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "~/.local/bin/ollama",
        ],
        argumentTemplate: ["run", PromptAgentAdapter.modelPlaceholder],
        promptDelivery: .stdin,
        resultSource: .stdout,
        supportsJSONSchema: false,
        destination: .localMachine
    )

    /// `claude -p` без позиционного аргумента читает промпт из stdin — проверено
    /// живьём 11.08.2026, поэтому расшифровка не попадает в argv.
    public static let claude = PromptAgentAdapter(
        id: claudeID,
        displayName: "Claude Code",
        executableName: "claude",
        knownPaths: [
            "~/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "~/.claude/local/claude",
        ],
        argumentTemplate: ["-p"],
        promptDelivery: .stdin,
        resultSource: .stdout,
        supportsJSONSchema: false,
        destination: .anthropic,
        homeSubdirectory: ".claude",
        authenticationFiles: [".credentials.json"],
        // Замерено 11.08.2026: с пустым HOME отвечает «Not logged in». Домашний
        // каталог агенту не отдаётся — иначе он утащит в контекст рабочие файлы
        // вместе с историей проектов и MCP-серверами из ~/.claude.json.
        // Обвязка важнее удобства, поэтому предупреждаем заранее.
        configurationNote: """
        Работает, только если вход сохранён в файле ~/.claude/.credentials.json. \
        Домашний каталог агенту не отдаётся, поэтому вход, лежащий в Связке ключей \
        или в ~/.claude.json, отсюда не виден.
        """
    )

    /// У `kimi` флаг объявлен как `-p, --prompt <prompt>`: аргумент обязателен,
    /// stdin не предусмотрен. Поэтому здесь — и только здесь — расшифровка
    /// проходит через argv. Это плата за чужой интерфейс, а не наш выбор.
    public static let kimi = PromptAgentAdapter(
        id: kimiID,
        displayName: "Kimi",
        executableName: "kimi",
        knownPaths: [
            "~/.kimi-code/bin/kimi",
            "/opt/homebrew/bin/kimi",
            "/usr/local/bin/kimi",
        ],
        argumentTemplate: ["-p", PromptAgentAdapter.promptPlaceholder],
        promptDelivery: .argument,
        resultSource: .stdout,
        supportsJSONSchema: false,
        destination: .moonshot,
        homeSubdirectory: ".kimi-code",
        authenticationFiles: ["credentials/kimi-code.json"],
        configurationNote: """
        Единственный агент, которому промпт уходит аргументом командной строки: \
        другого способа у него нет. Пока он работает, надиктовку видно в списке \
        процессов другим программам, запущенным под вашей учётной записью.
        """
    )

    /// Свой CLI. Аргументы задаёт владелец построчно, поэтому кавычек и shell-я
    /// нет вовсе. Есть `{prompt}` в шаблоне — текст идёт отдельным аргументом;
    /// нет — уходит в stdin.
    public static func custom(arguments: [String]) -> PromptAgentAdapter {
        PromptAgentAdapter(
            id: customID,
            displayName: "Свой CLI",
            executableName: "",
            knownPaths: [],
            argumentTemplate: arguments,
            promptDelivery: arguments.contains(PromptAgentAdapter.promptPlaceholder)
                ? .argument
                : .stdin,
            resultSource: .stdout,
            supportsJSONSchema: false,
            destination: .unknown
        )
    }

    /// Неизвестный идентификатор — внятный отказ, а не падение и не молчаливая
    /// подмена на что-то другое.
    public static func adapter(id: String, customArguments: [String] = []) -> PromptAgentAdapter? {
        switch id {
        case ollamaID: ollama
        case codexID: codex
        case claudeID: claude
        case kimiID: kimi
        case customID: custom(arguments: customArguments)
        default: nil
        }
    }
}

/// Терпимое чтение ответа у CLI без флага схемы: найти первый валидный
/// JSON-объект и не обращать внимания на болтовню вокруг.
public enum PromptAgentOutput {
    /// Больше кандидатов не разбираем: вывод из одних скобок иначе даёт
    /// квадратичный перебор на мегабайте. Пропущенный ответ честнее зависания.
    private static let candidateLimit = 64

    public static func firstJSONObject(in text: String) -> Data? {
        let bytes = Array(text.utf8)
        var index = 0
        var attempts = 0
        while index < bytes.count, attempts < candidateLimit {
            guard bytes[index] == UInt8(ascii: "{") else {
                index += 1
                continue
            }
            attempts += 1
            if let end = matchingBrace(bytes, from: index) {
                let candidate = Data(bytes[index...end])
                if (try? JSONSerialization.jsonObject(with: candidate)) != nil {
                    return candidate
                }
            }
            index += 1
        }
        return nil
    }

    private static func matchingBrace(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var insideString = false
        var escaped = false
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if insideString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    insideString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                insideString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}
