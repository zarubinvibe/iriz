import Foundation
import Testing

@testable import IrizPrompt

@Suite("PromptRenderer v1: синтетический baseline-корпус")
struct PromptRendererV1BaselineCorpusTests {
    @Test func корпусПолонИФиксируетДетерминированныйРендер() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/prompt-renderer-v1-baseline.json")
        let cases = try JSONDecoder().decode(
            [BaselineCase].self,
            from: Data(contentsOf: fixtureURL)
        )

        #expect(!cases.isEmpty)
        #expect(Set(cases.map(\.id)).count == cases.count, "ID кейсов должны быть уникальны")
        #expect(
            Set(cases.flatMap(\.categories)) == Set(BaselineCategory.allCases),
            "Корпус должен покрывать каждую обязательную категорию"
        )
        #expect(
            Set(cases.compactMap(\.expected.failureStage)) == Set(FailureStage.allCases),
            "Корпус должен покрывать generator/verifier/insertion failures"
        )

        let validator = PromptSpecValidator()
        let renderer = PromptRenderer()
        let verifier = PromptVerifier()

        for fixture in cases {
            #expect(!fixture.id.isEmpty)
            #expect(!fixture.raw.isEmpty)
            #expect(!fixture.categories.isEmpty)
            #expect(
                fixture.categories.contains(.generatorFailure)
                    == (fixture.expected.failureStage == .generator)
            )
            #expect(
                fixture.categories.contains(.verifierFailure)
                    == (fixture.expected.failureStage == .verifier)
            )
            #expect(
                fixture.categories.contains(.insertionFailure)
                    == (fixture.expected.failureStage == .insertion)
            )
            #expect(
                !fixture.expected.contains.isEmpty
                    || !fixture.expected.notContains.isEmpty
                    || !fixture.expected.preservedTokens.isEmpty
                    || fixture.expected.ambiguity != .none
                    || fixture.expected.failureStage != nil,
                "У кейса \(fixture.id) нет ожидаемого инварианта"
            )
            checkAmbiguity(fixture)

            if fixture.expected.failureStage == .generator {
                #expect(fixture.v1Prompt == nil, "Нерендеримый кейс не должен иметь snapshot")
                do {
                    try validator.validate(fixture.spec, raw: fixture.raw)
                    Issue.record("Кейс \(fixture.id) должен упасть на generator/validator")
                } catch is PromptSpecValidationError {
                    // Ожидаемый fail-closed исход генератора.
                } catch {
                    Issue.record("Кейс \(fixture.id) упал с неверной ошибкой: \(error)")
                }
                continue
            }

            try validator.validate(fixture.spec, raw: fixture.raw)
            let generation = try renderer.render(spec: fixture.spec, raw: fixture.raw)
            let snapshot = try #require(
                fixture.v1Prompt,
                "У renderable-кейса \(fixture.id) обязан быть точный v1 snapshot"
            )
            #expect(generation.prompt == snapshot, "Изменился v1 snapshot кейса \(fixture.id)")

            for text in fixture.expected.contains {
                #expect(generation.prompt.contains(text), "Кейс \(fixture.id) потерял: \(text)")
            }
            for text in fixture.expected.notContains {
                #expect(!generation.prompt.contains(text), "Кейс \(fixture.id) добавил: \(text)")
            }
            for token in fixture.expected.preservedTokens {
                #expect(fixture.raw.contains(token), "Токена \(token) нет в сырье кейса \(fixture.id)")
                #expect(generation.prompt.contains(token), "Кейс \(fixture.id) не сохранил токен: \(token)")
            }

            let report = verifier.verify(raw: fixture.raw, prompt: generation.artifact)
            if fixture.expected.failureStage == .verifier {
                #expect(report.hasBlockingFailure, "Кейс \(fixture.id) должен упасть на verifier")
            } else {
                #expect(!report.hasBlockingFailure, "Кейс \(fixture.id) упал раньше ожидаемой стадии")
            }
        }
    }

    private func checkAmbiguity(_ fixture: BaselineCase) {
        switch fixture.expected.ambiguity {
        case .none:
            #expect(fixture.spec.ambiguities.isEmpty, "Лишняя неясность в кейсе \(fixture.id)")
            #expect(fixture.spec.status == .ready)
        case .nonBlocking:
            #expect(!fixture.spec.ambiguities.isEmpty)
            #expect(fixture.spec.ambiguities.allSatisfy { !$0.blocking })
            #expect(fixture.spec.status == .ready)
        case .blocking:
            let hasBlockingAmbiguity = fixture.spec.ambiguities.contains { $0.blocking }
            #expect(hasBlockingAmbiguity)
            #expect(fixture.spec.status == .needsClarification)
        }
    }
}

private struct BaselineCase: Decodable {
    let id: String
    let categories: [BaselineCategory]
    let raw: String
    let spec: PromptSpec
    let expected: BaselineExpected
    let v1Prompt: String?
}

private struct BaselineExpected: Decodable {
    let contains: [String]
    let notContains: [String]
    let preservedTokens: [String]
    let ambiguity: AmbiguityExpectation
    let failureStage: FailureStage?
}

private enum AmbiguityExpectation: String, Decodable {
    case none
    case nonBlocking
    case blocking
}

private enum FailureStage: String, Decodable, CaseIterable {
    case generator
    case verifier
    case insertion
}

private enum BaselineCategory: String, Decodable, CaseIterable {
    case shortClearCommand = "short-clear-command"
    case fragmentedSpeech = "fragmented-speech"
    case repetition
    case selfCorrection = "self-correction"
    case negations
    case exactNumbers = "exact-numbers"
    case dependentSteps = "dependent-steps"
    case coding
    case research
    case writing
    case agentic
    case currentProject = "current-project"
    case currentVoiceFeature = "current-voice-feature"
    case thisDesign = "this-design"
    case whereStopped = "where-stopped"
    case additionToPreviousPrompt = "addition-to-previous-prompt"
    case correctionOfPreviousPrompt = "correction-of-previous-prompt"
    case blockingAmbiguity = "blocking-ambiguity"
    case externalActionProhibition = "external-action-prohibition"
    case researchBeforeImplementation = "research-before-implementation"
    case generatorFailure = "generator-failure"
    case verifierFailure = "verifier-failure"
    case insertionFailure = "insertion-failure"
}
