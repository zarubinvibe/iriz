// Тесты счётчиков доставки и полезной нагрузки status.json.
// Писатель снимка живёт в исполняемой цели IrizApp — тестами не достать,
// поэтому проверяются решение (что попадает в снимок) и счёт.
import Foundation
import Testing

@testable import IrizCore

@Suite("счётчики вставки в status.json")
struct StatusCountersTests {

    /// Свой домен на проверку: домен владельца не трогаем, файл после себя
    /// сносим (иначе cfprefsd оставляет plist от каждого прогона).
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let name = "smltlk-status-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer {
            defaults.removePersistentDomain(forName: name)
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: url)
        }
        body(defaults)
    }

    @Test func freshCountersAreZero() {
        withIsolatedDefaults { defaults in
            let stats = InsertionStats(defaults: defaults)
            #expect(stats.attempts == 0)
            #expect(stats.failures == 0)
        }
    }

    @Test func onlyUndeliveredInsertionsCountAsFailures() {
        withIsolatedDefaults { defaults in
            let stats = InsertionStats(defaults: defaults)
            stats.record(delivered: true)
            stats.record(delivered: false)
            stats.record(delivered: false)
            #expect(stats.attempts == 3)
            #expect(stats.failures == 2)
        }
    }

    @Test func recordReturnsRunningTotals() {
        withIsolatedDefaults { defaults in
            let stats = InsertionStats(defaults: defaults)
            let first = stats.record(delivered: false)
            #expect(first == (attempts: 1, failures: 1))
            let second = stats.record(delivered: true)
            #expect(second == (attempts: 2, failures: 1))
        }
    }

    @Test func garbageStoredValueDoesNotGoNegative() {
        withIsolatedDefaults { defaults in
            defaults.set(-42, forKey: InsertionStats.failuresKey)
            #expect(InsertionStats(defaults: defaults).failures == 0)
        }
    }

    /// Гейт этапа: счётчик неудачных вставок ВИДЕН в status.json.
    @Test func statusJSONCarriesInsertionCounters() throws {
        let data = try #require(statusReportJSONData(ax: true,
                                                     listen: true,
                                                     post: false,
                                                     loginItem: true,
                                                     version: "1.2.3",
                                                     insertionAttempts: 7,
                                                     insertionFailures: 3))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["insertionFailures"] as? Int == 3)
        #expect(decoded["insertionAttempts"] as? Int == 7)
    }

    /// Существующие ключи скрипты гейта читают по имени — не переименованы.
    @Test func statusJSONKeepsKeysGateScriptsRead() throws {
        let data = try #require(statusReportJSONData(ax: true,
                                                     listen: false,
                                                     post: true,
                                                     loginItem: false,
                                                     version: "dev",
                                                     insertionAttempts: 0,
                                                     insertionFailures: 0))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["ax"] as? Bool == true)
        #expect(decoded["listen"] as? Bool == false)
        #expect(decoded["post"] as? Bool == true)
        #expect(decoded["loginItem"] as? Bool == false)
        #expect(decoded["version"] as? String == "dev")
    }
}
