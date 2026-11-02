import CoreGraphics
import Foundation
// fnkey <down|up>: presses or releases fn alone, as the flagsChanged event a
// keyboard sends (keycode 63, the secondary-fn flag).
guard CommandLine.arguments.count == 2, ["down", "up"].contains(CommandLine.arguments[1]) else {
    print("usage: fnkey <down|up>"); exit(2)
}
let down = CommandLine.arguments[1] == "down"
let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 63, keyDown: down)!
e.type = .flagsChanged
e.flags = down ? .maskSecondaryFn : []
e.post(tap: .cghidEventTap)
usleep(15_000)
