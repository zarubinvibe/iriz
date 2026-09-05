// Тесты этапа «приложение перестаёт врать готово»:
// вердикт доставки текста, сырьё на диск при любом исходе, таймаут
// распознавания, отказ старта при защищённом вводе.
//
// Живой буфер обмена, живой ASR и защищённый ввод под `swift test`
// недоступны, поэтому проверяются РЕШЕНИЯ (чистые функции) и наблюдаемое
// состояние контроллера, а не железо.
import Foundation
import IrizCore
import IrizPrompt
import Testing

@testable import IrizDictate

// MARK: - Вердикт доставки текста

@Suite("textInsertionVerdict")
struct TextInsertionVerdictTests {

    /// Главный случай этапа: ⌘V отправлен, цель за окно ожидания текст НЕ
    /// запросила — «готово» звучать не имеет права.
    @Test func targetNeverRequestedTextIsNotDelivered() {
        let verdict = textInsertionVerdict(startedStrategy: .clipboardPaste,
                                          targetRequestedText: false,
                                          elapsed: 0.4,
                                          window: 0.4)
        #expect(verdict == .notDelivered(.targetNeverRequestedText))
        #expect(dictationFeedbackSound(for: verdict) == .error)
        #expect(dictationFeedbackSound(for: verdict) != .done)
    }

    @Test func targetRequestedTextIsDelivered() {
        let verdict = textInsertionVerdict(startedStrategy: .clipboardPaste,
                                          targetRequestedText: true,
                                          elapsed: 0.01,
                                          window: 0.4)
        #expect(verdict == .delivered)
        #expect(dictationFeedbackSound(for: verdict) == .done)
    }

    @Test func insideWindowKeepsWaiting() {
        #expect(textInsertionVerdict(startedStrategy: .clipboardPaste,
                                     targetRequestedText: false,
                                     elapsed: 0.05,
                                     window: 0.4) == .waiting)
    }

    /// Ожидание — ещё не подтверждение: пока вердикт не вынесен, звучит отказ,
    /// а не «готово».
    @Test func waitingNeverSoundsLikeDone() {
        #expect(dictationFeedbackSound(for: .waiting) == .error)
    }

    @Test func noStrategyStartedIsNotDelivered() {
        let verdict = textInsertionVerdict(startedStrategy: nil,
                                          targetRequestedText: false,
                                          elapsed: 0,
                                          window: 0.4)
        #expect(verdict == .notDelivered(.insertionFailed))
        #expect(dictationFeedbackSound(for: verdict) == .error)
    }

    /// Прямой ввод юникодом факта забора текста не даёт — врать «готово» нельзя.
    @Test func directUnicodeDeliveryIsNotObservable() {
        let verdict = textInsertionVerdict(startedStrategy: .directUnicode,
                                          targetRequestedText: false,
                                          elapsed: 0,
                                          window: 0.4)
        #expect(verdict == .notDelivered(.deliveryNotObservable))
        #expect(dictationFeedbackSound(for: verdict) == .error)
    }

    @Test func nonFiniteElapsedDoesNotHangOnWaiting() {
        #expect(textInsertionVerdict(startedStrategy: .clipboardPaste,
                                     targetRequestedText: false,
                                     elapsed: .nan,
                                     window: 0.4)
                == .notDelivered(.targetNeverRequestedText))
    }

    /// Окно ожидания — 0,3–0,5 с, не десять секунд: владелец не должен ждать.
    @Test func deliveryWindowStaysInAgreedRange() {
        #expect(INSERTION_DELIVERY_WINDOW_SECONDS >= 0.3)
        #expect(INSERTION_DELIVERY_WINDOW_SECONDS <= 0.5)
    }
}

// MARK: - Сырьё на диск при любом исходе

@Suite("сырьё надиктовки")
struct RawTranscriptStoreTests {

