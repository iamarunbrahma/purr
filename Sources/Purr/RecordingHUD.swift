import AppKit
import SwiftUI

// Fixed width reserved for the live dictation preview so the pill doesn't
// resize on every streamed word; the text head-truncates to fit.
private let hudPreviewWidth: CGFloat = 260

// Floating pill at the bottom centre of the active screen.
// Click-through and non-activating.
@MainActor
final class RecordingHUD {
    enum Mode: Equatable {
        case warmingUp
        case recording
        case loadingModel
        case downloadingModel
        case transcribing
        case meeting(elapsed: TimeInterval)
        case voiceEdit
        case summarizing
        case copied
        case error
    }

    private var window: NSPanel?
    private let model = HUDModel()

    // Pending auto-hide for the current transient message / copied-flash. Held so
    // a newer HUD state can cancel it; a stale timer would otherwise hide content
    // that has since replaced what it was scheduled for.
    private var autoHideTask: Task<Void, Never>?

    var isShowingMessage: Bool { model.message != nil }

    // Single gate the three hotkey flows run their press through. A press is a
    // no-op while a transient message is on screen (it would wipe it before
    // it's read) or while the caller has non-interruptible work in flight.
    func shouldIgnorePress(whileBusy busy: Bool) -> Bool {
        isShowingMessage || busy
    }

    func show(_ mode: Mode) {
        autoHideTask?.cancel()
        autoHideTask = nil
        model.message = nil
        model.mode = mode
        resetMeter()
        if window == nil { build() }
        resizeToFitContent()
        window?.orderFrontRegardless()
        position()
        // Already sized synchronously above; re-measure on the next runloop tick
        // as a safety net once SwiftUI has settled the new layout.
        scheduleSettledResize()
    }

    // Mid-session label update. Avoids orderFrontRegardless on every tick (which
    // triggers SwiftUI's "Publishing changes from within view updates is not
    // allowed" warning) but still resizes+repositions so the elapsed-time label
    // can grow "Meeting · 0:01" → "Meeting · 1:23:45" without clipping.
    func update(_ mode: Mode) {
        model.mode = mode
        resizeToFitContent()
        position()
        scheduleSettledResize()
    }

    // `icon` is the mode whose icon leads the message: the error triangle
    // unless a step's own icon fits better.
    func showMessage(_ text: String, icon: Mode = .error, autoHideAfter seconds: TimeInterval = 1.5) {
        autoHideTask?.cancel()
        model.mode = icon
        model.message = text
        if window == nil { build() }
        resizeToFitContent()
        window?.orderFrontRegardless()
        position()
        // Safety net; see show(_:).
        scheduleSettledResize()
        autoHideTask = Task { @MainActor [weak self] in
            // Cancelled - a newer state superseded the message; bail without hiding.
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.hide()
        }
    }

    // Live-waveform meter state (see meterLevel(forRMS:)).
    private var meterDisplay: Float = 0  // smoothed 0...1 value fed to the bars

    // Crest-factor gate. Speech amplitude-modulates at the syllable rate, so each
    // block's RMS rides well above a slow running average; steady noise (incl.
    // AGC-boosted hiss) sits on that average. The level-above-average is a crest
    // factor of the loudness envelope - gain-invariant, so the OS / Bluetooth AGC
    // can't lift quiet noise past the gate. A short attack rejects single-block
    // clicks; a hangover bridges inter-word pauses.
    private var avgEnv: Float = 0  // slow running-average RMS (the gate's baseline)
    private var meterReady = false  // false until the first block seeds avgEnv
    private var gateOpen = false
    private var openRun = 0  // consecutive speech-like blocks seen while closed
    private var hangover = 0  // blocks the gate stays open after speech drops out

    private static let avgCoef: Float = 0.01  // running-average follower (~1.5 s)
    private static let gateOpenDb: Float = 6  // crest above average that opens the gate
    private static let gateCloseDb: Float = 3  // hysteresis: lower bar to hold it open
    private static let gateFloorDbFS: Float = -55  // absolute floor; never open below this
    private static let gateAttackBlocks = 3  // sustained speech-like blocks to open (~45 ms)
    private static let gateHangoverBlocks = 16  // blocks held open through a pause (~250 ms)
    private static let winFloorDbFS: Float = -45  // RMS dBFS mapped to empty bars
    private static let winTopDbFS: Float = -10  // RMS dBFS mapped to full bars
    private static let meterAttack: Float = 0.4  // bar rise smoothing (fast)
    private static let meterDecay: Float = 0.12  // bar fall smoothing (slow)

    func updateLevel(_ rms: Float) {
        model.level = meterLevel(forRMS: rms)
    }

    // Reserve (or release) the pill's preview area. Called once when a smart-typing
    // streaming session starts/ends, so the pill never resizes per word.
    func setPreviewActive(_ active: Bool) {
        model.showsPreview = active
        if !active { model.previewText = "" }
    }

