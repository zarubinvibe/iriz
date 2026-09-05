import Foundation
import Testing
@testable import IrizPrompt

struct PromptTests {
    private struct Fixture: Decodable {
        let id: String
        let synthetic: Bool
        let text: String
    }

    @Test func синтетическиеНадиктовкиРазмечаются() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/transcripts.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(fixtures.count == 12)
        #expect(fixtures.allSatisfy { $0.synthetic })
        #expect(fixtures.allSatisfy { $0.id.hasPrefix("synthetic-") })
        #expect(Set(fixtures.map(\.id)).count == fixtures.count)
        let builder = PromptEnvelopeBuilder()
        let counts = fixtures.map { builder.analyze($0.text) }
        #expect(counts.reduce(0) { $0 + $1.negations.count } > 0)
        #expect(counts.reduce(0) { $0 + $1.deictics.count } > 0)
    }

    @Test func дополнениеОпределяетсяПоЯвномуМаркеру() {
        let markup = PromptEnvelopeBuilder().analyze("Дополни промп следующим: не усложняй.", hasPreviousPrompt: true)
        #expect(markup.mode == .addition)
    }

    @Test func терминыЗаменяютсяТолькоТочно() {
        let builder = PromptEnvelopeBuilder()
        let exact = builder.analyze("Используй Кими и Кодекс.")
        #expect(exact.terms.map(\.canonical).contains("Kimi"))
        #expect(exact.terms.map(\.canonical).contains("Codex"))
        let similar = builder.analyze("Используй кимикой и кодексом.")
        #expect(similar.terms.isEmpty)
    }

    @Test func блокирующийГейтЛовитДобавленноеОтрицание() {
        let raw = "Создай файл отчёта и запусти тесты проекта."
        let prompt = """
        ТРЕБОВАНИЯ
        1. [Р] Создай файл отчёта. «Создай файл отчёта»
        ЗАПРЕТЫ
        1. [Р] Не меняй исходники. «запусти тесты»
        ГРАНИЦЫ ДЕЙСТВИЙ
        [У] источник: /tmp/owner.md — локальные правки разрешены.
        """
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)
        #expect(report.items.count == 14)
        let b5 = report.items.first { $0.id == "Б5" }
        #expect(b5?.verdict == .no)
        #expect(report.hasBlockingFailure)
    }
}

@Suite("Выбор последней надиктовки")
struct LatestDictationTests {
    /// Импорт из старого приложения пишет папки в порядке «свежие первыми», нумеруя их
    /// назад по времени. Значит на диск ПОСЛЕДНЕЙ ложится самая старая папка, и выбор
    /// по времени изменения файла даёт не тот результат. Ключ — имя папки.
    @Test func свежейСчитаетсяПоследняяПоИмениАНеПоВремениЗаписи() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smltlk-latest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Пишем в том же порядке, что импорт: сначала свежая, потом старые.
        for name in ["2026-08-04T22:32:50Z", "2026-08-04T22:32:00Z", "2026-08-04T22:31:11Z"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: dir.appendingPathComponent("raw.txt"))
        }

        let latest = try PromptEnvelopeBuilder().latestDictation(in: root)
        #expect(latest.lastPathComponent == "2026-08-04T22:32:50Z")
    }
}

@Suite("Маркер добавки по основе слова")
struct AdditionMarkerTests {
    /// Владелец говорит «дополни», «дополню», «дополнить» — это одно и то же намерение.
    /// Ловить надо основу, а не одну словоформу: по «дополни\\w*» форма «дополню» терялась,
    /// а именно с неё начинается самая свежая настоящая надиктовка в хранилище.
    @Test func всеФормыДополнитьСчитаютсяМаркеромДобавки() {
        let builder = PromptEnvelopeBuilder()
        for form in ["Дополни промпт следующим", "Еще дополню проект тем", "Дополнить нужно вот чем",
                     "Добавь ещё пункт", "Добавлю к сказанному"] {
            let markup = builder.analyze(form, hasPreviousPrompt: true)
            #expect(markup.mode == .addition, "не распознан маркер добавки: \\(form)")
        }
        let plain = builder.analyze("Напиши заявление в полицию", hasPreviousPrompt: true)
        #expect(plain.mode != .addition)
    }
}

