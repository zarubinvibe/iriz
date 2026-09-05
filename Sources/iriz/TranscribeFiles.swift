// Подкоманда `iriz transcribe` — расшифровка записанного файла или папки.
//
// Записанное заседание, голосовое клиента, диктофон с телефона: модель уже
// лежит на диске, сеть не нужна ни на одном шаге. Распознаёт тот же
// `TranscriptionWorker`, что и живая диктовка (IrizDictate), второго
// распознавателя в проекте нет.
//
// Куда что печатается: ход работы — в stderr (его можно отбросить), итог по
// каждому файлу — в stdout. Расшифровка на экран не сыплется: она ложится
// файлом рядом с исходником.
import IrizCore
import ArgumentParser
import Darwin
import Foundation
import IrizDictate

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Расшифровать аудиофайл или все аудиофайлы в папке (офлайн, модель с диска).",
        discussion: """
            Расшифровка ложится рядом с исходником: заседание.m4a → заседание.txt.
            Понимает контейнеры, которые читает сама macOS: \
            \(AudioFileBatch.supportedExtensionsLabel).
            Папка обходится на один уровень: вложенные подпапки не трогаются.
            Сеть не используется ни на одном шаге; словарь замен из настроек \
            приложения здесь НЕ применяется — текст остаётся тем, что услышал \
            распознаватель.
            Коды возврата: 0 — все файлы расшифрованы, 1 — часть не удалась, \
            2 — расшифровывать нечего (не найдено, не читается, нет модели).
            """
    )

    @Argument(help: "Файл со звуком или папка с такими файлами.")
    var input: String

    @Option(name: [.customShort("o"), .long],
            help: "Куда положить расшифровку: файл или папка. По умолчанию — рядом с исходником.")
    var output: String?

    @Option(name: .long,
            help: "Язык записи: auto, ru, en, uk, … (auto — определяет сам).")
    var language: String = "auto"

    @Flag(name: .long, help: "Перезаписать расшифровки, которые уже есть.")
    var force = false

    @Option(name: .long,
            help: "Движок: \(SpeechModelProfile.allCases.map(\.rawValue).joined(separator: ", ")).")
    var engine: String = SpeechModelProfile.productDefault.rawValue

    @Option(name: .long,
            help: """
                Подсказка декодеру для whisper: задает СТИЛЬ записи, не словарь ответов. \
                Рычаг под русскую речь с английскими терминами - замер дал 26,19 против \
                19,05 процента ошибок. Без флага берется та же подсказка, что в живой \
                диктовке. Пустая строка отключает ее - так гоняется чистый замер. \
                У Parakeet рычага нет, флаг для него не действует.
                """)
    var initialPrompt: String?

    mutating func run() async throws {
        guard let dictationLanguage = DictationLanguage(rawValue: language) else {
            refuse(AudioBatchPlanError.unknownLanguage(
                language,
                allowed: DictationLanguage.allCases.map(\.rawValue)
            ).message)
            throw ExitCode(2)
        }

        guard let speechEngine = SpeechModelProfile(rawValue: engine) else {
            refuse("Неизвестный движок «\(engine)». Есть: \(SpeechModelProfile.allCases.map(\.rawValue).joined(separator: ", ")).")
            throw ExitCode(2)
        }
        // Без флага берется подсказка продукта: иначе расшифровка файла вышла бы
        // хуже живой диктовки на той же записи без единой причины.
        let prompt: String? = speechEngine.supportsInitialPrompt
            ? (initialPrompt ?? whisperDefaultInitialPrompt)
            : initialPrompt
        if initialPrompt != nil, !speechEngine.supportsInitialPrompt {
            let withLever = SpeechModelProfile.allCases.filter(\.supportsInitialPrompt).map(\.rawValue).joined(separator: ", ")
            refuse("Подсказка декодеру есть у: \(withLever). У \(speechEngine.rawValue) рычага нет, и молча ее проглотить нельзя.")
            throw ExitCode(2)
        }

        let jobs: [AudioTranscriptionJob]
        do {
            jobs = try AudioFileBatch.plan(inputPath: input, outputPath: output, force: force)
        } catch let error as AudioBatchPlanError {
            refuse(error.message)
            throw ExitCode(2)
        }

        let runner = TranscriptionRunner(jobs: jobs,
                                         language: dictationLanguage,
                                         speechEngine: speechEngine,
                                         initialPrompt: (prompt?.isEmpty ?? true) ? nil : prompt)
        let failures = try await runner.run()
        if failures > 0 { throw ExitCode(1) }
    }
}

