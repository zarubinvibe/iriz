// Разбивка отказов вставки по причине.
//
// Улика, ради которой это заведено: у владельца 03.09.2026 стояло
// `attempts = 1305`, `failures = 76` - 5,8 % надиктовок не доехали до поля,
// и разобрать этот процент было НЕЧЕМ. На диске при этом 196 каталогов из
// 1561 (12,6 %) без `inserted.txt`. Два числа спорят, и оба недоказуемы,
// пока причина не пишется рядом с фактом.
import Foundation
import Testing

@testable import IrizCore

@Suite("счётчики: разбивка отказов вставки")
struct InsertionBreakdownTests {

    /// Домен настроек, который сам за собой убирает.
    ///
    /// Прежде здесь стоял `freshDefaults()`: он чистил домен ТОЛЬКО ДО работы, и
    /// каждый прогон тестов оставлял на диске владельца один домен и один plist.
    /// К 06.09.2026 их накопилось 858 штук, и нашло их не внимание, а ворота
    /// уборки `scripts/tidy_gate.sh`. Класс, а не функция, ровно ради `deinit`:
    /// он срабатывает и когда проба падает на полпути.
    private final class IsolatedDefaults {
        let suite = "iriz.tests.insertion.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            // Одного забвения домена мало: cfprefsd дописывает plist обратно уже
            // после выхода процесса, и файл остаётся в ~/Library/Preferences.
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func причинаПишетсяРядомСФактом() {
        let box = IsolatedDefaults()
        let stats = InsertionStats(defaults: box.defaults)
        stats.record(delivered: false, reason: "targetNeverRequestedText")
        stats.record(delivered: false, reason: "targetNeverRequestedText")
        stats.record(delivered: false, reason: "insertionFailed")
        stats.record(delivered: true)

        #expect(stats.attempts == 4)
        #expect(stats.failures == 3)
        #expect(stats.failures(reason: "targetNeverRequestedText") == 2)
        #expect(stats.failures(reason: "insertionFailed") == 1)
        #expect(stats.failures(reason: "deliveryNotObservable") == 0)
    }

    @Test func суммаПричинНеБольшеОбщегоЧисла() {
        let box = IsolatedDefaults()
        let stats = InsertionStats(defaults: box.defaults)
        for reason in INSERTION_FAILURE_REASONS { stats.record(delivered: false, reason: reason) }
        let sum = INSERTION_FAILURE_REASONS.reduce(0) { $0 + stats.failures(reason: $1) }
        #expect(sum == stats.failures)
    }

    @Test func нечегоВставлятьСчитаетсяОтдельноОтОтказов() {
        // Вставка не провалилась - её не было. На диске эти случаи неотличимы,
        // и именно поэтому 12,6 % каталогов без вставки спорили с 5,8 % отказов.
        let box = IsolatedDefaults()
        let stats = InsertionStats(defaults: box.defaults)
        stats.recordNothingToInsert()
        stats.recordNothingToInsert()
        #expect(stats.nothingToInsert == 2)
        #expect(stats.attempts == 0, "нечего вставлять - это не попытка")
        #expect(stats.failures == 0, "нечего вставлять - это не отказ")
    }

    @Test func старыйВызовБезПричиныПродолжаетРаботать() {
        // История владельца лежит в общем ключе, и терять её ради красоты
        // нельзя: разбивка добавлена рядом, а не вместо.
        let box = IsolatedDefaults()
        let stats = InsertionStats(defaults: box.defaults)
        stats.record(delivered: false)
        #expect(stats.failures == 1)
        #expect(stats.failureBreakdown(reasons: INSERTION_FAILURE_REASONS).isEmpty)
    }

    @Test func снимокСостоянияНесётРазбивку() throws {
        let data = try #require(statusReportJSONData(
            ax: true, listen: true, post: true, loginItem: true, version: "0.3.0",
            insertionAttempts: 1305,
            insertionFailures: 76,
            insertionFailureReasons: ["targetNeverRequestedText": 60, "insertionFailed": 16],
            insertionNothingToInsert: 196
        ))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasons = try #require(json["insertionFailureReasons"] as? [String: Int])
        #expect(reasons["targetNeverRequestedText"] == 60)
        #expect(json["insertionNothingToInsert"] as? Int == 196)
    }
}
