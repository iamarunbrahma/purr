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

// Text fields only get ⌘X/⌘C/⌘V/⌘A/⌘Z through these menu items, even with the
// menu bar hidden. Without them dictation into Purr's own fields (setup's Try
// it box) is silently dropped, since dictation pastes with ⌘V.
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
app.mainMenu = mainMenu

app.run()
