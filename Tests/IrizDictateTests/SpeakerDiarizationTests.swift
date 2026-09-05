// Проба перевода отрезков движка в наш вид.
//
// Сам разбор записи требует моделей CoreML и минуты работы - под `swift test`
// ему не место. Судится то, что можно судить без движка: перевод типов,
// отсев мусора и порядок. Это единственное место, где чужой тип встречается с
// нашим, и ошибка здесь тихо перепутает, кто что сказал.
import Foundation
import Testing
import FluidAudio

@testable import IrizDictate

@Suite("Отрезки говорящих")
struct SpeakerDiarizationTests {
    @Test("отрезки переводятся и сортируются по времени")
    func отрезкиПереводятсяИСортируются() {
        let spans = speakerSpans(from: [
            fakeSegment("S2", 5.0, 8.0),
            fakeSegment("S1", 0.0, 4.0),
        ])
        #expect(spans.map(\.speaker) == ["S1", "S2"])
        #expect(spans[0].start == 0.0)
        #expect(spans[1].end == 8.0)
    }

    @Test("пустой отрезок отбрасывается")
    func пустойОтрезокОтбрасывается() {
        // Отрезок нулевой длины не несёт речи, но ломает сшивку: слово может
        // перекрыться с ним на ноль и уйти не тому.
        let spans = speakerSpans(from: [fakeSegment("S1", 3.0, 3.0)])
        #expect(spans.isEmpty)
    }

    @Test("перевёрнутый отрезок отбрасывается")
    func перевёрнутыйОтрезокОтбрасывается() {
        let spans = speakerSpans(from: [fakeSegment("S1", 5.0, 2.0)])
        #expect(spans.isEmpty)
    }

    @Test("короткая запись до разбора не доходит")
    func короткаяЗаписьНеРазбирается() {
        // Отказ по имени, а не молчание: разбирать будут запись заседания, и
        // «не смог» без причины неотличимо от поломки.
        #expect(SpeakerDiarizationFailure.tooShort.rawValue.contains("короче"))
        #expect(speakerDiarizationMinimumSeconds == 3)
    }

    private func fakeSegment(_ id: String, _ start: Float, _ end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(speakerId: id, embedding: [], startTimeSeconds: start,
                            endTimeSeconds: end, qualityScore: 1)
    }
}
