// Словарь замен и заготовки — в файл и обратно.
//
// ЗАЧЕМ. Не «вторая машина» (её долго не было), а бэкап: и словарь, и
// заготовки живут только в UserDefaults. Снёс defaults — снёс руками
// выверенный словарь целиком, восстановить неоткуда. JSON рядом с делами
// стоит одну кнопку и спасает годы правок.
//
// ФОРМАТ. Обычный читаемый JSON: кириллица не экранируется, ключи
// отсортированы, отступы есть. Файл можно открыть в редакторе, поправить
// руками и импортировать обратно — это его вторая функция.
//
// ОТКАЗ ГРОМКИЙ. Любая негодная запись валит ВЕСЬ файл с указанием, какая
// именно. Частичный импорт бэкапа хуже отказа: владелец уйдёт в уверенности,
// что словарь восстановлен, а на месте окажется половина.
import IrizCore
import Foundation

// MARK: - Документ

public struct DictionaryTransferDocument: Equatable, Sendable {
    public let corrections: [TranscriptCorrection]
    public let snippets: [DictationSnippet]

    public init(corrections: [TranscriptCorrection], snippets: [DictationSnippet]) {
        self.corrections = corrections
        self.snippets = snippets
    }
}

// MARK: - Отказы

public enum DictionaryTransferError: Error, Equatable {
    case notJSON
    case foreignFile
    case futureFormat(Int)
    case wrongShape(field: String)
    case badCorrection(index: Int, reason: String)
    case badSnippet(index: Int, reason: String)
    case emptyDocument
    case tooManyCorrections(Int)
    case tooManySnippets(Int)
    case correctionLimitExceeded(total: Int)
    case snippetLimitExceeded(total: Int)

    /// Человеку, а не в лог: что именно не так и что с этим делать.
    public var message: String {
        switch self {
        case .notJSON:
            "Файл не читается как JSON. Похоже, выбран не тот файл или он повреждён."
        case .foreignFile:
            "Это не файл словаря \(IRIZ_NAME). Импортируются только файлы, сделанные кнопкой «Экспортировать»."
        case .futureFormat(let version):
            "Файл сделан более новой версией \(IRIZ_NAME) (формат \(version), здесь понимают \(DictionaryTransfer.formatVersion)). Обновите приложение."
        case .wrongShape(let field):
            "В файле повреждено поле «\(field)» — там не то, что ожидалось."
        case .badCorrection(let index, let reason):
            "Замена №\(index + 1) не годится: \(reason). Ничего не импортировано."
        case .badSnippet(let index, let reason):
            "Заготовка №\(index + 1) не годится: \(reason). Ничего не импортировано."
        case .emptyDocument:
            "В файле нет ни одной замены и ни одной заготовки — импортировать нечего."
        case .tooManyCorrections(let count):
            "В файле \(count) замен — больше предела \(MAX_TRANSCRIPT_CORRECTIONS)."
        case .tooManySnippets(let count):
            "В файле \(count) заготовок — больше предела \(MAX_DICTATION_SNIPPETS)."
        case .correctionLimitExceeded(let total):
            "После импорта замен стало бы \(total) — больше предела \(MAX_TRANSCRIPT_CORRECTIONS). Удалите лишние и повторите."
        case .snippetLimitExceeded(let total):
            "После импорта заготовок стало бы \(total) — больше предела \(MAX_DICTATION_SNIPPETS). Удалите лишние и повторите."
        }
    }
}

// MARK: - Итог слияния

public struct DictionaryImportOutcome: Equatable, Sendable {
    public let corrections: [TranscriptCorrection]
    public let snippets: [DictationSnippet]
    public let addedCorrections: Int
    public let updatedCorrections: Int
    public let addedSnippets: Int
    public let updatedSnippets: Int

