// Тесты кандидата в движки (волна 2).
//
// Модели под `swift test` нет и быть не должно - те же 3,1 ГБ и ANE на каждый
// прогон, что и у Parakeet. Поэтому здесь проверяются РЕШЕНИЯ, а главное из них
// одно: движок обязан ОТКАЗАТЬ без модели на диске и ничего не качать (REQ-07).
// Офлайн у whisper.cpp держится по построению - сетевого кода в нем нет вовсе, -
// и эта проба сторожит, что мы не завели загрузку сами.
import Foundation
import Testing

@testable import IrizDictate

@Suite("Кандидат Whisper")
struct WhisperEngineTests {
    @Test("Без модели на диске движок отказывает, а не качает")
    func refusesWithoutModel() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iriz-whisper-\(UUID().uuidString)")
            .appendingPathComponent("ggml-large-v3.bin")

        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(throws: WhisperEngineError.self) { _ = try WhisperEngine(modelURL: missing) }

        // Отказ обязан НАЗЫВАТЬ путь: иначе владелец не поймет, куда класть файл.
        do {
            _ = try WhisperEngine(modelURL: missing)
            Issue.record("движок не отказал без модели")
        } catch let error as WhisperEngineError {
            let text = error.errorDescription ?? ""
            #expect(text.contains(missing.path))
            #expect(text.contains("не качает"))
        }

        // И ничего не появилось на диске: попытка загрузки не заводилась.
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    @Test("Модель лежит вне репозитория, рядом с моделями остальных движков")
    func modelLivesOutsideRepository() {
        let dir = whisperModelCacheDirectory().path
        #expect(dir.hasPrefix(NSHomeDirectory()))
        #expect(dir.contains("Library/Application Support"))
        #expect(!dir.contains("Проекты"))
        #expect(whisperModelURL().lastPathComponent == "ggml-large-v3.bin")
    }

    @Test("Энкодер CoreML ищется под именем, которое ждет whisper.cpp")
    func coreMLEncoderNameMatchesUpstream() {
        // whisper.cpp собирает имя как <модель без .bin>-encoder.mlmodelc и ищет
        // его РЯДОМ с моделью. Расхождение имени тихо уводит исполнение на Metal.
        let encoder = whisperCoreMLEncoderURL()
        #expect(encoder.lastPathComponent == "ggml-large-v3-encoder.mlmodelc")
        #expect(encoder.deletingLastPathComponent() == whisperModelURL().deletingLastPathComponent())
    }

    @Test("Автоязык уходит движку кодом auto, остальные своими кодами")
    /// Правило перевернулось после живого дефекта. Раньше при автоопределении
    /// движку не передавали НИЧЕГО, а `whisper_full_default_params` подставляет
    /// «en»: русская речь выходила английским текстом, и владелец увидел это
    /// как перевод, которого не просил.
    func автоязыкУходитКодом() {
        #expect(DictationLanguage.auto.whisperCode == "auto")
        #expect(DictationLanguage.russian.whisperCode == "ru")
    }
}

@Suite("Переключатель движков")
struct SpeechEngineSwitchTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ru.smltlk.tests.engine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Предпочтительный движок - Whisper turbo, он взял термины владельца")
    func defaultsToTurbo() {
        // Дефолт сменен осознанно 03.09.2026 по замеру: прежний движок
        // транслитерировал английские термины внутри русской фразы, и это
        // делало диктовку непригодной ровно в рабочем словаре владельца.
        let settings = DictationSettings(defaults: freshDefaults())
        // Настройка без значения решается ДИСКОМ, а не константой: под тестом
        // на машине сборки whisper может не стоять. Проверяем предпочтение.
        #expect(SpeechModelProfile.productDefault == .whisperTurbo)
        #expect(SpeechModelProfile.productDefault.supportsInitialPrompt)
    }

    @Test("Прежний движок остался доступен выбором")
    func parakeetStillSelectable() {
        let defaults = freshDefaults()
        var settings = DictationSettings(defaults: defaults)
        settings.speechEngine = .multilingualV3
        #expect(DictationSettings(defaults: defaults).speechEngine == .multilingualV3)
        #expect(!SpeechModelProfile.multilingualV3.supportsInitialPrompt)
    }

    @Test("Выбор владельца сохраняется и читается обратно")
    func choiceRoundTrips() {
        let defaults = freshDefaults()
        var settings = DictationSettings(defaults: defaults)
        settings.speechEngine = .whisperLargeV3
        #expect(DictationSettings(defaults: defaults).speechEngine == .whisperLargeV3)
    }

    @Test("Мусор в настройке не роняет диктовку, а откатывает на дефолт")
    func unknownValueFallsBack() {
        let defaults = freshDefaults()
        defaults.set("движок-которого-нет", forKey: "speech_engine_v1")
        // Мусор откатывает на заводское значение, а оно теперь зависит от диска.
        #expect(DictationSettings(defaults: defaults).speechEngine
                == SpeechModelProfile.installedDefault())
    }

    @Test("Подсказка декодеру по умолчанию не содержит терминов корпуса")
    func defaultPromptDoesNotLeak() {
        // Тот же запрет, что сторожат ворота bench_leak_check.py: промт задает
        // стиль, а не подсказывает ответы проверочного корпуса.
        let prompt = whisperDefaultInitialPrompt.lowercased()
        for term in ["pull request", "git rebase", "mcp", "supabase", "swift test", "force push"] {
            #expect(!prompt.contains(term))
        }
        #expect(prompt.range(of: "[a-z]", options: .regularExpression) != nil)
    }

    @Test("Каталог модели у движков разный, и ни один не смотрит в чужой")
    func cacheDirectoriesDoNotCollide() {
        let parakeet = speechModelCacheDirectory(for: .multilingualV3)
        let whisper = speechModelCacheDirectory(for: .whisperLargeV3)
        #expect(parakeet != whisper)
        #expect(!whisper.path.hasPrefix(parakeet.path))
        #expect(!parakeet.path.hasPrefix(whisper.path))
    }

    @Test("Оба движка называются человеку по-разному")
    func namesAreDistinct() {
        let names = Set(SpeechModelProfile.allCases.map(\.shortName))
        #expect(names.count == SpeechModelProfile.allCases.count)
        #expect(SpeechModelProfile.whisperLargeV3.shortName.contains("large-v3"))
    }
}
