import AppKit
import ApplicationServices
import Testing

@testable import IrizDictate

@Suite("Защита поля не равна глобальной защите клавиатуры")
@MainActor
struct FocusedInputProtectionTests {
    private func protection(role: String? = "AXTextField",
                            roleError: AXError = .success,
                            subrole: String? = nil,
                            subroleError: AXError = .attributeUnsupported,
                            protected: Bool? = nil,
                            protectedError: AXError = .attributeUnsupported) -> Bool? {
        Permissions.inputProtection { attribute in
            switch attribute as String {
            case kAXRoleAttribute:
                return (roleError, role.map { $0 as CFString })
            case kAXSubroleAttribute:
                return (subroleError, subrole.map { $0 as CFString })
            case NSAccessibility.Attribute.containsProtectedContent.rawValue:
                return (protectedError, protected.map { NSNumber(value: $0) })
            default:
                Issue.record("Неожиданный запрос атрибута: \(attribute)")
                return (.attributeUnsupported, nil)
            }
        }
    }

    @Test func парольЗащищёнПриЛюбомГлобальномФлаге() {
        let focused = protection(subrole: kAXSecureTextFieldSubrole, subroleError: .success)
        #expect(focused == true)
        for global in [false, true] {
            #expect(dictationInputIsProtected(secureInputActive: global, focusedInputProtected: focused))
        }
    }

    @Test func защищённоеСодержимоеНеТребуетПарольнойПодроли() {
        #expect(protection(role: "AXTextArea", protected: true, protectedError: .success) == true)
        #expect(protection(subroleError: .cannotComplete,
                           protected: true, protectedError: .success) == true)
        #expect(protection(roleError: .cannotComplete,
                           protected: true, protectedError: .success) == true)
        #expect(protection(roleError: .cannotComplete,
                           subrole: kAXSecureTextFieldSubrole, subroleError: .success) == true)
    }

    @Test func обычноеПолеИОкноНеБлокируютсяФоновымФлагом() {
        for role in ["AXTextField", "AXTextArea", "AXWindow"] {
            let focused = protection(role: role)
            #expect(focused == false)
            #expect(!dictationInputIsProtected(secureInputActive: true, focusedInputProtected: focused))
        }
        #expect(protection(role: "AXWindow", subrole: "AXStandardWindow", subroleError: .success,
                           protected: false, protectedError: .success) == false)
        #expect(protection(subroleError: .noValue, protectedError: .noValue) == false)
    }

    @Test func ошибкаИОтсутствующаяРольОставляютСостояниеНеизвестным() {
        for error: AXError in [.cannotComplete, .invalidUIElement, .attributeUnsupported, .noValue] {
            #expect(protection(roleError: error) == nil)
        }
        #expect(protection(role: nil) == nil)
        #expect(protection(role: "") == nil)
        #expect(protection(subroleError: .cannotComplete) == nil)
        #expect(protection(protectedError: .cannotComplete) == nil)
        #expect(protection(subroleError: .success) == nil)
        #expect(protection(protectedError: .success) == nil)
        #expect(dictationInputIsProtected(secureInputActive: true, focusedInputProtected: nil))
        #expect(!dictationInputIsProtected(secureInputActive: false, focusedInputProtected: nil))
    }

    @Test func запросОграниченМетаданнымиБезЗначенияИВыделения() {
        var requested: [String] = []
        let result = Permissions.inputProtection { attribute in
            let name = attribute as String
            requested.append(name)
            if name == kAXRoleAttribute { return (.success, "AXTextArea" as CFString) }
            return (.attributeUnsupported, nil)
        }
        #expect(result == false)
        #expect(requested == [kAXRoleAttribute, kAXSubroleAttribute,
                              NSAccessibility.Attribute.containsProtectedContent.rawValue])
        #expect(!requested.contains(kAXValueAttribute))
        #expect(!requested.contains(kAXSelectedTextAttribute))
    }
}