    /// Временный каталог: живые расшифровки владельца в
    /// ~/Library/Application Support/smltlk тесты не трогают.
    private func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func savedRawTextIsByteForByteWhatASRReturned() throws {
        let raw = "  Привет, мир.  "
        try withTempRoot { root in
            let url = try DictationStore.save(rawText: raw, in: root)
            #expect(try Data(contentsOf: url) == Data(raw.utf8))
        }
    }

    /// Обработка реально умеет вернуть пустую строку: trim съедает ответ из
    /// одних пробелов. Раньше в этом случае надиктовка не сохранялась вообще:
    /// владелец говорил, а файла не появлялось.
    @Test func whitespaceOnlyASRAnswerStillKeepsRawOnDisk() throws {
        try expectRawKept(raw: "  \n ", removeFinalPeriod: false)
    }

    /// Второй живой путь в пустоту: снятие финальной точки с ответа из одной
    /// точки. Настройка владельца включается в окне настроек.
    @Test func finalPeriodRemovalCanEmptyTextAndRawSurvives() throws {
        try expectRawKept(raw: ".", removeFinalPeriod: true)
    }

    private func expectRawKept(raw: String, removeFinalPeriod: Bool) throws {
        let processed = processedDictationText(rawTranscript: raw,
                                               corrections: [],
                                               removeFinalPeriod: removeFinalPeriod)
        #expect(processed.text.isEmpty)

        let plan = dictationDeliveryPlan(rawTranscript: raw, processedText: processed.text)
        #expect(plan.savesRawText)
        #expect(!plan.insertsText)

        try withTempRoot { root in
            let url = try DictationStore.save(rawText: raw, in: root)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try Data(contentsOf: url) == Data(raw.utf8))
        }
    }

    /// Обработка меняет только вставляемый текст. Сырьё неприкосновенно —
    /// закон проекта: сырьё неприкосновенно.
    @Test func processingNeverTouchesSavedRaw() throws {
        let raw = "надиктовка про паракит."
        let processed = processedDictationText(
            rawTranscript: raw,
            corrections: [TranscriptCorrection(source: "паракит", replacement: "Parakeet")],
            removeFinalPeriod: true
        )
        #expect(processed.text != raw)

        try withTempRoot { root in
            let url = try DictationStore.save(rawText: raw, in: root)
            #expect(try Data(contentsOf: url) == Data(raw.utf8))
        }
    }

    /// Провал вставки сырья не отменяет: план сохранения от исхода доставки
    /// не зависит вообще.
    @Test func planSavesRawWhateverHappensToInsertion() {
        for processed in ["", "текст"] {
            #expect(dictationDeliveryPlan(rawTranscript: "сырьё", processedText: processed).savesRawText)
        }
    }

    /// Пустой ответ ASR (молчание) каталога не заводит — иначе на диске
    /// владельца копились бы пустые raw.txt от каждого случайного касания.
    @Test func emptyASRAnswerSavesNothing() {
        let plan = dictationDeliveryPlan(rawTranscript: "", processedText: "")
        #expect(!plan.savesRawText)
        #expect(!plan.insertsText)
    }

    @Test func promptArtifactsArePrivateKeepRawAndDoNotOverwrite() throws {
        try withTempRoot { root in
            let raw = "  Собери промпт  "
            let rawURL = try DictationStore.save(rawText: raw, in: root)
            #expect(try DictationStore.savePromptArtifacts(
                artifact: "проверяемый артефакт",
                generatedPrompt: "готовый промпт",
                besideRawAt: rawURL
            ))
            #expect(!FileManager.default.fileExists(
                atPath: rawURL.deletingLastPathComponent().appendingPathComponent("inserted.txt").path
            ))
            #expect(try !DictationStore.savePromptArtifacts(
                artifact: "другой артефакт",
                generatedPrompt: "другой промпт",
                besideRawAt: rawURL
            ))
            #expect(try Data(contentsOf: rawURL) == Data(raw.utf8))
            let promptURL = rawURL.deletingLastPathComponent().appendingPathComponent("prompt.md")
            let generatedURL = rawURL.deletingLastPathComponent().appendingPathComponent("generated.txt")
            #expect(try String(contentsOf: promptURL, encoding: .utf8) == "проверяемый артефакт")
            #expect(try String(contentsOf: generatedURL, encoding: .utf8) == "готовый промпт")
            for url in [promptURL, generatedURL] {
                let permissions = try FileManager.default
                    .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                #expect(permissions?.intValue == 0o600)
            }
        }
    }

    @Test func promptArtifactConflictWritesNothing() throws {
        try withTempRoot { root in
            let rawURL = try DictationStore.save(rawText: "сырьё", in: root)
            let directory = rawURL.deletingLastPathComponent()
            let generatedURL = directory.appendingPathComponent("generated.txt")
            try Data("уже было".utf8).write(to: generatedURL)

            #expect(try !DictationStore.savePromptArtifacts(
                artifact: "новый артефакт",
                generatedPrompt: "новый промпт",
                besideRawAt: rawURL
            ))
            #expect(try String(contentsOf: generatedURL, encoding: .utf8) == "уже было")
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("prompt.md").path
            ))
            #expect(try String(contentsOf: rawURL, encoding: .utf8) == "сырьё")
        }
    }

    @Test func partialPromptArtifactWriteFailureRollsBackBothFiles() throws {
        try withTempRoot { root in
            for failingWrite in [1, 2] {
                let raw = "сырьё-\(failingWrite)"
                let rawURL = try DictationStore.save(rawText: raw, in: root)
                var writes = 0
                do {
                    _ = try DictationStore.savePromptArtifacts(
                        artifact: "артефакт",
                        generatedPrompt: "промпт",
                        besideRawAt: rawURL,
                        writer: { data, url in
                            writes += 1
                            if writes == failingWrite {
                                let partial = Data(data.prefix(max(1, data.count / 2)))
                                try IrizCore.appendPrivateLogData(partial, to: url)
                                throw POSIXError(.ENOSPC)
                            }
                            try IrizCore.appendPrivateLogData(data, to: url)
                        }
                    )
                    Issue.record("ожидался частичная запись номер \(failingWrite)")
                } catch {
                    #expect(writes == failingWrite)
                }

                let directory = rawURL.deletingLastPathComponent()
                #expect(!FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("prompt.md").path
                ))
                #expect(!FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("generated.txt").path
                ))
                #expect(try String(contentsOf: rawURL, encoding: .utf8) == raw)
            }
        }
    }
}

