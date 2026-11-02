import Foundation
// poll <docpath> <timeout_s> <stable_s> <outfile>: reads the TextEdit document
// at docpath (by path, never by index), from an empty baseline, until its text
// changes and then stays the same for stable_s. Started before the hotkey, so
// it is warm when text lands. Writes the final text to outfile and prints
// "first=<unix s> final=<unix s> chars=<n> misses=<n> gap=<s>" (first=-1 if
// nothing arrived within timeout_s; gap is the longest time between reads).
let a = CommandLine.arguments
guard a.count == 5, let timeout = Double(a[2]), let stable = Double(a[3]) else {
    print("usage: poll <docpath> <timeout_s> <stable_s> <outfile>"); exit(2)
}
let script = NSAppleScript(source: "tell application \"TextEdit\" to get text of (first document whose path is \"\(a[1])\")")!
var compileErr: NSDictionary?
script.compileAndReturnError(&compileErr)
func read() -> String? {
    var err: NSDictionary?
    let r = script.executeAndReturnError(&err)
    return err == nil ? (r.stringValue ?? "") : nil
}
_ = read()
// With POLL_MARKER set, text that settles before that file exists (the hotkey
// release) doesn't end the poll: streaming apps pause between sentences.
let marker = ProcessInfo.processInfo.environment["POLL_MARKER"]
func released() -> Bool { marker.map { FileManager.default.fileExists(atPath: $0) } ?? true }
let t0 = Date()
var first = -1.0, last = "", lastChange = 0.0, misses = 0, prev = 0.0, gap = 0.0
while true {
    let t = Date().timeIntervalSince(t0)
    if let s = read() {
        let now = Date().timeIntervalSince(t0)
        gap = max(gap, now - prev); prev = now
        if s != last { if first < 0 { first = now }; last = s; lastChange = now }
    } else { misses += 1 }
    if first >= 0 && t - lastChange >= stable && released() { break }
    if first < 0 && t >= timeout { break }
    if t >= timeout + 120 { break }
    usleep(10_000)
}
try? last.write(toFile: a[4], atomically: true, encoding: .utf8)
let base = t0.timeIntervalSince1970
print(String(format: "first=%.3f final=%.3f chars=%d misses=%d gap=%.3f",
             first < 0 ? -1 : base + first, base + lastChange, last.count, misses, gap))
