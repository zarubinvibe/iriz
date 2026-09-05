import Darwin
import Foundation
@testable import IrizPrompt
import Testing

@Suite("Codex CLI runner", .serialized)
struct CodexPromptGeneratorTests {
    @Test func invocationPlanIsLockedDown() {
        let root = URL(fileURLWithPath: "/private/tmp/runner-test", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let input = root.appendingPathComponent("input.txt")
        let schema = root.appendingPathComponent("schema.json")
        let result = root.appendingPathComponent("result.json")
        let isolatedHome = root.appendingPathComponent("home", isDirectory: true)
        let isolatedCodexHome = isolatedHome.appendingPathComponent(".codex", isDirectory: true)
        let executable = URL(fileURLWithPath: "/opt/tools/codex")
        let raw = "секретная расшифровка"
        let plan = CodexPromptGenerator.makeInvocationPlan(
            executableURL: executable,
            workDirectoryURL: work,
            inputURL: input,
            schemaURL: schema,
            resultURL: result,
            isolatedHomeURL: isolatedHome,
            isolatedCodexHomeURL: isolatedCodexHome,
            temporaryDirectoryURL: root,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/test",
                "TMPDIR": "/private/tmp",
                "LANG": "ru_RU.UTF-8",
                "SAMPLE_SECRET": "must-not-leak",
            ]
        )

        #expect(plan.executableURL == executable)
        #expect(plan.currentDirectoryURL == work)
        #expect(plan.standardInputURL == input)
        #expect(Array(plan.arguments.prefix(3)) == ["-a", "never", "exec"])
        for flag in [
            "--ignore-user-config",
            "--ignore-rules",
            "--ephemeral",
            "--skip-git-repo-check",
        ] {
            #expect(plan.arguments.contains(flag))
        }
        #expect(hasPair("--sandbox", "read-only", in: plan.arguments))
        #expect(hasPair("-C", work.path, in: plan.arguments))
        #expect(hasPair("--output-schema", schema.path, in: plan.arguments))
        #expect(hasPair("--output-last-message", result.path, in: plan.arguments))
        #expect(hasPair("--color", "never", in: plan.arguments))
        #expect(hasPair("-c", #"web_search="disabled""#, in: plan.arguments))
        #expect(hasPair("-c", #"history.persistence="none""#, in: plan.arguments))

        for feature in [
            "shell_tool", "unified_exec", "code_mode_host", "apps", "plugins",
            "browser_use", "browser_use_external", "browser_use_full_cdp_access",
            "computer_use", "image_generation", "multi_agent", "hooks", "skill_search",
        ] {
            #expect(hasPair("--disable", feature, in: plan.arguments))
        }

        #expect(!plan.arguments.contains(input.path))
        #expect(!plan.arguments.contains(raw))
        #expect(!plan.arguments.contains(FileManager.default.currentDirectoryPath))
        #expect(plan.environment["SAMPLE_SECRET"] == nil)
        #expect(Set(plan.environment.keys) == Set(["PATH", "HOME", "CODEX_HOME", "TMPDIR", "LANG"]))
        #expect(plan.environment["HOME"] == isolatedHome.path)
        #expect(plan.environment["CODEX_HOME"] == isolatedCodexHome.path)
        #expect(plan.environment["TMPDIR"] == root.path)
    }

    @Test func decoderRejectsInvalidJSONAndSchema() throws {
        for data in [Data("not json".utf8), Data("{}".utf8)] {
            do {
                _ = try CodexPromptGenerator.decodeResult(data)
                Issue.record("Декодер принял некорректный ответ")
            } catch let error as CodexPromptGeneratorError {
                #expect(error == .invalidResultJSON)
            }
        }
    }