@Suite("таксономия сбоев prompt-режима")
struct PromptFailureKindTests {
    @Test func generatorErrorsMapToSmallSanitizedKinds() {
        let secret = "СЕКРЕТ-{\"raw\":true}"
        let cases: [(any Error, PromptFailureKind)] = [
            (CodexPromptGeneratorError.invalidExecutable, .executableConfiguration),
            (CodexPromptGeneratorError.invalidTimeout, .launchRuntime),
            (CodexPromptGeneratorError.temporaryDirectoryUnavailable, .launchRuntime),
            (CodexPromptGeneratorError.privateFilePreparationFailed, .launchRuntime),
            (CodexPromptGeneratorError.launchFailed, .launchRuntime),
            (CodexPromptGeneratorError.nonZeroExit(status: 17, stderr: secret), .launchRuntime),
            (CodexPromptGeneratorError.terminated(signal: 9, stderr: secret), .launchRuntime),
            (CodexPromptGeneratorError.timedOut, .timeout),
            (CodexPromptGeneratorError.missingResult, .invalidResult),
            (CodexPromptGeneratorError.resultTooLarge, .invalidResult),
            (CodexPromptGeneratorError.invalidResultJSON, .invalidResult),
            (CodexPromptGeneratorError.invalidPromptSpec, .invalidResult),
            (CodexPromptGeneratorError.invalidPromptOutcome, .invalidResult),
            (CodexPromptGeneratorError.renderingFailed, .invalidResult),
        ]

        for (error, expected) in cases {
            let kind = promptFailureKind(for: error)
            #expect(kind == expected)
            let label = safePromptFailureLogLabel(for: error)
            #expect(!label.contains(secret))
            #expect(!label.contains("{"))
            #expect(!label.isEmpty)
        }
    }

