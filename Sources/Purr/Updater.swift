import AppKit
import Combine
import CryptoKit
import Foundation
import os.log

// In-app updater backed by GitHub Releases.
//
// The install helper waits for our PID to exit, mounts the DMG, verifies the
// embedded .app's codesign seal, ditto-copies it over the running bundle,
// strips quarantine, detaches, and relaunches. The codesign gate runs *before*
// we touch the running app, so a corrupt download cannot destroy the install.
//
// Releases are signed with a stable Developer ID (Team 5JCFRMC367), so TCC
// keys off the designated requirement rather than a per-build cdhash and
// Accessibility and Microphone grants survive an update. They are lost
// only if the bundle ID or signing identity changes.
//
// Caveat: the helper's codesign gate is NOT pinned to our Team ID - any bundle
// with a valid Developer ID signature passes. Pinning with `codesign -R`
// against 5JCFRMC367 is the outstanding fix; until then the SHA-256 sidecar is
// what ties the download to a release we published.
//
// The class stays non-isolated with @MainActor methods so AppDelegate (which
// can't be @MainActor because main.swift initialises it from a synchronous
// top-level context) can hold it as a stored property.
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, dmgURL: URL, sha256URL: URL?, sizeBytes: Int64)
        case downloading(progress: Double)
        case readyToInstall(dmgPath: URL, version: String)
        case installing
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private static let releasesAPI = URL(
        string: "https://api.github.com/repos/iamarunbrahma/purr/releases/latest"
    )!
    // Probe for /releases/latest 404s: GitHub returns 404 both when the repo is
    // gone and when it exists with zero releases. The repo root tells them apart.
    private static let repoAPI = URL(
        string: "https://api.github.com/repos/iamarunbrahma/purr"
    )!

    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "updater")
    private var downloader: UpdateDownloader?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    @MainActor
    func checkForUpdates() async {
        state = .checking
        do {
            var request = URLRequest(url: Self.releasesAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Purr/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 404 {
                    state = try await resolve404()
                    return
                }
                state = .error("GitHub returned \(http.statusCode). Try again later.")
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.trimmingCharacters(
                in: CharacterSet(charactersIn: "vV ")
            )
            guard
                let asset = release.assets.first(where: {
                    $0.name.lowercased().hasSuffix(".dmg")
                })
            else {
                state = .error("Latest release has no .dmg asset.")
                return
            }
            guard let dmgURL = URL(string: asset.browserDownloadURL),
                Self.isTrustedDownloadHost(dmgURL)
            else {
                state = .error("Update download URL is not a trusted GitHub host.")
                return
            }
            let sha256URL = Self.findSHA256AssetURL(matching: asset.name, in: release.assets)
            if Self.compareVersions(remoteVersion, currentVersion) <= 0 {
                state = .upToDate
            } else {
                state = .available(
                    version: remoteVersion,
                    dmgURL: dmgURL,
                    sha256URL: sha256URL,
                    sizeBytes: Int64(asset.size)
                )
            }
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .error("Could not reach GitHub: \(error.localizedDescription)")
        }
    }

    // About calls this each time it opens. The updater lives as long as the
    // app, so otherwise a reopened About keeps showing its first result. A
    // check, download or install that's under way is left alone.
    @MainActor
    func checkForUpdatesUnlessBusy() async {
        switch state {
        case .checking, .downloading, .readyToInstall, .installing:
            return
        case .idle, .upToDate, .available, .error:
            await checkForUpdates()
        }
    }

    // Repo present but releaseless -> up to date. Repo missing -> surface it,
    // so a renamed/deleted repo can't silently look like "no updates".
    private func resolve404() async throws -> State {
        var request = URLRequest(url: Self.repoAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Purr/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200:
            return .upToDate
        case 404:
            return .error("Purr release feed is unreachable (repository missing). Please report this.")
        default:
            return .error("GitHub returned \(code). Try again later.")
        }
    }

    // Each phase publishes its own state transition, so chaining them still
    // renders progress and errors without a second button press.
    @MainActor
    func updatePurr() async {
        await downloadUpdate()
        guard case .readyToInstall = state else { return }
        installAndRelaunch()
    }

    @MainActor
    func downloadUpdate() async {
        guard case .available(let version, let dmgURL, let sha256URL, _) = state else { return }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purr-update-\(version).dmg")
        try? FileManager.default.removeItem(at: dst)
        state = .downloading(progress: 0)

        let dl = UpdateDownloader(destination: dst) { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.state {
                    self.state = .downloading(progress: progress)
                }
            }
        }
        downloader = dl
        do {
            let path = try await dl.download(from: dmgURL)
            // The helper's codesign gate is unpinned, so the sidecar is the
            // only thing tying this download to a release we published. Its
            // absence is fatal: refuse rather than install an unverified binary.
            guard let sha256URL else {
                try? FileManager.default.removeItem(at: path)
                log.error(
                    "Release has no .sha256 sidecar; refusing to install without an integrity gate."
                )
                state = .error(
                    "Update is missing its SHA-256 sidecar and cannot be verified. Install was cancelled."
                )
                downloader = nil
                return
            }
            do {
                try await verifyDMG(at: path, against: sha256URL)
            } catch {
                try? FileManager.default.removeItem(at: path)
                log.error(
                    "DMG SHA-256 verification failed: \(error.localizedDescription, privacy: .public)"
                )
                state = .error(
                    "Downloaded update failed integrity verification (SHA-256 mismatch). The file was rejected. Try again later."
                )
                downloader = nil
                return
            }
            state = .readyToInstall(dmgPath: path, version: version)
        } catch {
            log.error("Download failed: \(error.localizedDescription, privacy: .public)")
            state = .error("Download failed: \(error.localizedDescription)")
        }
        downloader = nil
    }

    // Sidecar format is `shasum -a 256` output: "<hex>  <filename>".
    private func verifyDMG(at dmgPath: URL, against sha256URL: URL) async throws {
        guard Self.isTrustedDownloadHost(sha256URL) else {
            throw UpdaterIntegrityError.untrustedSidecarHost
        }
        var request = URLRequest(url: sha256URL)
        request.setValue("Purr/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdaterIntegrityError.sidecarHTTPStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdaterIntegrityError.sidecarUnreadable
        }
        let expected =
            text
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw UpdaterIntegrityError.sidecarUnreadable
        }
        // Hash off the main actor so the UI runloop doesn't stall on I/O.
        let actual = try await Task.detached(priority: .userInitiated) {
            try Self.sha256OfFile(at: dmgPath).lowercased()
        }.value
        guard actual == expected else {
            log.error(
                "DMG SHA-256 mismatch: expected \(expected, privacy: .public), got \(actual, privacy: .public)."
            )
            throw UpdaterIntegrityError.hashMismatch
        }
        log.info("DMG SHA-256 verified.")
    }

    // 1 MiB chunks - keeps peak memory bounded.
    private static func sha256OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let bufferSize = 1 * 1024 * 1024
        while true {
            let chunk = try handle.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { raw in
                hasher.update(bufferPointer: raw)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Matches strictly on "<DMG>.sha256" so releases that ship multiple
    // hash files (per-architecture, signed/unsigned, etc.) don't collide.
    private static func findSHA256AssetURL(
        matching dmgName: String,
        in assets: [GitHubRelease.Asset]
    ) -> URL? {
        let target = "\(dmgName).sha256".lowercased()
        guard
            let asset = assets.first(where: { $0.name.lowercased() == target }),
            let url = URL(string: asset.browserDownloadURL),
            isTrustedDownloadHost(url)
        else { return nil }
        return url
    }

    enum UpdaterIntegrityError: LocalizedError {
        case untrustedSidecarHost
        case sidecarHTTPStatus(Int)
        case sidecarUnreadable
        case hashMismatch

        var errorDescription: String? {
            switch self {
            case .untrustedSidecarHost:
                return "Update SHA-256 sidecar is hosted on an untrusted domain."
            case .sidecarHTTPStatus(let code):
                return "Could not fetch update SHA-256 sidecar (HTTP \(code))."
            case .sidecarUnreadable:
                return "Update SHA-256 sidecar is malformed."
            case .hashMismatch:
                return
                    "Downloaded update failed integrity verification (SHA-256 mismatch)."
            }
        }
    }

    @MainActor
    func installAndRelaunch() {
        guard case .readyToInstall(let dmgPath, _) = state else { return }
        state = .installing
        do {
            let scriptPath = try writeInstallScript()
            let appPath = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptPath, String(pid), dmgPath.path, appPath]
            // No waitUntilExit: the helper has to outlive our termination.
            try task.run()

            // Let the helper reach its kill -0 loop before we terminate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            log.error("Install bootstrap failed: \(error.localizedDescription, privacy: .public)")
            state = .error("Could not launch installer: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func writeInstallScript() throws -> String {
        // Args: $1=parent_pid  $2=dmg_path  $3=app_bundle_path
        //
        // ditto preserves the symlinks, ACLs, xattrs, and resource forks that
        // cp -R drops, which would break the signature seal.
        // hdiutil -nobrowse keeps Finder from popping the volume; -noverify
        // skips the integrity-check delay.
        // codesign --verify --deep --strict mirrors Gatekeeper (Apple TN2206)
        // and runs BEFORE rm -rf'ing the live install so a bad DMG cannot brick
        // the app. It is unpinned: add -R "anchor apple generic and certificate
        // leaf[subject.OU] = 5JCFRMC367" to also require our own signature.
        // xattr -dr com.apple.quarantine prevents the "Are you sure you want to
        // open?" prompt LaunchServices attaches to URLSession downloads; only
        // stripped once the codesign gate passes.
        let script = """
            #!/bin/sh
            set -u
            PARENT_PID=$1
            DMG=$2
            APP=$3

            i=0
            while kill -0 "$PARENT_PID" 2>/dev/null; do
                i=$((i+1))
                if [ "$i" -gt 150 ]; then break; fi
                sleep 0.2
            done

            MOUNT=$(hdiutil attach -nobrowse -noautoopen -noverify "$DMG" \
                | tail -n1 \
                | awk -F'\\t' '{print $NF}' \
                | sed 's/^ *//;s/ *$//')
            if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
                exit 1
            fi

            SRC=$(find "$MOUNT" -maxdepth 1 -name "*.app" -type d | head -n1)
            if [ -z "$SRC" ]; then
                hdiutil detach -force -quiet "$MOUNT" >/dev/null 2>&1
                exit 1
            fi

            if ! /usr/bin/codesign --verify --deep --strict "$SRC" >/dev/null 2>&1; then
                hdiutil detach -force -quiet "$MOUNT" >/dev/null 2>&1
                exit 2
            fi

            rm -rf "$APP"
            /usr/bin/ditto "$SRC" "$APP"
            xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

            hdiutil detach -force -quiet "$MOUNT" >/dev/null 2>&1
            rm -f "$DMG"

            open "$APP"
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purr-install-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url.path
    }

    // Trust boundary for asset URLs taken from the release JSON:
    // browser_download_url is attacker-controllable if the API response is ever
    // poisoned, so an arbitrary URL must not reach the download → install flow.
    // Vouching for the initial host suffices - URLSession follows the
    // github.com → CDN redirect over HTTPS and ATS rejects plaintext.
    private static func isTrustedDownloadHost(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return host == "github.com"
    }

    // Numeric compare on dot-separated parts, returning -1 / 0 / 1. Missing
    // parts count as 0, so "1.2" == "1.2.0".
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(aParts.count, bParts.count)
        for i in 0..<n {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return -1 }
            if av > bv { return 1 }
        }
        return 0
    }
}

// MARK: - GitHub release schema (subset)

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let size: Int
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }
}

// MARK: - Download with progress

// Delegate rather than AsyncBytes: byte-at-a-time iteration is far too slow
// for a 16MB DMG, and the delegate is how URLSession reports chunked progress.
private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession!

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            var request = URLRequest(url: url)
            request.setValue("Purr-Updater", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // didFinishDownloading runs on the delegate queue and the temp file
        // disappears the moment this method returns - we MUST move it now.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        session.invalidateAndCancel()
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
