import Foundation
import Testing
@testable import IrizPrompt

@Suite("Prompt core v2")
struct PromptCoreV2Tests {
    @Test func discoverableContextMarkersAreDetectedBeforeGeneration() {
        for raw in [
            "Доработай этот дизайн.",
            "Исправь ошибку в текущем проекте.",
            "Продолжи то, на чём остановились.",
        ] {
            #expect(!PromptEnvelopeBuilder().analyze(raw).deictics.isEmpty)
        }
    }

    @Test func contractRequiresAmbiguityKindAndCallerProfile() throws {
        #expect(PromptGenerationContract.version == "prompt-spec-v2")
        #expect(PromptGenerationContract.outputSchema.contains(#""kind""#))
        #expect(PromptGenerationContract.outputSchema.contains("blockingUserChoice"))
        #expect(!PromptGenerationContract.outputSchema.contains(#""blocking""#))

        let raw = "Исправь ошибку."
        let markup = PromptEnvelopeBuilder().analyze(raw)
        let codexRequest = PromptGenerationContract().request(raw: raw, markup: markup, profile: .codex)
        let genericRequest = PromptGenerationContract().request(raw: raw, markup: markup)

        #expect(codexRequest.contains("ПРОФИЛЬ ПОЛУЧАТЕЛЯ: codex"))
        #expect(genericRequest.contains("ПРОФИЛЬ ПОЛУЧАТЕЛЯ: generic"))
        #expect(codexRequest.contains("Не включай профиль"))
        #expect(codexRequest.contains("workspace, Git, документацию и инструменты"))
        #expect(codexRequest.contains("Дейктики о репозитории и текущей сессии классифицируй как discoverable"))
        #expect(genericRequest.contains("Опирайся только на переданные материалы"))
        #expect(!genericRequest.localizedCaseInsensitiveContains("workspace"))
        #expect(!genericRequest.localizedCaseInsensitiveContains("git"))
        #expect(codexRequest.contains("Режим addition/correction из детерминированной разметки — авторитетный"))
    }

    @Test func legacyRendererNeverClaimsV2Contract() throws {
        let raw = "Проверь текст."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )
        let markup = PromptEnvelopeBuilder().analyze(raw)

        let legacy = try PromptRenderer().render(
            spec: spec,
            raw: raw,
            markup: markup,
            date: Date(timeIntervalSince1970: 0)
        )
        let v2 = try PromptRenderer().renderV2(
            spec: spec,
            raw: raw,
            markup: markup,
            profile: .codex,
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(legacy.artifact.contains("КОНТРАКТ: prompt-spec-v1"))
        #expect(!legacy.artifact.contains("КОНТРАКТ: prompt-spec-v2"))
        #expect(v2.artifact.contains("КОНТРАКТ: prompt-spec-v2"))
    }

    @Test func ambiguityDecodesLegacyBlockingButEncodesV2Kind() throws {
        let legacy = Data(#"{"description":"Неясно","evidence":"это","blocking":true}"#.utf8)
        let ambiguity = try JSONDecoder().decode(PromptAmbiguity.self, from: legacy)
        #expect(ambiguity.kind == .blockingUserChoice)
        #expect(ambiguity.blocking)

        let encoded = String(decoding: try JSONEncoder().encode(ambiguity), as: UTF8.self)
        #expect(encoded.contains(#""kind":"blockingUserChoice""#))
        #expect(!encoded.contains(#""blocking""#))

        let compatible = PromptAmbiguity(description: "Можно допустить", evidence: "это", blocking: false)
        #expect(compatible.kind == .safeAssumption)
        #expect(!compatible.blocking)
    }

    @Test func statusDependsOnlyOnBlockingUserChoice() {
        let raw = "Исправь текущую ошибку проекта."
        let discoverable = PromptSpec(
            status: .needsClarification,
            taskKind: .coding,
            goal: PromptField(text: raw, evidence: raw),
            ambiguities: [PromptAmbiguity(
                description: "Какой файл сломан?",
                evidence: "текущую ошибку",
                kind: .discoverable
            )]
        )

        do {
            try PromptSpecValidator().validate(discoverable, raw: raw)
            Issue.record("Discoverable ambiguity must not force clarification")
        } catch let error as PromptSpecValidationError {
            #expect(error == .inconsistentStatus)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let blocking = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw),
            ambiguities: [PromptAmbiguity(
                description: "Какой вариант выбрать?",
                evidence: "текущую ошибку",
                kind: .blockingUserChoice
            )]
        )
        #expect(throws: PromptSpecValidationError.inconsistentStatus) {
            try PromptSpecValidator().validate(blocking, raw: raw)
        }
    }

