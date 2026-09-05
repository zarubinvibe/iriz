import IrizCore
import SwiftUI
import IrizSettings

@main
struct SettingsPreviewApp: App {
    var body: some Scene {
        WindowGroup("Настройки \(IRIZ_NAME)") {
            IrizSettingsView(preview: true)
        }
        .windowResizability(.contentSize)
    }
}
