import AppKit

// Manual NSApplication bootstrap instead of @main / SwiftUI App. Two reasons:
//
// 1. We want a pure menu-bar app (LSUIElement = true). SwiftUI's App
//    lifecycle insists on at least one Scene, which forces window plumbing
//    we don't need and makes MenuBarExtra-vs-NSStatusItem decisions awkward
//    on macOS 13.
//
// 2. The hotkey + audio + transcription pipeline is fundamentally an
//    AppKit/Combine system. Driving it from a SwiftUI scene root would mean
//    weaving lifecycle hooks through the View tree. AppDelegate is the
//    right home.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Give AppKit a real main menu. A pure-agent app (LSUIElement + .accessory)
// that never sets NSApp.mainMenu has only the status-item menu bar, and on
// macOS Tahoe that can leave the NSStatusItem orphaned off the bar (icon never
// drawn). Working menu-bar apps always carry a standard app menu; mirror that.
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
