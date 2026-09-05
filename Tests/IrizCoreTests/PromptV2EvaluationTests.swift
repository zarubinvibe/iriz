import Foundation
import Testing

@testable import IrizPrompt

@Suite("Prompt v2: независимая синтетическая приёмка")
struct PromptV2EvaluationTests {
    @Test func corpusCoversRequiredSpeechAndTaskClasses() {
        let covered = Set(evaluationCorpus.flatMap(\.coverage))

        #expect(covered == Set(EvaluationCoverage.allCases))
        #expect(Set(evaluationCorpus.map(\.id)).count == evaluationCorpus.count)
        #expect(evaluationCorpus.allSatisfy { !$0.raw.isEmpty })
    }

    @Test func v1BaselineAndV2PreserveFidelitySafetyAndBrevity() throws {
        for fixture in evaluationCorpus {
            let pair = try renderPair(fixture)
            let repeatedPair = try renderPair(fixture)

            #expect(pair.v1 == repeatedPair.v1, "v1 недетерминирован для \(fixture.id)")
            #expect(pair.v2 == repeatedPair.v2, "v2 недетерминирован для \(fixture.id)")
            #expect(pair.v1.hasPrefix(fixture.spec.goal.text), "v1 потерял исполняемую цель в \(fixture.id)")
            #expect(pair.v2.hasPrefix(fixture.spec.goal.text), "v2 потерял исполняемую цель в \(fixture.id)")

            for token in fixture.rawTokens {
                #expect(
                    fixture.raw.localizedCaseInsensitiveContains(token),
                    "Контрольного токена нет в синтетическом сырье \(fixture.id): \(token)"
                )
                #expect(
                    pair.v1.localizedCaseInsensitiveContains(token),
                    "v1 потерял факт/отрицание/число \(fixture.id): \(token)"
                )
                #expect(
                    pair.v2.localizedCaseInsensitiveContains(token),
                    "v2 потерял факт/отрицание/число \(fixture.id): \(token)"
                )
            }

            for constraint in fixture.spec.constraints {
                #expect(pair.v1.contains(constraint.text), "v1 потерял ограничение \(fixture.id)")
                #expect(pair.v2.contains(constraint.text), "v2 потерял ограничение \(fixture.id)")
            }
            for forbidden in fixture.forbiddenFragments {
                #expect(!pair.v1.localizedCaseInsensitiveContains(forbidden), "v1 добавил запрещённое в \(fixture.id)")
                #expect(!pair.v2.localizedCaseInsensitiveContains(forbidden), "v2 добавил запрещённое в \(fixture.id)")
            }

            let outcome = PromptOutcomeVerifier().verify(
                spec: fixture.spec,
                prompt: pair.v2,
                raw: fixture.raw,
                profile: fixture.profile
            )
            #expect(outcome.isAcceptable, "v2 нарушил outcome-инвариант \(fixture.id): \(outcome.issues)")
            #expect(
                pair.v2.count <= max(320, fixture.raw.count * 6),
                "v2 раздул короткий запрос \(fixture.id)"
            )
        }
    }

    @Test func v2ProducesRepresentativeDownstreamReadyInstructions() throws {
        for fixture in evaluationCorpus {
            let prompt = try renderPair(fixture).v2
            for signal in fixture.downstreamSignals {
                #expect(prompt.contains(signal), "v2 не готов для downstream-кейса \(fixture.id): \(signal)")
            }

            if fixture.spec.taskKind == .passthrough {
                #expect(prompt == fixture.spec.goal.text, "Короткая команда не должна обрастать шаблоном")
            }
            if fixture.spec.modules.contains(.orderedSteps) {
                #expect(prompt.contains("сохрани их порядок"), "Потерян порядок шагов в \(fixture.id)")
            }
            if fixture.spec.modules.contains(.grounding) {
                #expect(prompt.contains("факты от предположений"), "Потерян grounding в \(fixture.id)")
            }
            if fixture.spec.modules.contains(.actionBoundaries) {
                #expect(prompt.contains("Внешние и необратимые действия"), "Потеряна граница действий в \(fixture.id)")
            }
        }
    }

    @Test func discoverableContextAndBlockingChoiceStayDistinctAcrossProfiles() throws {
        for fixture in evaluationCorpus where fixture.spec.ambiguities.contains(where: { $0.kind == .discoverable }) {
            let prompt = try renderPair(fixture).v2

            #expect(prompt.contains("Сначала проверь"), "Discoverable-контекст не направлен на поиск в \(fixture.id)")
            #expect(!prompt.contains("Нужно уточнить до выполнения"), "Discoverable ошибочно блокирует \(fixture.id)")
            #expect(!prompt.contains("?"), "Discoverable превращён в вопрос в \(fixture.id)")

            switch fixture.profile {
            case .codex:
                #expect(prompt.contains("workspace"))
                #expect(prompt.contains("Git"))
                #expect(prompt.contains("незавершённые изменения"))
            case .generic:
                #expect(prompt.contains("доступные материалы"))
                #expect(prompt.contains("если контекста нет"))
                #expect(!prompt.localizedCaseInsensitiveContains("workspace"))
                #expect(!prompt.localizedCaseInsensitiveContains("git"))
                #expect(!prompt.localizedCaseInsensitiveContains("инструмент"))
            }
        }

        let blocking = try #require(evaluationCorpus.first { $0.coverage.contains(.blockingChoice) })
        let blockingPrompt = try renderPair(blocking).v2
        #expect(blocking.spec.status == .needsClarification)
        #expect(blockingPrompt.contains("Нужно уточнить до выполнения"))
        #expect(blockingPrompt.contains("Какой счёт Алексея использовать?"))
    }

    @Test func additionAndCorrectionRemainExplicitAndDifferent() throws {
        let addition = try #require(evaluationCorpus.first { $0.coverage.contains(.addition) })
        let correction = try #require(evaluationCorpus.first { $0.coverage.contains(.correction) })
        let additionPair = try renderPair(addition)
        let correctionPair = try renderPair(correction)

        #expect(!additionPair.v1.contains("Добавка к предыдущему запросу"))
        #expect(additionPair.v2.contains("Добавка к предыдущему запросу"))
        #expect(!correctionPair.v1.contains("Правка предыдущего запроса"))
        #expect(correctionPair.v2.contains("Правка предыдущего запроса"))
        #expect(additionPair.v2 != correctionPair.v2)
    }

    @Test func deterministicBlindPairwiseEvaluationNeverRewardsLostMeaning() throws {
        var v2Wins = Set<String>()

        for (index, fixture) in evaluationCorpus.enumerated() {
            let pair = try renderPair(fixture)
            let rubric = BlindRubric(fixture: fixture)
            let v2Score = BlindMechanicalEvaluator.score(pair.v2, against: rubric)

            #expect(
                v2Score.fidelity == rubric.requiredFacts.count,
                "v2 не может выиграть, потеряв факт/отрицание/число/ограничение: \(fixture.id)"
            )

            var semanticDecisions: [BlindDecision] = []
            var v2Labels: [BlindLabel] = []
            for pass in 0..<2 {
                let trial = BlindTrial.make(
                    v1: pair.v1,
                    v2: pair.v2,
                    swap: (index + pass).isMultiple(of: 2)
                )
                let labelDecision = BlindMechanicalEvaluator.choose(
                    first: trial.first,
                    second: trial.second,
                    against: rubric
                )
                semanticDecisions.append(trial.resolve(labelDecision))
                v2Labels.append(trial.v2Label)
            }

            #expect(v2Labels[0] != v2Labels[1], "A/B-метки не сменились для \(fixture.id)")
            #expect(semanticDecisions[0] == semanticDecisions[1], "Решение зависит от A/B-метки: \(fixture.id)")
            #expect(semanticDecisions[0] != .v1, "v2 проиграл механическую приёмку: \(fixture.id)")

            if semanticDecisions[0] == .v2 {
                v2Wins.insert(fixture.id)
                #expect(v2Score.fidelity == rubric.requiredFacts.count)
                #expect(v2Score.safety == rubric.maximumSafety)
            }
        }

        let requiredAdvantages = Set(evaluationCorpus.filter(\.expectsV2Advantage).map(\.id))
        #expect(requiredAdvantages.isSubset(of: v2Wins), "v2 не улучшил обязательные кейсы: \(requiredAdvantages.subtracting(v2Wins))")
    }
}

