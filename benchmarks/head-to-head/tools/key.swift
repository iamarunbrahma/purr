import CoreGraphics
import Foundation
// key <keycode> <ctrl,alt,cmd,shift|none> <tap|down|up>: one synthetic key press.
// Modifiers go down and up as their own (left-side) flagsChanged events, like a
// real keyboard, so the HID modifier state is clean afterwards. Setting flags on
// the key event alone leaves them logged as held, and later synthetic keys
// inherit them.
let a = CommandLine.arguments
guard a.count == 4, let code = UInt16(a[1]) else { print("usage: key <code> <mods> <tap|down|up>"); exit(2) }
let table: [String: (CGKeyCode, CGEventFlags)] = [
    "ctrl": (59, .maskControl), "alt": (58, .maskAlternate), "cmd": (55, .maskCommand), "shift": (56, .maskShift),
]
let mods = a[2].split(separator: ",").compactMap { table[String($0)] }
let all = mods.reduce(CGEventFlags()) { $0.union($1.1) }
let src = CGEventSource(stateID: .hidSystemState)
func modifier(_ key: CGKeyCode, flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!
    e.type = .flagsChanged
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(15_000)
}
func press() {
    var held = CGEventFlags()
    for (key, bit) in mods { held.insert(bit); modifier(key, flags: held) }
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
    e.flags = all
    e.post(tap: .cghidEventTap)
}
func release() {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
    e.flags = all
    e.post(tap: .cghidEventTap)
    usleep(15_000)
    var held = all
    for (key, bit) in mods.reversed() { held.remove(bit); modifier(key, flags: held) }
}
switch a[3] {
case "down": press()
case "up": release()
default: press(); usleep(80_000); release()
}
