import AppKit

// Manual NSApplication bootstrap instead of @main / SwiftUI App:
// SwiftUI's App lifecycle insists on at least one Scene, which forces window
// plumbing a pure menu-bar app (LSUIElement) doesn't need, and the hotkey +
// audio + transcription pipeline is an AppKit/Combine system that belongs in
// an AppDelegate rather than woven through a View tree.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Give AppKit a real main menu. A pure-agent app (LSUIElement + .accessory)
// that never sets NSApp.mainMenu can end up with an orphaned NSStatusItem on
// macOS Tahoe - the icon is never drawn.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(
    NSMenuItem(
        title: "Quit Purr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
