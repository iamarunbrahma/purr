import Foundation
import os.log

// Settings › General › Uninstall Purr…: removes what Purr put on this Mac.
// Models, meetings and the app go to the Trash, so a slip can be undone until
// it's emptied. Permissions are reset while the app is still in place. Settings
// and caches are deleted outright, by a helper that runs once Purr has quit so
// nothing can write them back.
enum Uninstaller {
    private static let log = Logger(subsystem: "com.arunbrahma.purr", category: "uninstall")

    enum Failure: LocalizedError {
        case noBundleID

        var errorDescription: String? {
            "Purr's bundle ID is missing, so it can't tell which settings are its own."
        }
    }

    // Purr's names for a meeting's transcript, summary and audio; see
    // MeetingDocument.write, MeetingSummarizer.sidecarURL and writeAudio.
    private static let meetingFileName = try! NSRegularExpression(
        pattern: #"^Meeting \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}(\.md|\.summary\.md|\.m4a)$"#)

    // Models, the default meetings folder, and everything else Purr writes.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Purr", isDirectory: true)
    }

    // Darwin's per-user cache folder (/var/folders/…/C/), where Metal keeps
    // Purr's shader caches.
    static var userCacheDirectory: URL? {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        // Absolute only ("/"), so the helper never deletes a relative path.
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &path, path.count) > 0, path[0] == 0x2F else { return nil }
        return URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
    }

    static var meetingFolders: [URL] {
        [SettingsStore.defaultMeetingsDirectory] + (customMeetingsFolder.map { [$0] } ?? [])
    }

    // False when Purr runs from where it can't move itself, such as its disk
    // image, or /Applications for an account that isn't an administrator.
    static var canMoveApp: Bool {
        FileManager.default.isDeletableFile(atPath: Bundle.main.bundlePath)
    }

    // A folder picked in Settings can hold the user's other files, so only
    // Purr's own leave it. Nil when it's inside the support folder, which
    // goes to the Trash whole.
    private static var customMeetingsFolder: URL? {
        let path = SettingsStore.shared.meetingsFolderPath
        guard !path.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let inSupport = (folder.path + "/").hasPrefix(supportDirectory.standardizedFileURL.path + "/")
        return inSupport ? nil : folder
    }

    static func purrMeetingFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return
            names
            .filter { meetingFileName.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            .map { folder.appendingPathComponent($0, isDirectory: false) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    // Transcripts only, so a meeting with a summary and audio counts once.
    static func meetingCount(in folders: [URL]) -> Int {
        folders.flatMap(purrMeetingFiles).filter {
            $0.pathExtension == "md" && !$0.lastPathComponent.hasSuffix(".summary.md")
        }.count
    }

    // Moves Purr's meetings and its support folder to the Trash, resets its
    // permissions, moves the app, then starts the cleanup helper. The caller
    // must quit next, without turning the run loop: Purr re-reading its
    // Accessibility trust, as a timer or the change notification can, lists
    // it in System Settings again. Throws, before anything is deleted or
    // reset, if one of Purr's files couldn't be moved.
    static func run() throws {
        // The helper deletes folders named after the bundle ID, so it must be
        // a real reverse-DNS name, never empty or "..".
        guard let id = Bundle.main.bundleIdentifier,
            id.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
        else { throw Failure.noBundleID }

        let fm = FileManager.default
        if let custom = customMeetingsFolder {
            for file in purrMeetingFiles(in: custom) {
                try fm.trashItem(at: file, resultingItemURL: nil)
            }
        }
        var support: NSURL?
        if fm.fileExists(atPath: supportDirectory.path) {
            try fm.trashItem(at: supportDirectory, resultingItemURL: &support)
        }
        // Before the app moves: tccutil finds Purr by bundle ID through
        // Launch Services, which leaves out apps in the Trash.
        resetPermissions(bundleID: id)
        var app: NSURL?
        do {
            try fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: &app)
        } catch {
            log.error("Uninstall: Purr.app didn't move: \(error.localizedDescription, privacy: .public)")
        }
        // The models are already in the Trash, so the caller still quits.
        do {
            try startCleanupHelper(bundleID: id)
        } catch {
            log.error("Uninstall: cleanup helper didn't start: \(error.localizedDescription, privacy: .public)")
        }
        log.info(
            """
            Uninstall: in the Trash as \(support?.lastPathComponent ?? "-", privacy: .public) \
            and \(app?.lastPathComponent ?? "-", privacy: .public).
            """)
    }

    private static func resetPermissions(bundleID: String) {
        switch runToCompletion("/usr/bin/tccutil", ["reset", "All", bundleID]) {
        case (0, let output)?:
            log.info("Uninstall: \(output, privacy: .public)")
        case let (status, output)?:
            log.error("Uninstall: tccutil exited \(status, privacy: .public): \(output, privacy: .public)")
        case nil:
            log.error("Uninstall: tccutil didn't finish, so permissions may stay.")
        }
    }

    // Runs a tool to its exit and returns its status and output, or nil if it
    // didn't start or finish in time. Unlike waitUntilExit, it never turns the
    // run loop, so none of Purr's timers or observers run in the meantime.
    static func runToCompletion(
        _ path: String, _ arguments: [String], timeout: TimeInterval = 10
    )
        -> (status: Int32, output: String)?
    {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        guard (try? task.run()) != nil, exited.wait(timeout: .now() + timeout) == .success else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (task.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Detached like OnboardingModel.relaunch()'s helper, so it outlives
    // NSApp.terminate.
    private static func startCleanupHelper(bundleID: String) throws {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        let script = cleanupScript(
            pid: ProcessInfo.processInfo.processIdentifier, bundleID: bundleID, library: library,
            support: supportDirectory, userCache: userCacheDirectory)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("purr-uninstall-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptURL.path]
        try task.run()
    }

    // Waits for `pid` to exit, then deletes the preferences through cfprefsd
    // (a live app would write its cached copy back) and the empty plist that
    // leaves, the caches, and any empty folders a getter re-created in the
    // support folder after it moved. Then deletes itself.
    static func cleanupScript(pid: Int32, bundleID: String, library: URL, support: URL, userCache: URL?) -> String {
        let caches =
            [
                "Preferences/\(bundleID).plist",
                "Caches/\(bundleID)",
                "HTTPStorages/\(bundleID)",
                "HTTPStorages/\(bundleID).binarycookies",
                "Saved Application State/\(bundleID).savedState",
                "WebKit/\(bundleID)",
            ].map { library.appendingPathComponent($0) }
            + (userCache.map { [$0.appendingPathComponent(bundleID)] } ?? [])
        return """
            #!/bin/sh
            i=0
            while kill -0 \(pid) 2>/dev/null; do
                i=$((i+1))
                if [ "$i" -gt 150 ]; then break; fi
                sleep 0.2
            done
            defaults delete \(quoted(bundleID)) >/dev/null 2>&1
            rm -rf \(caches.map { quoted($0.path) }.joined(separator: " "))
            if [ -d \(quoted(support.path)) ]; then find \(quoted(support.path)) -depth -type d -empty -delete; fi
            rm -f "$0"
            """
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