    // No resize needed - setPreviewActive already sized the pill.
    func updatePreview(_ text: String) {
        model.previewText = text
    }

    // Turns a block's RMS amplitude (0...1) into a perceptual 0...1 bar level: the
    // crest gate holds the bars flat unless the signal is modulated like speech, and
    // when open RMS maps through a fixed dBFS window so louder speech reads taller.
    // Thresholds are starting points - tune against the dBFS AudioRecorder logs.
    private func meterLevel(forRMS rms: Float) -> Float {
        if !meterReady {
            avgEnv = rms
            meterReady = true
        }
        avgEnv += (rms - avgEnv) * Self.avgCoef

        let rmsDb: Float = 20 * log10(max(rms, 1e-6))
        let crestDb = rmsDb - 20 * log10(max(avgEnv, 1e-6))
        let loudEnough = rmsDb > Self.gateFloorDbFS

        if gateOpen {
            if loudEnough, crestDb > Self.gateCloseDb {
                hangover = Self.gateHangoverBlocks
            } else if hangover > 0 {
                hangover -= 1
            } else {
                gateOpen = false
            }
        } else {
            openRun = (loudEnough && crestDb > Self.gateOpenDb) ? openRun + 1 : 0
            if openRun >= Self.gateAttackBlocks {
                gateOpen = true
                hangover = Self.gateHangoverBlocks
                openRun = 0
            }
        }

        let span = Self.winTopDbFS - Self.winFloorDbFS
        let target: Float = gateOpen ? min(1, max(0, (rmsDb - Self.winFloorDbFS) / span)) : 0
        let coef = target > meterDisplay ? Self.meterAttack : Self.meterDecay
        meterDisplay += (target - meterDisplay) * coef
        return meterDisplay
    }

    private func resetMeter() {
        meterDisplay = 0
        avgEnv = 0
        meterReady = false
        gateOpen = false
        openRun = 0
        hangover = 0
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        model.message = nil
        model.showsPreview = false
        model.previewText = ""
        window?.orderOut(nil)
    }