    @Test func pipelineErrorsKeepVerificationAndArtifactConflictSeparate() {
        #expect(promptFailureKind(for: PromptPipelineError.codexUnavailable)
                == .executableConfiguration)
        #expect(promptFailureKind(for: PromptPipelineError.verificationFailed(["секрет"]))
                == .invalidResult)
        #expect(promptFailureKind(for: PromptPipelineError.artifactAlreadyExists)
                == .artifactConflict)
        #expect(promptFailureKind(for: NSError(domain: "секрет", code: 1)) == .launchRuntime)
        #expect(safePromptFailureLogLabel(
            for: PromptPipelineError.verificationFailed(["СЕКРЕТ"])
        ) == "verification failed")
    }

    /// Красный вердикт обязан называть пункт: без него владелец видит «не
    /// получилось» и чинить ему нечего. Но наружу проходит только ФОРМА
    /// идентификатора - остальное отбрасывается, и граница остаётся закрытой.
    @Test func verificationLabelNamesChecksAndDropsAnythingElse() {
        #expect(safePromptFailureLogLabel(for: PromptPipelineError.verificationFailed(["Б2"]))
                == "verification failed — Б2")
        #expect(safePromptFailureLogLabel(for: PromptPipelineError.verificationFailed(["Б2", "Б14"]))
                == "verification failed — Б2, Б14")
        for junk in ["СЕКРЕТ", "Б", "Б123", "B2", "Б2 и текст владельца", "", "{\"key\": 1}"] {
            #expect(safePromptFailureLogLabel(for: PromptPipelineError.verificationFailed([junk]))
                    == "verification failed", "пропущено наружу: \(junk)")
        }
        // Смесь: годный пункт проходит, мусор рядом с ним - нет.
        #expect(safePromptFailureLogLabel(
            for: PromptPipelineError.verificationFailed(["СЕКРЕТ", "Б5"])
        ) == "verification failed — Б5")
    }
}

@Suite("фокус prompt-режима")
struct PromptFocusTests {
    @Test func insertsOnlyIntoTheApplicationThatStartedRecording() {
        #expect(promptInsertionAllowed(recordedTargetPID: 42, currentTargetPID: 42))
        #expect(!promptInsertionAllowed(recordedTargetPID: 42, currentTargetPID: 43))
        #expect(!promptInsertionAllowed(recordedTargetPID: nil, currentTargetPID: 42))
        #expect(!promptInsertionAllowed(recordedTargetPID: 42, currentTargetPID: nil))

        // Обычная диктовка остаётся привязана к текущему фокусу. Только
        // prompt-вставка получает закреплённую цель.
        #expect(textInsertionTargetAllowsPosting(expectedTargetPID: nil, currentTargetPID: 43))
        #expect(textInsertionTargetAllowsPosting(expectedTargetPID: 42, currentTargetPID: 42))
        #expect(!textInsertionTargetAllowsPosting(expectedTargetPID: 42, currentTargetPID: 43))
    }
}

// MARK: - Таймаут распознавания

@Suite("transcriptionTimeoutSeconds")
struct TranscriptionTimeoutTests {