    /// Отчёт вслух. Тихий импорт неотличим от импорта, который ничего не сделал.
    public var summary: String {
        var parts: [String] = []
        if addedCorrections > 0 { parts.append("замен добавлено \(addedCorrections)") }
        if updatedCorrections > 0 { parts.append("замен перезаписано \(updatedCorrections)") }
        if addedSnippets > 0 { parts.append("заготовок добавлено \(addedSnippets)") }
        if updatedSnippets > 0 { parts.append("заготовок перезаписано \(updatedSnippets)") }
        guard !parts.isEmpty else {
            return "Всё из файла уже было заведено — менять нечего."
        }
        return "Импорт: " + parts.joined(separator: ", ") + "."
    }
}

// MARK: - Кодирование и разбор

public enum DictionaryTransfer {
    public static let formatVersion = 1
    static let marker = "smltlk-dictionary"
    public static let suggestedFileName = "irida-словарь.json"

    private struct Payload: Encodable {
        let corrections: [TranscriptCorrection]
        let smltlk: String
        let snippets: [DictationSnippet]
        let version: Int
    }

    /// На выход идёт УЖЕ нормализованный набор — ровно то, что работает в
    /// приложении. Экспортировать сырьё из редактора значило бы записать
    /// в бэкап полупустые строки, которые движок всё равно не применяет.
    public static func encode(corrections: [TranscriptCorrection],
                              snippets: [DictationSnippet]) -> Data {
        let payload = Payload(
            corrections: normalizedTranscriptCorrections(corrections),
            smltlk: marker,
            snippets: normalizedDictationSnippets(snippets),
            version: formatVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Кодирование фиксированной структуры без пользовательских типов
        // упасть не может; пустой Data наружу отдавать нельзя — это был бы
        // бэкап-пустышка, поэтому падаем громко.
        guard let data = try? encoder.encode(payload) else {
            preconditionFailure("JSONEncoder не смог закодировать словарь")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> DictionaryTransferDocument {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw DictionaryTransferError.notJSON
        }
        guard let root = object as? [String: Any],
              let fileMarker = root["smltlk"] as? String,
              fileMarker == marker else {
            throw DictionaryTransferError.foreignFile
        }
        guard let version = root["version"] as? Int, version >= 1 else {
            throw DictionaryTransferError.wrongShape(field: "version")
        }
        guard version <= formatVersion else {
            throw DictionaryTransferError.futureFormat(version)
        }

        let corrections = try decodeCorrections(root["corrections"])
        let snippets = try decodeSnippets(root["snippets"])
        guard !corrections.isEmpty || !snippets.isEmpty else {
            throw DictionaryTransferError.emptyDocument
        }
        return DictionaryTransferDocument(corrections: corrections, snippets: snippets)
    }

    private static func decodeCorrections(_ raw: Any?) throws -> [TranscriptCorrection] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let rows = raw as? [Any] else {
            throw DictionaryTransferError.wrongShape(field: "corrections")
        }
        guard rows.count <= MAX_TRANSCRIPT_CORRECTIONS else {
            throw DictionaryTransferError.tooManyCorrections(rows.count)
        }

        var result: [TranscriptCorrection] = []
        for (index, row) in rows.enumerated() {
            guard let row = row as? [String: Any],
                  let source = row["source"] as? String,
                  let replacement = row["replacement"] as? String else {
                throw DictionaryTransferError.badCorrection(
                    index: index,
                    reason: "нет пары «source» и «replacement» из двух строк"
                )
            }
            switch validatedTranscriptCorrection(
                TranscriptCorrection(source: source, replacement: replacement)
            ) {
            case .success(let correction):
                result.append(correction)
            case .failure(let defect):
                throw DictionaryTransferError.badCorrection(index: index, reason: defect.message)
            }
        }
        return normalizedTranscriptCorrections(result)
    }

    private static func decodeSnippets(_ raw: Any?) throws -> [DictationSnippet] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let rows = raw as? [Any] else {
            throw DictionaryTransferError.wrongShape(field: "snippets")
        }
        guard rows.count <= MAX_DICTATION_SNIPPETS else {
            throw DictionaryTransferError.tooManySnippets(rows.count)
        }

        var result: [DictationSnippet] = []
        for (index, row) in rows.enumerated() {
            guard let row = row as? [String: Any],
                  let trigger = row["trigger"] as? String,
                  let body = row["body"] as? String else {
                throw DictionaryTransferError.badSnippet(
                    index: index,
                    reason: "нет пары «trigger» и «body» из двух строк"
                )
            }
            switch validatedDictationSnippet(DictationSnippet(trigger: trigger, body: body)) {
            case .success(let snippet):
                result.append(snippet)
            case .failure(let defect):
                throw DictionaryTransferError.badSnippet(index: index, reason: defect.message)
            }
        }
        return normalizedDictationSnippets(result)
    }

