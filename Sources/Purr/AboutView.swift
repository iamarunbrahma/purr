import AppKit
import SwiftUI

// About panel. Check for Updates hands off to Sparkle's own windows.
struct AboutView: View {
    @ObservedObject var updater: Updater

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

            Button("Check for Updates…") { updater.checkForUpdates() }
                .buttonStyle(.borderedProminent)
                .disabled(!updater.canCheckForUpdates)

            (Text("Built by ")
                + Text("[Arun Brahma](https://arunbrahma.com)")
                + Text("."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.secondary)
        }
        .padding(24)
        .frame(width: 380, height: 300)
    }
}
