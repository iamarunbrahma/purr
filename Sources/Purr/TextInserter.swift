import AppKit
import os.log

// Pastes a string at the cursor in the focused app: snapshot pasteboard,
// write text, synth ⌘V, restore the original contents after a delay.
//
// Why not type the string character-by-character with
// `CGEventKeyboardSetUnicodeString`? It works, but:
//   - it's measurably slower for paragraphs (paste is O(1), typing is O(n))
//   - some apps (Slack rich-text input, parts of Office) misinterpret rapid
//     synthetic keystrokes
//   - emojis and combining characters need extra care
// Paste avoids all of that and is the same trick BetterTouchTool, Raycast,
// and the dictation reference apps use.
final class TextInserter {
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "paste")

    // V on a US ANSI keyboard.
    private let kVKey: CGKeyCode = 9

    // How long to wait after sending ⌘V before restoring the original
    // pasteboard. Apps process the paste asynchronously; restore too early
    // and you'll paste the *previous* clipboard contents instead. 250 ms is
    // a comfortable ceiling - Slack, Notes, VS Code, Chrome, and Safari all
    // dispatch the paste within ~50–100 ms on Apple Silicon.
    private let restoreDelay: TimeInterval = 0.25

    // nspasteboard.org markers. Cooperative clipboard managers (Paste,
    // Maccy, Alfred, Raycast) and Universal Clipboard honour these to
    // skip recording or syncing sensitive, short-lived content.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    // Pending pastes, drained one at a time. Each paste owns the system
    // pasteboard from the moment it writes until restoreDelay later (when the
    // target app has consumed the ⌘V and we restore the user's clipboard).
    // A second insert() that fired in the meantime must NOT overwrite the
    // pasteboard yet - it would replace the text the first paste hasn't been
    // consumed for, and that text is lost silently. That is exactly what
    // dropped the trailing dictation word: the final committed sentence and
    // the session's trailing space are inserted back-to-back, so the space
    // clobbered the sentence before the app pasted it. Serialising the writes
    // closes that window. All callers are @MainActor, so this state is only
    // ever touched on the main thread - no lock needed.
    //
    // Serialising narrows the race but doesn't close it: restoreDelay is a
    // fixed guess, and some contexts (observed with tmux panes in
    // WezTerm/Terminal.app, and with Spotlight search) take longer than
    // 250ms to actually read the pasteboard after ⌘V. When that happens the
    // *next* queued paste still overwrites the pasteboard before the first
    // one was consumed, and the app reads that instead of the real
    // sentence. The one caller that reliably queues a second paste
    // immediately behind the first - the streaming flow's trailing gap
    // space - now goes through insertLiteralSpace() instead, so it can't
    // hit this window at all. See AppCoordinator.runStreamingTask().
    private var pasteQueue: [String] = []
    private var draining = false

    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        pasteQueue.append(text)
        guard !draining else { return }
        draining = true
        drainNextPaste()
    }

    // Paste the head of the queue, then schedule the next one only after this
    // paste's restore window elapses, so successive inserts never share the
    // pasteboard. Mid-session sentences are seconds apart (EOU debounce), so
    // this adds no latency there; only the final sentence + trailing space
    // pair actually queues, and a ~restoreDelay gap at session end is invisible.
    private func drainNextPaste() {
        guard !pasteQueue.isEmpty else {
            draining = false
            return
        }
        let text = pasteQueue.removeFirst()

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

        sendCommandV()

        // Restore the previous contents on the main queue, then drain the next
        // paste. We can't restore synchronously because the paste hasn't been
        // consumed yet - see the comment on `restoreDelay` above.
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [self] in
            restorePasteboard(pasteboard, snapshot: snapshot)
            drainNextPaste()
        }
    }

    // Deletes the `count` characters before the cursor by synthesising Backspace
    // presses. Used to undo a just-pasted sentence ("scratch that"). A short gap
    // between events stops the Window Server coalescing them, which would
    // otherwise leave stray characters behind.
    func deleteBackward(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let backspace: CGKeyCode = 51
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false)?
                .post(tap: .cghidEventTap)
            usleep(800)
        }
    }

    // Types a single literal space instead of routing it through the paste
    // queue. Used for the streaming flow's trailing "session gap" space,
    // which is otherwise queued as a second paste immediately behind the
    // final committed sentence's paste - see the race described on
    // `pasteQueue` above. A direct keystroke never touches the pasteboard,
    // so it can't overwrite (or be overwritten by) anything the sentence
    // paste is still waiting to be consumed.
    func insertLiteralSpace() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("Could not create CGEventSource - literal space skipped.")
            return
        }
        let spaceKey: CGKeyCode = 49
        CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    // ------------------------------------------------------------------
    // Pasteboard snapshot/restore
    // ------------------------------------------------------------------

    // Capture every pasteboard item with all of its types. We snapshot the
    // raw Data per type rather than the rendered strings/images because
    // some pasteboard types (rich text, file lists, custom UTIs) lose
    // information when round-tripped through their semantic accessors.
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
        // Combined session state preserves the user's actual modifier-key
        // state. If they happened to be holding Shift, we don't want to
        // accidentally send ⇧⌘V (= "Paste and Match Style" in many apps).
        // The flags we set on the keyDown event override anyway.
        let down = CGEvent(keyboardEventSource: source, virtualKey: kVKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: kVKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