private enum EvaluationCoverage: CaseIterable, Hashable {
    case shortCommand
    case fragmentedSpeech
    case selfCorrection
    case negationsAndNumbers
    case dependentSteps
    case coding
    case research
    case writing
    case agentic
    case currentProject
    case thisDesign
    case whereStopped
    case addition
    case correction
    case blockingChoice
    case externalActionProhibition
    case researchThenImplement
    case knownCurrentDesignDefect
    case knownVoiceFeatureDefect
    case codexProfile
    case genericProfile
}

private struct EvaluationCase {
    let id: String
    let coverage: Set<EvaluationCoverage>
    let raw: String
    let spec: PromptSpec
    let profile: PromptRecipientProfile
    let rawTokens: [String]
    let forbiddenFragments: [String]
    let downstreamSignals: [String]
    let usesMarkup: Bool
    let hasPreviousPrompt: Bool
    let expectsV2Advantage: Bool

    init(
        id: String,
        coverage: Set<EvaluationCoverage>,
        raw: String,
        spec: PromptSpec,
        profile: PromptRecipientProfile = .generic,
        rawTokens: [String],
        forbiddenFragments: [String] = [],
        downstreamSignals: [String] = [],
        usesMarkup: Bool = false,
        hasPreviousPrompt: Bool = false,
        expectsV2Advantage: Bool = false
    ) {
        self.id = id
        self.coverage = coverage
        self.raw = raw
        self.spec = spec
        self.profile = profile
        self.rawTokens = rawTokens
        self.forbiddenFragments = forbiddenFragments
        self.downstreamSignals = downstreamSignals
        self.usesMarkup = usesMarkup
        self.hasPreviousPrompt = hasPreviousPrompt
        self.expectsV2Advantage = expectsV2Advantage
    }
}

