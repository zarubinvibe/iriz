import Foundation
import IrizCore

/// Каталог данных приложения. Путь НЕ строится здесь: он приходит из
/// `irizApplicationSupportDirectory()` - единственного места, которое знает имя
/// каталога и умеет перевезти его со старого имени.
///
/// Прежде путь собирался прямо тут, своими руками. Это была пятая копия одного
/// адреса в проекте, и именно из-за неё переименование продукта осталось
/// половинчатым: всё приложение переехало, а снимок состояния продолжал
/// дописывать status.json по старому пути, воскрешая мёртвый каталог.
enum SupportPaths {
    static var dir: URL {
        (try? irizApplicationSupportDirectory()) ?? irizApplicationSupportDirectoryURL()
    }
}

/// Диагностический снимок состояния приложения — опора scripts/gate_app.sh.
///
/// Счётчики вставки накопительные: их растит DictationController по вердикту
/// доставки, а снимок публикует итог. Так частота главной боли («сказал, а
/// текста нет») становится измеримой — до этого числа не было ни у кого.
enum StatusReport {
    static func write(ax: Bool, listen: Bool, post: Bool, loginItem: Bool) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let stats = InsertionStats()
        guard let data = statusReportJSONData(ax: ax,
                                              listen: listen,
                                              post: post,
                                              loginItem: loginItem,
                                              version: version,
                                              insertionAttempts: stats.attempts,
                                              insertionFailures: stats.failures,
                                              // Разбивка по причинам: процент отказов
                                              // без неё недиагностируем, и это уже
                                              // стоило владельцу 76 непонятных случаев.
                                              insertionFailureReasons: stats.failureBreakdown(
                                                  reasons: INSERTION_FAILURE_REASONS),
                                              insertionNothingToInsert: stats.nothingToInsert
                                             ) else { return }
        try? data.write(to: SupportPaths.dir.appendingPathComponent("status.json"), options: .atomic)
    }
}