    func flashCopied(autoHideAfter seconds: TimeInterval = 1.2) {
        show(.copied)  // cancels any pending auto-hide and clears the message
        autoHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.hide()
        }
    }

    // ------------------------------------------------------------------
    // Window construction
    // ------------------------------------------------------------------

    // Placeholder for creation only; resizeToFitContent() overrides it on the
    // very first show(), so this size never reaches the screen.
    private static let initialSize = NSSize(width: 200, height: 48)
    private static let panelHeight: CGFloat = 48

    private func build() {
        let host = NSHostingView(rootView: HUDView(model: model))
        // Advertise the SwiftUI view's intrinsic size to AppKit; the panel
        // itself is sized explicitly by measurePillSize().
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(origin: .zero, size: Self.initialSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Sits above every other app's fullscreen overlay. `.statusBar` (25) is
        // below what macOS composites on top of another app's fullscreen Space, so
        // the HUD vanished when Chrome / any non-native app went fullscreen;
        // CGShieldingWindowLevel is what the lock screen uses. `.transient` +
        // `.canJoinAllSpaces` + `.fullScreenAuxiliary` is the combination that lets
        // an LSUIElement app's panel cross into those Spaces (we have no anchor
        // window of our own).
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient,
        ]
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.contentView = host
        self.window = panel
    }

    private func resizeToFitContent() {
        guard let panel = window else { return }
        let target = measurePillSize()
        if panel.frame.size != target {
            panel.setContentSize(target)
        }
    }

    // Compute the pill's size from the current label rather than reading
    // NSHostingView.intrinsicContentSize, which settles a runloop tick *after* the
    // @Published mode change - a synchronous resize saw the previous (narrower)
    // label and clipped a wider one like "Summarizing meeting". Measuring here is
    // synchronous, so the pill is the right width on its first rendered frame.
    //
    // The font and constants mirror HUDView: leading icon (38) + spacing (10) +
    // text + trailing waveform (38), inside .padding(.horizontal, 18 / .vertical,
    // 11). Over-sizing is invisible (transparent panel, SwiftUI centres the pill),
    // so `margin` absorbs sub-pixel rounding and keeps us clear of clipping.
    private func measurePillSize() -> NSSize {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let iconWidth: CGFloat = 38
        let spacing: CGFloat = 10
        let hPadding: CGFloat = 18 * 2
        let vPadding: CGFloat = 11 * 2
        let margin: CGFloat = 6
        let label = model.displayLabel as NSString

        if model.isMessage {
            // Error messages wrap inside a 360 pt cap and grow vertically.
            let maxTextWidth: CGFloat = 360
            let rect = label.boundingRect(
                with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font])
            let width = hPadding + iconWidth + spacing + ceil(rect.width) + margin
            let height = max(Self.panelHeight, ceil(rect.height) + vPadding + 4)
            return NSSize(width: ceil(width), height: height)
        }

        // Fixed preview width (the text head-truncates to fit) so streamed words
        // never resize the pill.
        if model.showsPreview {
            var width = hPadding + iconWidth + spacing + hudPreviewWidth
            if model.showsWaveform { width += spacing + 38 }
            return NSSize(width: ceil(width) + margin, height: Self.panelHeight)
        }

        // Single-line status labels; the Text carries a 100 pt min width.
        let textWidth = max(100, ceil(label.size(withAttributes: [.font: font]).width))
        var width = hPadding + iconWidth + spacing + textWidth
        if model.showsWaveform { width += spacing + 38 }
        return NSSize(width: ceil(width) + margin, height: Self.panelHeight)
    }

    private func scheduleSettledResize() {
        DispatchQueue.main.async { [weak self] in
            self?.resizeToFitContent()
            self?.position()
        }
    }

    private func position() {
        guard let window, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var mode: RecordingHUD.Mode = .recording
    @Published var level: Float = 0
    @Published var message: String? = nil

    // The in-progress sentence shown while the user speaks (smart-typing only).
    // `showsPreview` reserves the pill's width; `previewText` is the text.
    @Published var previewText: String = ""
    @Published var showsPreview: Bool = false

    // Single source of truth for what the pill renders, shared by HUDView (drawing)
    // and measurePillSize() (sizing) so the two can't disagree about width.
    var isMessage: Bool { message != nil }

    var displayLabel: String {
        if let message { return message }
        switch mode {
        case .warmingUp: return "Warming up…"
        case .recording: return "Listening"
        case .loadingModel: return "Loading model"
        case .downloadingModel: return "Downloading model"
        case .transcribing: return "Transcribing"
        case .voiceEdit: return "Voice Edit"
        case .meeting(let t): return "Meeting · \(Self.formatElapsed(t))"
        case .summarizing: return "Summarizing meeting"
        case .copied: return "Copied"
        case .error: return "Try again"
        }
    }

    // Only the live-mic modes get the trailing waveform; an error message
    // (which reuses .recording-ish layout) stays text-only.
    var showsWaveform: Bool {
        guard message == nil else { return false }
        switch mode {
        case .recording, .voiceEdit, .meeting: return true
        default: return false
        }
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch model.mode {
                case .recording:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 24)
                case .voiceEdit:
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 24)
                case .meeting:
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .frame(width: 38, height: 24)
                case .loadingModel:
                    Image(systemName: "cpu.fill")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 24)
                case .downloadingModel:
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 24)
                case .warmingUp, .transcribing, .summarizing:
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .frame(width: 38, height: 24)
                case .copied:
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 24)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 38, height: 24)
                }
            }

            if model.showsPreview {
                Text(model.previewText.isEmpty ? model.displayLabel : model.previewText)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .opacity(model.previewText.isEmpty ? 0.8 : 1)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: hudPreviewWidth, alignment: .leading)
            } else {
                Text(model.displayLabel)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .modifier(HUDLabelSizing(isMessage: model.message != nil))
            }

            // Live waveform trails the label while the mic is open, so the pill
            // still shows it's actively listening.
            if model.showsWaveform {
                Waveform(level: model.level)
                    .frame(width: 38, height: 24)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.78))
        )
    }

}

// Five-bar waveform that pulses with the perceptual level (a dB-windowed,
// crest-gated RMS from RecordingHUD's meter). Driven by `level` rather than a
// CADisplayLink - SwiftUI re-renders whenever `model.level` changes.
private struct Waveform: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: barHeight(at: i))
                    .animation(.easeInOut(duration: 0.12), value: level)
            }
        }
    }

    private func barHeight(at i: Int) -> CGFloat {
        // Bias inner bars taller so the shape looks like a waveform rather than a row of identical sticks.
        let bias: [CGFloat] = [0.45, 0.7, 1.0, 0.7, 0.45]
        let base: CGFloat = 6
        // A small floor keeps a faint idle pulse.
        let amplitude = CGFloat(min(1.0, max(0.04, Double(level)))) * 18
        return base + amplitude * bias[i]
    }
}

// Status labels (Listening, Meeting · 1:23:45, …) stay on one line at their
// natural width. Error messages can be a full sentence, so they wrap inside a
// capped width and grow the pill vertically instead of running off-screen -
// the panel height tracks this via resizeToFitContent().
private struct HUDLabelSizing: ViewModifier {
    let isMessage: Bool

    func body(content: Content) -> some View {
        if isMessage {
            content
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
        } else {
            content
                .lineLimit(1)
                // 100 pt minimum stops the second-tick jitter; natural width
                // otherwise so "Summarizing meeting" doesn't clip.
                .frame(minWidth: 100, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