private struct RenderedPair {
    let v1: String
    let v2: String
}

private func renderPair(_ fixture: EvaluationCase) throws -> RenderedPair {
    let renderer = PromptRenderer()
    if fixture.usesMarkup {
        let markup = PromptEnvelopeBuilder().analyze(
            fixture.raw,
            hasPreviousPrompt: fixture.hasPreviousPrompt
        )
        let date = Date(timeIntervalSince1970: 0)
        return RenderedPair(
            v1: try renderer.render(
                spec: fixture.spec,
                raw: fixture.raw,
                markup: markup,
                date: date
            ).prompt,
            v2: try renderer.renderV2(
                spec: fixture.spec,
                raw: fixture.raw,
                markup: markup,
                profile: fixture.profile,
                date: date
            ).prompt
        )
    }

    return RenderedPair(
        v1: try renderer.render(spec: fixture.spec, raw: fixture.raw).prompt,
        v2: try renderer.renderV2(
            spec: fixture.spec,
            raw: fixture.raw,
            profile: fixture.profile
        ).prompt
    )
}

private struct BlindRubric {
    let goal: String
    let requiredFacts: [String]
    let forbiddenFragments: [String]
    let downstreamSignals: [String]
    let profile: PromptRecipientProfile
    let hasDiscoverableContext: Bool
    let hasBlockingChoice: Bool
    let requiresActionBoundary: Bool
    let modeSignal: String?
    let lengthLimit: Int

    init(fixture: EvaluationCase) {
        let fields = [fixture.spec.goal]
            + fixture.spec.context
            + fixture.spec.requirements
            + fixture.spec.constraints
            + fixture.spec.outputRequirements
            + fixture.spec.acceptance
        goal = fixture.spec.goal.text
        requiredFacts = Array(Set(fields.map(\.text) + fixture.rawTokens)).sorted()
        forbiddenFragments = fixture.forbiddenFragments
        downstreamSignals = fixture.downstreamSignals
        profile = fixture.profile
        hasDiscoverableContext = fixture.spec.ambiguities.contains { $0.kind == .discoverable }
        hasBlockingChoice = fixture.spec.ambiguities.contains { $0.kind == .blockingUserChoice }
        requiresActionBoundary = fixture.spec.modules.contains(.actionBoundaries)
        if fixture.coverage.contains(.addition) {
            modeSignal = "Добавка к предыдущему запросу"
        } else if fixture.coverage.contains(.correction) {
            modeSignal = "Правка предыдущего запроса"
        } else {
            modeSignal = nil
        }
        lengthLimit = max(320, fixture.raw.count * 6)
    }

