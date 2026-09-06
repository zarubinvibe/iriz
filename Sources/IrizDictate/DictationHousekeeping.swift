// Уборка за собой: продукт не имеет права копить мусор на чужом диске.
//
// Повод названный и измеренный. 06.09.2026 диск владельца встал колом на нуле
// свободных байт посреди работы, и разбор показал, из чего сложились гигабайты:
//
//   1,1 ГБ  архив `ggml-large-v3-encoder.mlmodelc.zip`, распакованный каталог
//           которого лежит рядом. Архив после распаковки не нужен НИКОМУ.
//   432 КБ  карантинный каталог `dictations-quarantine-…` месячной давности.
//   2027    каталогов надиктовок, старейшему месяц: по отдельности крошки,
//           вместе - каталог, в котором ничего не найти.
//
// Слова владельца 06.09.2026: «нужно предусмотреть инструмент, который спустя
// время будет удалять вот эти надиктовки. Раз они так сильно забивают место,
// это очень хороший инструмент».
//
// ЧТО ЗДЕСЬ МОЖНО И ЧЕГО НЕЛЬЗЯ. Уборка делится надвое, и это разделение важнее
// самой уборки:
//
//   МУСОР      - то, что доказуемо избыточно: архив рядом с распакованным
//                каталогом, карантин старше срока. Удаляется всегда, вопросов
//                не задаёт: восстановить нечего, потому что терять нечего.
//   СЫРЬЁ      - надиктовки. Удаляется ТОЛЬКО по сроку, который владелец видит
//                и меняет в настройках, и только по возрасту каталога. Ноль
//                дней значит «не удалять никогда» - у владельца обязан быть
//                способ выключить уборку совсем.
//
// План уборки считается ЧИСТОЙ функцией и проверяется пробой без диска: правило
// «что удалять» не имеет права жить в теле, которое ходит в файловую систему.
import Foundation
import IrizCore

/// Сколько дней хранится карантин. Он заводится, когда надиктовку отложили
/// разбираться, и месяц - предел, после которого никто уже не разберётся.
public let DICTATION_QUARANTINE_KEEP_DAYS = 30

/// Заводской срок хранения надиктовок. Владелец просил уборку по времени;
/// три месяца - тот срок, за который надиктовка либо понадобилась, либо нет.
public let DICTATION_RETENTION_DEFAULT_DAYS = 90

/// Одна находка уборки: что удалить и почему.
public struct DictationHousekeepingItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Архив, распакованный каталог которого лежит рядом.
        case unpackedArchive
        /// Карантинный каталог старше срока.
        case staleQuarantine
        /// Надиктовка старше срока хранения.
        case agedDictation
    }

    public let url: URL
    public let kind: Kind
    public let bytes: Int64

    public init(url: URL, kind: Kind, bytes: Int64) {
        self.url = url
        self.kind = kind
        self.bytes = bytes
    }
}

/// Что видно в каталоге. Слепок диска, отдельный от решения: пробе он даётся
/// руками, живому коду его собирает `dictationHousekeepingSnapshot`.
public struct DictationHousekeepingEntry: Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let modified: Date
    public let bytes: Int64
    /// Есть ли рядом каталог с тем же именем без расширения `.zip`.
    public let hasUnpackedTwin: Bool

    public init(url: URL, isDirectory: Bool, modified: Date, bytes: Int64,
                hasUnpackedTwin: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.modified = modified
        self.bytes = bytes
        self.hasUnpackedTwin = hasUnpackedTwin
    }
}

/// Что удалять. Чистая функция: диска не касается, времени сама не берёт.
///
/// `retentionDays == 0` значит «надиктовки не трогать». Мусор при этом всё
/// равно убирается: он не сырьё, и держать его незачем ни при каком сроке.
public func dictationHousekeepingPlan(models: [DictationHousekeepingEntry] = [],
                                      quarantines: [DictationHousekeepingEntry] = [],
                                      dictations: [DictationHousekeepingEntry] = [],
                                      retentionDays: Int,
                                      keepLimit: Int = DICTATION_HISTORY_KEEP_LIMIT,
                                      now: Date) -> [DictationHousekeepingItem] {
    var plan: [DictationHousekeepingItem] = []

    for entry in models where !entry.isDirectory
        && entry.url.pathExtension.lowercased() == "zip"
        && entry.hasUnpackedTwin {
        plan.append(.init(url: entry.url, kind: .unpackedArchive, bytes: entry.bytes))
    }

    let quarantineEdge = now.addingTimeInterval(-Double(DICTATION_QUARANTINE_KEEP_DAYS) * 86_400)
    for entry in quarantines where entry.isDirectory && entry.modified < quarantineEdge {
        plan.append(.init(url: entry.url, kind: .staleQuarantine, bytes: entry.bytes))
    }

    // Потолок ЧИСЛА. Решение владельца 06.09.2026: «пусть 500 последних, а
    // просматривать можно будет только последние, например, 100».
    //
    // Срок и потолок работают вместе, а не вместо друг друга: за неделю бывает
    // и тысяча надиктовок, и тогда срок не спасает, а за год - двадцать, и
    // тогда не спасает потолок.
    let sorted = dictations
        .filter(\.isDirectory)
        .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    var overflow: Set<URL> = []
    if sorted.count > keepLimit {
        overflow = Set(sorted.dropFirst(keepLimit).map(\.url))
    }

    let dictationEdge = retentionDays > 0
        ? now.addingTimeInterval(-Double(retentionDays) * 86_400)
        : Date.distantPast
    for entry in sorted {
        let tooOld = retentionDays > 0 && entry.modified < dictationEdge
        guard tooOld || overflow.contains(entry.url) else { continue }
        plan.append(.init(url: entry.url, kind: .agedDictation, bytes: entry.bytes))
    }
    return plan
}

