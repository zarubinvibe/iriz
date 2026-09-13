// Integration fixtures for an ephemeral GitHub-hosted Mac, never the developer's Mac.
// Use --check locally: it only reads the enabled layouts and iriz's language key.
import Carbon
import Foundation

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
require(arguments == ["--check"] || arguments == ["--prepare-hosted"],
        "Usage: macos_ci_environment.swift --check | --prepare-hosted")
let prepare = arguments == ["--prepare-hosted"]
if prepare {
    let environment = ProcessInfo.processInfo.environment
    require(environment["GITHUB_ACTIONS"] == "true"
            && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
            && environment["RUNNER_OS"] == "macOS",
            "Fixture writes require a GitHub-hosted macOS runner.")
}

func layouts(includeAllInstalled: Bool) -> [TISInputSource] {
    // Same enabled-only filter as LayoutSwitcher.installedLayouts() when false.
    let conditions = [
        kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
        kTISPropertyInputSourceIsSelectCapable as String: true as Any,
    ] as CFDictionary
    guard let sources = TISCreateInputSourceList(conditions, includeAllInstalled)?
        .takeRetainedValue() as? [TISInputSource] else {
        require(false, "Cannot list macOS keyboard input sources.")
        return []
    }
    return sources
}

func sourceID(_ source: TISInputSource) -> String {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

func currentSourceID() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
    return sourceID(source)
}

func language(_ source: TISInputSource) -> String {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return "" }
    let languages = Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as? [String]
    return String(languages?.first?.lowercased().prefix(2) ?? "")
}

func hasUnicodeData(_ source: TISInputSource) -> Bool {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return false }
    return CFDataGetLength(Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue()) > 0
}

let englishIDs = ["com.apple.keylayout.US", "com.apple.keylayout.ABC"]
let russianID = "com.apple.keylayout.Russian"
let languageKey = "ru.smltlk.interfaceLanguage" as CFString
let originalSourceID = currentSourceID()
require(!originalSourceID.isEmpty, "Cannot identify the active keyboard input source.")

if prepare {
    let enabled = layouts(includeAllInstalled: false)
    let all = layouts(includeAllInstalled: true)
    // Reuse an enabled Apple English layout; otherwise enable one, not both.
    let english = (enabled + all).first { englishIDs.contains(sourceID($0)) }
    let russian = all.first { sourceID($0) == russianID }
    require(english != nil && russian != nil, "Apple US/ABC and Russian keyboard layouts must be installed.")
    let pair = [english!, russian!]
    require(pair.allSatisfy(hasUnicodeData), "Apple EN/RU layouts must expose nonempty Unicode layout data.")
    for source in pair where !enabled.contains(where: { sourceID($0) == sourceID(source) }) {
        let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnableCapable)
        require(property.map { Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue() == kCFBooleanTrue } == true,
                "The Apple layout \(sourceID(source)) cannot be enabled.")
        let status = TISEnableInputSource(source)
        require(status == noErr, "Cannot enable \(sourceID(source)): OSStatus \(status).")
    }
    // kCFPreferencesAnyApplication is NSGlobalDomain. Only this iriz key changes;
    // system language preferences and all unrelated global preferences stay intact.
    CFPreferencesSetValue(languageKey, "ru" as CFString, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    require(CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                    kCFPreferencesAnyHost), "Cannot save iriz's CI language preference.")
}

let enabled = layouts(includeAllInstalled: false)
// Check the first EN/RU pair, exactly as DynamicKeyMapping.configureSharedKeyMapping does.
for (code, allowedIDs) in [("en", englishIDs), ("ru", [russianID])] {
    guard let source = enabled.first(where: { language($0) == code }),
          allowedIDs.contains(sourceID(source)), hasUnicodeData(source) else {
        require(false, "Missing enabled Apple \(code) layout with Unicode data; the integration fixture is not ready.")
        exit(1)
    }
    print("Enabled \(code) layout: \(sourceID(source)); Unicode data available.")
}
require(currentSourceID() == originalSourceID,
        "The active keyboard input source changed during the environment check.")
let globalLanguage = CFPreferencesCopyValue(languageKey, kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
require(globalLanguage == "ru" && UserDefaults.standard.string(forKey: languageKey as String) == "ru",
        "iriz's NSGlobalDomain language key must be ru and readable through UserDefaults.standard.")
print("PASS macOS integration environment: Apple EN/RU layouts, iriz language ru; active input unchanged.")