// MARK: - Прогон

private struct TranscriptionRunner: Sendable {
    let jobs: [AudioTranscriptionJob]
    let language: DictationLanguage
    let speechEngine: SpeechModelProfile
    let initialPrompt: String?

    /// Возвращает число файлов, которые расшифровать не вышло.
    func run() async throws -> Int {
        // Длительности заранее: без них «сколько ждать» пришлось бы выдумывать.
        var durations: [Double?] = []
        for job in jobs { durations.append(await AudioFileDecoder.probeSeconds(job.source)) }
        let knownTotal = durations.compactMap { $0 }.reduce(0, +)

        printProgress("\(IRIZ_NAME): расшифровка офлайн, модель берётся с диска, сеть не используется.")
        printProgress("Файлов: \(jobs.count)"
                      + (knownTotal > 0 ? ", звука: \(humanDurationLabel(seconds: knownTotal))." : "."))
        // Звук держится в памяти целиком — про это лучше сказать заранее,
        // чем показать вздувшийся процесс.
        if let longest = durations.compactMap({ $0 }).max(), longest > 3_600 {
            printProgress("Самая длинная запись — \(humanDurationLabel(seconds: longest)); "
                          + "звук держится в памяти, это примерно "
                          + "\(Int((longest / 3_600 * 230).rounded())) МБ.")
        }

        let engine = AudioFileTranscriber(engine: speechEngine, initialPrompt: initialPrompt)
        printProgress("Движок: \(speechEngine.shortName)\(initialPrompt == nil ? "" : ", с подсказкой декодеру").")
        do {
            let warmedIn = try await engine.prepare()
            printProgress("Модель готова за \(humanDurationLabel(seconds: warmedIn)).")
        } catch {
            refuse(error.localizedDescription)
            throw ExitCode(2)
        }

        var failures = 0
        var doneAudioSeconds: Double = 0
        var doneProcessingSeconds: Double = 0

        for (index, job) in jobs.enumerated() {
            let counter = "[\(index + 1)/\(jobs.count)]"
            let name = job.source.lastPathComponent
            let known = durations[index]
            printProgress("\(counter) \(name)"
                          + (known.map { " — \(humanDurationLabel(seconds: $0)) звука" } ?? ""))
            if jobs.count > 1,
               let rest = remainingBatchSecondsEstimate(
                   remainingAudioSeconds: max(0, knownTotal - doneAudioSeconds),
                   measuredSpeedFactor: speedFactor(audioSeconds: doneAudioSeconds,
                                                    processingSeconds: doneProcessingSeconds)
               ) {
                printProgress("      на всю пачку осталось ≈\(humanDurationLabel(seconds: rest))")
            }

            do {
                let transcript = try await transcribe(job: job, engine: engine)
                doneAudioSeconds += transcript.audioSeconds
                doneProcessingSeconds += transcript.processingSeconds
                try write(transcript.text, to: job.destination)
                print("\(counter) \(name) → \(job.destination.path) · "
                      + "\(humanDurationLabel(seconds: transcript.processingSeconds))"
                      + speedSuffix(transcript))
            } catch let error as AudioDecodingError {
                failures += 1
                refuse("\(counter) \(error.message)")
            } catch let error as TranscriptOutcomeError {
                failures += 1
                refuse("\(counter) \(error.message)")
            } catch {
                failures += 1
                refuse("\(counter) \(name): \(error.localizedDescription)")
            }
        }

        let done = jobs.count - failures
        printProgress("Готово: \(done) из \(jobs.count)."
                      + (failures > 0 ? " Не вышло: \(failures)." : ""))
        return failures
    }