    @Test func fakeCLIReadsStdinAndProducesGeneration() async throws {
        let raw = "Собери отчёт."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let fake = try makeFakeExecutable(
            body: fakeResultScript(json: json, requiredInput: raw, checkPrivateFiles: true)
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let generation = try await fakeGenerator(fake)
            .generate(
                rawTranscript: raw,
                markup: PromptEnvelopeBuilder().analyze(raw),
                date: Date(timeIntervalSince1970: 0)
            )

        #expect(generation.spec == spec)
        #expect(generation.prompt == raw)
        #expect(generation.artifact.contains("1970-01-01"))
        let marker = fake.directory.appendingPathComponent("temp-root")
        let temporaryRoot = String(decoding: try Data(contentsOf: marker), as: UTF8.self)
        #expect(!FileManager.default.fileExists(atPath: temporaryRoot))
    }

    @Test func passesRecipientProfileIntoRequestAndUsesV2Renderer() async throws {
        let raw = "Доделай текущую фичу."
        let ambiguity = "Текущую фичу найди в репозитории?"
        let spec = PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: raw, evidence: raw),
            ambiguities: [
                PromptAmbiguity(description: ambiguity, evidence: raw, kind: .discoverable),
            ]
        )
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let fake = try makeFakeExecutable(body: """
        result=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then shift; result="$1"; fi
          shift
        done
        input=$(/bin/cat)
        case "$input" in *"ПРОФИЛЬ ПОЛУЧАТЕЛЯ: codex"*) ;; *) exit 61 ;; esac
        /usr/bin/printf '%s' '\(json)' > "$result"
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let generation = try await fakeGenerator(fake).generate(
            rawTranscript: raw,
            markup: PromptEnvelopeBuilder().analyze(raw),
            profile: .codex,
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(generation.prompt.contains("Сначала проверь"))
        #expect(generation.prompt.contains("workspace"))
        #expect(!generation.prompt.contains("Неясности"))
        #expect(generation.artifact.contains("ПРОФИЛЬ: codex"))
    }

    @Test func executableSymlinkToRegularFileIsAccepted() async throws {
        let raw = "Собери отчёт."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let fake = try makeFakeExecutable(body: fakeResultScript(json: json))
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let symlink = fake.directory.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: fake.executable.lastPathComponent
        )

        let generation = try await fakeGenerator((fake.directory, symlink))
            .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.prompt == raw)
    }

    @Test func rootWorkingDirectoryAllowsPrivateTemporaryDirectory() throws {
        let directory = try CodexPromptGenerator.makeTemporaryDirectory(
            currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func onlyOutputLastMessageIsDecoded() async throws {
        let raw = "Собери отчёт."
        let valid = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let validJSON = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        let fake = try makeFakeExecutable(body: """
        result=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then shift; result="$1"; fi
          shift
        done
        /bin/cat >/dev/null
        /usr/bin/printf '%s' '\(validJSON)'
        /usr/bin/printf '%s' 'not json' > "$result"
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        do {
            _ = try await fakeGenerator(fake)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Runner прочитал stdout вместо output-last-message")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidResultJSON)
        }
    }

