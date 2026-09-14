// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Три системных разрешения диктовки: микрофон, Accessibility, Input Monitoring.
import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import CoreGraphics
import Foundation

enum Permission: String {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring"
}

@MainActor
enum Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        }
    }

    /// Глобальная защита клавиатурных событий: её может держать фоновый
    /// процесс. Сама по себе она не описывает поле в фокусе и не запрещает микрофон.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    static var isDictationInputProtected: Bool {
        dictationInputIsProtected(secureInputActive: isSecureInputActive,
                                  focusedInputProtected: focusedInputProtection)
    }

    /// Только метаданные текущего элемента; содержимое поля не запрашивается.
    /// Неизвестное состояние сохраняется как nil для осторожного fallback.
    static var focusedInputProtection: Bool? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return inputProtection(of: focused as! AXUIElement)
    }

    static func inputProtection(of element: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        return inputProtection { attribute in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute, &value)
            return (error, value)
        }
    }

    /// Тот же путь чтения в продукте и в пробе: проба не касается чужого окна.
    static func inputProtection(readAttribute: (CFString) -> (AXError, CFTypeRef?)) -> Bool? {
        let (roleError, roleValue) = readAttribute(kAXRoleAttribute as CFString)
        let (subroleError, subroleValue) = readAttribute(kAXSubroleAttribute as CFString)
        if subroleError == .success, subroleValue as? String == kAXSecureTextFieldSubrole { return true }
        let (protectedError, protectedValue) = readAttribute(
            NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString)
        if protectedError == .success, protectedValue as? Bool == true { return true }

        // Необязательного атрибута может не быть у обычного поля/окна.
        // Таймаут и ошибка связи отсутствием атрибута не считаются.
        // Явная защита выше ошибки роли: её нельзя потерять при частичном ответе AX.
        guard roleError == .success, let role = roleValue as? String, !role.isEmpty else { return nil }
        let optionalAbsent: [AXError] = [.attributeUnsupported, .noValue]
        guard (subroleError == .success && subroleValue is String) || optionalAbsent.contains(subroleError),
              (protectedError == .success && protectedValue is Bool) || optionalAbsent.contains(protectedError)
        else { return nil }
        return false
    }

    /// Trigger the system prompt or, if previously denied, push the
    /// user toward the right Settings pane. Returns immediately;
    /// actual grant happens asynchronously.
    static func request(_ p: Permission) {
        switch p {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .denied {
                openSettings(for: p)
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    log("Microphone request: granted=\(granted)")
                }
            }
        case .accessibility:
            // The AX-trust-with-prompt API shows a native dialog
            // when status is undetermined, falls through silently if
            // already granted. We also open Settings as a fallback
            // for the previously-denied case.
            // kAXTrustedCheckOptionPrompt is an Apple-defined CFStringRef.
            // Swift 6 strict concurrency complains about referencing the
            // global directly from an @MainActor method; bridge via a
            // string literal that matches its documented value.
            let key = "AXTrustedCheckOptionPrompt"
            _ = AXIsProcessTrustedWithOptions([key: kCFBooleanTrue!] as CFDictionary)
        case .inputMonitoring:
            // CGRequestListenEventAccess is the canonical request
            // path for CGEventTap clients. On macOS 26 it registers
            // the app in the Input Monitoring list and shows the
            // native permission prompt.
            _ = CGRequestListenEventAccess()
        }
    }

    static func openSettings(for permission: Permission) {
        let subpath: String
        switch permission {
        case .microphone:
            subpath = "Privacy_Microphone"
        case .accessibility:
            subpath = "Privacy_Accessibility"
        case .inputMonitoring:
            subpath = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(subpath)") {
            NSWorkspace.shared.open(url)
        }
    }
}
