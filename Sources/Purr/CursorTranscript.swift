import Foundation

// Append-only output for live dictation. Never delete/rewrite text in another
// app: autocorrect and the user's editor own that document. Sentence mode is
// still available when post-processing or recognizer corrections are wanted.
struct CursorTranscript {
    private var emitted = ""
    private var utterancePrefix = ""
    private var lastOutput: Character?
    private var lastCompleted: String?
    private var receivedPartial = false
    private(set) var hadRevision = false

    mutating func partial(_ text: String) -> String {
        receivedPartial = true
        return append(text)
    }

    mutating func endOfUtterance(_ text: String) -> String {
        // finish() can repeat the last EOU without another audio partial.
        if !receivedPartial, emitted.isEmpty, lastCompleted == text { return "" }
        let suffix = append(text)
        lastCompleted = text
        emitted = ""
        utterancePrefix = ""
        receivedPartial = false
        return suffix
    }

    mutating func finish() -> String {
        guard let lastOutput, !lastOutput.isWhitespace else { return "" }
        self.lastOutput = " "
        return " "
    }

    private mutating func append(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        guard text.hasPrefix(emitted) else {
            // A revised snapshot is not a suffix. Appending it would duplicate
            // the sentence; backspacing could erase editor/user-owned text.
            hadRevision = true
            return ""
        }
        if emitted.isEmpty {
            utterancePrefix = lastOutput.map { !$0.isWhitespace } == true
                && text.first.map { !$0.isWhitespace } == true ? " " : ""
        }
        let suffix = String(text.dropFirst(emitted.count))
        guard !suffix.isEmpty else { return "" }
        let output = (emitted.isEmpty ? utterancePrefix : "") + suffix
        emitted = text
        lastOutput = output.last
        return output
    }
}
