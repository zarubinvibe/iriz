// Охранный тест: рядом с сырьём появился inserted.txt (то, что фактически
// ушло в поле). Перечислитель промпт-режима не имеет права это заметить.
//
// Почему это охраняется тестом, а не комментарием: перечислитель собирает
// каталоги ПО НАЛИЧИЮ raw.txt и берёт максимум ПО ИМЕНИ каталога
// (PromptEnvelope.swift, latestDictation). Оба правила легко сломать
// «улучшением», а промпт обязан собираться из сырья — из ответа ASR байт в
// байт, а не из текста, уже прошедшего словарь замен и суффикс вставки.
import Foundation
import IrizPrompt
import Testing

@Suite("Промпт-режим и inserted.txt")
struct PromptEnvelopeInsertedTextTests {

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeDictation(in root: URL,
                               label: String,
                               raw: String,
                               inserted: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: dir.appendingPathComponent("raw.txt"))
        if let inserted {
            try Data(inserted.utf8).write(to: dir.appendingPathComponent("inserted.txt"))
        }
        return dir
    }

    /// Конверт собирается из raw.txt. Вставленный текст в него не попадает.
    @Test func конвертСобираетсяИзСырьяАНеИзВставленного() throws {
        try withRoot { root in
            let dir = try makeDictation(in: root,
                                        label: "2026-08-04_22-32-50",
                                        raw: "напиши в смолток про кодекс",
                                        inserted: "Напиши в smltlk про Codex ")

            let envelope = try PromptEnvelopeBuilder().build(for: dir)
            #expect(envelope.contains("напиши в смолток про кодекс"))
            #expect(!envelope.contains("Напиши в smltlk про Codex"))
            #expect(!envelope.contains("inserted.txt"))
        }
    }

    /// Появление inserted.txt не меняет выбор последней надиктовки: ключ — имя
    /// каталога. Макет повторяет импорт: на диск папки ложатся «свежие
    /// первыми», поэтому по mtime свежей оказалась бы самая старая.
    @Test func выборПоследнейНеЗависитОтВставленного() throws {
        try withRoot { root in
            _ = try makeDictation(in: root, label: "2026-08-04_22-32-50",
                                  raw: "самая свежая")
            _ = try makeDictation(in: root, label: "2026-08-04_22-32-00",
                                  raw: "средняя", inserted: "средняя вставленная")
            _ = try makeDictation(in: root, label: "2026-08-04_22-31-11",
                                  raw: "самая старая", inserted: "старая вставленная")

            let latest = try PromptEnvelopeBuilder().latestDictation(in: root)
            #expect(latest.lastPathComponent == "2026-08-04_22-32-50")
        }
    }

    /// Каталог с одним inserted.txt и без сырья надиктовкой не считается —
    /// иначе перечислитель предложил бы собрать промпт из того, чего нет.
    @Test func каталогБезСырьяНеСчитаетсяНадиктовкой() throws {
        try withRoot { root in
            _ = try makeDictation(in: root, label: "2026-08-04_10-00-00", raw: "есть сырьё")
            let orphan = root.appendingPathComponent("2026-08-04_23-59-59", isDirectory: true)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("только вставленное".utf8)
                .write(to: orphan.appendingPathComponent("inserted.txt"))

            let latest = try PromptEnvelopeBuilder().latestDictation(in: root)
            #expect(latest.lastPathComponent == "2026-08-04_10-00-00")
        }
    }

    /// Разметка конверта считается по сырью: словарь замен на неё не влияет,
    /// потому что до неё не доходит.
    @Test func разметкаСчитаетсяПоСырью() throws {
        try withRoot { root in
            let dir = try makeDictation(in: root,
                                        label: "2026-08-04_10-00-00",
                                        raw: "напиши в кодекс",
                                        inserted: "напиши в Codex")
            let envelope = try PromptEnvelopeBuilder().build(for: dir)
            // Термин «кодекс» найден в СЫРЬЕ и предложен к сверке. Если бы
            // конверт собирался из вставленного, сверять было бы нечего.
            #expect(envelope.contains("кодекс"))
            #expect(envelope.contains("Codex"))
        }
    }
}