    @Test func shortClipWaitsLessThanLongClip() {
        #expect(transcriptionTimeoutSeconds(clipSeconds: 2)
                < transcriptionTimeoutSeconds(clipSeconds: 600))
    }

    @Test func timeoutScalesWithClipDuration() {
        #expect(transcriptionTimeoutSeconds(clipSeconds: 60) == 240)
    }

    @Test func floorProtectsVeryShortClips() {
        #expect(transcriptionTimeoutSeconds(clipSeconds: 0.3)
                == TRANSCRIPTION_TIMEOUT_MINIMUM_SECONDS)
    }

    @Test func ceilingCapsHugeClips() {
        #expect(transcriptionTimeoutSeconds(clipSeconds: 100_000)
                == TRANSCRIPTION_TIMEOUT_MAXIMUM_SECONDS)
    }

    @Test func garbageClipDurationFallsBackToFloor() {
        #expect(transcriptionTimeoutSeconds(clipSeconds: .nan)
                == TRANSCRIPTION_TIMEOUT_MINIMUM_SECONDS)
        #expect(transcriptionTimeoutSeconds(clipSeconds: -10)
                == TRANSCRIPTION_TIMEOUT_MINIMUM_SECONDS)
        #expect(transcriptionTimeoutSeconds(clipSeconds: 60, realtimeFactor: 0)
                == TRANSCRIPTION_TIMEOUT_MINIMUM_SECONDS)
    }
}

// MARK: - Зависшее распознавание разблокирует диктовку

@Suite("зависшее распознавание")
@MainActor
struct HungTranscriptionTests {

    /// Свой домен настроек: домен владельца тесты не трогают.
    private func makeController(transcriptionTimeout: Double?) -> (DictationController, () -> Void) {
        let name = "smltlk-dictate-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let controller = DictationController(settings: DictationSettings(defaults: defaults),
                                            transcriptionTimeout: transcriptionTimeout,
                                            insertionStats: InsertionStats(defaults: defaults))
        return (controller, { removeSuiteFile(named: name, defaults: defaults) })
    }

    @Test func watchdogClearsBusyAndReturnsToReady() async throws {
        let (controller, cleanup) = makeController(transcriptionTimeout: 0.05)
        defer { cleanup() }

        controller.simulateHungTranscriptionForTesting(clipSeconds: 1)
        #expect(controller.isBusyForTesting)
        #expect(controller.state == .transcribing)

        let deadline = ContinuousClock.now + .seconds(3)
        while controller.isBusyForTesting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.isBusyForTesting == false)
        #expect(controller.state == .ready)
    }

    /// Таймаут считается от длительности клипа, а не константой.
    @Test func controllerTimeoutFollowsClipDuration() {
        let (controller, cleanup) = makeController(transcriptionTimeout: nil)
        defer { cleanup() }
        #expect(controller.transcriptionTimeoutForTesting(clipSeconds: 3)
                < controller.transcriptionTimeoutForTesting(clipSeconds: 300))
    }
}

// MARK: - Отказ старта записи

@Suite("dictationStartRefusal")
struct DictationStartRefusalTests {

    /// Защищённый ввод: запись не стартует, причина названа — звонит отказ.
    @Test func secureInputBlocksRecording() {
        #expect(dictationStartRefusal(modelReady: true,
                                      isRecording: false,
                                      isBusy: false,
                                      secureInputActive: true) == .secureInputActive)
    }

    @Test func secureInputWinsOverEveryOtherReason() {
        #expect(dictationStartRefusal(modelReady: false,
                                      isRecording: true,
                                      isBusy: true,
                                      secureInputActive: true) == .secureInputActive)
    }

    @Test func readyAndIdleStarts() {
        #expect(dictationStartRefusal(modelReady: true,
                                      isRecording: false,
                                      isBusy: false,
                                      secureInputActive: false) == nil)
    }

    @Test func oldGuardsSurvive() {
        #expect(dictationStartRefusal(modelReady: false, isRecording: false,
                                      isBusy: false, secureInputActive: false) == .modelNotReady)
        #expect(dictationStartRefusal(modelReady: true, isRecording: true,
                                      isBusy: false, secureInputActive: false) == .alreadyRecording)
        #expect(dictationStartRefusal(modelReady: true, isRecording: false,
                                      isBusy: true, secureInputActive: false) == .transcriptionInFlight)
    }
}
