// Тесты расшифровки файла и папки.
//
// Модели под `swift test` нет и быть не должно (16 с прогрева и ANE на каждый
// прогон), поэтому проверяются РЕШЕНИЯ и ЧТЕНИЕ ЗВУКА — всё, что не требует
// распознавателя:
//   • какие файлы папки берём и в каком порядке;
//   • куда ложится расшифровка и когда мы отказываемся её класть;
//   • что декодер делает с не-звуком, пустышкой и слишком коротким клипом;
//   • что показывается в строке прогресса, пока мерить нечем.
//
// Звук синтезируется здесь же: 440 Гц, 44,1 кГц, два канала — то есть путь
// «пересчёт частоты + сведение в моно» проверяется живьём, а не на словах.
import AVFoundation
import Foundation
import Testing

@testable import IrizDictate

// MARK: - Опора

private func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("smltlk-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func withTempDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("smltlk-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

/// Настоящий WAV: тон 440 Гц, стерео, 44,1 кГц — специально НЕ в том формате,
/// который нужен распознавателю.
@discardableResult
private func writeToneWAV(at url: URL,
                          seconds: Double,
                          sampleRate: Double = 44_100,
                          channels: AVAudioChannelCount = 2) throws -> URL {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(seconds * sampleRate))
    else {
        Issue.record("не удалось собрать буфер для тона")
        return url
    }
    let frames = Int(seconds * sampleRate)
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(channels) {
        let samples = buffer.floatChannelData![channel]
        for index in 0..<frames {
            samples[index] = 0.2 * sinf(2 * .pi * 440 * Float(index) / Float(sampleRate))
        }
    }
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
    return url
}

// MARK: - Что берём из папки

@Suite("Расшифровка файлов: выбор файлов")
struct AudioFileSelectionTests {

    @Test func берутсяТолькоЗвуковыеРасширения() {
        // Порядок — русский алфавитный, как в Finder: «запись» раньше
        // «заседания» (п < с).
        let names = ["заседание.m4a", "иск.pdf", "запись.WAV", "договор.docx", "видео.mov", "readme"]
        #expect(AudioFileBatch.audioFileNames(in: names) == ["видео.mov", "запись.WAV", "заседание.m4a"])
    }

    /// `.DS_Store` и хвосты синхронизации — не звук.
    @Test func скрытыеФайлыПропускаются() {
        #expect(AudioFileBatch.audioFileNames(in: [".DS_Store", ".заседание.m4a", "запись.mp3"]) == ["запись.mp3"])
    }

    /// Порядок — как в Finder: «первый» в отчёте совпадает с первым на экране.
    @Test func порядокКакВFinder() {
        let names = ["дело-10.mp3", "дело-2.mp3", "дело-1.mp3"]
        #expect(AudioFileBatch.audioFileNames(in: names) == ["дело-1.mp3", "дело-2.mp3", "дело-10.mp3"])
    }

    @Test func пустаяПапкаДаётПустойСписок() {
        #expect(AudioFileBatch.audioFileNames(in: []).isEmpty)
        #expect(AudioFileBatch.audioFileNames(in: ["иск.pdf"]).isEmpty)
    }
}

// MARK: - Куда пишем

@Suite("Расшифровка файлов: куда ложится текст")
struct AudioFileDestinationTests {

