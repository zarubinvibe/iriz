// Основано на SuperDictate (MIT, © 2025 shlgd), коммит 83dd7e4.
//
// Отметка поставлена 06.09.2026 по итогу сверки с донором: приватная запись
// файлов (O_NOFOLLOW/O_CLOEXEC, fchmod 0600, проверка st_nlink, writeAllData,
// currentPOSIXError) взята у него дословно. Механика жила в Logger.swift, где
// отметка есть; коммит 846456a вынес её в общий модуль, а отметка за кодом не
// поехала. Условие MIT - нести уведомление вместе с кодом, а не вместе с
// файлом, где он лежал раньше.
import Darwin
import Foundation

public let PRIVATE_LOG_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)
public let PRIVATE_DIRECTORY_MODE = mode_t(S_IRWXU)
public let SMLTLK_PRIVATE_FILE_PERMISSION_MIGRATION_KEY = "ru.smltlk.privateFilePermissionsMigrated"

/// Имя каталога данных до переименования продукта. Нужно ровно для одного:
/// один раз перенести накопленное. Новых записей туда не бывает.
let LEGACY_PRIVATE_ROOT_NAME = "smltlk"

/// Путь каталога данных БЕЗ побочных действий: ничего не создаёт и ничего не
/// переносит. Нужен там, где каталог только адресуют, а создаст его первый же
/// вызов `irizApplicationSupportDirectory()`.
public func irizApplicationSupportDirectoryURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(IRIZ_PRIVATE_ROOT_NAME, isDirectory: true)
}

/// ~/Library/Application Support/iriz — общий каталог приложения.
///
/// Переезд с прежнего имени идёт ОДИН раз и только когда нового каталога ещё
/// нет: у владельца там полторы тысячи надиктовок и счётчики, и бросить их по
/// старому адресу значит показать пустую историю человеку, который ей
/// пользуется. Перенос делается `moveItem` - атомарно в пределах тома, без
/// копии и без окна, в котором данные лежат в двух местах.
public func irizApplicationSupportDirectory() throws -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = support.appendingPathComponent(IRIZ_PRIVATE_ROOT_NAME, isDirectory: true)
    let legacy = support.appendingPathComponent(LEGACY_PRIVATE_ROOT_NAME, isDirectory: true)
    try migratePrivateRootIfNeeded(from: legacy, to: url)
    try createPrivateDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Одноразовый переезд каталога данных на новое имя продукта.
///
/// Решение вынесено отдельной функцией не ради красоты: у владельца в старом
/// каталоге полторы тысячи надиктовок, и «переехало ли» - это то, что обязано
/// проверяться тестом, а не наблюдаться в проде.
///
/// Правила про сохранность, и одно из них написано кровью:
///   - переносим, когда нового каталога нет ЛИБО в нём нет наших данных. Первое
///     правило было «только когда нового нет вовсе», и оно провалилось живьём:
///     каталог успел завестись пустым от постороннего кода, охранник честно
///     отказался переезжать, и полторы тысячи надиктовок остались по старому
///     адресу навсегда - история у владельца была бы пуста;
///   - если в новом каталоге УЖЕ есть наши данные, старый не трогаем вовсе:
///     иначе запуск прежней сборки рядом однажды затрёт свежие записи архивом;
///   - неудача переноса НЕ роняет приложение. Хуже потерянной истории только
///     приложение, которое из-за неё не стартует; тогда заводится новый пустой
///     каталог, а старый остаётся лежать нетронутым.
public func migratePrivateRootIfNeeded(
    from legacy: URL,
    to target: URL,
    fileManager manager: FileManager = .default
) throws {
    guard manager.fileExists(atPath: legacy.path) else { return }
    if manager.fileExists(atPath: target.path) {
        guard !privateRootHasData(at: target, fileManager: manager) else { return }
        // Пустой каталог-пустышка переезду не помеха: переносим содержимое
        // старого внутрь него, а не через себя.
        let items = (try? manager.contentsOfDirectory(atPath: legacy.path)) ?? []
        for item in items {
            try? manager.moveItem(at: legacy.appendingPathComponent(item),
                                  to: target.appendingPathComponent(item))
        }
        if ((try? manager.contentsOfDirectory(atPath: legacy.path))?.isEmpty ?? false) {
            try? manager.removeItem(at: legacy)
        }
        return
    }
    try? manager.moveItem(at: legacy, to: target)
}

