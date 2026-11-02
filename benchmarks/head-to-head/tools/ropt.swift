import CoreGraphics
import Foundation
// ropt <down|up>: presses or releases Right Option alone, as the flagsChanged
// event a real keyboard sends (keycode 61, Option plus its right-side device bit).
guard CommandLine.arguments.count == 2, ["down", "up"].contains(CommandLine.arguments[1]) else {
    print("usage: ropt <down|up>"); exit(2)
}
let down = CommandLine.arguments[1] == "down"
let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 61, keyDown: down)!
e.type = .flagsChanged
e.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
e.post(tap: .cghidEventTap)
usleep(15_000)