    @Test func codexDiscoversContextWithoutBlockingQuestion() throws {
        let raw = "Исправь текущую ошибку проекта."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: raw, evidence: raw),
            ambiguities: [PromptAmbiguity(
                description: "Какой файл сломан?",
                evidence: "текущую ошибку",
                kind: .discoverable
            )]
        )

        let result = try PromptRenderer().renderV2(spec: spec, raw: raw, profile: .codex)
        #expect(result.prompt.contains("workspace"))
        #expect(result.prompt.contains("Git"))
        #expect(result.prompt.contains("документац"))
        #expect(result.prompt.contains("незавершённые изменения"))
        #expect(!result.prompt.contains("Нужно уточнить до выполнения"))
        #expect(!result.prompt.contains("?"))
        #expect(PromptOutcomeVerifier().verify(spec: spec, prompt: result.prompt, raw: raw, profile: .codex).isAcceptable)
    }

    @Test func genericUsesOnlyAvailableMaterialsAndConditionalContextRequest() throws {
        let raw = "Исправь текущую ошибку проекта."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: raw, evidence: raw),
            ambiguities: [PromptAmbiguity(
                description: "Какой файл сломан?",
                evidence: "текущую ошибку",
                kind: .discoverable
            )]
        )

        let result = try PromptRenderer().renderV2(spec: spec, raw: raw, profile: .generic)
        #expect(result.prompt.contains("доступные материалы"))
        #expect(result.prompt.contains("если контекста нет"))
        #expect(!result.prompt.localizedCaseInsensitiveContains("workspace"))
        #expect(!result.prompt.localizedCaseInsensitiveContains("git"))
        #expect(PromptOutcomeVerifier().verify(spec: spec, prompt: result.prompt, raw: raw, profile: .generic).isAcceptable)
    }

    @Test func assumptionsAndBlockingChoicesGetDifferentSections() throws {
        let assumptionsRaw = "Собери краткий отчёт в обычном формате."
        let assumptionSpec = PromptSpec(
            status: .ready,
            taskKind: .writing,
            goal: PromptField(text: assumptionsRaw, evidence: assumptionsRaw),
            ambiguities: [PromptAmbiguity(
                description: "Используй Markdown как обычный формат.",
                evidence: "обычном формате",
                kind: .safeAssumption
            )]
        )
        let assumptionPrompt = try PromptRenderer().renderV2(
            spec: assumptionSpec,
            raw: assumptionsRaw,
            profile: .generic
        ).prompt
        #expect(assumptionPrompt.contains("Допущения"))
        #expect(!assumptionPrompt.contains("Нужно уточнить"))

        let blockingRaw = "Подготовь отчёт для выбранного клиента."
        let blockingSpec = PromptSpec(
            status: .needsClarification,
            taskKind: .writing,
            goal: PromptField(text: blockingRaw, evidence: blockingRaw),
            ambiguities: [PromptAmbiguity(
                description: "Для какого клиента готовить отчёт",
                evidence: "выбранного клиента",
                kind: .blockingUserChoice
            )]
        )
        let blockingPrompt = try PromptRenderer().renderV2(
            spec: blockingSpec,
            raw: blockingRaw,
            profile: .generic
        ).prompt
        #expect(blockingPrompt.contains("Нужно уточнить до выполнения"))
        #expect(blockingPrompt.contains("?"))
        #expect(PromptOutcomeVerifier().verify(
            spec: blockingSpec,
            prompt: blockingPrompt,
            raw: blockingRaw,
            profile: .generic
        ).isAcceptable)
    }

    @Test func v2DropsExactDuplicatesAndKeepsPassthroughShort() throws {
        let raw = "Проверь текст."
        let duplicate = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw),
            requirements: [PromptField(text: raw, evidence: raw)]
        )
        let prompt = try PromptRenderer().renderV2(spec: duplicate, raw: raw, profile: .generic).prompt
        #expect(prompt.components(separatedBy: raw).count - 1 == 1)
        #expect(!prompt.contains("Требования"))

        let passthrough = PromptSpec(
            status: .ready,
            taskKind: .passthrough,
            goal: PromptField(text: "Йоу, как дела?", evidence: "Йоу, как дела?")
        )
        let short = try PromptRenderer().renderV2(
            spec: passthrough,
            raw: "Йоу, как дела?",
            profile: .codex
        ).prompt
        #expect(short == "Йоу, как дела?")
    }

    @Test func markupKeepsAdditionAndCorrectionDistinct() throws {
        let additionRaw = "Добавь новый раздел."
        let additionSpec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: additionRaw, evidence: additionRaw)
        )
        let addition = try PromptRenderer().renderV2(
            spec: additionSpec,
            raw: additionRaw,
            markup: PromptEnvelopeBuilder().analyze(additionRaw, hasPreviousPrompt: true),
            profile: .codex,
            date: Date(timeIntervalSince1970: 0)
        ).prompt

        let correctionRaw = "Нет, исправь то, что было до этого."
        let correctionSpec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: correctionRaw, evidence: correctionRaw)
        )
        let correction = try PromptRenderer().renderV2(
            spec: correctionSpec,
            raw: correctionRaw,
            markup: PromptEnvelopeBuilder().analyze(correctionRaw, hasPreviousPrompt: true),
            profile: .codex,
            date: Date(timeIntervalSince1970: 0)
        ).prompt

        #expect(addition.contains("Добавка к предыдущему запросу"))
        #expect(correction.contains("Правка предыдущего запроса"))
        #expect(addition != correction)
    }

    @Test func outcomeVerifierReportsMachineCheckableFailures() {
        let raw = "Подготовь отчёт."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .writing,
            goal: PromptField(text: raw, evidence: raw),
            outputRequirements: [PromptField(text: "Дай таблицу.", evidence: "отчёт")]
        )
        let missing = PromptOutcomeVerifier().verify(
            spec: spec,
            prompt: "Подготовь отчёт.",
            raw: raw,
            profile: .generic
        )
        #expect(missing.issues.contains(.missingExplicitField(path: "outputRequirements[0]")))

        let leak = PromptOutcomeVerifier().verify(
            spec: PromptSpec(status: .ready, taskKind: .general, goal: PromptField(text: raw, evidence: raw)),
            prompt: raw + "\n\nПроверь workspace и Git через tools.",
            raw: raw,
            profile: .generic
        )
        #expect(leak.issues.contains(.unsupportedProfileReference))

        let verbose = PromptOutcomeVerifier().verify(
            spec: PromptSpec(status: .ready, taskKind: .general, goal: PromptField(text: raw, evidence: raw)),
            prompt: raw + String(repeating: " лишний", count: 500),
            raw: raw,
            profile: .generic
        )
        #expect(verbose.issues.contains(.excessiveLength))
    }

    @Test func discoverableAndRealBlockingChoiceCanCoexist() throws {
        let raw = "Исправь текущий файл и выбери целевой аккаунт."
        let spec = PromptSpec(
            status: .needsClarification,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw),
            ambiguities: [
                PromptAmbiguity(
                    description: "Определи текущий файл?",
                    evidence: "текущий файл",
                    kind: .discoverable
                ),
                PromptAmbiguity(
                    description: "Какой целевой аккаунт выбрать",
                    evidence: "целевой аккаунт",
                    kind: .blockingUserChoice
                ),
            ]
        )
        let prompt = try PromptRenderer().renderV2(spec: spec, raw: raw, profile: .codex).prompt

        #expect(PromptOutcomeVerifier().verify(spec: spec, prompt: prompt, raw: raw, profile: .codex).isAcceptable)
    }

    @Test func outcomeVerifierRequiresEveryAmbiguityDescription() {
        let raw = "Исправь текущий файл."
        let goal = PromptField(text: raw, evidence: raw)
        let cases: [(PromptAmbiguityKind, PromptSpecStatus, String)] = [
            (.discoverable, .ready, raw + "\n\nСначала проверь\n- Проверь доступные материалы."),
            (.safeAssumption, .ready, raw),
            (.blockingUserChoice, .needsClarification, raw + "\n\nНужно уточнить до выполнения\n- Что выбрать?"),
        ]

        for (kind, status, prompt) in cases {
            let spec = PromptSpec(
                status: status,
                taskKind: .general,
                goal: goal,
                ambiguities: [PromptAmbiguity(
                    description: "Определи, какой файл изменять?",
                    evidence: "текущий файл",
                    kind: kind
                )]
            )
            let report = PromptOutcomeVerifier().verify(
                spec: spec,
                prompt: prompt,
                raw: raw,
                profile: .generic
            )
            #expect(report.issues.contains(.missingAmbiguity(path: "ambiguities[0]")))
        }
    }

    @Test func brevityUsesRawLengthInsteadOfInflatedSpec() {
        let raw = "Сделай отчёт."
        let inflated = String(repeating: "Лишнее уточнение. ", count: 40)
        let spec = PromptSpec(
            status: .ready,
            taskKind: .writing,
            goal: PromptField(text: raw, evidence: raw),
            requirements: [PromptField(text: inflated, evidence: raw)]
        )
        let report = PromptOutcomeVerifier().verify(
            spec: spec,
            prompt: raw + "\n\nТребования\n- " + inflated,
            raw: raw,
            profile: .generic
        )

        #expect(report.issues.contains(.excessiveLength))
    }
}
