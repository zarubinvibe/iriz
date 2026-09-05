import SwiftUI

@main
struct IrizAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: appDelegate.menuState, appDelegate: appDelegate)
        } label: {
            MenuBarLabelView(state: appDelegate.menuState)
        }
        // .window, а не .menu: NSMenu не даёт ни кегля, ни веса, ни отступов —
        // иерархию в нём не построить (см. MenuContentView и VISUAL_SPEC §6).
        .menuBarExtraStyle(.window)
    }
}
