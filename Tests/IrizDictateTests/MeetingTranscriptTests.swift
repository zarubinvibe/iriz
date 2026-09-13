import Foundation
import Testing

@testable import IrizDictate

@Suite("Сохранность расшифровки встречи")
struct MeetingTranscriptTests {
    private func token(_ text: String, _ start: Double, _ end: Double) -> DictationTokenTiming {
        DictationTokenTiming(token: text, start: start, end: end, confidence: 1)
    }

    private func snapshot(_ raw: String, tokens: [DictationTokenTiming],
                          spans: [SpeakerSpan] = []) -> MeetingTranscriptSnapshot {
        meetingTranscriptSnapshot(
            transcript: AudioFileTranscript(text: raw, processingSeconds: 1,
                                            audioSeconds: 6, tokenTimings: tokens),
            spans: spans)
    }

    private func expectExactText(_ result: MeetingTranscriptSnapshot, _ raw: String) {
        // String == допускает каноническую эквивалентность Unicode. Здесь нужны исходные байты.
        #expect(Array(result.rawText.utf8) == Array(raw.utf8))
        #expect(Array(result.turns.map(\.text).joined().utf8) == Array(raw.utf8))
    }

    private func expectUntimedFallback(_ result: MeetingTranscriptSnapshot, _ raw: String) {
        expectExactText(result, raw)
        #expect(result.timingQuality == .unavailable)
        #expect(result.speakerQuality == .unavailable)
        #expect(result.turns.count == 1)
        #expect(result.turns.allSatisfy { !$0.hasKnownTiming && $0.speaker.isEmpty })
    }

