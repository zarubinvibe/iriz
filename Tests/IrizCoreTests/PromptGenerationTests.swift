import Foundation
import Testing
@testable import IrizPrompt

@Suite("Второй слой: проектирование промпта")
struct PromptGenerationTests {
    @Test func контрактРазделяетДваСлояИЗапрещаетКаргоКульт() throws {
        let text = PromptGenerationContract.instructions
        #expect(text.contains("Слой 1 — сохранение смысла"))
        #expect(text.contains("Слой 2 — проектирование"))
        #expect(text.contains("мега-шаблон"))
        #expect(text.contains("декоративную роль"))
        #expect(text.contains("Few-shot"))
        #expect(text.contains("XML"))
        #expect(text.contains("Chain-of-Thought"))
        #expect(text.contains("самокритика без лимита"))
        #expect(text.contains("магические фразы"))

        let schemaObject = try JSONSerialization.jsonObject(with: PromptGenerationContract.outputSchemaData)
        #expect(schemaObject is [String: Any])

        let raw = "Напиши короткий ответ."
        let markup = PromptEnvelopeBuilder().analyze(raw)
        let request = PromptGenerationContract().request(raw: raw, markup: markup)
        #expect(request.contains(PromptGenerationContract.version))
        #expect(request.contains(PromptGenerationContract.outputSchema))
        #expect(request.contains(raw))
        #expect(request.contains("ДЕТЕРМИНИРОВАННАЯ РАЗМЕТКА"))
    }

    @Test func схемаНеИспользуетНеподдерживаемыйUniqueItems() {
        #expect(!PromptGenerationContract.outputSchema.contains(#""uniqueItems""#))
    }

