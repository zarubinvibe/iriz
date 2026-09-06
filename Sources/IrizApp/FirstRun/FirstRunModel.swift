// Состояние знакомства: какой шаг открыт и что система уже разрешила.
//
// Решения живут здесь, чистыми функциями: какой шаг следующий, можно ли идти
// дальше, пройдено ли знакомство. Вьюха их только показывает. В этом проекте
// уже пять раз платили за то, что решение жило в рисующем коде и разъезжалось
// с моделью.
import AppKit
import AVFoundation
import Foundation
import IrizCore

/// Шаги знакомства. Порядок - это и есть сценарий, и он не случайный: сначала
/// «что это» и «где оно живёт», потом разрешения от самого понятного к самому
/// пугающему, и только потом проба голосом. Человек, которому уже объяснили,
/// зачем нужен микрофон, спокойнее отвечает на «сможет читать все нажатия».
enum FirstRunStep: String, CaseIterable, Equatable {
    case welcome
    case whereItLives
    case model
    case microphone
    case accessibility
    case inputMonitoring
    case tryIt
    case plate
    case agent
    case translate
    case whenItBreaks

    var copy: FirstRunCopy.Step {
        switch self {
        case .welcome: return FirstRunCopy.welcome
        case .whereItLives: return FirstRunCopy.whereItLives
        case .model: return FirstRunCopy.model
        case .microphone: return FirstRunCopy.microphone
        case .accessibility: return FirstRunCopy.accessibility
        case .inputMonitoring: return FirstRunCopy.inputMonitoring
        case .tryIt: return FirstRunCopy.tryIt
        case .plate: return FirstRunCopy.plate
        case .agent: return FirstRunCopy.agent
        case .translate: return FirstRunCopy.translate
        case .whenItBreaks: return FirstRunCopy.whenItBreaks
        }
    }

    /// Подпись у стрелки к кнопке. Пустая там, где кнопки нет.
    var actionHint: String {
        switch self {
        case .model: return FirstRunCopy.hintModel
        case .microphone: return FirstRunCopy.hintMicrophone
        case .accessibility: return FirstRunCopy.hintAccessibility
        case .inputMonitoring: return FirstRunCopy.hintInputMonitoring
        default: return ""
        }
    }

    /// Разрешение, которое просит этот шаг. Шаги без разрешения возвращают nil.
    var permission: FirstRunPermission? {
        switch self {
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        default: return nil
        }
    }
}

enum FirstRunPermission: String, CaseIterable, Equatable {
    case microphone
    case accessibility
    case inputMonitoring
}

/// Ни один шаг не запирает дверь.
///
/// Разрешение можно не дать прямо сейчас - и всё равно пройти дальше. Заперев
/// человека на «Мониторинге ввода», продукт получил бы не согласие, а закрытое
/// окно: именно на этой двери в карте путей стоял самый высокий риск ухода.
/// Что не работает без разрешения, сказано словами на самом шаге.
func firstRunCanAdvance(from step: FirstRunStep) -> Bool { true }

/// Следующий шаг или nil, если знакомство кончилось.
func firstRunNextStep(after step: FirstRunStep) -> FirstRunStep? {
    let all = FirstRunStep.allCases
    guard let index = all.firstIndex(of: step), index + 1 < all.count else { return nil }
    return all[index + 1]
}

func firstRunPreviousStep(before step: FirstRunStep) -> FirstRunStep? {
    let all = FirstRunStep.allCases
    guard let index = all.firstIndex(of: step), index > 0 else { return nil }
    return all[index - 1]
}

/// Ключ «знакомство пройдено». Живёт в том же домене, что и остальные
/// настройки, поэтому переезжает вместе с ними миграцией бандла.
let FIRST_RUN_COMPLETED_KEY = "ru.smltlk.firstRunCompleted"

/// Показывать ли знакомство. Один раз на установку.
///
/// Вопрос решается ДО того, как что-либо нарисовано: показать знакомство тому,
/// кто уже год пользуется продуктом, - это не забота, а неуважение к его
/// времени.
func firstRunShouldShow(defaults: UserDefaults,
                        permissionsGranted: Bool,
                        modelInstalled: Bool = true) -> Bool {
    if defaults.bool(forKey: FIRST_RUN_COMPLETED_KEY) { return false }
    // Без модели продукт не работает вовсе, а поставить её можно только
    // отсюда. Человек с выданными разрешениями и пустым диском иначе не увидел
    // бы ни знакомства, ни модели - только отказ распознавания.
    if !modelInstalled { return true }
    // Разрешения уже выданы - значит человек прошёл этот путь руками до того,
    // как знакомство появилось в продукте. Ему показывать нечего.
    return !permissionsGranted
}

/// Живое состояние разрешений. Читается системой, а не запоминается: человек
/// уходит в Системные настройки и возвращается, и окно обязано это заметить.
@MainActor
func firstRunPermissionGranted(_ permission: FirstRunPermission) -> Bool {
    switch permission {
    case .microphone:
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    case .accessibility:
        return AXIsProcessTrusted()
    case .inputMonitoring:
        return CGPreflightListenEventAccess()
    }
}
