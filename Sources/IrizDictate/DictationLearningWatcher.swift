// Наблюдатель за правкой: когда спрашивать поле и когда молчать.
//
// Ядро (`DictationLearning.swift`) умеет сравнивать два текста. Здесь решается
// более тонкое: КОГДА вообще заглядывать в поле и при каких условиях отказаться.
// Это отдельный файл, потому что решения тут - про доверие, а не про алгоритм.
//
// Чтение поля отделено замыканием `readFocusedText`. Так проба судит решения
// без разрешений системы и без живого приложения: подставляет свой «фокус» и
// проверяет, спросили его или нет.
import AppKit
import ApplicationServices
import Foundation

/// Что мы вставили и куда. Живёт до первой проверки, потом стирается.
struct DictationLearningInsertion: Equatable {
    let text: String
    let pid: pid_t
    let at: Date
}

/// Причины отказа. Названы поимённо, потому что молчание прибора без причины
/// неотличимо от поломки: в логе должно быть видно, ПОЧЕМУ пары не случилось.
enum DictationLearningRefusal: String, Error, Equatable {
    case nothingRemembered = "нечего сравнивать"
    case focusMovedToAnotherApp = "фокус ушёл в другое приложение"
    case fieldUnreadable = "поле не читается"
    case tooLate = "прошло слишком много времени"
    case noPairs = "правок нет или они не словарные"
}

/// Сколько ждём правку. Дольше - и мы сравним нашу вставку с текстом, который
/// человек с тех пор переписал целиком; такое сравнение даёт мусор, а не пары.
let dictationLearningWindowSeconds: TimeInterval = 180

@MainActor
final class DictationLearningWatcher {
    /// Чтение текста поля в фокусе и pid его приложения. Отделено замыканием:
    /// проба подставляет своё и судит решения без разрешений системы.
    var readFocusedText: @MainActor () -> (text: String, pid: pid_t)?
    /// Куда уходят найденные пары. Хранение и показ - не дело наблюдателя.
    var onPairs: ([DictationLearnedPair]) -> Void = { _ in }

    private var pending: DictationLearningInsertion?

    init(readFocusedText: @escaping @MainActor () -> (text: String, pid: pid_t)? = dictationLearningReadFocusedText) {
        self.readFocusedText = readFocusedText
    }

    /// Запомнить свою вставку. Чужого здесь нет: только наш текст и адрес окна.
    func remember(inserted: String, pid: pid_t?, now: Date = Date()) {
        guard let pid, !inserted.isEmpty else {
            pending = nil
            return
        }
        pending = DictationLearningInsertion(text: inserted, pid: pid, at: now)
    }

    /// Забыть, ничего не спрашивая. Зовётся, когда вставка заведомо потеряла
    /// смысл: человек начал новую диктовку в другом месте.
    func forget() {
        pending = nil
    }

    /// Спросить поле один раз и отдать пары. Проверка ОДНОРАЗОВАЯ: после неё
    /// вставка забывается независимо от исхода, поэтому одна правка не может
    /// быть предложена дважды.
    @discardableResult
    func check(now: Date = Date()) -> Result<[DictationLearnedPair], DictationLearningRefusal> {
        guard let insertion = pending else { return .failure(.nothingRemembered) }
        pending = nil

        guard now.timeIntervalSince(insertion.at) <= dictationLearningWindowSeconds else {
            return .failure(.tooLate)
        }
        guard let focused = readFocusedText() else { return .failure(.fieldUnreadable) }
        // Чужое приложение не спрашиваем вовсе: наш текст туда не попадал, а
        // значит и сравнивать нечего - только читать чужое без повода.
        guard focused.pid == insertion.pid else { return .failure(.focusMovedToAnotherApp) }

        let pairs = dictationLearnedPairs(inserted: insertion.text, current: focused.text)
        guard !pairs.isEmpty else { return .failure(.noPairs) }
        onPairs(pairs)
        return .success(pairs)
    }
}

/// Чтение текста поля в фокусе через систему доступности.
///
/// Читается ЗНАЧЕНИЕ поля и pid его приложения, и ничего больше: ни имени окна,
/// ни соседних элементов, ни выделения. Прочитанное уходит вызывающему и нигде
/// не задерживается - ни в логе, ни на диске.
///
/// Роль проверяется до чтения: у не-текстового элемента значение спрашивать
/// незачем, и лишний вопрос к чужому приложению здесь такой же дефект, как
/// лишний байт в сети.
@MainActor
func dictationLearningReadFocusedText() -> (text: String, pid: pid_t)? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)

    var focusedRaw: AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString,
                                        &focusedRaw) == .success,
          let focused = focusedRaw else { return nil }
    let element = focused as! AXUIElement

    var roleRaw: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
    let role = (roleRaw as? String) ?? ""
    let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
    guard textRoles.contains(role) else { return nil }

    var valueRaw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                        &valueRaw) == .success,
          let text = valueRaw as? String, !text.isEmpty else { return nil }
    return (text, pid)
}
