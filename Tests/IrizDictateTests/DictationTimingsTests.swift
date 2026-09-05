// Тесты таймингов токенов распознавателя.
//
// Проверяется ровно то, ради чего они сохраняются: данные доезжают до диска
// в форме, по которой БУДУЩАЯ фича сможет померить паузы, — и при этом сырьё
// остаётся байт в байт. Сам разрез абзацев здесь не проверяется: его нет.
//
// Живого распознавателя под `swift test` нет, поэтому тайминги подаются
// руками — как их отдаёт FluidAudio: кусками слов с «▁» на границе.
import Foundation
import Testing

@testable import IrizDictate

private func withTimingsRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("smltlk-timings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

/// Три токена с паузой 1,4 с посередине — та самая улика, ради которой всё.
private let сЗаметнойПаузой: [DictationTokenTiming] = [
    DictationTokenTiming(token: "▁Уважаемый", start: 0.10, end: 0.62, confidence: 0.94),
    DictationTokenTiming(token: "▁суд", start: 0.62, end: 0.90, confidence: 0.97),
    DictationTokenTiming(token: "▁Далее", start: 2.30, end: 2.75, confidence: 0.88),
]

@Suite("Тайминги токенов: форма данных")
struct DictationTimingsShapeTests {

    /// Санитайзер на входе, а не на чтении: один NaN из декодера не имеет
    /// права обесценить весь файл.
    @Test func нефинитныеЗначенияНеПопадаютВДокумент() {
        let timing = DictationTokenTiming(token: "▁да",
                                          start: .nan,
                                          end: .infinity,
                                          confidence: .nan)
        #expect(timing.start == 0)
        #expect(timing.end == 0)
        #expect(timing.confidence == 0)
    }

    @Test func отрицательноеВремяПодтягиваетсяКНулюАКонецКНачалу() {
        let timing = DictationTokenTiming(token: "▁нет",
                                          start: -3,
                                          end: -9,
                                          confidence: 1.7)
        #expect(timing.start == 0)
        #expect(timing.end == 0)
        #expect(timing.confidence == 1)
    }

    @Test func порядокТокеновСохраняетсяКакОтдалРаспознаватель() {
        let document = DictationTimings(audioSeconds: 2.9, tokens: сЗаметнойПаузой)
        #expect(document.tokens.map(\.token) == ["▁Уважаемый", "▁суд", "▁Далее"])
        #expect(document.schemaVersion == DictationTimings.currentSchemaVersion)
    }

    @Test func документБезТокеновСчитаетсяПустым() {
        #expect(DictationTimings(audioSeconds: 5, tokens: []).isEmpty)
        #expect(!DictationTimings(audioSeconds: 5, tokens: сЗаметнойПаузой).isEmpty)
    }

    /// Формат на диске обязан пережить чтение через полгода другой фичей.
    @Test func круговойРейсЧерезJSONНеТеряетНичего() throws {
        let document = DictationTimings(audioSeconds: 2.9, tokens: сЗаметнойПаузой)
        let restored = try DictationTimings.decoded(from: document.encoded())
        #expect(restored == document)
    }

    /// Кириллица в файле — читаемая, а не \u04xx: файл смотрят глазами.
    @Test func кириллицаВФайлеОстаётсяКириллицей() throws {
        let json = String(decoding: try DictationTimings(audioSeconds: 1,
                                                         tokens: сЗаметнойПаузой).encoded(),
                          as: UTF8.self)
        #expect(json.contains("▁Уважаемый"))
        #expect(!json.contains("\\u04"))
        #expect(json.contains("\"schemaVersion\" : 1"))
    }

    /// СМЫСЛ ВСЕЙ ЗАТЕИ (FEATURES.md §3): по сохранённому файлу пауза между
    /// токенами считается арифметикой. Разрез абзацев здесь НЕ делается —
    /// проверяется только то, что мерить теперь есть чем.
    @Test func паузаМеждуТокенамиВычислимаПоСохранённомуФайлу() throws {
        let restored = try DictationTimings.decoded(
            from: DictationTimings(audioSeconds: 2.9, tokens: сЗаметнойПаузой).encoded()
        )
        let pauses = zip(restored.tokens, restored.tokens.dropFirst())
            .map { $1.start - $0.end }
        #expect(pauses.count == 2)
        #expect(abs(pauses[0]) < 0.001)
        #expect(abs(pauses[1] - 1.4) < 0.001)
    }
}

@Suite("Тайминги токенов: запись рядом с сырьём")
struct DictationTimingsStoreTests {

    /// Закон проекта: сырьё неприкосновенно. Появление timings.json не меняет
    /// raw.txt ни на байт.
    @MainActor
    @Test func сырьёОстаётсяБайтВБайтПослеПоявленияТаймингов() throws {
        let raw = "  Уважаемый суд. Далее.  "
        try withTimingsRoot { root in
            let rawURL = try DictationStore.save(rawText: raw, in: root)
            #expect(try Data(contentsOf: rawURL) == Data(raw.utf8))

            #expect(try DictationStore.saveTokenTimings(
                DictationTimings(audioSeconds: 2.9, tokens: сЗаметнойПаузой),
                besideRawAt: rawURL
            ))

            #expect(try Data(contentsOf: rawURL) == Data(raw.utf8))
        }
    }

    @MainActor
    @Test func таймингиЛожатсяРядомССырьёмИЧитаютсяНазад() throws {
        try withTimingsRoot { root in
            let rawURL = try DictationStore.save(rawText: "Уважаемый суд", in: root)
            let document = DictationTimings(audioSeconds: 2.9, tokens: сЗаметнойПаузой)
            #expect(try DictationStore.saveTokenTimings(document, besideRawAt: rawURL))

            let directory = rawURL.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(names == ["raw.txt", "timings.json"])

            let data = try Data(contentsOf: directory.appendingPathComponent("timings.json"))
            #expect(try DictationTimings.decoded(from: data) == document)
        }
    }

    /// Права 0600, как у сырья: в токенах — та же речь клиента.
    @MainActor
    @Test func таймингиПишутсяПриватно() throws {
        try withTimingsRoot { root in
            let rawURL = try DictationStore.save(rawText: "текст", in: root)
            try DictationStore.saveTokenTimings(
                DictationTimings(audioSeconds: 1, tokens: сЗаметнойПаузой),
                besideRawAt: rawURL
            )
            let url = rawURL.deletingLastPathComponent().appendingPathComponent("timings.json")
            let mode = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(mode?.int16Value == 0o600)
        }
    }

    /// Приватная запись ДОПИСЫВАЕТ. Второй вызов склеил бы два JSON в один
    /// нечитаемый файл — он отказывается и оставляет первый как есть.
    @MainActor
    @Test func второйВызовНеДописываетКУжеСохранённым() throws {
        try withTimingsRoot { root in
            let rawURL = try DictationStore.save(rawText: "текст", in: root)
            let first = DictationTimings(audioSeconds: 1, tokens: сЗаметнойПаузой)
            #expect(try DictationStore.saveTokenTimings(first, besideRawAt: rawURL))
            #expect(try DictationStore.saveTokenTimings(
                DictationTimings(audioSeconds: 9,
                                 tokens: [DictationTokenTiming(token: "▁другое",
                                                               start: 0, end: 1, confidence: 1)]),
                besideRawAt: rawURL
            ) == false)

            let url = rawURL.deletingLastPathComponent().appendingPathComponent("timings.json")
            #expect(try DictationTimings.decoded(from: Data(contentsOf: url)) == first)
        }
    }

    /// Тишина в микрофон: токенов нет — файла-обещания тоже нет.
    @MainActor
    @Test func пустыеТаймингиФайлаНеЗаводят() throws {
        try withTimingsRoot { root in
            let rawURL = try DictationStore.save(rawText: "текст", in: root)
            #expect(try DictationStore.saveTokenTimings(
                DictationTimings(audioSeconds: 3, tokens: []),
                besideRawAt: rawURL
            ) == false)
            let names = try FileManager.default
                .contentsOfDirectory(atPath: rawURL.deletingLastPathComponent().path)
            #expect(names == ["raw.txt"])
        }
    }
}