    @Test func валидаторПоПрежнемуОтвергаетПовторМодуля() {
        let raw = "Проверь резервную копию."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw),
            modules: [.finalCheck, .finalCheck]
        )

        do {
            try PromptSpecValidator().validate(spec, raw: raw)
            Issue.record("Повтор модуля должен быть отклонён локальным валидатором")
        } catch let error as PromptSpecValidationError {
            #expect(error == .duplicateModule(.finalCheck))
        } catch {
            Issue.record("Неверный тип ошибки: \(error)")
        }
    }

    @Test func валидаторОтвергаетНедословнуюЦитату() {
        let raw = "Напиши отчёт."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .writing,
            goal: PromptField(text: "Напиши отчёт.", evidence: "напиши отчёт")
        )

        do {
            try PromptSpecValidator().validate(spec, raw: raw)
            Issue.record("Недословная evidence должна быть отклонена")
        } catch let error as PromptSpecValidationError {
            #expect(error == .evidenceNotVerbatim(path: "goal", evidence: "напиши отчёт"))
        } catch {
            Issue.record("Неверный тип ошибки: \(error)")
        }
    }

    @Test func валидаторНеПропускаетВыдуманноеЧисло() {
        let raw = "Собери два отчёта."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Собери три отчёта.", evidence: raw)
        )

        do {
            try PromptSpecValidator().validate(spec, raw: raw)
            Issue.record("Выдуманное число должно быть отклонено")
        } catch let error as PromptSpecValidationError {
            #expect(error == .unsupportedLiteral(path: "goal", literal: "три"))
        } catch {
            Issue.record("Неверный тип ошибки: \(error)")
        }
    }

    @Test func сквознойВходНеРаздувается() throws {
        let raw = "Йоу, как дела?"
        let spec = PromptSpec(
            status: .ready,
            taskKind: .passthrough,
            goal: PromptField(text: raw, evidence: raw)
        )

        let result = try PromptRenderer().render(spec: spec, raw: raw)
        #expect(result.prompt == raw)
        #expect(!result.prompt.contains("Требования"))
        #expect(!result.prompt.contains("Рабочий протокол"))
    }

    @Test func пустыеРазделыНеПечатаются() throws {
        let raw = "Проверь текст."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: raw, evidence: raw)
        )

        let prompt = try PromptRenderer().render(spec: spec, raw: raw).prompt
        #expect(prompt == raw)
        #expect(!prompt.contains("Контекст"))
        #expect(!prompt.contains("Ограничения"))
        #expect(!prompt.contains("Критерии готовности"))
    }

    @Test func модулиИсследованияИДействийПечатаютсяТолькоПоСигналу() throws {
        let researchRaw = "Исследуй официальные источники."
        let base = PromptSpec(
            status: .ready,
            taskKind: .research,
            goal: PromptField(text: researchRaw, evidence: researchRaw)
        )
        let plain = try PromptRenderer().render(spec: base, raw: researchRaw).prompt
        #expect(!plain.contains("факты от предположений"))

        let grounded = PromptSpec(
            status: .ready,
            taskKind: .research,
            goal: base.goal,
            modules: [.grounding]
        )
        let groundedPrompt = try PromptRenderer().render(spec: grounded, raw: researchRaw).prompt
        #expect(groundedPrompt.contains("факты от предположений"))

        let actionRaw = "Опубликуй готовый отчёт."
        let actionSpec = PromptSpec(
            status: .ready,
            taskKind: .agentic,
            goal: PromptField(text: actionRaw, evidence: actionRaw),
            modules: [.actionBoundaries]
        )
        let actionPrompt = try PromptRenderer().render(spec: actionSpec, raw: actionRaw).prompt
        #expect(actionPrompt.contains("Внешние и необратимые действия"))
    }

    @Test func агентБезГраницДействийНеПроходит() {
        let raw = "Опубликуй готовый отчёт."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .agentic,
            goal: PromptField(text: raw, evidence: raw)
        )

        do {
            try PromptSpecValidator().validate(spec, raw: raw)
            Issue.record("Агентная задача без границ действий должна быть отклонена")
        } catch let error as PromptSpecValidationError {
            #expect(error == .missingRequiredModule(.actionBoundaries))
        } catch {
            Issue.record("Неверный тип ошибки: \(error)")
        }
    }

    @Test func артефактПроходитМашинныеБлокирующиеВорота() throws {
        let raw = "Исследуй официальную документацию Codex, сравни два подхода, не используй блоги и дай таблицу с источниками."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .research,
            goal: PromptField(
                text: "Исследуй официальную документацию Codex.",
                evidence: "Исследуй официальную документацию Codex"
            ),
            requirements: [PromptField(text: "Сравни два подхода.", evidence: "сравни два подхода")],
            constraints: [PromptField(text: "Не используй блоги.", evidence: "не используй блоги")],
            outputRequirements: [PromptField(text: "Дай таблицу с источниками.", evidence: "дай таблицу с источниками")],
            acceptance: [PromptField(text: "Результат содержит сравнение, таблицу и источники.", evidence: "сравни два подхода, не используй блоги и дай таблицу с источниками")],
            modules: [.grounding, .finalCheck]
        )

        // Ворота проверяют боевой путь. Наследный v1-рендерер в проде не вызывается
        // (единственный вызов — CodexPromptGenerator через renderV2), поэтому судить
        // артефакт надо тем же рендерером, который реально уходит получателю.
        let markup = PromptEnvelopeBuilder().analyze(raw)
        let result = try PromptRenderer().renderV2(
            spec: spec,
            raw: raw,
            markup: markup,
            profile: .codex,
            date: Date(timeIntervalSince1970: 0)
        )
        let report = PromptVerifier().verify(raw: raw, prompt: result.artifact)

        #expect(result.artifact.contains("ИСПОЛНЯЕМЫЙ ПРОМПТ"))
        #expect(result.artifact.contains("ГРАНИЦЫ ДЕЙСТВИЙ"))
        #expect(result.artifact.contains("КОНТРАКТ: \(PromptGenerationContract.version)"))
        #expect(!report.hasBlockingFailure)
    }
}