    // MARK: - Слияние

    /// СТОЛКНОВЕНИЕ ИМЁН: побеждает файл, запись остаётся на своём месте
    /// в списке.
    ///
    /// Почему так, а не «пропустить существующие» и не «заменить всё».
    /// Пропуск существующих ломает главный сценарий: файл на то и бэкап, что
    /// в нём выверенная версия записи; молча оставить местную — значит не
    /// восстановить ничего и не сказать об этом. Замена всего списка целиком
    /// убивает записи, которых в файле нет: перенос со старой машины стёр бы
    /// всё, что заведено на новой. Слияние не удаляет ничего и сообщает
    /// числом, сколько записей перезаписано, — а полная замена достижима
    /// руками: очистить список и импортировать. Разрушительное остаётся
    /// осознанным действием, а не побочным эффектом импорта.
    public static func merge(_ document: DictionaryTransferDocument,
                             intoCorrections corrections: [TranscriptCorrection],
                             snippets: [DictationSnippet]) throws -> DictionaryImportOutcome {
        let existingCorrections = normalizedTranscriptCorrections(corrections)
        let existingSnippets = normalizedDictationSnippets(snippets)

        let existingCorrectionKeys = Set(existingCorrections.map {
            normalizedTranscriptCorrectionSource($0.source)
        })
        let existingSnippetKeys = Set(existingSnippets.map {
            normalizedDictationSnippetTrigger($0.trigger)
        })

        let importedCorrectionKeys = Set(document.corrections.map {
            normalizedTranscriptCorrectionSource($0.source)
        })
        let importedSnippetKeys = Set(document.snippets.map {
            normalizedDictationSnippetTrigger($0.trigger)
        })

        // Предел проверяем ДО слияния: нормализация обрезала бы хвост молча,
        // и отчёт «добавлено N» соврал бы.
        let totalCorrections = existingCorrectionKeys.union(importedCorrectionKeys).count
        guard totalCorrections <= MAX_TRANSCRIPT_CORRECTIONS else {
            throw DictionaryTransferError.correctionLimitExceeded(total: totalCorrections)
        }
        let totalSnippets = existingSnippetKeys.union(importedSnippetKeys).count
        guard totalSnippets <= MAX_DICTATION_SNIPPETS else {
            throw DictionaryTransferError.snippetLimitExceeded(total: totalSnippets)
        }

        let updatedCorrections = importedCorrectionKeys.intersection(existingCorrectionKeys).count
        let updatedSnippets = importedSnippetKeys.intersection(existingSnippetKeys).count

        return DictionaryImportOutcome(
            corrections: normalizedTranscriptCorrections(existingCorrections + document.corrections),
            snippets: normalizedDictationSnippets(existingSnippets + document.snippets),
            addedCorrections: importedCorrectionKeys.count - updatedCorrections,
            updatedCorrections: updatedCorrections,
            addedSnippets: importedSnippetKeys.count - updatedSnippets,
            updatedSnippets: updatedSnippets
        )
    }
}