/// Человеческая строка итога уборки. Молчать об удалении нельзя: владелец
/// обязан узнать из лога, что продукт что-то стёр, и сколько.
public func dictationHousekeepingSummary(_ plan: [DictationHousekeepingItem]) -> String {
    guard !plan.isEmpty else { return "уборка: мусора нет" }
    let bytes = plan.reduce(Int64(0)) { $0 + $1.bytes }
    let counts = Dictionary(grouping: plan, by: \.kind).mapValues(\.count)
    let parts = [
        counts[.unpackedArchive].map { "распакованных архивов \($0)" },
        counts[.staleQuarantine].map { "карантинов \($0)" },
        counts[.agedDictation].map { "надиктовок старше срока \($0)" },
    ].compactMap { $0 }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return "уборка: \(parts.joined(separator: ", ")) — \(formatter.string(fromByteCount: bytes))"
}

// MARK: - Диск

/// Снять слепок каталога: что в нём лежит, когда изменено, сколько весит.
public func dictationHousekeepingSnapshot(_ directory: URL,
                                          fileManager: FileManager = .default)
    -> [DictationHousekeepingEntry] {
    guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
    let all = Set(names)
    return names.compactMap { name in
        let url = directory.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        // Близнец ищется по имени без `.zip`: распакованный каталог whisper.cpp
        // называется ровно так же.
        let twin = name.lowercased().hasSuffix(".zip") ? String(name.dropLast(4)) : nil
        return DictationHousekeepingEntry(
            url: url,
            isDirectory: isDirectory.boolValue,
            modified: values?.contentModificationDate ?? .distantFuture,
            bytes: diskUsageBytesForHousekeeping(url, fileManager: fileManager),
            hasUnpackedTwin: twin.map(all.contains) ?? false
        )
    }
}

/// Вес файла или каталога. Своя копия обхода: `IrizSettings` зависит от этого
/// модуля, а не наоборот, и тянуть его сюда ради одной функции нельзя.
func diskUsageBytesForHousekeeping(_ url: URL, fileManager: FileManager = .default) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
    let values = try? url.resourceValues(forKeys: Set(keys))
    if values?.isDirectory != true {
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
    guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: keys,
                                              options: [.skipsHiddenFiles]) else { return 0 }
    var total: Int64 = 0
    for case let item as URL in walker {
        let v = try? item.resourceValues(forKeys: Set(keys))
        total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
    }
    return total
}

/// Убраться. Возвращает исполненный план - тем же составом, что и решала
/// чистая функция, за вычетом того, что не удалилось.
///
/// Зовётся на запуске, а не по таймеру: уборка обязана быть дешёвой и редкой.
/// Тысяча каталогов обходится за миллисекунды, и второй повод её гонять чаще
/// придумывать незачем.
@discardableResult
public func dictationHousekeepingRun(retentionDays: Int,
                                     now: Date = Date(),
                                     fileManager: FileManager = .default) -> [DictationHousekeepingItem] {
    let support = irizApplicationSupportDirectoryURL()
    let models = support.appendingPathComponent("Models/whisper", isDirectory: true)
    let dictations = support.appendingPathComponent("dictations", isDirectory: true)
    // Карантины лежат рядом с надиктовками, именем `dictations-quarantine-…`.
    let quarantines = dictationHousekeepingSnapshot(support, fileManager: fileManager)
        .filter { $0.url.lastPathComponent.hasPrefix("dictations-quarantine-") }
    let plan = dictationHousekeepingPlan(
        models: dictationHousekeepingSnapshot(models, fileManager: fileManager),
        quarantines: quarantines,
        dictations: dictationHousekeepingSnapshot(dictations, fileManager: fileManager),
        retentionDays: retentionDays,
        now: now
    )
    var done: [DictationHousekeepingItem] = []
    for item in plan {
        do {
            try fileManager.removeItem(at: item.url)
            done.append(item)
        } catch {
            log("уборка не смогла удалить \(item.url.lastPathComponent): \(error.localizedDescription)")
        }
    }
    if !done.isEmpty { log(dictationHousekeepingSummary(done)) }
    return done
}
