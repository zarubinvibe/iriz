// Живая запись встречи с микрофона.
//
// Цвет режима записи уже был, а начать запись было нечем: состояние
// существовало и оставалось недостижимым. Владелец это и заметил.
//
// ЧЕМ ЗАПИСЬ ВСТРЕЧИ ОТЛИЧАЕТСЯ ОТ ДИКТОВКИ, И ПОЧЕМУ ЭТО ОТДЕЛЬНЫЙ ПУТЬ.
//
//   Диктовка   короткая, звук не сохраняется, текст едет в поле под курсором.
//   Встреча    длинная, звук СОХРАНЯЕТСЯ вместе с расшифровкой, текст никуда
//              не вставляется - он ложится протоколом в свою папку.
//
// Смешать их нельзя: вставленный посреди чужого письма протокол заседания и
// незаписанный звук - две разные катастрофы, и обе тихие.
//
// ПОТОЛОК НАЗВАН ВСЛУХ. Звук копится в памяти и пишется на диск при остановке.
// Час записи это около 230 МБ при 16 кГц, и на трёхчасовом заседании такой
// подход упрётся в память. Поэтому стоит жёсткий предел: на нём запись
// останавливается САМА и сохраняется, а не падает. Потоковая запись прямо в
// файл - следующий шаг, и делать её нужно тогда, когда предел начнёт мешать,
// а не раньше.
import AVFoundation
import Foundation

/// Предел одной записи. Три часа: обычное судебное заседание короче, а всё,
/// что длиннее, надёжнее вести диктофоном и приносить файлом.
public let meetingRecordingLimitSeconds: Double = 3 * 60 * 60

public enum MeetingRecorderFailure: String, Error, Equatable {
    case alreadyRecording = "запись уже идёт"
    case nothingRecorded = "звук не записался"
    case cannotWriteFile = "не удалось записать звук на диск"
}

/// Запись сохранена в файл. Дальше её берёт MeetingPipeline.
public struct MeetingRecording: Sendable {
    public let url: URL
    public let seconds: Double
}

/// Сохранение накопленных сэмплов в WAV.
///
/// Отдельной чистой функцией: запись на диск проверяется пробой без микрофона
/// и без разрешений системы, а это единственное место, где звук встречи
/// превращается в файл - тот самый файл, который потом лежит доказательством.
public func writeMeetingWAV(samples: [Float], sampleRate: Double,
                            to url: URL) throws -> MeetingRecording {
    guard !samples.isEmpty else { throw MeetingRecorderFailure.nothingRecorded }
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: 1,
                                     interleaved: false) else {
        throw MeetingRecorderFailure.cannotWriteFile
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = buffer.floatChannelData?[0] else {
        throw MeetingRecorderFailure.cannotWriteFile
    }
    samples.withUnsafeBufferPointer { source in
        channel.update(from: source.baseAddress!, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
    // Права закрываются сразу: это запись чужого голоса, и лежать открытой она
    // не должна ни секунды.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: url.path)
    return MeetingRecording(url: url, seconds: Double(samples.count) / sampleRate)
}

/// Куда падает свежая запись до разбора. Отдельная папка, а не общий временный
/// каталог: файл может пролежать до конца разбора, и терять его нельзя.
public func meetingRecordingScratchURL(at date: Date = Date()) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let root = try MeetingStore.meetingsDirectory()
        .appendingPathComponent("_recording", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return root.appendingPathComponent("meeting-\(formatter.string(from: date)).wav")
}
