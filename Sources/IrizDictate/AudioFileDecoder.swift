// Чтение готового файла в те же 16 кГц моно Float32, что даёт микрофон.
//
// Один системный путь — AVAssetReader поверх AVURLAsset: он же демультиплексор,
// он же ресемплер, он же сведение каналов. Ни ffmpeg, ни новых зависимостей;
// AVFoundation уже линкуется ради захвата звука (AudioCapture.swift).
//
// Сети здесь нет по конструкции: URL всегда файловый (`fileURLWithPath`),
// удалённые схемы до AVURLAsset не доходят.
import AVFoundation
import Foundation

/// Звук, готовый к распознаванию.
public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let seconds: Double
}

/// Отказ на чтении файла. Формулировки — для человека, не для лога.
public enum AudioDecodingError: Error, Equatable {
    case unreadable(path: String, reason: String)
    case noAudioTrack(path: String)
    case silentOrEmpty(path: String)
    case tooShort(path: String, seconds: Double)

    public var message: String {
        switch self {
        case .unreadable(let path, let reason):
            return "Не смог прочитать \(path) как звук: \(reason)"
        case .noAudioTrack(let path):
            return "В \(path) нет звуковой дорожки — расшифровывать нечего."
        case .silentOrEmpty(let path):
            return "В \(path) нет ни одного отсчёта звука."
        case .tooShort(let path, let seconds):
            return String(format: "В %@ всего %.2f с звука — распознаватель требует минимум %.1f с.",
                          path, seconds, AudioFileDecoder.minimumSeconds)
        }
    }
}

public enum AudioFileDecoder {
    /// Частота распознавателя. Та же, что у микрофонного пути.
    public static let targetSampleRate: Double = SAMPLE_RATE
    /// Ниже этого FluidAudio отвечает `invalidAudioData`. Лучше сказать заранее
    /// и своими словами, чем показать чужую ошибку из библиотеки.
    public static let minimumSeconds: Double = 0.3

    /// Длительность без декодирования — для честной оценки «сколько ждать».
    /// `nil`, если длительность неизвестна: тогда и оценки не будет.
    public static func probeSeconds(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// Полное декодирование в память.
    ///
    /// Держим весь звук массивом: 16 кГц моно Float32 — это ~230 МБ на час
    /// записи. Для заседания на пару часов приемлемо, и зато на диск не ложится
    /// ни одной временной копии чужого разговора.
    public static func decode(_ url: URL) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioDecodingError.unreadable(path: url.path,
                                                reason: error.localizedDescription)
        }
        guard !tracks.isEmpty else {
            throw AudioDecodingError.noAudioTrack(path: url.path)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioDecodingError.unreadable(path: url.path,
                                                reason: error.localizedDescription)
        }

        // Сведение всех звуковых дорожек в одну моно 16 кГц делает сам
        // AVFoundation: у записи с телефона дорожка одна, у видео с камеры
        // их бывает две, и обе — голос в зале.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks,
                                                 audioSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioDecodingError.unreadable(path: url.path,
                                                reason: "система не берётся декодировать этот формат")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecodingError.unreadable(
                path: url.path,
                reason: reader.error?.localizedDescription ?? "чтение не началось"
            )
        }

        var samples: [Float] = []
        if let seconds = await probeSeconds(url) {
            samples.reserveCapacity(Int(seconds * targetSampleRate))
        }
        while let buffer = output.copyNextSampleBuffer() {
            try appendSamples(from: buffer, to: &samples, path: url.path)
            CMSampleBufferInvalidate(buffer)
        }

        if reader.status == .failed {
            throw AudioDecodingError.unreadable(
                path: url.path,
                reason: reader.error?.localizedDescription ?? "чтение оборвалось"
            )
        }
        guard !samples.isEmpty else {
            throw AudioDecodingError.silentOrEmpty(path: url.path)
        }
        let seconds = Double(samples.count) / targetSampleRate
        guard seconds >= minimumSeconds else {
            throw AudioDecodingError.tooShort(path: url.path, seconds: seconds)
        }
        return DecodedAudio(samples: samples, seconds: seconds)
    }

    /// Вычисляемое, а не константа: словарь `[String: Any]` не Sendable,
    /// и глобальным его в Swift 6 не удержать.
    private static var pcmSettings: [String: Any] {[
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: targetSampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]}

    private static func appendSamples(from buffer: CMSampleBuffer,
                                      to samples: inout [Float],
                                      path: String) throws {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= MemoryLayout<Float>.size else { return }

        var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(kCMBlockBufferBlockAllocationFailedErr) }
            return CMBlockBufferCopyDataBytes(block,
                                              atOffset: 0,
                                              dataLength: raw.count,
                                              destination: base)
        }
        guard status == kCMBlockBufferNoErr else {
            throw AudioDecodingError.unreadable(path: path,
                                                reason: "не смог скопировать отсчёты (\(status))")
        }
        samples.append(contentsOf: chunk)
    }
}