@Suite("Гейт и русская морфология")
struct VerifierMorphologyTests {
    private func verify(raw: String, prompt: String) -> [String: String] {
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)
        return Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0.verdict.rawValue) })
    }

    /// Спека требует писать запреты ЗАГЛАВНЫМИ, а владелец говорит другой словоформой.
    /// «НЕ ТРОГАТЬ ТЕСТЫ» против «не трогай тесты» — это опора, а не выдумка.
    /// Без учёта основы гейт краснел бы на каждом правильно оформленном запрете.
    @Test func словоформаЗапретаНеСчитаетсяВыдумкой() {
        let raw = "Нужно починить скрипт сборки и обязательно не трогай тесты в проекте."
        let prompt = """
        ТРЕБОВАНИЯ
        1. [Р] Починить скрипт сборки.  «починить скрипт сборки»

        ЗАПРЕТЫ
        - НЕ ТРОГАТЬ ТЕСТЫ. («не трогай тесты»)
        """
        #expect(verify(raw: raw, prompt: prompt)["Б6"] == "ДА")
    }

    /// А вот выдуманное слово опоры не имеет и обязано быть поймано.
    @Test func выдуманныйЗапретЛовится() {
        let raw = "Нужно починить скрипт сборки и обязательно не трогай тесты в проекте."
        let prompt = """
        ТРЕБОВАНИЯ
        1. [Р] Починить скрипт сборки.  «починить скрипт сборки»

        ЗАПРЕТЫ
        - НЕ УДАЛЯТЬ КОНФИГИ.
        """
        let r = verify(raw: raw, prompt: prompt)
        #expect(r["Б6"] == "НЕТ")
        #expect(r["Б5"] == "НЕТ", "добавленное отрицание обязано ловиться")
    }
}

@Suite("Б6 не считает выдумкой разметку и обычные слова")
struct FactSupportTests {
    private func b6(raw: String, prompt: String) -> String {
        PromptVerifier().verify(raw: raw, prompt: prompt).items.first { $0.id == "Б6" }!.verdict.rawValue
    }

    /// Метка [В] обязана нести источник (Б3), а источник — это путь. Если считать путь и
    /// первое слово после метки выдумкой, метка [В] в требованиях становится технически
    /// невозможной: Б3 требует то, что Б6 бракует. Гейт не имеет права противоречить шаблону.
    @Test func путьИсточникаИСловоПослеМеткиНеВыдумка() {
        let raw = "Нужно починить скрипт сборки и не трогай тесты."
        let prompt = """
        ТРЕБОВАНИЯ
        1. [Р] Починить скрипт сборки.  «починить скрипт сборки»
        2. [В] Указать владельцу источник.  «починить скрипт»  источник: ~/project/README.md
        """
        #expect(b6(raw: raw, prompt: prompt) == "ДА")
    }

    /// Но выдуманное слово в запрете опоры не имеет и обязано ловиться.
    @Test func выдуманноеСловоВЗапретеЛовится() {
        let raw = "Нужно починить скрипт сборки и не трогай тесты."
        let prompt = """
        ТРЕБОВАНИЯ
        1. [Р] Починить скрипт сборки.  «починить скрипт сборки»

        ЗАПРЕТЫ
        - [Р] НЕ УДАЛЯТЬ КОНФИГИ.
        """
        #expect(b6(raw: raw, prompt: prompt) == "НЕТ")
    }
}

@Suite("П1: пол и скидка на источники")
struct InflationNormTests {
    private func p1(raw: String, prompt: String) -> String {
        PromptVerifier().verify(raw: raw, prompt: prompt).items.first { $0.id == "П1" }!.verdict.rawValue
    }

    /// На коротком входе голый множитель 6x вырождается: 6 x 13 = 78 знаков, куда не влезает
    /// даже один источник. Пол в 1500 знаков снимает вырождение.
    @Test func короткийВходНеПровальныйИзЗаОбвязки() {
        let raw = "Запусти тест."
        // Исполняемая часть укладывается в 2x (22 знака при норме 26 — так вышло на живой
        // надиктовке); длинная здесь только обвязка с разбором.
        let prompt = "ТРЕБОВАНИЯ\n[Р] запусти тест\n\nКОНТЕКСТ\n"
            + String(repeating: "обвязка с разбором и картой сегментов. ", count: 20)
        #expect(p1(raw: raw, prompt: prompt) == "ДА")
    }

    /// Раздутие ИСПОЛНЯЕМОЙ части ловится по-прежнему — именно её раздувают выдумкой.
    @Test func раздутиеИсполняемойЧастиЛовится() {
        let raw = "Почини сборку."
        let prompt = "ТРЕБОВАНИЯ\n1. [Р] " + String(repeating: "лишнее требование сверх сказанного. ", count: 10)
        #expect(p1(raw: raw, prompt: prompt) == "НЕТ")
    }
}