    @Test func isolatedHomeCopiesOnlyAuthentication() async throws {
        let raw = "Собери отчёт."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let fake = try makeFakeExecutable(body: """
        result=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then shift; result="$1"; fi
          shift
        done
        /bin/cat >/dev/null
        [ "$HOME" != "${0%/*}/source-home" ] || exit 41
        [ "$CODEX_HOME" != "${0%/*}/source-home/.codex" ] || exit 42
        [ "$(/usr/bin/stat -f '%Lp' "$HOME")" = "700" ] || exit 43
        [ "$(/usr/bin/stat -f '%Lp' "$CODEX_HOME")" = "700" ] || exit 44
        [ "$(/usr/bin/stat -f '%Lp' "$CODEX_HOME/auth.json")" = "600" ] || exit 45
        [ "$(/bin/cat "$CODEX_HOME/auth.json")" = '{"auth":"test-only"}' ] || exit 46
        [ ! -e "$CODEX_HOME/agents" ] || exit 47
        [ ! -e "$CODEX_HOME/skills" ] || exit 48
        [ ! -e "$HOME/.agents" ] || exit 49
        /usr/bin/printf '%s' '\(json)' > "$result"
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let sourceHome = fake.directory.appendingPathComponent("source-home", isDirectory: true)
        let sourceCodexHome = sourceHome.appendingPathComponent(".codex", isDirectory: true)
        let sourceAgents = sourceCodexHome.appendingPathComponent("agents", isDirectory: true)
        let sourceSkills = sourceCodexHome.appendingPathComponent("skills", isDirectory: true)
        let userSkills = sourceHome.appendingPathComponent(".agents/skills", isDirectory: true)
        for directory in [sourceAgents, sourceSkills, userSkills] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        let authURL = sourceCodexHome.appendingPathComponent("auth.json")
        try Data(#"{"auth":"test-only"}"#.utf8).write(to: authURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: authURL.path
        )
        try Data("private agent".utf8).write(to: sourceAgents.appendingPathComponent("private.toml"))
        try Data("private skill".utf8).write(to: sourceSkills.appendingPathComponent("SKILL.md"))
        try Data("private user skill".utf8).write(to: userSkills.appendingPathComponent("SKILL.md"))

        let generation = try await CodexPromptGenerator(
            executableURL: fake.executable,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": sourceHome.path,
                "TMPDIR": FileManager.default.temporaryDirectory.path,
                "LANG": "ru_RU.UTF-8",
            ]
        ).generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.prompt == raw)
    }

    @Test func semanticValidationRejectsUnsupportedSpec() async throws {
        let raw = "Собери отчёт."
        let invalid = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Удали базу", evidence: "этого нет в сырье")
        )
        let json = String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self)
        let fake = try makeFakeExecutable(body: fakeResultScript(json: json))
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        do {
            _ = try await fakeGenerator(fake)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Runner принял PromptSpec без дословной опоры")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidPromptSpec)
        }
    }

    @Test func retriesOnceAfterInvalidPromptSpecWithReminderOnlyOnSecondAttempt() async throws {
        let raw = "Retry this task"
        let invalid = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Unsupported", evidence: "Unsupported")
        )
        let valid = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let fake = try makeFakeExecutable(
            body: retryResultScript(
                firstJSON: String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self),
                secondJSON: String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
            )
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let generation = try await fakeGenerator(fake)
            .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.spec == valid)
    }

    @Test func retriesOnceAfterInvalidResultJSON() async throws {
        let raw = "Repair schema task"
        let valid = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let fake = try makeFakeExecutable(
            body: retryResultScript(
                firstJSON: "not-json",
                secondJSON: String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
            )
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let generation = try await fakeGenerator(fake)
            .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.spec == valid)
        let attempts = try String(contentsOf: fake.directory.appendingPathComponent("attempts"))
        #expect(attempts == "2")
    }

    @Test func repairsInvalidOutcomeExactlyOnce() async throws {
        let raw = "Сделай задачу."
        let invalidOutcome = verboseSpec(raw: raw)
        let valid = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let fake = try makeFakeExecutable(
            body: retryResultScript(
                firstJSON: String(decoding: try JSONEncoder().encode(invalidOutcome), as: UTF8.self),
                secondJSON: String(decoding: try JSONEncoder().encode(valid), as: UTF8.self),
                secondInputMustContain: "Repair the rendered prompt outcome"
            )
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let generation = try await fakeGenerator(fake)
            .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.spec == valid)
        let attempts = try String(contentsOf: fake.directory.appendingPathComponent("attempts"))
        #expect(attempts == "2")
    }

    @Test func stopsAfterSecondInvalidOutcome() async throws {
        let raw = "Сделай задачу."
        let invalidOutcome = verboseSpec(raw: raw)
        let json = String(decoding: try JSONEncoder().encode(invalidOutcome), as: UTF8.self)
        let fake = try makeFakeExecutable(
            body: retryResultScript(
                firstJSON: json,
                secondJSON: json,
                secondInputMustContain: "Repair the rendered prompt outcome"
            )
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        do {
            _ = try await fakeGenerator(fake)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Ожидалась ошибка итогового промпта")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidPromptOutcome)
            #expect(error.errorDescription == "Готовый промпт не прошёл проверку качества.")
            #expect(!(error.errorDescription ?? "").contains(raw))
        }

        let attempts = try String(contentsOf: fake.directory.appendingPathComponent("attempts"))
        #expect(attempts == "2")
    }

    @Test func promptSpecAndOutcomeFailuresShareTwoAttemptBudget() async throws {
        let raw = "Сделай задачу."
        let invalidSpec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Выдуманная задача", evidence: "нет в сырье")
        )
        let invalidOutcome = verboseSpec(raw: raw)
        let fake = try makeFakeExecutable(
            body: retryResultScript(
                firstJSON: String(decoding: try JSONEncoder().encode(invalidSpec), as: UTF8.self),
                secondJSON: String(decoding: try JSONEncoder().encode(invalidOutcome), as: UTF8.self)
            )
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        do {
            _ = try await fakeGenerator(fake)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Ожидалось исчерпание общего бюджета")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidPromptOutcome)
        }

        let attempts = try String(contentsOf: fake.directory.appendingPathComponent("attempts"))
        #expect(attempts == "2")
    }

    @Test func stopsAfterSecondInvalidPromptSpec() async throws {
        let raw = "Retry this task"
        let invalid = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Unsupported", evidence: "Unsupported")
        )
        let json = String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self)
        let fake = try makeFakeExecutable(body: retryResultScript(firstJSON: json, secondJSON: json))
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        do {
            _ = try await fakeGenerator(fake)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Expected invalid prompt spec")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .invalidPromptSpec)
        }

        let attempts = try String(contentsOf: fake.directory.appendingPathComponent("attempts"))
        #expect(attempts == "2")
    }

    @Test func nonZeroExitIncludesOnlyCappedStderr() async throws {
        let fake = try makeFakeExecutable(body: """
        /bin/cat >/dev/null
        i=0
        while [ "$i" -lt 800 ]; do
          printf '%s' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2
          i=$((i + 1))
        done
        exit 23
        """)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let raw = "Собери отчёт."
        do {
            _ = try await fakeGenerator(fake)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Runner принял ненулевой exit")
        } catch let error as CodexPromptGeneratorError {
            guard case let .nonZeroExit(status, stderr) = error else {
                Issue.record("Неверная ошибка: \(error)")
                return
            }
            #expect(status == 23)
            #expect(!stderr.isEmpty)
            #expect(stderr.utf8.count <= 64 * 1024)
        }
    }

    @Test func timeoutTerminatesFakeProcess() async throws {
        let fake = try makeFakeExecutable(body: """
        marker=${0%/*}/process.pid
        printf '%s' "$$" > "$marker"
        exec /usr/bin/perl -e '$SIG{INT} = $SIG{TERM} = "IGNORE"; sleep 1 while 1'
        """)
        let marker = fake.directory.appendingPathComponent("process.pid")
        defer {
            if let pid = processID(at: marker), Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: fake.directory)
        }
        let raw = "Собери отчёт."
        let started = Date()

        do {
            _ = try await fakeGenerator(fake, timeoutSeconds: 1)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Runner не сработал по таймауту")
        } catch let error as CodexPromptGeneratorError {
            #expect(error == .timedOut)
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 5)
        let pid = try #require(processID(at: marker))
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func retriesOnceAfterTimeout() async throws {
        let fake = try makeFakeExecutable(
            body: """
            result=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output-last-message" ]; then shift; result="$1"; fi
              shift
            done
            /bin/cat >/dev/null
            case "$result" in
              */attempt-0/result.json) exec /bin/sleep 60 ;;
              */attempt-1/result.json) /usr/bin/printf '%s' '{"status":"ready","taskKind":"general","goal":{"text":"Timeout task","evidence":"Timeout task"},"context":[],"requirements":[],"constraints":[],"outputRequirements":[],"acceptance":[],"ambiguities":[],"modules":[]}' > "$result" ;;
              *) exit 73 ;;
            esac
            """
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let raw = "Timeout task"

        // Порог 3 с, а не 1: первая попытка спит минуту и провалит его при
        // любой нагрузке, а ВТОРОЙ нужен запас на запуск процесса. На пороге 1
        // проба падала на занятой машине - зазор съедал сам запуск оболочки.
        let generation = try await fakeGenerator(fake, timeoutSeconds: 3)
            .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.prompt == raw)
    }

    @Test func timedOutAttemptCannotOverwriteRetryResult() async throws {
        let fake = try makeFakeExecutable(
            body: """
            result=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output-last-message" ]; then shift; result="$1"; fi
              shift
            done
            /bin/cat >/dev/null
            /usr/bin/printf '%s\n' "$result" >> "${0%/*}/result-paths"
            attempts="${0%/*}/attempts"
            count=$(cat "$attempts" 2>/dev/null || printf '0')
            count=$((count + 1))
            printf '%s' "$count" > "$attempts"
            case "$count" in
              1)
                (trap '' HUP INT TERM; /bin/sleep 5; /usr/bin/printf '%s' 'stale' > "$result"; /usr/bin/printf '%s' 'yes' > "${0%/*}/stale-wrote") &
                exec /bin/sleep 60
                ;;
              2)
                /usr/bin/printf '%s' '{"status":"ready","taskKind":"general","goal":{"text":"Fresh retry","evidence":"Fresh retry"},"context":[],"requirements":[],"constraints":[],"outputRequirements":[],"acceptance":[],"ambiguities":[],"modules":[]}' > "$result"
                /bin/sleep 3
                ;;
              *) exit 73 ;;
            esac
            """
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let raw = "Fresh retry"

        // Времена разведены с запасом. Раньше устаревшая запись приходила
        // через 0,1 с после снятия первой попытки и должна была попасть в
        // трёхсекундное окно второй - зазор в одну десятую секунды не
        // переживает занятую машину. Теперь: попытка снимается на 4 с,
        // устаревшая запись приходит на 5-й, вторая попытка идёт 3 с, то есть
        // окно шире зазора в тридцать раз.
        let generation = try await fakeGenerator(fake, timeoutSeconds: 4)
            .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))

        #expect(generation.prompt == raw)
        let attempts = try String(contentsOf: fake.directory.appendingPathComponent("attempts"))
        #expect(attempts == "2")
        let resultPaths = try String(
            contentsOf: fake.directory.appendingPathComponent("result-paths")
        ).split(separator: "\n").map(String.init)
        #expect(resultPaths.count == 2)
        if resultPaths.count == 2 {
            #expect(resultPaths[0] != resultPaths[1])
        }
        let staleWriterURL = fake.directory.appendingPathComponent("stale-wrote")
        var staleWriter = ""
        for _ in 0..<50 where staleWriter != "yes" {
            staleWriter = (try? String(contentsOf: staleWriterURL)) ?? ""
            if staleWriter != "yes" {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(staleWriter == "yes")
    }

    @Test func inheritedStderrDoesNotHangRunner() async throws {
        let fake = try makeFakeExecutable(body: """
        marker=${0%/*}/child.pid
        /bin/sleep 10 &
        printf '%s' "$!" > "$marker"
        exit 17
        """)
        let marker = fake.directory.appendingPathComponent("child.pid")
        defer {
            if let data = try? Data(contentsOf: marker),
               let text = String(data: data, encoding: .utf8),
               let pid = Int32(text) {
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: fake.directory)
        }

        let raw = "Собери отчёт."
        let started = Date()
        do {
            _ = try await fakeGenerator(fake)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
            Issue.record("Runner принял ненулевой exit")
        } catch let error as CodexPromptGeneratorError {
            guard case let .nonZeroExit(status, _) = error else {
                Issue.record("Неверная ошибка: \(error)")
                return
            }
            #expect(status == 17)
        }
        #expect(Date().timeIntervalSince(started) < 5)
        guard let data = try? Data(contentsOf: marker),
              let text = String(data: data, encoding: .utf8),
              let childPID = Int32(text) else {
            Issue.record("Фальшивый CLI не записал PID потомка")
            return
        }
        #expect(Darwin.kill(childPID, 0) == 0)
    }

    @Test func cancellationTerminatesFakeProcess() async throws {
        let fake = try makeFakeExecutable(body: """
        marker=${0%/*}/process.pid
        printf '%s' "$$" > "$marker"
        exec /bin/sleep 5
        """)
        let marker = fake.directory.appendingPathComponent("process.pid")
        defer {
            if let pid = processID(at: marker), Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: fake.directory)
        }
        let raw = "Собери отчёт."
        let task = Task {
            try await fakeGenerator(fake, timeoutSeconds: 10)
                .generate(rawTranscript: raw, markup: PromptEnvelopeBuilder().analyze(raw))
        }
        for _ in 0..<100 where processID(at: marker) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(processID(at: marker))
        let cancelledAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Runner проигнорировал отмену Task")
        } catch is CancellationError {
            // Ожидаемый путь.
        }
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    private func hasPair(_ first: String, _ second: String, in arguments: [String]) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { $0 == first && $1 == second }
    }

    private func processID(at url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Int32(text)
    }

    private func fakeGenerator(
        _ fake: (directory: URL, executable: URL),
        timeoutSeconds: TimeInterval = 90
    ) -> CodexPromptGenerator {
        CodexPromptGenerator(
            executableURL: fake.executable,
            timeoutSeconds: timeoutSeconds,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": fake.directory.appendingPathComponent("source-home", isDirectory: true).path,
                "TMPDIR": FileManager.default.temporaryDirectory.path,
                "LANG": "ru_RU.UTF-8",
            ]
        )
    }

    private func verboseSpec(raw: String) -> PromptSpec {
        PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw),
            requirements: [
                PromptField(
                    text: String(repeating: "Подробное требование ", count: 24),
                    evidence: raw
                ),
            ]
        )
    }

    private func makeFakeExecutable(body: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-fake-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let executable = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }

    private func fakeResultScript(
        json: String,
        requiredInput: String? = nil,
        checkPrivateFiles: Bool = false
    ) -> String {
        """
        result=""
        schema=""
        work=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output-last-message) shift; result="$1" ;;
            --output-schema) shift; schema="$1" ;;
            -C) shift; work="$1" ;;
          esac
          shift
        done
        input=$(/bin/cat)
        \(requiredInput.map { "case \"$input\" in *\"\($0)\"*) ;; *) exit 31 ;; esac" } ?? ":")
        \(checkPrivateFiles ? """
        root=${result%/*}
        [ "$(/bin/pwd -P)" = "$(cd "$work" && /bin/pwd -P)" ] || exit 32
        [ -z "$(/bin/ls -A "$work")" ] || exit 33
        [ "$(/usr/bin/stat -f '%Lp' "$root")" = "700" ] || exit 34
        [ "$(/usr/bin/stat -f '%Lp' "$work")" = "700" ] || exit 35
        [ "$(/usr/bin/stat -f '%Lp' "$schema")" = "600" ] || exit 36
        [ "$(/usr/bin/stat -f '%Lp' "$root/input.txt")" = "600" ] || exit 37
        [ "$(/usr/bin/stat -f '%Lp' "$result")" = "600" ] || exit 38
        [ "$HOME" = "$root/home" ] || exit 39
        [ "$CODEX_HOME" = "$root/home/.codex" ] || exit 40
        [ "$TMPDIR" = "$root" ] || exit 41
        [ "$(/usr/bin/stat -f '%Lp' "$HOME")" = "700" ] || exit 42
        [ "$(/usr/bin/stat -f '%Lp' "$CODEX_HOME")" = "700" ] || exit 43
        [ ! -e "$CODEX_HOME/agents" ] || exit 44
        [ ! -e "$CODEX_HOME/skills" ] || exit 45
        [ ! -e "$HOME/.agents" ] || exit 46
        printf '%s' "$root" > "${0%/*}/temp-root"
        """ : ":")
        /usr/bin/printf '%s' '\(json)' > "$result"
        """
    }

    private func retryResultScript(
        firstJSON: String,
        secondJSON: String,
        secondInputMustContain: String = "Repair the JSON prompt specification"
    ) -> String {
        """
        #!/bin/sh
        result=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then shift; result="$1"; fi
          shift
        done
        input=$(/bin/cat)
        attempts="${0%/*}/attempts"
        count=$(cat "$attempts" 2>/dev/null || printf '0')
        count=$((count + 1))
        printf '%s' "$count" > "$attempts"
        case "$count" in
          1)
            case "$input" in *"\(secondInputMustContain)"*) exit 70 ;; esac
            /usr/bin/printf '%s' '\(firstJSON)' > "$result"
            ;;
          2)
            case "$input" in *"\(secondInputMustContain)"*) ;; *) exit 71 ;; esac
            /usr/bin/printf '%s' '\(secondJSON)' > "$result"
            ;;
          *) exit 72 ;;
        esac
        """
    }
}