    @Test func поУмолчаниюРядомСИсходником() {
        let source = URL(fileURLWithPath: "/private/tmp/Стол/заседание.m4a")
        #expect(AudioFileBatch.destination(forSource: source, in: nil).path
                == "/private/tmp/Стол/заседание.txt")
    }

    @Test func вЗаданнуюПапкуСТемЖеИменем() {
        let source = URL(fileURLWithPath: "/private/tmp/Стол/заседание.m4a")
        let folder = URL(fileURLWithPath: "/private/tmp/Документы", isDirectory: true)
        #expect(AudioFileBatch.destination(forSource: source, in: folder).path
                == "/private/tmp/Документы/заседание.txt")
    }

    @Test func точкиВИмениНеТеряются() {
        let source = URL(fileURLWithPath: "/tmp/дело 2-1234.2026.m4a")
        #expect(AudioFileBatch.destination(forSource: source, in: nil).lastPathComponent
                == "дело 2-1234.2026.txt")
    }

    @Test func одиночныйФайлДаётОднуРаботу() throws {
        try withTempDirectory { root in
            let source = root.appendingPathComponent("заседание.m4a")
            try Data("не важно".utf8).write(to: source)
            let jobs = try AudioFileBatch.plan(inputPath: source.path)
            #expect(jobs.count == 1)
            #expect(jobs[0].destination.lastPathComponent == "заседание.txt")
        }
    }

    @Test func папкаДаётРаботуНаКаждыйЗвуковойФайл() throws {
        try withTempDirectory { root in
            for name in ["б.mp3", "а.m4a", "иск.pdf", ".скрытая.wav"] {
                try Data("x".utf8).write(to: root.appendingPathComponent(name))
            }
            let jobs = try AudioFileBatch.plan(inputPath: root.path)
            #expect(jobs.map(\.source.lastPathComponent) == ["а.m4a", "б.mp3"])
            #expect(jobs.map(\.destination.lastPathComponent) == ["а.txt", "б.txt"])
        }
    }

    @Test func выходнаяПапкаСобираетВсеРасшифровки() throws {
        try withTempDirectory { root in
            let source = root.appendingPathComponent("звук", isDirectory: true)
            let target = root.appendingPathComponent("текст", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for name in ["а.m4a", "б.mp3"] {
                try Data("x".utf8).write(to: source.appendingPathComponent(name))
            }
            let jobs = try AudioFileBatch.plan(inputPath: source.path, outputPath: target.path)
            #expect(jobs.allSatisfy { $0.destination.deletingLastPathComponent().path == target.path })
        }
    }

    /// Косая черта на конце — явное «это папка», даже если её ещё нет.
    @Test func несуществующийПутьСКосойЧертойСчитаетсяПапкой() throws {
        try withTempDirectory { root in
            let source = root.appendingPathComponent("заседание.m4a")
            try Data("x".utf8).write(to: source)
            let jobs = try AudioFileBatch.plan(inputPath: source.path,
                                               outputPath: root.path + "/новая/")
            #expect(jobs[0].destination.path == root.path + "/новая/заседание.txt")
        }
    }

    @Test func заданныйФайлИспользуетсяКакЕсть() throws {
        try withTempDirectory { root in
            let source = root.appendingPathComponent("заседание.m4a")
            try Data("x".utf8).write(to: source)
            let jobs = try AudioFileBatch.plan(inputPath: source.path,
                                               outputPath: root.path + "/протокол.md")
            #expect(jobs[0].destination.lastPathComponent == "протокол.md")
        }
    }
}

// MARK: - Отказы

@Suite("Расшифровка файлов: отказы до чтения звука")
struct AudioFileRefusalTests {

    @Test func несуществующийПуть() {
        #expect(throws: AudioBatchPlanError.self) {
            try AudioFileBatch.plan(inputPath: "/такого/пути/нет.m4a")
        }
    }

    @Test func папкаБезЗвукаОтказываетИПеречисляетЧтоПонимает() throws {
        try withTempDirectory { root in
            try Data("x".utf8).write(to: root.appendingPathComponent("иск.pdf"))
            do {
                _ = try AudioFileBatch.plan(inputPath: root.path)
                Issue.record("папка без звука обязана отказать")
            } catch let error as AudioBatchPlanError {
                #expect(error.message.contains(".m4a"))
                #expect(error.message.contains(".wav"))
            }
        }
    }

    /// Один --output-файл на несколько расшифровок — верный способ склеить
    /// два заседания в одно. Не даём.
    @Test func одинФайлНаВыходеПриНесколькихИсходниках() throws {
        try withTempDirectory { root in
            for name in ["а.m4a", "б.mp3"] {
                try Data("x".utf8).write(to: root.appendingPathComponent(name))
            }
            #expect(throws: AudioBatchPlanError.outputFileForManySources(root.path + "/всё.txt")) {
                try AudioFileBatch.plan(inputPath: root.path, outputPath: root.path + "/всё.txt")
            }
        }
    }

    @Test func существующаяРасшифровкаНеЗатираетсяБезForce() throws {
        try withTempDirectory { root in
            let source = root.appendingPathComponent("заседание.m4a")
            try Data("x".utf8).write(to: source)
            try Data("старая расшифровка".utf8)
                .write(to: root.appendingPathComponent("заседание.txt"))

            #expect(throws: AudioBatchPlanError.self) {
                try AudioFileBatch.plan(inputPath: source.path)
            }
            // С --force — можно, и это единственный способ.
            #expect(try AudioFileBatch.plan(inputPath: source.path, force: true).count == 1)
        }
    }

    /// Два файла с одним именем и разными расширениями дали бы одну и ту же
    /// расшифровку — второй затёр бы первого молча.
    @Test func коллизияИмёнОстанавливаетВсюПачку() throws {
        try withTempDirectory { root in
            for name in ["дело.m4a", "дело.mp3"] {
                try Data("x".utf8).write(to: root.appendingPathComponent(name))
            }
            #expect(throws: AudioBatchPlanError.self) {
                try AudioFileBatch.plan(inputPath: root.path)
            }
        }
    }

    /// `smltlk transcribe заметки.txt` — расшифровка затёрла бы сам файл.
    @Test func расшифровкаНеЗатираетИсходник() throws {
        try withTempDirectory { root in
            let source = root.appendingPathComponent("заметки.txt")
            try Data("x".utf8).write(to: source)
            #expect(throws: AudioBatchPlanError.destinationOverwritesSource(source.path)) {
                try AudioFileBatch.plan(inputPath: source.path)
            }
        }
    }
}

// MARK: - Чтение звука

@Suite("Расшифровка файлов: чтение звука")
struct AudioFileDecoderTests {