/// Есть ли в каталоге НАШИ данные. Посторонние папки вроде кэша моделей
/// данными приложения не считаются: именно из-за такой папки первый вариант
/// переезда и заклинил.
func privateRootHasData(at url: URL, fileManager manager: FileManager = .default) -> Bool {
    let ours = ["dictations", "counters.json", "status.json", "terms.json"]
    return ours.contains { manager.fileExists(atPath: url.appendingPathComponent($0).path) }
}

public func createPrivateDirectory(
    at url: URL,
    withIntermediateDirectories: Bool,
    fileManager: FileManager = .default
) throws {
    try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: withIntermediateDirectories,
        attributes: [.posixPermissions: PRIVATE_DIRECTORY_MODE]
    )
    try fileManager.setAttributes(
        [.posixPermissions: PRIVATE_DIRECTORY_MODE],
        ofItemAtPath: url.path
    )
}

// MARK: - Приватная запись файлов (0600, без симлинков и хардлинков)

public func appendPrivateLogData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
        throw currentPOSIXError()
    }

    try writeAllData(data, to: fd)
}

public func validateSingleLinkRegularFileDescriptor(_ fd: Int32) throws {
    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw posixError(EFTYPE)
    }
    guard st.st_nlink == 1 else {
        throw posixError(EMLINK)
    }
}

public func writeAllData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(
                fd,
                base.advanced(by: offset),
                rawBuffer.count - offset
            )
            if written < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

public func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

public func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

/// Имя каталога, за пределы которого рекурсивная смена прав не выходит.
public let IRIZ_PRIVATE_ROOT_NAME = "iriz"

public func migrateSmltlkPrivateFilePermissionsOnce(
    at root: URL,
    defaults: UserDefaults,
    fileManager: FileManager = .default,
    log: @escaping (String) -> Void = { _ in }
) {
    // ПРЕДОХРАНИТЕЛЬ. Это рекурсивная смена прав, и корень ей передаёт вызывающий.
    // Вызывающий получает корень отрезанием последнего компонента от пути к
    // хранилищу надиктовок — то есть одна опечатка выше по стеку наводит chmod
    // на общий каталог. Замерено, а не выдумано: тесты передали каталог,
    // лежащий прямо в корне temp, и миграция пошла чесать права
    // com.apple.financed, proactived и searchpartyuseragent. Система не дала,
    // но полагаться на это нельзя.
    // Поэтому корень обязан называться своим именем, иначе работы не будет.
    guard root.lastPathComponent == IRIZ_PRIVATE_ROOT_NAME else {
        log("Private file permission migration refused: \(root.path) is not an iriz root")
        return
    }

    guard !defaults.bool(forKey: SMLTLK_PRIVATE_FILE_PERMISSION_MIGRATION_KEY) else {
        return
    }

    var hadError = false

    func record(_ url: URL, _ error: Error) {
        hadError = true
        log("Private file permission migration failed for \(url.path): \(error.localizedDescription)")
    }

    guard fileManager.fileExists(atPath: root.path) else {
        defaults.set(true, forKey: SMLTLK_PRIVATE_FILE_PERMISSION_MIGRATION_KEY)
        return
    }

    do {
        try applyPrivatePermission(to: root)
    } catch {
        record(root, error)
    }

    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { url, error in
            hadError = true
            log("Private file permission migration cannot enumerate \(url.path): \(error.localizedDescription)")
            return true
        }
    ) else {
        defaults.set(false, forKey: SMLTLK_PRIVATE_FILE_PERMISSION_MIGRATION_KEY)
        return
    }

    for case let url as URL in enumerator {
        do {
            try applyPrivatePermission(to: url)
        } catch {
            record(url, error)
        }
    }

    if !hadError {
        defaults.set(true, forKey: SMLTLK_PRIVATE_FILE_PERMISSION_MIGRATION_KEY)
    }
}

private func applyPrivatePermission(to url: URL) throws {
    var st = stat()
    guard Darwin.lstat(url.path, &st) == 0 else {
        throw currentPOSIXError()
    }

    switch st.st_mode & S_IFMT {
    case S_IFDIR:
        guard Darwin.chmod(url.path, PRIVATE_DIRECTORY_MODE) == 0 else {
            throw currentPOSIXError()
        }
    case S_IFREG:
        guard Darwin.chmod(url.path, PRIVATE_LOG_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
    default:
        return
    }
}