    var maximumSafety: Int {
        forbiddenFragments.count
            + (requiresActionBoundary ? 1 : 0)
            + (hasBlockingChoice ? 1 : 0)
            + (hasDiscoverableContext ? 1 : 0)
    }
}

private struct BlindScore: Equatable {
    let fidelity: Int
    let actionability: Int
    let contextRecovery: Int
    let brevity: Int
    let safety: Int

    var total: Int { fidelity + actionability + contextRecovery + brevity + safety }
}

private enum BlindMechanicalEvaluator {
    /// Здесь нет литературной или вероятностной оценки: только наблюдаемые строки и границы.
    static func score(_ prompt: String, against rubric: BlindRubric) -> BlindScore {
        let fidelity = rubric.requiredFacts.count {
            prompt.localizedCaseInsensitiveContains($0)
        }
        let actionableBase = prompt.hasPrefix(rubric.goal) ? 1 : 0
        let downstream = rubric.downstreamSignals.count { prompt.contains($0) }
        let mode = rubric.modeSignal.map { prompt.contains($0) ? 1 : 0 } ?? 0

        let contextRecovery: Int
        if rubric.hasDiscoverableContext {
            switch rubric.profile {
            case .codex:
                contextRecovery = prompt.contains("Сначала проверь")
                    && prompt.contains("workspace")
                    && prompt.contains("Git")
                    && !prompt.contains("?") ? 1 : 0
            case .generic:
                contextRecovery = prompt.contains("Сначала проверь")
                    && prompt.contains("доступные материалы")
                    && prompt.contains("если контекста нет")
                    && !prompt.localizedCaseInsensitiveContains("workspace")
                    && !prompt.localizedCaseInsensitiveContains("git") ? 1 : 0
            }
        } else {
            contextRecovery = 1
        }

        var safety = rubric.forbiddenFragments.count {
            !prompt.localizedCaseInsensitiveContains($0)
        }
        if rubric.requiresActionBoundary, prompt.contains("Внешние и необратимые действия") {
            safety += 1
        }
        if rubric.hasBlockingChoice,
           prompt.contains("Нужно уточнить до выполнения"),
           prompt.contains("?") {
            safety += 1
        }
        if rubric.hasDiscoverableContext,
           !prompt.contains("Нужно уточнить до выполнения") {
            safety += 1
        }

        return BlindScore(
            fidelity: fidelity,
            actionability: actionableBase + downstream + mode,
            contextRecovery: contextRecovery,
            brevity: prompt.count <= rubric.lengthLimit ? 1 : 0,
            safety: safety
        )
    }

    static func choose(first: BlindVariant, second: BlindVariant, against rubric: BlindRubric) -> BlindLabelDecision {
        let firstScore = score(first.prompt, against: rubric).total
        let secondScore = score(second.prompt, against: rubric).total
        if firstScore == secondScore { return .tie }
        return firstScore > secondScore ? .first : .second
    }
}

private enum BlindLabel: Equatable {
    case a
    case b
}

private struct BlindVariant {
    let label: BlindLabel
    let prompt: String
}

private enum BlindLabelDecision {
    case first
    case second
    case tie
}

private enum BlindDecision: Equatable {
    case v1
    case v2
    case tie
}

private struct BlindTrial {
    let first: BlindVariant
    let second: BlindVariant
    let v1Label: BlindLabel
    let v2Label: BlindLabel

    static func make(v1: String, v2: String, swap: Bool) -> BlindTrial {
        if swap {
            return BlindTrial(
                first: BlindVariant(label: .a, prompt: v2),
                second: BlindVariant(label: .b, prompt: v1),
                v1Label: .b,
                v2Label: .a
            )
        }
        return BlindTrial(
            first: BlindVariant(label: .a, prompt: v1),
            second: BlindVariant(label: .b, prompt: v2),
            v1Label: .a,
            v2Label: .b
        )
    }

    func resolve(_ decision: BlindLabelDecision) -> BlindDecision {
        let winningLabel: BlindLabel
        switch decision {
        case .first:
            winningLabel = first.label
        case .second:
            winningLabel = second.label
        case .tie:
            return .tie
        }
        return winningLabel == v1Label ? .v1 : .v2
    }
}