@Suite("Б8 не читает дейктики из блока сырья")
struct RawBlockDeicticTests {
    @Test func дейктикВнутриСырьяНеЛомаетВерификацию() throws {
        let raw = "Сделай это аккуратно. Затем проверь результат и подготовь короткое сообщение о готовности."
        let spec = PromptSpec(
            status: .ready,
            taskKind: .general,
            goal: PromptField(text: "Сделай задачу аккуратно.", evidence: "Сделай")
        )

        let artifact = try PromptRenderer().render(
            spec: spec,
            raw: raw,
            markup: PromptEnvelopeBuilder().analyze(raw),
            date: Date(timeIntervalSince1970: 0)
        ).artifact
        let report = PromptVerifier().verify(raw: raw, prompt: artifact)

        #expect(report.items.first { $0.id == "Б8" }?.verdict == .yes)
    }

    @Test func дейктикВГотовомПромптеПоПрежнемуБлокируется() {
        let raw = "Подготовь подробный отчёт по результатам проверки и перечисли найденные проблемы по приоритету."
        let prompt = "ТРЕБОВАНИЯ\n1. [Р] Сделай это. «Подготовь подробный отчёт»"
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)

        #expect(report.items.first { $0.id == "Б8" }?.verdict == .no)
    }

    @Test func дейктикВнеИзвестныхСекцийТожеБлокируется() {
        let raw = "Подготовь подробный отчёт по результатам проверки и перечисли найденные проблемы по приоритету."
        let prompt = "Служебная строка просит сделать это.\nТРЕБОВАНИЯ\n1. [Р] Подготовь отчёт. «Подготовь подробный отчёт»"
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)

        #expect(report.items.first { $0.id == "Б8" }?.verdict == .no)
    }

    @Test func размеченнаяНеясностьНеСчитаетсяНеразрешённымДейктиком() throws {
        let raw = "Подготовь отчёт и уточни, что означает это. Значение указателя меняет итоговый результат работы."
        let spec = PromptSpec(
            status: .needsClarification,
            taskKind: .general,
            goal: PromptField(text: "Подготовь отчёт.", evidence: "Подготовь отчёт"),
            ambiguities: [PromptAmbiguity(
                description: "Нужно уточнить, что означает это.",
                evidence: "это",
                blocking: true
            )]
        )
        let artifact = try PromptRenderer().render(
            spec: spec,
            raw: raw,
            markup: PromptEnvelopeBuilder().analyze(raw),
            date: Date(timeIntervalSince1970: 0)
        ).artifact
        let report = PromptVerifier().verify(raw: raw, prompt: artifact)

        #expect(report.items.first { $0.id == "Б8" }?.verdict == .yes)
    }
}

@Suite("Б5 сохраняет смысл отрицаний")
struct NegationSemanticsTests {
    @Test func неИБезМожноПереформулироватьБезНовогоЗапрета() {
        let raw = "Подготовь отчёт без ошибок и не пропускай обязательные проверки."
        let prompt = """
        ТРЕБОВАНИЯ
        1. [Р] Подготовь отчёт без ошибок. «без ошибок»
        2. [Р] Проведи работу без пропуска обязательных проверок. «не пропускай обязательные проверки»
        """
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)

        #expect(report.items.first { $0.id == "Б5" }?.verdict == .yes)
    }

    @Test func безИНетМожноПереформулироватьБезНовогоЗапрета() {
        let raw = "Подготовь итоговый отчёт без ошибок."
        let prompt = "ТРЕБОВАНИЯ\n1. [Р] Подготовь итоговый отчёт, в котором нет ошибок. «без ошибок»"
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)

        #expect(report.items.first { $0.id == "Б5" }?.verdict == .yes)
    }

    @Test func усилениеДоНикогдаПоПрежнемуБлокируется() {
        let raw = "Отчёт не пропускает обязательные проверки."
        let prompt = "ТРЕБОВАНИЯ\n1. [Р] Отчёт никогда не пропускает обязательные проверки. «не пропускает обязательные проверки»"
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)

        #expect(report.items.first { $0.id == "Б5" }?.verdict == .no)
    }

    @Test func усилениеДоНельзяПоПрежнемуБлокируется() {
        let raw = "Не удаляй архив проекта."
        let prompt = "ТРЕБОВАНИЯ\n1. [Р] Удалять архив проекта нельзя. «Не удаляй архив проекта»"
        let report = PromptVerifier().verify(raw: raw, prompt: prompt)

        #expect(report.items.first { $0.id == "Б5" }?.verdict == .no)
    }
}
