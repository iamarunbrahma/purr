import AppKit
import SwiftUI

// About panel + in-app updater UI, driven entirely by the Updater state
// machine so no label or button needs a second switch elsewhere.
struct AboutView: View {
    @ObservedObject var updater: Updater
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("Purr")
                    .font(.title2.weight(.semibold))
                Text("Version \(updater.currentVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("MIT licensed open source.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            updateSection
                .frame(maxWidth: .infinity)

            (Text("Built by ")
                + Text("[Arun Brahma](https://arunbrahma.com)")
                + Text("."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.secondary)
        }
        .padding(24)
        .frame(width: 380, height: 320)
        .onAppear {
            // Quiet check on first open; the button re-triggers it on demand.
            if case .idle = updater.state {
                Task { await updater.checkForUpdates() }
            }
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        switch updater.state {
        case .idle:
            Button("Check for Updates") {
                Task { await updater.checkForUpdates() }
            }
            .buttonStyle(.borderedProminent)

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)

        case .available(let version, _, _, let size):
            VStack(spacing: 8) {
                Text("Version \(version) available")
                    .font(.callout.weight(.medium))
                Text(formatSize(size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Update Purr") {
                    Task { await updater.updatePurr() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.safeToQuit)
                if coordinator.safeToQuit {
                    Text("Purr will quit, replace itself, then relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Finish your current recording before updating.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }

        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(maxWidth: 240)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .readyToInstall:
            // Transient - updatePurr() flips straight to .installing, so this
            // shows only if the chained install fails to fire.
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing installer…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing… the app will relaunch shortly.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await updater.checkForUpdates() }
                }
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