    /// Главная проверка: 44,1 кГц стерео на входе — 16 кГц моно на выходе.
    @Test func стереоСорокЧетыреКилогерцаПриводятсяКФормातуРаспознавателя() async throws {
        try await withTempDirectoryAsync { root in
            let url = try writeToneWAV(at: root.appendingPathComponent("тон.wav"), seconds: 1.0)
            let audio = try await AudioFileDecoder.decode(url)
            // Ресемплер имеет право на пару кадров туда-сюда.
            #expect(abs(audio.seconds - 1.0) < 0.05)
            #expect(abs(Double(audio.samples.count) - AudioFileDecoder.targetSampleRate) < 800)
            #expect(audio.samples.contains { abs($0) > 0.05 })
        }
    }

    @Test func длительностьУзнаётсяБезПолногоЧтения() async throws {
        try await withTempDirectoryAsync { root in
            let url = try writeToneWAV(at: root.appendingPathComponent("тон.wav"), seconds: 2.0)
            let seconds = await AudioFileDecoder.probeSeconds(url)
            #expect(seconds != nil)
            #expect(abs((seconds ?? 0) - 2.0) < 0.05)
        }
    }

    /// Текст, переименованный в .wav: пустой расшифровки быть не должно —
    /// должен быть отказ.
    @Test func неЗвукОтказываетАНеОтдаётПустоту() async throws {
        try await withTempDirectoryAsync { root in
            let url = root.appendingPathComponent("иск.wav")
            try Data("Это договор, а не запись.".utf8).write(to: url)
            await #expect(throws: AudioDecodingError.self) {
                _ = try await AudioFileDecoder.decode(url)
            }
        }
    }

    @Test func пустойФайлОтказывает() async throws {
        try await withTempDirectoryAsync { root in
            let url = root.appendingPathComponent("пусто.m4a")
            try Data().write(to: url)
            await #expect(throws: AudioDecodingError.self) {
                _ = try await AudioFileDecoder.decode(url)
            }
        }
    }

    /// Щелчок в 0,1 с распознаватель не примет — говорим об этом своими
    /// словами, а не чужой ошибкой библиотеки.
    @Test func слишкомКороткийКлипОтказываетПонятно() async throws {
        try await withTempDirectoryAsync { root in
            let url = try writeToneWAV(at: root.appendingPathComponent("щелчок.wav"), seconds: 0.1)
            do {
                _ = try await AudioFileDecoder.decode(url)
                Issue.record("клип 0,1 с обязан быть отклонён")
            } catch let error as AudioDecodingError {
                #expect(error.message.contains("минимум"))
            }
        }
    }
}

// MARK: - Честные цифры

@Suite("Расшифровка файлов: честные цифры")
struct AudioBatchProgressTests {

    @Test func длительностьПоЧеловечески() {
        #expect(humanDurationLabel(seconds: 0.4) == "0,4 с")
        #expect(humanDurationLabel(seconds: 42) == "42 с")
        #expect(humanDurationLabel(seconds: 201) == "3 мин 21 с")
        #expect(humanDurationLabel(seconds: 3_840) == "1 ч 04 мин")
        #expect(humanDurationLabel(seconds: -5) == "0 с")
        #expect(humanDurationLabel(seconds: .nan) == "0 с")
    }

    /// ГЛАВНОЕ ПРАВИЛО ПРОГРЕССА: пока мерить нечем — оценки НЕТ.
    @Test func доПервыхПроцентовОценкиНет() {
        #expect(remainingSecondsEstimate(doneFraction: 0, elapsedSeconds: 12) == nil)
        #expect(remainingSecondsEstimate(doneFraction: 0.01, elapsedSeconds: 12) == nil)
        #expect(remainingSecondsEstimate(doneFraction: 0.5, elapsedSeconds: 0) == nil)
        #expect(remainingSecondsEstimate(doneFraction: .nan, elapsedSeconds: 12) == nil)
    }

    @Test func оценкаОстаткаСчитаетсяПоФактическойСкорости() throws {
        let estimate = try #require(remainingSecondsEstimate(doneFraction: 0.25, elapsedSeconds: 10))
        #expect(abs(estimate - 30) < 0.001)
    }

    @Test func скоростьОтносительноЗаписи() {
        #expect(speedFactor(audioSeconds: 600, processingSeconds: 60) == 10)
        #expect(speedFactor(audioSeconds: 600, processingSeconds: 0) == nil)
        #expect(speedFactor(audioSeconds: 0, processingSeconds: 60) == nil)
    }

    @Test func остатокПачкиБезИзмереннойСкоростиНеВыдумывается() {
        #expect(remainingBatchSecondsEstimate(remainingAudioSeconds: 3_600,
                                              measuredSpeedFactor: nil) == nil)
        let estimate = remainingBatchSecondsEstimate(remainingAudioSeconds: 3_600,
                                                     measuredSpeedFactor: 12)
        #expect(estimate == 300)
    }

    @Test func числаПишутсяСЗапятой() {
        #expect(decimalLabel(12.64, digits: 1) == "12,6")
    }
}
