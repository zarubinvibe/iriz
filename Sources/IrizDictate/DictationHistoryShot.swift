import SwiftUI

/// Что показать на снимке окна истории. Прибор поверхностей снимает все три:
/// пустой список тоже часть внешнего вида, и он тоже бывает уродливым.
public enum DictationHistoryShotKind: String, CaseIterable, Sendable {
    case list, empty, rescue
}

/// Вид окна истории для прибора раскадровки поверхностей.
///
/// Это ТОТ ЖЕ вид, что живёт в панели (`DictationHistoryView`), с
/// детерминированными данными вместо диска: приговор внешнему виду выносится
/// по снимку, а снимок обязан показывать настоящую вёрстку, а не макет.
@MainActor
public func dictationHistoryShotView(_ kind: DictationHistoryShotKind) -> AnyView {
    let model = DictationHistoryModel()
    switch kind {
    case .list:
        model.load(dictationHistoryShotEntries())
    case .empty:
        model.load([])
    case .rescue:
        model.load(dictationHistoryShotEntries())
        model.showRescue(DictationRescue(
            text: "Проверь, пожалуйста, что ворота натуральной величины стоят в приемке, "
                + "и покажи кадр 248 на 74 рядом с прежним.",
            failure: .insertionFailed
        ))
    }
    return AnyView(DictationHistoryView(model: model))
}

/// Записи для снимка. Текст выдуман: реальные надиктовки владельца в
/// раскадровку не попадают никогда.
private func dictationHistoryShotEntries() -> [DictationHistoryEntry] {
    let base = URL(fileURLWithPath: "/tmp/iriz-shot", isDirectory: true)
    let rows: [(String, String?, String?)] = [
        ("Собери прибор, который снимает все поверхности приложения одной командой.", nil, nil),
        ("Лента записи должна читаться лентой, а не толстой линией.",
         "Лента записи должна читаться лентой, а не толстой линией.", nil),
        ("Ночная тема - это ночное небо, прямо со звездами.", nil, nil),
        ("речь про то как собрать промпт под проект",
         nil,
         "Собери промпт под текущий проект: дом определяется рабочим каталогом сессии."),
        ("Отдельно проверь контраст и уменьшенную анимацию в обеих темах.",
         "Отдельно проверь контраст и уменьшенную анимацию в обеих темах.", nil),
    ]
    return rows.enumerated().map { index, row in
        DictationHistoryEntry(
            // Имя каталога такое же, как в проде: из него окно берёт подпись,
            // и снимок обязан показывать настоящий формат, а не «-01».
            directory: base.appendingPathComponent(String(format: "2026-09-03_1%d-2%d-4%d",
                                                          index, index * 2 % 6, index * 7 % 6)),
            text: row.0,
            insertedText: row.1,
            generatedText: row.2
        )
    }
}
