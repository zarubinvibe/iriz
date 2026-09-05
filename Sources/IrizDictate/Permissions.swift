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

    /// Активен ли защищённый ввод — поле пароля, Secure Keyboard Entry в
    /// терминале. Тот же системный вызов, что у AutoSwitchPolicy в IrizInput
    /// (тянуть IrizInput в IrizDictate не за чем — API системное).
    ///
    /// Для диктовки это честный класс провала вставки: в защищённое поле
    /// синтетический ⌘V не дойдёт всё равно, а сырьё уже легло бы на диск.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

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
