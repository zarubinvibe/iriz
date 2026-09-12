import AppKit
import Testing
@testable import IrizDictate

@Suite("плашка: доступные кнопки и уменьшение движения")
@MainActor
struct DictationHUDAccessibilityTests {
    @Test func действиеAXИспользуетАктуальнуюКнопку() {
        let button = DictationHUDActionButton(action: dictationHUDActions(isRecording: false)[0])
        var invoked: [DictationHUDActionID] = []
        button.onPress = { invoked.append($0) }
        #expect(button.isAccessibilityElement())
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == button.action.title)
        #expect(button.accessibilityPerformPress())
        button.action = dictationHUDActions(isRecording: true)[0]
        #expect(button.accessibilityLabel() == button.action.title)
        #expect(button.toolTip == button.action.title)
        #expect(button.accessibilityPerformPress())
        #expect(invoked == [.record, .record])
        button.isHidden = true
        #expect(!button.accessibilityPerformPress())
        #expect(invoked.count == 2)
    }

    @Test func копированиеИЗакрытиеИмеютСемантикуИДействия() {
        // Обработчики-заглушки: настоящий буфер обмена тест не меняет.
        let copy = DictationHUDCopyPill(frame: .zero)
        let close = DictationHUDCloseRing(frame: .zero)
        var copies = 0
        var closes = 0
        copy.title = "Скопировать"
        copy.onPress = { copies += 1 }
        close.onPress = { closes += 1 }
        for button in [copy as NSView, close as NSView] {
            #expect(button.isAccessibilityElement())
            #expect(button.accessibilityRole() == .button)
            #expect(button.accessibilityLabel()?.isEmpty == false)
            #expect(button.accessibilityPerformPress())
        }
        #expect(copies == 1)
        #expect(closes == 1)
        copy.title = "Скопировано"
        #expect(copy.accessibilityLabel() == "Скопировано")
        close.isHidden = true
        #expect(!close.accessibilityPerformPress())
        #expect(closes == 1)
    }

    @Test func сменаНастройкиОстанавливаетУжеНачатыйHover() throws {
        let center = NotificationCenter()
        var reduced = false
        let button = DictationHUDActionButton(
            action: dictationHUDActions(isRecording: false)[0],
            reduceMotion: { reduced }, displayOptionsCenter: center)
        button.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        button.forceHover(true)
        let layer = try #require(button.layer)
        #expect(layer.animation(forKey: "irizHoverLift") != nil)
        reduced = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(layer.animation(forKey: "irizHoverLift") == nil)
        #expect(CATransform3DIsIdentity(layer.transform))
        button.forceHover(false)
        button.forceHover(true)
        #expect(layer.animation(forKey: "irizHoverLift") == nil)
        #expect(CATransform3DIsIdentity(layer.transform))
        reduced = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(layer.animation(forKey: "irizHoverLift") != nil)
    }

    @Test func ожиданиеПеречитываетНастройкуБезТаймераУровня() throws {
        let center = NotificationCenter()
        let surface = AccessibilityHUDSurface()
        var reduced = false
        let presenter = DictationHUDPresenter(
            level: { 0 }, pipelineState: { .transcribing }, historyHint: { "" },
            reduceMotion: { reduced }, displayOptionsCenter: center, surface: { surface })
        presenter.pipelineStateChanged(.transcribing)
        #expect(!presenter.isPollingLevel)
        #expect(try #require(surface.content).animatesWaiting)
        reduced = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let still = try #require(surface.content)
        #expect(still.stage == .recognizing)
        #expect(!still.animatesWaiting)
        reduced = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(try #require(surface.content).animatesWaiting)
        #expect(!presenter.isPollingLevel)
    }
}

@MainActor
private final class AccessibilityHUDSurface: DictationHUDSurface {
    var content: DictationHUDContent?
    func present(_ content: DictationHUDContent) { self.content = content }
    func dismiss() { content = nil }
}
