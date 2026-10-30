import AppKit
import os.log

// Pastes a string at the cursor: snapshot pasteboard, write text, synth ⌘V,
// restore after a delay. Not typed character-by-character - that's slower
// for paragraphs, some apps misinterpret rapid synthetic keystrokes, and
// emojis/combining characters need extra care.
final class TextInserter {
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "paste")

    // V on a US ANSI keyboard.
    private let kVKey: CGKeyCode = 9

    // Restore too early and the target re-pastes the *previous* clipboard
    // contents; 250ms comfortably covers real-world paste latency (~50-100ms).
    private let restoreDelay: TimeInterval = 0.25

    // nspasteboard.org markers so clipboard managers skip recording this
    // short-lived paste.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    // Drained one at a time so a second action never runs while the target
    // hasn't consumed the first - firing early (a paste overwriting the
    // pasteboard, or a keystroke landing before the paste is read) is what
    // silently dropped the trailing dictated word on slow targets like tmux
    // and Spotlight. @MainActor only, so no lock needed.
    private enum Action {
        case paste(String)
        case literalSpace
    }
    private var actionQueue: [Action] = []
    private var draining = false

    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(.paste(text))
    }

    // Direct keystroke (see sendSpaceKeystroke), but still queued behind any
    // paste ahead of it - see the comment on `actionQueue` above.
    func insertLiteralSpace() {
        enqueue(.literalSpace)
    }

    private func enqueue(_ action: Action) {
        actionQueue.append(action)
        guard !draining else { return }
        draining = true
        drainNextAction()
    }

    // Moves to the next action only once this one's effect has landed - a
    // paste after its restore window, a keystroke immediately. Mid-session
    // sentences are seconds apart (EOU debounce), so this only adds latency
    // at session end, where it's invisible.
    private func drainNextAction() {
        guard !actionQueue.isEmpty else {
            draining = false
            return
        }
        switch actionQueue.removeFirst() {
        case .paste(let text):
            performPaste(text)
        case .literalSpace:
            sendSpaceKeystroke()
            drainNextAction()
        }
    }

    private func performPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        // Single item so the markers travel with the string; separate
        // setData calls would land on independent pasteboard items.
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealedType)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
        // Any other write to the pasteboard from here on bumps this.
        let ourChangeCount = pasteboard.changeCount

        sendCommandV()

        // Restore the previous contents on the main queue, then drain the next
        // action. We can't restore synchronously because the paste hasn't been
        // consumed yet - see the comment on `restoreDelay` above.
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [self] in
            // Something copied while the paste was in flight (the user, or an
            // app writing the clipboard), so its contents are now the newest:
            // restoring the old snapshot over them would silently lose them.
            if pasteboard.changeCount == ourChangeCount {
                restorePasteboard(pasteboard, snapshot: snapshot)
            } else {
                log.info("Pasteboard changed during a paste - leaving the newer contents in place.")
            }
            drainNextAction()
        }
    }

    // Undoes a just-pasted sentence ("scratch that"). The gap between events
    // stops the Window Server coalescing them into stray characters.
    func deleteBackward(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let backspace: CGKeyCode = 51
        for _ in 0..<count {
            postBareKeystroke(backspace, source: source)
            usleep(800)
        }
    }

    // A direct keystroke, not a clipboard round-trip: same technique as
    // deleteBackward, just Space instead of Backspace. Only called from
    // drainNextAction(), which is what makes it safe - see `actionQueue`.
    private func sendSpaceKeystroke() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let space: CGKeyCode = 49
        postBareKeystroke(space, source: source)
    }

    // Explicit empty flags, like sendCommandV: a new event otherwise inherits
    // the session's modifier state, which keeps ⌘ latched after our own
    // synthetic ⌘V and includes a held Right Option. Space would turn into
    // ⌘Space (Spotlight) and Backspace into ⌘⌫ / ⌥⌫ (delete line / word).
    private func postBareKeystroke(_ key: CGKeyCode, source: CGEventSource) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }

    // ------------------------------------------------------------------
    // Pasteboard snapshot/restore
    // ------------------------------------------------------------------

    // Raw Data per type, not semantic accessors - rich text, file lists, and
    // custom UTIs lose information when round-tripped through those.
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pb.pasteboardItems else { return PasteboardSnapshot(items: []) }
        let captured: [[NSPasteboard.PasteboardType: Data]] = items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
        return PasteboardSnapshot(items: captured)
    }

    private func restorePasteboard(_ pb: NSPasteboard, snapshot: PasteboardSnapshot) {
        pb.clearContents()
        if snapshot.items.isEmpty { return }
        let restored: [NSPasteboardItem] = snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(restored)
    }

    // ------------------------------------------------------------------
    // ⌘V synthesis
    // ------------------------------------------------------------------

    private func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("Could not create CGEventSource - paste injection skipped.")
            return
        }
        // Explicit flags override the session's modifier state, so a Shift
        // held by the user can't turn this into ⇧⌘V ("Paste and Match Style").
        let down = CGEvent(keyboardEventSource: source, virtualKey: kVKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: kVKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