    private func transcribe(job: AudioTranscriptionJob,
                            engine: AudioFileTranscriber) async throws -> AudioFileTranscript {
        let audio = try await AudioFileDecoder.decode(job.source)
        let line = ProgressLine()
        let startedAt = ProcessInfo.processInfo.systemUptime

        // Поток прогресса спрашиваем ТОЛЬКО когда библиотека его действительно
        // шлёт: на коротком файле открытая сессия не закроется и утащила бы
        // прогресс следующего файла.
        var reporter: Task<Void, Never>?
        if AudioFileTranscriber.reportsProgress(forSamples: audio.samples.count),
           let stream = await engine.progressStream() {
            reporter = Task {
                try? await consumeProgress(stream, into: line, startedAt: startedAt)
            }
        }
        defer { reporter?.cancel() }

        let transcript = try await engine.transcribe(audio, language: language)
        reporter?.cancel()
        await line.finish()

        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptOutcomeError.nothingRecognised(path: job.source.path)
        }
        return AudioFileTranscript(text: text,
                                   processingSeconds: transcript.processingSeconds,
                                   audioSeconds: transcript.audioSeconds)
    }

    private func speedSuffix(_ transcript: AudioFileTranscript) -> String {
        guard let factor = speedFactor(audioSeconds: transcript.audioSeconds,
                                       processingSeconds: transcript.processingSeconds) else { return "" }
        return ", в \(decimalLabel(factor, digits: 1)) раза быстрее записи"
    }

    /// Файл — 0600: в нём разговор клиента, а не публичная заметка.
    private func write(_ text: String, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((text + "\n").utf8).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: destination.path)
        } catch {
            throw TranscriptOutcomeError.cannotWrite(path: destination.path,
                                                     reason: error.localizedDescription)
        }
    }
}

private enum TranscriptOutcomeError: Error {
    case nothingRecognised(path: String)
    case cannotWrite(path: String, reason: String)

    var message: String {
        switch self {
        case .nothingRecognised(let path):
            return "В \(path) распознаватель не услышал ни слова — файла с расшифровкой не будет."
        case .cannotWrite(let path, let reason):
            return "Не смог записать \(path): \(reason)"
        }
    }
}

/// Свободная функция, а не метод: задача-читатель не должна тащить за собой
/// состояние прогона.
private func consumeProgress(_ stream: AsyncThrowingStream<Double, Error>,
                             into line: ProgressLine,
                             startedAt: Double) async throws {
    for try await fraction in stream {
        await line.update(fraction: fraction,
                          elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
    }
}

// MARK: - Строка прогресса

/// Одна перерисовываемая строка в терминале; в файл-лог — отдельные строки,
/// но не чаще раза в 10 секунд, чтобы не залить лог.
private actor ProgressLine {
    private let interactive = isatty(STDERR_FILENO) == 1
    private var lastShownAt: Double = 0
    private var shownSomething = false

    func update(fraction: Double, elapsed: Double) {
        // Ноль процентов — это не прогресс, а факт открытия сессии.
        // Показывать его значит сообщать пустоту.
        guard fraction > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let interval: Double = interactive ? 1 : 10
        guard now - lastShownAt >= interval else { return }
        lastShownAt = now

        var line = "      \(Int((fraction * 100).rounded())) % · прошло \(humanDurationLabel(seconds: elapsed))"
        if let rest = remainingSecondsEstimate(doneFraction: fraction, elapsedSeconds: elapsed) {
            line += " · осталось ≈\(humanDurationLabel(seconds: rest))"
        } else {
            line += " · сколько осталось — пока не скажу"
        }
        shownSomething = true
        if interactive {
            FileHandle.standardError.write(Data(("\r" + line + "\u{1B}[K").utf8))
        } else {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    func finish() {
        guard interactive, shownSomething else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}

// MARK: - Печать

private func printProgress(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

private func refuse(_ text: String) {
    FileHandle.standardError.write(Data(("\(IRIZ_NAME): " + text + "\n").utf8))
}
