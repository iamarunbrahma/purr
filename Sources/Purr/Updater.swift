import AppKit
import Combine
import Sparkle

// Updates through Sparkle, from the appcast.xml each GitHub release carries.
// Sparkle shows the new version's notes, checks the download's EdDSA
// signature against SUPublicEDKey and its Developer ID against this app's,
// then replaces Purr and relaunches it.
//
// On the second launch Sparkle asks whether to check automatically, then
// checks once a day. For a menu bar app it would put a daily pop-up behind
// other windows, except within a few seconds of launch, so an update found
// later marks the menu bar icon and menu instead (Sparkle's gentle
// reminders) until the user opens it.
//
// A relaunch waits while Purr is recording or transcribing.
@MainActor
final class Updater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var checksAutomatically = false
    // An update a scheduled check found that the user hasn't looked at yet.
    @Published private(set) var reminder: String?

    private let coordinator: AppCoordinator
    private var controller: SPUStandardUpdaterController!
    private var relaunchWait: AnyCancellable?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksAutomatically)
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // Also brings back an update window that's open or waiting as a reminder.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard !coordinator.safeToQuit else { return false }
        relaunchWait = coordinator.$safeToQuit.first(where: { $0 }).sink { [weak self] _ in
            self?.relaunchWait = nil
            installHandler()
        }
        return true
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    // Sparkle shows it itself only when it would come to the front.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { reminder = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { reminder = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { reminder = nil }
    }
}