    @Test("полная сшивка сохраняет все байты, пробелы, пунктуацию и границы абзацев")
    func exactRawBytesSurviveAlignedTurns() {
        let raw = " \t«Да»,  —\nнет! 👩🏽‍💻 е\u{301}\r\n"
        let result = snapshot(raw, tokens: [
            token("«Да»,", 0, 0.5), token("—", 0.5, 1),
            token("нет!", 2, 2.5), token("👩🏽‍💻", 2.5, 3), token("е\u{301}", 3, 3.5)
        ], spans: [SpeakerSpan(speaker: "S1", start: 0, end: 1),
                   SpeakerSpan(speaker: "S2", start: 2, end: 4)])

        expectExactText(result, raw)
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .diarized)
        #expect(result.turns.map(\.speaker) == ["S1", "S2"])
        #expect(result.turns.allSatisfy { $0.hasKnownTiming })
        #expect(result.warnings.isEmpty)
    }

    @Test("SentencePiece-маркеры и части слов выравниваются без переписывания сырья")
    func sentencePieceFragmentsAlign() {
        let raw = "Привет,  мир!\nПока."
        let pieces = ["▁При", "вет", ",", "▁мир", "!", "▁Пока", "."]
        let result = snapshot(raw, tokens: pieces.enumerated().map {
            token($0.element, Double($0.offset) * 0.5, Double($0.offset + 1) * 0.5)
        }, spans: [SpeakerSpan(speaker: "S1", start: 0, end: 4)])

        expectExactText(result, raw)
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .diarized)
        #expect(result.turns.allSatisfy { $0.speaker == "S1" && $0.hasKnownTiming })
    }

    @Test("ведущие пробелы токенов не подменяют исходные отступы")
    func leadingSpacePiecesAlign() {
        let raw = "\tHello,   world!\nAgain.  "
        let pieces = [" Hello", ",", " world", "!", " Again", "."]
        let result = snapshot(raw, tokens: pieces.enumerated().map {
            token($0.element, Double($0.offset) * 0.5, Double($0.offset + 1) * 0.5)
        }, spans: [SpeakerSpan(speaker: "S1", start: 0, end: 4)])

        expectExactText(result, raw)
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .diarized)
    }

    @Test("пробельная последовательность токена сопоставляется один раз")
    func repeatedTokenWhitespaceAligns() {
        for separator in ["  ", " \t", "\n\t"] {
            let raw = "Да.\n\tНет.  "
            let result = snapshot(raw, tokens: [token("Да.", 0, 1),
                                                token(separator + "Нет.", 1, 2)],
                                  spans: [SpeakerSpan(speaker: "S1", start: 0, end: 3)])
            expectExactText(result, raw)
            #expect(result.timingQuality == .aligned)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test("пробел в хвосте предыдущего токена сохраняет границу говорящих")
    func trailingTokenWhitespaceKeepsNextWordBoundary() {
        let raw = "Да. Нет."
        let result = snapshot(raw, tokens: [token("Да. ", 0, 1), token("Нет.", 1, 2)],
                              spans: [SpeakerSpan(speaker: "S1", start: 0, end: 1),
                                      SpeakerSpan(speaker: "S2", start: 1, end: 2)])
        expectExactText(result, raw)
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .diarized)
        #expect(result.turns.map(\.speaker) == ["S1", "S2"])
        #expect(result.warnings.isEmpty)
    }

    @Test("Whisper без времён сохраняет весь текст без придуманных границ")
    func absentTimingsKeepRawWithoutInventedBounds() {
        let raw = "\t Полный текст.\n\nВторая реплика!  "
        let result = snapshot(raw, tokens: [],
                              spans: [SpeakerSpan(speaker: "S1", start: 0, end: 6)])

        expectUntimedFallback(result, raw)
        #expect(result.warnings.contains(.missingTimings))
    }

    @Test("пропущенный хвост, пунктуация или неверное начало отменяют всю привязку")
    func incompleteOrDifferentTokenTextFallsBack() {
        let cases: [(String, [String])] = [
            ("Первые слова и потерянный хвост.", ["Первые", "слова"]),
            ("Да!", ["Да"]),
            ("Привет мир.", ["Здравствуйте", "мир."])
        ]
        for (raw, pieces) in cases {
            let result = snapshot(raw, tokens: pieces.enumerated().map {
                token($0.element, Double($0.offset), Double($0.offset + 1))
            }, spans: [SpeakerSpan(speaker: "S1", start: 0, end: 6)])

            expectUntimedFallback(result, raw)
            #expect(result.warnings.contains(.textMismatch))
        }
    }

    @Test("границы из JSON проверяются повторно, включая отрицательные и нечисловые")
    func decodedInvalidTimingsFallBack() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let ranges = [("-1", "1"), ("2", "1"), ("0", "7"),
                      ("\"NaN\"", "1"), ("0", "\"Infinity\""), ("\"-Infinity\"", "1")]
        for (start, end) in ranges {
            // Decodable обходит санитайзер публичного init: проверяем настоящую границу доверия.
            let json = """
                {"token":"Текст.","start":\(start),"end":\(end),"confidence":1}
                """
            let decoded = try decoder.decode(DictationTokenTiming.self, from: Data(json.utf8))
            let result = snapshot("Текст.", tokens: [decoded],
                                  spans: [SpeakerSpan(speaker: "S1", start: 0, end: 6)])

            expectUntimedFallback(result, "Текст.")
            #expect(result.warnings.contains(.invalidTimings))
        }
    }

    @Test("обратный порядок времён не исправляется перестановкой исходных слов")
    func outOfOrderTimingsFallBackWithoutSortingText() {
        let raw = "Раз. Два."
        let result = snapshot(raw, tokens: [token("Раз.", 2, 3), token("Два.", 0, 1)],
                              spans: [SpeakerSpan(speaker: "S1", start: 0, end: 6)])

        expectUntimedFallback(result, raw)
        #expect(result.warnings.contains(.invalidTimings))
    }

    @Test("перекрывающиеся времена токенов не становятся достоверной шкалой")
    func overlappingTokenTimingsAreUnavailable() {
        let raw = "Раз. Два."
        let result = snapshot(raw, tokens: [token("Раз.", 0, 2), token("Два.", 1, 3)],
                              spans: [SpeakerSpan(speaker: "S1", start: 0, end: 6)])

        expectUntimedFallback(result, raw)
        #expect(result.warnings.contains(.overlappingTimings))
    }

    @Test("перекрытие разных говорящих оставляет неизвестной только спорную реплику")
    func differentSpeakerOverlapDoesNotGuessOwner() {
        let raw = "Первое. Спорно. Последнее."
        let result = snapshot(raw, tokens: [token("Первое.", 0.1, 0.5),
                                            token("Спорно.", 1.2, 1.8),
                                            token("Последнее.", 2.2, 2.8)],
                              spans: [SpeakerSpan(speaker: "S1", start: 0, end: 2),
                                      SpeakerSpan(speaker: "S2", start: 1, end: 3)])

        expectExactText(result, raw)
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .partial)
        #expect(result.turns.map(\.speaker) == ["S1", "", "S2"])
        #expect(result.turns.allSatisfy { $0.hasKnownTiming })
        #expect(result.warnings.contains(.overlappingSpeakers))
    }

    @Test("слово в промежутке не приписывается ближайшему говорящему")
    func speakerGapDoesNotUseNearestSpan() {
        let raw = "Первое. Чьё? Последнее."
        let result = snapshot(raw, tokens: [token("Первое.", 0.2, 0.8),
                                            token("Чьё?", 1.1, 1.3),
                                            token("Последнее.", 2.1, 2.5)],
                              spans: [SpeakerSpan(speaker: "S1", start: 0, end: 1),
                                      SpeakerSpan(speaker: "S2", start: 2, end: 3)])

        expectExactText(result, raw)
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .partial)
        #expect(result.turns.map(\.speaker) == ["S1", "", "S2"])
        #expect(result.warnings.contains(.unassignedSpeech))
    }

    @Test("без диаризации полные времена остаются известными, говорящий — нет")
    func missingSpeakersDoNotEraseValidTimings() {
        let raw = " \tДа.\nНет.\n"
        let result = snapshot(raw, tokens: [token("Да.", 0, 0.8), token("Нет.", 1, 1.8)])

        expectExactText(result, raw)
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .unavailable)
        #expect(result.turns.allSatisfy { $0.speaker.isEmpty && $0.hasKnownTiming })
        #expect(result.warnings.contains(.missingSpeakers))
    }

    @Test("невалидные дорожки говорящих не создают ложной атрибуции")
    func invalidSpeakerSpansAreReportedAndNotAssigned() {
        let ranges: [(Double, Double)] = [(-1, 1), (2, 1), (0, 7),
                                           (.nan, 1), (0, .infinity)]
        for (start, end) in ranges {
            let result = snapshot("Текст.", tokens: [token("Текст.", 0.2, 0.8)],
                                  spans: [SpeakerSpan(speaker: "S1", start: start, end: end)])

            expectExactText(result, "Текст.")
            #expect(result.timingQuality == .aligned)
            #expect(result.speakerQuality == .unavailable)
            #expect(result.turns.allSatisfy { $0.speaker.isEmpty && $0.hasKnownTiming })
            #expect(result.warnings.contains(.invalidSpeakerSpans))
        }
    }

    @Test("перекрывающиеся дорожки одного ID не изображают двух говорящих")
    func sameSpeakerOverlapIsNotAmbiguous() {
        let result = snapshot("Текст.", tokens: [token("Текст.", 1.2, 1.8)],
                              spans: [SpeakerSpan(speaker: "S1", start: 0, end: 2),
                                      SpeakerSpan(speaker: "S1", start: 1, end: 3)])

        expectExactText(result, "Текст.")
        #expect(result.timingQuality == .aligned)
        #expect(result.speakerQuality == .diarized)
        #expect(result.turns.map(\.speaker) == ["S1"])
        #expect(!result.warnings.contains(.overlappingSpeakers))
    }

    @Test("JSON сохраняет исходные пробелы и различие известных и неизвестных времён")
    func jsonRoundTripPreservesRawAndTimingKnowledge() throws {
        let raw = "\t Да.\nНет.  \r\n"
        let tokens = [token("Да.", 0, 1), token("Нет.", 1, 2)]
        let cases = [snapshot(raw, tokens: tokens), snapshot(raw, tokens: [])]
        for result in cases {
            let data = try JSONEncoder().encode(result)
            let restored = try JSONDecoder().decode(MeetingTranscriptSnapshot.self, from: data)

            #expect(restored == result)
            expectExactText(restored, raw)
            #expect(restored.turns.map(\.hasKnownTiming) == result.turns.map(\.hasKnownTiming))
        }
    }

    @Test("нулевые legacy-поля не превращают неизвестное время в начало записи")
    func unknownTurnHasAnExplicitTimingFlag() {
        let unknown = SpeakerTurn(speaker: "", text: "Без времён.")
        let known = SpeakerTurn(speaker: "S1", text: "С начала записи.", start: 0, end: 1)

        #expect(!unknown.hasKnownTiming)
        #expect(unknown.start == 0 && unknown.end == 0)
        #expect(known.hasKnownTiming)
    }

    @Test("JSON неизвестной реплики не содержит вымышленных start/end")
    func unknownTimingIsAbsentFromJSON() throws {
        let turn = SpeakerTurn(speaker: "", text: "Без времён.")
        let data = try JSONEncoder().encode(turn)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["hasKnownTiming"] as? Bool == false)
        #expect(fields["start"] == nil && fields["end"] == nil)
        #expect(speakerTurnsNamed([turn], names: SpeakerNames())[0].hasKnownTiming == false)
    }
}
