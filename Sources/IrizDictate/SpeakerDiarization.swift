// Распознавание по говорящим: запуск диаризатора на файле записи.
//
// Всё на устройстве. Диаризатор FluidAudio уже лежит в доме, ему нужны свои
// модели CoreML - те же правила, что у распознавателя:
//
//   Рубильник офлайна снимается ТОЛЬКО на время явной установки моделей,
//   которую начал человек, и возвращается в `defer` - в том числе на ошибке и
//   на отмене. Наружу при разборе записи не уходит ничего: файл владельца
//   остаётся на его машине, и это условие, а не настройка.
//
// Отказы названы поимённо: «не смог» без причины неотличимо от поломки, а
// разбирать здесь будут запись судебного заседания.
import AVFoundation
import FluidAudio
import Foundation

public enum SpeakerDiarizationFailure: String, Error, Equatable {
    case modelsMissing = "модели распознавания говорящих не установлены"
    case audioUnreadable = "запись не читается"
    case tooShort = "запись короче, чем нужно для разбора"
    case engineFailed = "разбор не удался"
}

/// Короче этого разбирать нечего: диаризатору нужен кусок речи, а не хлопок.
let speakerDiarizationMinimumSeconds: Double = 3

/// Актор, а не класс на главной очереди: движок диаризатора не Sendable, и
/// звать его асинхронные методы с главной очереди значит гонять чужой объект
/// между изоляциями. Актор даёт ему один дом.
public actor SpeakerDiarizer {
    // `nonisolated(unsafe)` тем же приёмом, что и внутри самого движка: модели
    // CoreML не Sendable, но после установки читаются только на чтение, а
    // единственная точка входа сюда - этот актор.
    nonisolated(unsafe) private let manager = OfflineDiarizerManager()
    private var ready = false

    public init() {}

    /// Установка моделей. Отдельным шагом и по решению человека: тянуть
    /// полгигабайта молча в момент, когда он бросил файл в окно, нельзя.
    public func installModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        DownloadUtils.enforceOffline = false
        defer { DownloadUtils.enforceOffline = true }
        let models = try await OfflineDiarizerModels.load { snapshot in
            progress(snapshot.fractionCompleted)
        }
        manager.initialize(models: models)
        ready = true
    }

    /// Уже установлены ли модели: спрашивается до разбора, чтобы отказ пришёл
    /// сразу, а не после минуты ожидания.
    public var modelsInstalled: Bool { ready }

    /// Разбор записи на дорожки говорящих.
    ///
    /// Сеть здесь запрещена: рубильник офлайна не трогается, и любой сетевой
    /// вызов внутри FluidAudio бросит ошибку вместо тихого обращения наружу.
    public func spans(of url: URL) async throws -> [SpeakerSpan] {
        guard ready else { throw SpeakerDiarizationFailure.modelsMissing }
        guard let duration = try? await audioDurationSeconds(url) else {
            throw SpeakerDiarizationFailure.audioUnreadable
        }
        guard duration >= speakerDiarizationMinimumSeconds else {
            throw SpeakerDiarizationFailure.tooShort
        }
        do {
            let result = try await manager.process(url)
            return speakerSpans(from: result.segments)
        } catch {
            log("diarization: \(error)")
            throw SpeakerDiarizationFailure.engineFailed
        }
    }
}

/// Перевод отрезков движка в наш вид.
///
/// Отдельной чистой функцией, потому что это единственное место, где чужой тип
/// встречается с нашим: проба судит перевод без моделей и без записи.
public func speakerSpans(from segments: [TimedSpeakerSegment]) -> [SpeakerSpan] {
    segments
        .map { SpeakerSpan(speaker: $0.speakerId,
                           start: Double($0.startTimeSeconds),
                           end: Double($0.endTimeSeconds)) }
        .filter { $0.end > $0.start }
        .sorted { $0.start < $1.start }
}

private func audioDurationSeconds(_ url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
}