private let evaluationCorpus: [EvaluationCase] = [
    EvaluationCase(
        id: "short-command",
        coverage: [.shortCommand, .genericProfile],
        raw: "Проверь орфографию.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .passthrough,
            goal: PromptField(text: "Проверь орфографию.", evidence: "Проверь орфографию.")
        ),
        rawTokens: ["орфографию"]
    ),
    EvaluationCase(
        id: "fragmented-self-correction",
        coverage: [.fragmentedSpeech, .selfCorrection],
        raw: "Так, сделай, сделай таблицу рисков, нет, не таблицу, составь список рисков.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Составь список рисков.", evidence: "составь список рисков"),
            constraints: [PromptField(text: "Не делай таблицу.", evidence: "нет, не таблицу")]
        ),
        rawTokens: ["таблицу", "список рисков"],
        forbiddenFragments: ["сделай, сделай"]
    ),
    EvaluationCase(
        id: "negations-and-numbers",
        coverage: [.negationsAndNumbers],
        raw: "Сравни ровно 3 варианта, не больше 3, и не используй платные источники.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Сравни ровно 3 варианта.", evidence: "Сравни ровно 3 варианта"),
            requirements: [PromptField(text: "Не больше 3 вариантов.", evidence: "не больше 3")],
            constraints: [PromptField(text: "Не используй платные источники.", evidence: "не используй платные источники")]
        ),
        rawTokens: ["ровно 3", "не больше 3", "не используй платные источники"],
        forbiddenFragments: ["4 варианта"]
    ),
    EvaluationCase(
        id: "dependent-steps",
        coverage: [.dependentSteps],
        raw: "Сначала собери требования, затем создай прототип и только после этого запусти тесты.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Создай прототип по собранным требованиям.", evidence: "собери требования, затем создай прототип"),
            requirements: [
                PromptField(text: "Сначала собери требования.", evidence: "Сначала собери требования"),
                PromptField(text: "Затем создай прототип.", evidence: "затем создай прототип"),
                PromptField(text: "После этого запусти тесты.", evidence: "после этого запусти тесты"),
            ],
            modules: [.orderedSteps]
        ),
        rawTokens: ["требования", "прототип", "тесты"],
        downstreamSignals: ["Сначала собери требования.", "После этого запусти тесты."]
    ),
    EvaluationCase(
        id: "coding",
        coverage: [.coding],
        raw: "В Parser.swift исправь разбор пустой строки и добавь тест на этот случай.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: "Исправь разбор пустой строки в Parser.swift.", evidence: "В Parser.swift исправь разбор пустой строки"),
            requirements: [PromptField(text: "Добавь тест на этот случай.", evidence: "добавь тест на этот случай")]
        ),
        rawTokens: ["Parser.swift", "пустой строки"],
        downstreamSignals: ["Добавь тест на этот случай."]
    ),
    EvaluationCase(
        id: "research",
        coverage: [.research],
        raw: "Исследуй официальную документацию API, не используй блоги и приложи ссылки на источники.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .research,
            goal: PromptField(text: "Исследуй официальную документацию API.", evidence: "Исследуй официальную документацию API"),
            constraints: [PromptField(text: "Не используй блоги.", evidence: "не используй блоги")],
            outputRequirements: [PromptField(text: "Приложи ссылки на источники.", evidence: "приложи ссылки на источники")],
            modules: [.grounding]
        ),
        rawTokens: ["официальную документацию API", "не используй блоги", "ссылки на источники"],
        forbiddenFragments: ["социальные сети"],
        downstreamSignals: ["Приложи ссылки на источники."]
    ),
    EvaluationCase(
        id: "writing",
        coverage: [.writing],
        raw: "Напиши короткое приглашение на встречу. Сохрани нейтральный тон.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .writing,
            goal: PromptField(text: "Напиши короткое приглашение на встречу.", evidence: "Напиши короткое приглашение на встречу"),
            constraints: [PromptField(text: "Сохрани нейтральный тон.", evidence: "Сохрани нейтральный тон.")]
        ),
        rawTokens: ["короткое приглашение", "нейтральный тон"],
        forbiddenFragments: ["торжественный тон"],
        downstreamSignals: ["Сохрани нейтральный тон."]
    ),
    EvaluationCase(
        id: "agentic-local-only",
        coverage: [.agentic],
        raw: "Открой локальный журнал, запусти проверку и сохрани отчёт рядом, ничего наружу не отправляй.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .agentic,
            goal: PromptField(text: "Проверь локальный журнал и сохрани отчёт рядом.", evidence: "Открой локальный журнал, запусти проверку и сохрани отчёт рядом"),
            requirements: [
                PromptField(text: "Открой локальный журнал.", evidence: "Открой локальный журнал"),
                PromptField(text: "Запусти проверку.", evidence: "запусти проверку"),
            ],
            constraints: [PromptField(text: "Ничего наружу не отправляй.", evidence: "ничего наружу не отправляй")],
            modules: [.orderedSteps, .actionBoundaries]
        ),
        rawTokens: ["локальный журнал", "отчёт", "не отправляй"],
        forbiddenFragments: ["Опубликуй"],
        downstreamSignals: ["Открой локальный журнал.", "Запусти проверку."]
    ),
    EvaluationCase(
        id: "current-project-codex",
        coverage: [.currentProject, .codexProfile],
        raw: "В текущем проекте исправь оставшуюся ошибку сборки.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: "Исправь оставшуюся ошибку сборки в текущем проекте.", evidence: "В текущем проекте исправь оставшуюся ошибку сборки"),
            ambiguities: [PromptAmbiguity(
                description: "Определи, какой проект сейчас открыт?",
                evidence: "текущем проекте",
                kind: .discoverable
            )]
        ),
        profile: .codex,
        rawTokens: ["текущем проекте", "ошибку сборки"],
        downstreamSignals: ["Исправь оставшуюся ошибку сборки"],
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "known-current-design-codex",
        coverage: [.thisDesign, .knownCurrentDesignDefect, .codexProfile],
        raw: "Доработать текущий дизайн в тёмной теме, сохранив сетку.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Доработать текущий дизайн в тёмной теме, сохранив сетку.", evidence: "Доработать текущий дизайн в тёмной теме, сохранив сетку."),
            ambiguities: [PromptAmbiguity(
                description: "Определи текущий дизайн по контексту проекта?",
                evidence: "текущий дизайн",
                kind: .discoverable
            )]
        ),
        profile: .codex,
        rawTokens: ["текущий дизайн", "тёмной теме", "сетку"],
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "this-design-generic",
        coverage: [.thisDesign, .genericProfile],
        raw: "Доработай этот дизайн в светлой теме, сохрани сетку.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Доработай этот дизайн в светлой теме, сохрани сетку.", evidence: "Доработай этот дизайн в светлой теме, сохрани сетку."),
            ambiguities: [PromptAmbiguity(
                description: "Определи, к какому дизайну относится запрос?",
                evidence: "этот дизайн",
                kind: .discoverable
            )]
        ),
        rawTokens: ["этот дизайн", "светлой теме", "сетку"],
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "where-stopped-codex",
        coverage: [.whereStopped, .codexProfile],
        raw: "Продолжи то, где остановились, и доведи работу до тестов.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: "Продолжи то, где остановились, и доведи работу до тестов.", evidence: "Продолжи то, где остановились, и доведи работу до тестов."),
            ambiguities: [PromptAmbiguity(
                description: "Найди последний незавершённый шаг текущей работы?",
                evidence: "где остановились",
                kind: .discoverable
            )]
        ),
        profile: .codex,
        rawTokens: ["то, где остановились", "до тестов"],
        downstreamSignals: ["доведи работу до тестов"],
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "known-current-voice-feature",
        coverage: [.knownVoiceFeatureDefect, .coding, .codexProfile],
        raw: "Довести текущую голосовую фичу до рабочего состояния: найти реализацию, исправить ошибки и запустить тесты.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: "Довести текущую голосовую фичу до рабочего состояния.", evidence: "Довести текущую голосовую фичу до рабочего состояния"),
            requirements: [
                PromptField(text: "Найти текущую реализацию.", evidence: "найти реализацию"),
                PromptField(text: "Исправить ошибки.", evidence: "исправить ошибки"),
                PromptField(text: "Запустить тесты.", evidence: "запустить тесты"),
            ],
            acceptance: [PromptField(text: "Голосовая фича работает, тесты проходят.", evidence: "до рабочего состояния")],
            ambiguities: [PromptAmbiguity(
                description: "Найди реализацию текущей голосовой фичи в проекте?",
                evidence: "текущую голосовую фичу",
                kind: .discoverable
            )],
            modules: [.orderedSteps, .finalCheck]
        ),
        profile: .codex,
        rawTokens: ["текущую голосовую фичу", "исправить ошибки", "запустить тесты"],
        downstreamSignals: ["Найти текущую реализацию.", "Запустить тесты.", "Голосовая фича работает"],
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "addition",
        coverage: [.addition],
        raw: "Добавь к предыдущему запросу требование проверить ссылки.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Добавь к предыдущему запросу требование проверить ссылки.", evidence: "Добавь к предыдущему запросу требование проверить ссылки."),
            requirements: [PromptField(text: "Проверь ссылки.", evidence: "проверить ссылки")]
        ),
        rawTokens: ["предыдущему запросу", "проверить ссылки"],
        downstreamSignals: ["Проверь ссылки."],
        usesMarkup: true,
        hasPreviousPrompt: true,
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "correction",
        coverage: [.correction],
        raw: "Нет, в предыдущем запросе замени два отчёта на три отчёта.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "В предыдущем запросе замени два отчёта на три отчёта.", evidence: "Нет, в предыдущем запросе замени два отчёта на три отчёта."),
            requirements: [PromptField(text: "Замени два отчёта на три отчёта.", evidence: "замени два отчёта на три отчёта")]
        ),
        rawTokens: ["два отчёта", "три отчёта"],
        forbiddenFragments: ["четыре отчёта"],
        downstreamSignals: ["Замени два отчёта на три отчёта."],
        usesMarkup: true,
        hasPreviousPrompt: true,
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "blocking-money-choice",
        coverage: [.blockingChoice, .agentic],
        raw: "Переведи 5000 рублей на счёт Алексея после подтверждения.",
        spec: PromptSpec(
            status: .needsClarification,
            taskKind: .agentic,
            goal: PromptField(text: "Переведи 5000 рублей на счёт Алексея после подтверждения.", evidence: "Переведи 5000 рублей на счёт Алексея после подтверждения."),
            ambiguities: [PromptAmbiguity(
                description: "Какой счёт Алексея использовать",
                evidence: "счёт Алексея",
                kind: .blockingUserChoice
            )],
            modules: [.actionBoundaries]
        ),
        rawTokens: ["5000", "Алексея", "после подтверждения"],
        forbiddenFragments: ["Выполни перевод немедленно"],
        expectsV2Advantage: true
    ),
    EvaluationCase(
        id: "external-action-prohibited",
        coverage: [.externalActionProhibition, .agentic],
        raw: "Подготовь письмо поставщику, но не отправляй его без моего подтверждения.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .agentic,
            goal: PromptField(text: "Подготовь письмо поставщику.", evidence: "Подготовь письмо поставщику"),
            constraints: [PromptField(
                text: "Не отправляй письмо без моего подтверждения.",
                evidence: "не отправляй его без моего подтверждения"
            )],
            modules: [.actionBoundaries]
        ),
        rawTokens: ["поставщику", "не отправляй", "без моего подтверждения"],
        forbiddenFragments: ["Отправь письмо."],
        downstreamSignals: ["Не отправляй письмо без моего подтверждения."]
    ),
    EvaluationCase(
        id: "research-then-implement",
        coverage: [.researchThenImplement, .dependentSteps, .coding, .research],
        raw: "Сначала изучи официальное описание API, потом реализуй адаптер и проверь его тестами.",
        spec: PromptSpec(
            status: .ready,
            taskKind: .coding,
            goal: PromptField(text: "Реализуй адаптер и проверь его тестами.", evidence: "реализуй адаптер и проверь его тестами"),
            requirements: [
                PromptField(text: "Сначала изучи официальное описание API.", evidence: "Сначала изучи официальное описание API"),
                PromptField(text: "Потом реализуй адаптер.", evidence: "потом реализуй адаптер"),
                PromptField(text: "После реализации проверь адаптер тестами.", evidence: "проверь его тестами"),
            ],
            acceptance: [PromptField(text: "Тесты адаптера проходят.", evidence: "проверь его тестами")],
            modules: [.orderedSteps, .grounding, .finalCheck]
        ),
        rawTokens: ["официальное описание API", "потом реализуй адаптер", "тестами"],
        forbiddenFragments: ["Сначала реализуй"],
        downstreamSignals: ["Сначала изучи официальное описание API.", "Потом реализуй адаптер.", "Тесты адаптера проходят."]
    ),
]
