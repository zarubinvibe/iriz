import Foundation
import Testing

@testable import IrizCore

@Suite("переезд каталога данных на новое имя")
struct IrizSupportDirectoryMigrationTests {
    /// Владелец спросил «почему всё ещё smltlk». Каталог данных переезжает, но
    /// внутри лежат полторы тысячи надиктовок: потерять их значит показать
    /// пустую историю человеку, который ей пользуется.
    @Test func legacyDirectoryMovesOnceAndKeepsItsContent() throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = sandbox.appendingPathComponent("smltlk", isDirectory: true)
        let target = sandbox.appendingPathComponent("iriz", isDirectory: true)
        try manager.createDirectory(at: legacy.appendingPathComponent("dictations"),
                                    withIntermediateDirectories: true)
        let witness = legacy.appendingPathComponent("dictations/raw.txt")
        try Data("надиктовка".utf8).write(to: witness)
        defer { try? manager.removeItem(at: sandbox) }

        try migratePrivateRootIfNeeded(from: legacy, to: target)

        #expect(manager.fileExists(atPath: target.appendingPathComponent("dictations/raw.txt").path))
        #expect(!manager.fileExists(atPath: legacy.path), "старый каталог обязан исчезнуть")
    }

    /// Новый каталог уже есть - старый НЕ трогаем. Иначе переезд затрёт свежие
    /// записи содержимым архива при первом же запуске старой сборки рядом.
    @Test func existingTargetIsNeverOverwritten() throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = sandbox.appendingPathComponent("smltlk", isDirectory: true)
        let target = sandbox.appendingPathComponent("iriz", isDirectory: true)
        try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        // Именно НАШ файл: посторонние имена переезду больше не помеха.
        try Data("старое".utf8).write(to: legacy.appendingPathComponent("counters.json"))
        try Data("новое".utf8).write(to: target.appendingPathComponent("counters.json"))
        defer { try? manager.removeItem(at: sandbox) }

        try migratePrivateRootIfNeeded(from: legacy, to: target)

        let kept = try String(contentsOf: target.appendingPathComponent("counters.json"), encoding: .utf8)
        #expect(kept == "новое", "содержимое нового каталога затёрто старым")
        #expect(manager.fileExists(atPath: legacy.path), "старый каталог трогать не за что")
    }

    /// Старого каталога нет вовсе - чистая установка, переезжать нечего.
    @Test func missingLegacyIsNotAnError() throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: sandbox) }
        try migratePrivateRootIfNeeded(from: sandbox.appendingPathComponent("smltlk"),
                                       to: sandbox.appendingPathComponent("iriz"))
        #expect(!manager.fileExists(atPath: sandbox.appendingPathComponent("iriz").path))
    }
}

@Suite("переезд не заклинивает на пустышке")
struct IrizSupportDirectoryStrayTests {
    /// Провалилось живьём: каталог с новым именем завёлся пустым от
    /// постороннего кода, охранник отказался переезжать, и полторы тысячи
    /// надиктовок остались по старому адресу.
    @Test func strayEmptyTargetDoesNotBlockTheMove() throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = sandbox.appendingPathComponent("smltlk", isDirectory: true)
        let target = sandbox.appendingPathComponent("iriz", isDirectory: true)
        try manager.createDirectory(at: legacy.appendingPathComponent("dictations"),
                                    withIntermediateDirectories: true)
        try Data("надиктовка".utf8).write(to: legacy.appendingPathComponent("dictations/raw.txt"))
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("counters.json"))
        // Пустышка: посторонний каталог внутри, наших данных нет.
        try manager.createDirectory(at: target.appendingPathComponent("Models"),
                                    withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: sandbox) }

        try migratePrivateRootIfNeeded(from: legacy, to: target)

        #expect(manager.fileExists(atPath: target.appendingPathComponent("dictations/raw.txt").path))
        #expect(manager.fileExists(atPath: target.appendingPathComponent("counters.json").path))
        #expect(manager.fileExists(atPath: target.appendingPathComponent("Models").path),
                "посторонний каталог обязан уцелеть")
        #expect(!manager.fileExists(atPath: legacy.path), "опустевший старый каталог убран")
    }

    /// А вот НАШИ данные в новом каталоге переезд обязан остановить.
    @Test func targetWithOurDataStopsTheMove() throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = sandbox.appendingPathComponent("smltlk", isDirectory: true)
        let target = sandbox.appendingPathComponent("iriz", isDirectory: true)
        try manager.createDirectory(at: legacy.appendingPathComponent("dictations"),
                                    withIntermediateDirectories: true)
        try Data("старое".utf8).write(to: legacy.appendingPathComponent("counters.json"))
        try manager.createDirectory(at: target.appendingPathComponent("dictations"),
                                    withIntermediateDirectories: true)
        try Data("новое".utf8).write(to: target.appendingPathComponent("counters.json"))
        defer { try? manager.removeItem(at: sandbox) }

        try migratePrivateRootIfNeeded(from: legacy, to: target)

        let kept = try String(contentsOf: target.appendingPathComponent("counters.json"), encoding: .utf8)
        #expect(kept == "новое")
        #expect(manager.fileExists(atPath: legacy.path))
    }
}
