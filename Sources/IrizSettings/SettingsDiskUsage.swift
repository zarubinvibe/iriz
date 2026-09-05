// Сколько места занято и чем. Отдельной страницей настроек.
//
// Повод не абстрактный: у владельца на диске лежало 7,9 ГБ моделей, забытый
// архив надиктовок на 1,17 ГБ и карантинный каталог месячной давности - и
// узнать об этом из продукта было неоткуда. Продукт, который молча ест десять
// гигабайт, обязан хотя бы показывать, где они.
//
// Показываем и открываем в Finder. Удалять отсюда нельзя намеренно: в этих
// каталогах лежат надиктовки, а кнопка «очистить», нажатая не глядя, стоит
// дороже любого сэкономленного гигабайта. Чистка живёт там, где видно, что
// именно чистишь, - в окне истории.
import Foundation
import IrizCore

/// Одна строка страницы: что это, сколько весит, где лежит.
public struct DiskUsageEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let note: String
    public let url: URL
    public let bytes: Int64

    public init(id: String, title: String, note: String, url: URL, bytes: Int64) {
        self.id = id
        self.title = title
        self.note = note
        self.url = url
        self.bytes = bytes
    }
}

/// Человеческий размер. Своя функция, а не ByteCountFormatter по месту вызова:
/// формат обязан быть одинаковым во всех строках, иначе рядом окажутся
/// «1,2 ГБ» и «1200 MB».
public func diskUsageSizeText(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
}

/// Вес каталога. Считается обходом: у каталога нет собственного размера, а
/// у надиктовок его тем более нет - это тысячи мелких файлов.
public func diskUsageBytes(at url: URL, fileManager: FileManager = .default) -> Int64 {
    guard let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: Int64 = 0
    for case let item as URL in enumerator {
        let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
        total += Int64(size)
    }
    return total
}

/// Что мы вообще показываем. Список собирается по диску, а не по памяти о том,
/// что продукт когда-то создавал: забытый карантинный каталог как раз и есть
/// то, о чём код уже не помнит.
public func diskUsageEntries(fileManager: FileManager = .default) -> [DiskUsageEntry] {
    var entries: [DiskUsageEntry] = []
    let home = fileManager.homeDirectoryForCurrentUser
    let support = irizApplicationSupportDirectoryURL()

    let model = home
        .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    if fileManager.fileExists(atPath: model.path) {
        entries.append(DiskUsageEntry(
            id: "model",
            title: "Модель распознавания",
            note: "Без неё диктовка не работает. Скачивается один раз.",
            url: model,
            bytes: diskUsageBytes(at: model, fileManager: fileManager)
        ))
    }

    let whisper = support.appendingPathComponent("Models/whisper", isDirectory: true)
    if fileManager.fileExists(atPath: whisper.path) {
        entries.append(DiskUsageEntry(
            id: "whisper",
            title: "Модели whisper",
            note: "Второй движок распознавания. Нужен только если вы его выбрали.",
            url: whisper,
            bytes: diskUsageBytes(at: whisper, fileManager: fileManager)
        ))
    }

    let dictations = support.appendingPathComponent("dictations", isDirectory: true)
    if fileManager.fileExists(atPath: dictations.path) {
        entries.append(DiskUsageEntry(
            id: "dictations",
            title: "Надиктовки",
            note: "Расшифровки, по папке на каждую. Чистятся в окне истории.",
            url: dictations,
            bytes: diskUsageBytes(at: dictations, fileManager: fileManager)
        ))
    }

    // Карантин остаётся от прежних починок и о нём не помнит уже никто.
    let contents = (try? fileManager.contentsOfDirectory(atPath: support.path)) ?? []
    for name in contents.sorted() where name.hasPrefix("dictations-quarantine") {
        let url = support.appendingPathComponent(name, isDirectory: true)
        entries.append(DiskUsageEntry(
            id: name,
            title: "Отложенные надиктовки",
            note: "Каталог \(name). Остался от прежней починки, продуктом не используется.",
            url: url,
            bytes: diskUsageBytes(at: url, fileManager: fileManager)
        ))
    }

    return entries
}
