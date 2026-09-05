// Тесты постобработки расшифровки и решений по записи.
// Опорные кейсы перенесены из self-тестов донора (main.swift 19861–19964),
// адаптированы: фильтр слов-паразитов в срез не вошёл.
import Foundation
import Testing

@testable import IrizDictate

// MARK: - Решение о судьбе записи

@Suite("recordingReleaseAction")
struct RecordingReleaseActionTests {
    @Test func discardsClipUnderMinimum() {
        #expect(recordingReleaseAction(capturedSampleCount: 3_999,
                                       sampleRate: 16_000,
                                       minimumClipSeconds: 0.25)
                == .discardTooShort(duration: 0.2499375))
    }

    @Test func transcribesClipAtMinimum() {
        #expect(recordingReleaseAction(capturedSampleCount: 4_000,
                                       sampleRate: 16_000,
                                       minimumClipSeconds: 0.25)
                == .transcribe(duration: 0.25))
    }

    @Test func invalidSampleRateDiscardsDefensively() {
        #expect(recordingReleaseAction(capturedSampleCount: 4_000,
                                       sampleRate: 0,
                                       minimumClipSeconds: 0.25)
                == .discardTooShort(duration: 0))
    }

    @Test func negativeSampleCountDiscardsDefensively() {
        #expect(recordingReleaseAction(capturedSampleCount: -10)
                == .discardTooShort(duration: 0))
    }
}

// MARK: - Постобработка текста

@Suite("processedDictationText")
struct ProcessedDictationTextTests {
    @Test func trimsAndAppliesCorrections() {
        let result = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Parakey")]
        )
        #expect(result == DictationTextProcessingResult(text: "Um, Parakey is fast.",
                                                        appliedCorrectionCount: 1))
    }

    @Test func repairsUnknownTokenToYo() {
        let result = processedDictationText(
            rawTranscript: "  <unk>лка, мо<UNK> и е<unk>. Потом <unk>жик.  ",
            corrections: []
        )
        #expect(result.text == "Ёлка, моё и её. Потом ёжик.")
    }

    @Test func explicitRussianRepairsYo() {
        let result = processedDictationText(rawTranscript: "  <unk>лка.  ",
                                            corrections: [],
                                            language: .russian)
        #expect(result.text == "Ёлка.")
    }

    @Test func nonRussianRemovesUnknownTokenAndCleansUp() {
        let result = processedDictationText(rawTranscript: "the <unk> cat , sat",
                                            corrections: [],
                                            language: .english)
        #expect(result.text == "the cat, sat")
    }

    @Test func finalPeriodRemovedOnlyWhenEnabled() {
        #expect(processedDictationText(rawTranscript: "Привет.", corrections: [],
                                     removeFinalPeriod: true).text == "Привет")
        #expect(processedDictationText(rawTranscript: "Привет.", corrections: [],
                                     removeFinalPeriod: false).text == "Привет.")
        // Двойную точку не трогаем — это многоточие по смыслу.
        #expect(processedDictationText(rawTranscript: "Стой..", corrections: [],
                                     removeFinalPeriod: true).text == "Стой..")
    }

    @Test func pasteSuffixVariants() {
        #expect(pastedText(from: "текст", suffix: .appendSpace) == "текст ")
        #expect(pastedText(from: "текст", suffix: .none) == "текст")
        #expect(pastedText(from: "текст", suffix: .appendNewline) == "текст\n")
    }
}

// MARK: - Пользовательские замены

@Suite("TranscriptCorrector")
struct TranscriptCorrectorTests {
    @Test func longestMatchWinsAndNoOverlap() {
        let corrections = [
            TranscriptCorrection(source: "a", replacement: "Y"),
            TranscriptCorrection(source: "a b", replacement: "X"),
        ]
        let result = TranscriptCorrector.apply(to: "a b a", corrections: corrections)
        #expect(result.text == "X Y")
        #expect(result.appliedCount == 2)
    }

    @Test func wordBoundariesRespected() {
        let corrections = [TranscriptCorrection(source: "cat", replacement: "dog")]
        let result = TranscriptCorrector.apply(to: "concatenate cat", corrections: corrections)
        #expect(result.text == "concatenate dog")
    }

    @Test func caseInsensitiveMatch() {
        let corrections = [TranscriptCorrection(source: "привет", replacement: "здравствуй")]
        let result = TranscriptCorrector.apply(to: "Привет мир", corrections: corrections)
        #expect(result.text == "здравствуй мир")
    }

    @Test func emptyCorrectionsPassThrough() {
        let result = TranscriptCorrector.apply(to: "как есть", corrections: [])
        #expect(result.text == "как есть")
        #expect(result.appliedCount == 0)
    }

    @Test func normalizationDropsInvalidAndDuplicates() {
        let long = String(repeating: "x", count: 600)  // свыше лимита 512 байт
        let normalized = normalizedTranscriptCorrections([
            TranscriptCorrection(source: "  ", replacement: "x"),      // пустой источник
            TranscriptCorrection(source: "a", replacement: "  "),       // пустая замена
            TranscriptCorrection(source: long, replacement: "y"),       // сверх лимита
            TranscriptCorrection(source: "b", replacement: "1"),
            TranscriptCorrection(source: "B", replacement: "2"),        // дубль по ключу
        ])
        #expect(normalized == [TranscriptCorrection(source: "B", replacement: "2")])
    }
}

// MARK: - Чанкинг Unicode для прямой вставки

@Suite("unicodeInsertionChunks")
struct UnicodeChunkTests {
    @Test func shortTextSingleChunk() {
        let chunks = unicodeInsertionChunks(for: "hello", maxUTF16UnitsPerEvent: 20)
        #expect(chunks.count == 1)
        #expect(chunks.first?.count == 5)
    }

    @Test func splitsAtUnitLimit() {
        let chunks = unicodeInsertionChunks(for: "hello", maxUTF16UnitsPerEvent: 2)
        #expect(chunks.map { $0.count } == [2, 2, 1])
    }

    @Test func oversizedCharacterGetsOwnChunk() {
        // Суррогатная пара (2 юнита) при лимите 1 — отдельным чанком целиком.
        let chunks = unicodeInsertionChunks(for: "a😀b", maxUTF16UnitsPerEvent: 1)
        #expect(chunks.map { $0.count } == [1, 2, 1])
    }

    @Test func emptyInputProducesNoChunks() {
        #expect(unicodeInsertionChunks(for: "", maxUTF16UnitsPerEvent: 20).isEmpty)
        #expect(unicodeInsertionChunks(for: "abc", maxUTF16UnitsPerEvent: 0).isEmpty)
    }

    @Test func chunksRoundTrip() {
        let text = "Привет, мир! 123 😀"
        let chunks = unicodeInsertionChunks(for: text, maxUTF16UnitsPerEvent: 5)
        let restored = chunks.map { String(decoding: $0, as: UTF16.self) }.joined()
        #expect(restored == text)
    }
}
