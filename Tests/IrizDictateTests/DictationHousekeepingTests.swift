// Проба уборки: что удаляется, а что не имеет права удалиться никогда.
//
// Правило живёт здесь, а не во внимании: уборка стирает файлы владельца, и
// цена ошибки - потерянная надиктовка, которую взять больше неоткуда.
import Foundation
import Testing

@testable import IrizDictate

@Suite("уборка: план считается без диска")
struct DictationHousekeepingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ name: String, days: Double, dir: Bool = true,
                       bytes: Int64 = 1024, twin: Bool = false) -> DictationHousekeepingEntry {
        DictationHousekeepingEntry(url: URL(fileURLWithPath: "/tmp/\(name)"),
                                   isDirectory: dir,
                                   modified: now.addingTimeInterval(-days * 86_400),
                                   bytes: bytes,
                                   hasUnpackedTwin: twin)
    }

    /// Архив, распакованный каталог которого лежит рядом, - доказуемо лишний.
    /// Ровно он съел 1,1 ГБ у владельца.
    @Test func распакованныйАрхивУходит() {
        let plan = dictationHousekeepingPlan(
            models: [entry("ggml-large-v3-encoder.mlmodelc", days: 1),
                     entry("ggml-large-v3-encoder.mlmodelc.zip", days: 1, dir: false,
                           bytes: 1_175_711_232, twin: true)],
            retentionDays: 90, now: now)
        #expect(plan.count == 1)
        #expect(plan.first?.kind == .unpackedArchive)
        #expect(plan.first?.url.lastPathComponent == "ggml-large-v3-encoder.mlmodelc.zip")
    }

    /// А архив БЕЗ распакованного близнеца не трогаем: он единственный носитель.
    @Test func одинокийАрхивОстаётся() {
        let plan = dictationHousekeepingPlan(
            models: [entry("model.zip", days: 400, dir: false, twin: false)],
            retentionDays: 90, now: now)
        #expect(plan.isEmpty, "удалён архив, распаковки которого нет — модель потеряна")
    }

    /// Ноль дней значит «надиктовки не трогать». Мусор при этом убирается:
    /// он не сырьё.
    @Test func нольДнейВыключаетУборкуНадиктовок() {
        let plan = dictationHousekeepingPlan(
            models: [entry("a.mlmodelc", days: 1),
                     entry("a.mlmodelc.zip", days: 1, dir: false, twin: true)],
            dictations: [entry("2020-01-01_00-00-00", days: 3000)],
            retentionDays: 0, now: now)
        #expect(plan.map(\.kind) == [.unpackedArchive])
    }

    /// Свежая надиктовка не уходит НИ ПРИ КАКОМ сроке.
    @Test func свежаяНадиктовкаОстаётся() {
        let plan = dictationHousekeepingPlan(
            dictations: [entry("вчерашняя", days: 1), entry("старая", days: 200)],
            retentionDays: 90, now: now)
        #expect(plan.count == 1)
        #expect(plan.first?.url.lastPathComponent == "старая")
        #expect(plan.first?.kind == .agedDictation)
    }

    /// Граница срока не съедает день: ровно на сроке надиктовка ещё живёт.
    @Test func границаСрокаНеСъедаетДень() {
        let onEdge = dictationHousekeepingPlan(
            dictations: [entry("ровно", days: 90)], retentionDays: 90, now: now)
        #expect(onEdge.isEmpty)
        let past = dictationHousekeepingPlan(
            dictations: [entry("на день позже", days: 90.5)], retentionDays: 90, now: now)
        #expect(past.count == 1)
    }

    /// Карантин старше месяца уходит, свежий остаётся.
    @Test func карантинУходитПоСроку() {
        let plan = dictationHousekeepingPlan(
            quarantines: [entry("dictations-quarantine-старый", days: 40),
                          entry("dictations-quarantine-свежий", days: 3)],
            retentionDays: 0, now: now)
        #expect(plan.count == 1)
        #expect(plan.first?.kind == .staleQuarantine)
    }

    /// Потолок числа: хранится 500 последних, остальное уходит независимо от
    /// срока. Решение владельца 06.09.2026 — «пусть 500 последних».
    @Test func потолокЧислаРежетЛишнееДажеБезСрока() {
        let many = (0..<12).map { i in
            entry(String(format: "2026-09-%02d_10-00-00", 30 - i), days: Double(i))
        }
        let plan = dictationHousekeepingPlan(dictations: many,
                                             retentionDays: 0, keepLimit: 5, now: now)
        #expect(plan.count == 7, "потолок 5 из 12 оставил не то число")
        #expect(plan.allSatisfy { $0.kind == .agedDictation })
        // Свежие пять - на месте. Свежесть считается ИМЕНЕМ каталога.
        let deleted = Set(plan.map { $0.url.lastPathComponent })
        #expect(!deleted.contains("2026-09-30_10-00-00"))
        #expect(!deleted.contains("2026-09-26_10-00-00"))
        #expect(deleted.contains("2026-09-25_10-00-00"))
    }

    /// Срок и потолок не удаляют одно и то же дважды.
    @Test func срокИПотолокНеДублируютДругДруга() {
        let many = (0..<8).map { i in
            entry(String(format: "2026-01-%02d_10-00-00", 20 - i), days: Double(i) + 200)
        }
        let plan = dictationHousekeepingPlan(dictations: many,
                                             retentionDays: 90, keepLimit: 3, now: now)
        #expect(plan.count == 8, "старое посчиталось дважды")
        #expect(Set(plan.map(\.url)).count == plan.count)
    }

    /// Итог уборки говорит владельцу, что именно стёрли и сколько.
    @Test func итогНазываетСоставИРазмер() {
        let plan = dictationHousekeepingPlan(
            models: [entry("a.mlmodelc", days: 1),
                     entry("a.mlmodelc.zip", days: 1, dir: false, bytes: 1_000_000_000, twin: true)],
            dictations: [entry("старая", days: 200, bytes: 2048)],
            retentionDays: 90, now: now)
        let text = dictationHousekeepingSummary(plan)
        #expect(text.contains("распакованных архивов 1"))
        #expect(text.contains("надиктовок старше срока 1"))
        #expect(text.contains("ГБ") || text.contains("GB"))
        #expect(dictationHousekeepingSummary([]) == "уборка: мусора нет")
    }
}
