// Распознавание по говорящим: запуск диаризатора на файле записи.
//
// Всё на устройстве. Диаризатор FluidAudio уже лежит в доме, ему нужны свои
// модели CoreML - те же правила, что у распознавателя:
//
//   Установка получает только закреплённые публичные файлы отдельным
//   действием человека. Глобальный рубильник офлайна не меняется.
//   Наружу при разборе записи не уходит ничего: файл владельца
//   остаётся на его машине, и это условие, а не настройка.
//
// Отказы названы поимённо: «не смог» без причины неотличимо от поломки, а
// разбирать здесь будут запись судебного заседания.
import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum SpeakerDiarizationFailure: String, Error, Equatable {
    case modelsMissing = "модели распознавания говорящих не установлены"
    case modelsInvalid = "модели распознавания говорящих повреждены или несовместимы"
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
    private var processing = false
    private var installing = false
    private let modelsDirectory: URL

    /// Родитель каталога speaker-diarization; параметр нужен и для
    /// изолированной проверки отсутствующего кэша, без чтения личных моделей.
    public init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory ?? OfflineDiarizerModels.defaultModelsDirectory()
    }

    /// Только готовый локальный кэш. Не используем DownloadUtils.loadModels:
    /// его recovery может удалять кэш и выходить в сеть при глобальном false.
    public func prepareOffline() async throws {
        try Task.checkCancellation()
        guard !installing else { throw SpeakerDiarizationFailure.engineFailed }
        try prepareOfflineModels()
    }

    private func prepareOfflineModels() throws {
        try Task.checkCancellation()
        guard !ready else { return }
        do {
            let paths = try speakerDiarizationModelURLs(in: modelsDirectory)
            let started = ProcessInfo.processInfo.systemUptime
            let psi = try speakerDiarizationPLDAPsi(from: Data(contentsOf: paths[4]))
            var models: [MLModel] = []
            for (index, path) in paths.prefix(4).enumerated() {
                try Task.checkCancellation()
                let config = MLModelConfigurationUtils.defaultConfiguration(
                    computeUnits: index == 1 ? .cpuOnly : .all)
                models.append(try MLModel(contentsOf: path, configuration: config))
            }
            try Task.checkCancellation()
            manager.initialize(models: OfflineDiarizerModels(
                segmentationModel: models[0], fbankModel: models[1], embeddingModel: models[2],
                pldaRhoModel: models[3], pldaPsi: psi,
                compilationDuration: ProcessInfo.processInfo.systemUptime - started))
            ready = true
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SpeakerDiarizationFailure {
            try Task.checkCancellation()
            throw failure
        } catch {
            try Task.checkCancellation()
            throw SpeakerDiarizationFailure.modelsInvalid
        }
    }

    /// Явная установка 21,6 МБ. Кэш публикуется после проверки всех SHA-256;
    /// предыдущая копия сохраняется. Никакого глобального сетевого toggle.
    public func installModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard !installing, !processing else { throw SpeakerDiarizationFailure.engineFailed }
        installing = true
        defer { installing = false }
        try await SpeakerModelInstaller.shared.install(modelsDirectory: modelsDirectory, progress: progress)
        try Task.checkCancellation()
        ready = false
        try prepareOfflineModels()
    }

    /// Уже установлены ли модели: спрашивается до разбора, чтобы отказ пришёл
    /// сразу, а не после минуты ожидания.
    public var modelsInstalled: Bool { ready }

    /// Разбор записи на дорожки говорящих.
    ///
    /// Сеть здесь запрещена: рубильник офлайна не трогается, и любой сетевой
    /// вызов внутри FluidAudio бросит ошибку вместо тихого обращения наружу.
    public func spans(of url: URL) async throws -> [SpeakerSpan] {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SpeakerDiarizationFailure.audioUnreadable }
        guard !processing, !installing else { throw SpeakerDiarizationFailure.engineFailed }
        processing = true
        defer { processing = false }
        let duration: Double
        do {
            duration = try await audioDurationSeconds(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw SpeakerDiarizationFailure.audioUnreadable
        }
        try Task.checkCancellation()
        guard duration.isFinite else { throw SpeakerDiarizationFailure.audioUnreadable }
        guard duration >= speakerDiarizationMinimumSeconds else {
            throw SpeakerDiarizationFailure.tooShort
        }
        try await prepareOffline()
        do {
            let result = try await manager.process(url)
            try Task.checkCancellation()
            return speakerSpans(from: result.segments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw SpeakerDiarizationFailure.engineFailed
        }
    }
}

/// Порядок соответствует public initializer OfflineDiarizerModels. Ничего не
/// создаёт и не удаляет; даже частичный кэш остаётся как был.
func speakerDiarizationModelURLs(in root: URL) throws -> [URL] {
    guard root.isFileURL else { throw SpeakerDiarizationFailure.modelsMissing }
    let directory = root.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    let names = [ModelNames.OfflineDiarizer.segmentationPath, ModelNames.OfflineDiarizer.fbankPath,
                 ModelNames.OfflineDiarizer.embeddingPath, ModelNames.OfflineDiarizer.pldaRhoPath,
                 ModelNames.OfflineDiarizer.pldaParameters]
    let paths = names.map { directory.appendingPathComponent($0) }
    for (index, path) in paths.enumerated() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw SpeakerDiarizationFailure.modelsMissing
        }
        guard isDirectory.boolValue == (index < 4) else { throw SpeakerDiarizationFailure.modelsInvalid }
        if index < 4, !FileManager.default.fileExists(atPath: path.appendingPathComponent("coremldata.bin").path) {
            throw SpeakerDiarizationFailure.modelsInvalid
        }
    }
    return paths
}

/// Формат PLDA тот же, что читает FluidAudio. Float32 little-endian, без
/// игнорирования повреждённых base64/хвоста и без нефинитных параметров модели.
func speakerDiarizationPLDAPsi(from data: Data) throws -> [Double] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tensors = root["tensors"] as? [String: Any],
          let psi = tensors["psi"] as? [String: Any],
          let base64 = psi["data_base64"] as? String,
          let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count % 4 == 0 else {
        throw SpeakerDiarizationFailure.modelsInvalid
    }
    var values: [Double] = []
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        let value = Double(Float(bitPattern: bits))
        guard value.isFinite, value >= 0 else { throw SpeakerDiarizationFailure.modelsInvalid }
        values.append(value)
    }
    return values
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
