import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

// Captures the microphone as 16 kHz mono Float32 PCM (the shape WhisperKit/Parakeet
// consume) from the system default input.
//
// Uses a HAL Output Audio Unit (AUHAL), not AVAudioEngine: one AudioOutputUnitStart
// lights the macOS mic indicator once and steady (no blink), and AUHAL survives the
// device / sample-rate switches (built-in ↔ Bluetooth) that crash AVAudioEngine's
// installTap. The input callback runs on the Core Audio real-time thread (hence
// `@unchecked Sendable`; it reaches `self` via an unretained pointer and only touches
// lock-guarded state). See Apple TN2091.
final class AudioRecorder: @unchecked Sendable {
    private let targetFormat: AVAudioFormat

    private var unit: AudioUnit?
    private var deviceSampleRate: Double = 0  // device native rate; we resample to 16 kHz
    private var converter: AVAudioConverter?

    // renderBuffer's single AudioBuffer aliases inputBuffer's channel memory, so
    // AudioUnitRender writes straight into the buffer we hand the converter.
    private var inputBuffer: AVAudioPCMBuffer?
    private var renderBuffer: UnsafeMutableAudioBufferListPointer?
    private static let maxFrames = 16_384

    private var samples: [Float] = []
    private let lock = NSLock()
    private var isRecording = false  // guarded by `lock`

    // Host time (mach_absolute_time units) of the first sample captured after
    // start(); 0 until set. Meeting mode reads it after stop() to align the
    // system-audio tap - which omits silent gaps - to the mic's continuous
    // timeline. Only meaningful on a cold start (meeting mode never warm-keeps,
    // so samples[0] is the first rendered frame). Guarded by `lock`.
    private var firstSampleHostTime: UInt64 = 0

    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var chunkContinuation: AsyncStream<[Float]>.Continuation?
    private(set) var levels: AsyncStream<Float> = AsyncStream { _ in }
    // Fresh 16 kHz mono PCM chunks from the input callback. Streaming engines
    // pipe these into their session; batch engines use stop().
    private(set) var chunks: AsyncStream<[Float]> = AsyncStream { _ in }

    // Push-to-talk recorders (dictation, voice edit) opt in; see stop(). Meeting leaves false.
    var allowsWarmKeeping = false
    private var idleTeardownItem: DispatchWorkItem?
    private static let warmWindow: TimeInterval = 10  // mic stays warm this long after stop()
    private var openedDeviceID = AudioDeviceID(0)
    // Decided at open time from the device actually in use; see isWarmEligible.
    private var warmEligible = false

    // Live listeners that follow a default-input or sample-rate change and reconfigure
    // the AUHAL mid-recording.
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerDeviceID = AudioDeviceID(0)
    private var reconfigureItem: DispatchWorkItem?
    // A reconfigure can race a device that isn't render-ready yet (Bluetooth needs
    // ~1-3s to switch A2DP→HFP), so we wait/retry with backoff and verify the new
    // unit actually delivers frames before trusting it.
    private static let reconfigureMaxAttempts = 8
    private static let reconfigureRetryDelay: TimeInterval = 0.3
    private static let reconfigureLivenessDelay: TimeInterval = 0.4

    // Most-recent 16 kHz samples, kept filled whenever the unit runs and prepended on
    // start() so opening words aren't clipped. Guarded by `lock`.
    private var lookbackBuffer: [Float] = []
    private static let lookbackCapacity = 12_000  // 0.75 s at 16 kHz

    // Diagnostics.
    private var sessionStartedAt: Date?
    private var statsTimer: Timer?
    private var lastRenderError: OSStatus = noErr
    private var renderErrorCount = 0
    // Monotonic count of callbacks that produced audio; the reconfigure liveness
    // check watches it to tell a live unit from a started-but-NoConnection one.
    private var renderSuccessCount = 0

    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "audio")

    init() {
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else {
            fatalError("Could not construct 16kHz mono Float32 audio format")
        }
        targetFormat = target
    }

    func start() throws {
        idleTeardownItem?.cancel()
        idleTeardownItem = nil

        // A warm unit that's now pointed at a stale device (the user switched the
        // system default while we idled) must be reopened on the new one.
        if unit != nil, openedDeviceID != Self.currentDefaultInputDeviceID() {
            teardownAUHAL()
        }

        levels = AsyncStream { continuation in
            self.levelContinuation = continuation
        }
        chunks = AsyncStream { continuation in
            self.chunkContinuation = continuation
        }

        let warmReuse = unit != nil
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        firstSampleHostTime = 0
        // Prepend the lookback (audio from just before the keypress); empty unless a
        // warm unit was already running, so a cold start is unaffected.
        if warmReuse, !lookbackBuffer.isEmpty {
            samples.append(contentsOf: lookbackBuffer)
        }
        isRecording = true
        lock.unlock()

        if !warmReuse {
            do {
                try openAUHAL()
            } catch {
                // Roll back so the recorder is clean for the next attempt.
                lock.lock()
                isRecording = false
                samples.removeAll(keepingCapacity: false)
                lock.unlock()
                levelContinuation?.finish()
                levelContinuation = nil
                chunkContinuation?.finish()
                chunkContinuation = nil
                throw error
            }
        }

        sessionStartedAt = Date()
        lastRenderError = noErr
        renderErrorCount = 0
        startStatsTicker()
        log.info("Audio capture started (AUHAL, \(warmReuse ? "warm" : "cold", privacy: .public)).")
    }

    func stop() -> [Float] {
        statsTimer?.invalidate()
        statsTimer = nil

        lock.lock()
        isRecording = false
        let copy = samples
        samples.removeAll(keepingCapacity: false)
        // Drop the lookback so the next recording can't inherit this utterance's
        // tail; a warm unit refills it before the next press.
        lookbackBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        levelContinuation?.finish()
        levelContinuation = nil
        chunkContinuation?.finish()
        chunkContinuation = nil

        // Cancel any in-flight device-change reconfigure so it can't reopen the unit
        // behind the idle timer's back (which would leave the indicator lit forever).
        reconfigureItem?.cancel()
        reconfigureItem = nil

        // Keep the mic warm so the next press is instant, unless this recorder didn't
        // opt in or the device isn't warm-eligible (Bluetooth/aggregate).
        if allowsWarmKeeping, unit != nil, warmEligible {
            scheduleIdleTeardown()
        } else {
            teardownAUHAL()
        }

        let wallClock = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sessionStartedAt = nil
        let audioSeconds = Double(copy.count) / 16_000.0
        let coverage = wallClock > 0 ? (audioSeconds / wallClock) * 100 : 0
        log.info(
            "Audio capture stopped - \(copy.count, privacy: .public) samples (~\(String(format: "%.2f", audioSeconds), privacy: .public)s of audio over \(String(format: "%.2f", wallClock), privacy: .public)s wall clock = \(String(format: "%.0f", coverage), privacy: .public)% coverage, renderErrors=\(self.renderErrorCount, privacy: .public), lastRenderErr=\(self.lastRenderError, privacy: .public))"
        )

        // A near-silent capture and a healthy one produce the same sample count and
        // coverage above; only the level tells them apart. Peak + RMS in dBFS
        // disambiguate "no speech" reports (real speech peaks around -20…-3 dBFS;
        // a dead mic sits near the -120 floor).
        if !copy.isEmpty {
            var peak: Float = 0
            var rms: Float = 0
            vDSP_maxmgv(copy, 1, &peak, vDSP_Length(copy.count))
            vDSP_rmsqv(copy, 1, &rms, vDSP_Length(copy.count))
            let peakDB = peak > 0 ? 20 * log10(peak) : -120
            let rmsDB = rms > 0 ? 20 * log10(rms) : -120
            log.info(
                "Mic level - peak \(String(format: "%.3f", peak), privacy: .public) (\(String(format: "%.1f", peakDB), privacy: .public) dBFS), rms \(String(format: "%.4f", rms), privacy: .public) (\(String(format: "%.1f", rmsDB), privacy: .public) dBFS)"
            )
        }
        return copy
    }

    // See firstSampleHostTime. Valid after stop(); start() resets it, and it stays
    // 0 if nothing was captured.
    var captureStartHostTime: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return firstSampleHostTime
    }

    // Force-release the mic now, so the next press re-acquires a fresh device
    // (used after a wake-up failure). Safe to call when already stopped.
    func invalidate() {
        teardownAUHAL()
    }

    // ------------------------------------------------------------------
    // AUHAL setup / teardown
    // ------------------------------------------------------------------

    private static let halOutputDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    // Runs the two one-time setup costs of a process's first start(), so the
    // first press doesn't wait on them. Later starts reuse both:
    // - The first Audio Unit lookup fetches the component list from macOS's
    //   AudioComponentRegistrar, which exits when idle. Its cold start includes
    //   an x86-64 plug-in scan under Rosetta and can take ~2 s.
    // - Core Audio's in-process setup (audio server connection, device list,
    //   voice isolation) took 0.1-0.5 s. Reading the default input runs it
    //   without opening the mic. Skipped until mic access is granted, so it
    //   can never be what prompts.
    static func prepareForFirstStart() {
        var desc = halOutputDescription
        _ = AudioComponentFindNext(nil, &desc)
        if Permissions.isGranted(.microphone) {
            _ = currentDefaultInputDeviceID()
        }
    }

    private func openAUHAL() throws {
        var desc = Self.halOutputDescription
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioError.auhalSetup(selector: "AudioComponentFindNext", status: -1)
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let au else { throw AudioError.auhalSetup(selector: "instance", status: -1) }

        // `self.unit` is assigned only once the unit is fully started. If any step below
        // throws (e.g. CurrentDevice returns -10851 on an aggregate device mid-switch),
        // dispose the half-built unit so `unit != nil` never sees a zombie.
        var started = false
        defer {
            if !started {
                AudioOutputUnitStop(au)
                AudioUnitUninitialize(au)
                AudioComponentInstanceDispose(au)
                if let abl = renderBuffer {
                    free(abl.unsafeMutablePointer)
                    renderBuffer = nil
                }
                converter = nil
                inputBuffer = nil
                deviceSampleRate = 0
                openedDeviceID = 0
            }
        }

        // Enable input (element 1), disable output (element 0). Disabling output also
        // sidesteps the Bluetooth aggregate output-probe crash the old engine hit.
        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable,
                UInt32(MemoryLayout<UInt32>.size)), "EnableIO(input)")
        var disable: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable,
                UInt32(MemoryLayout<UInt32>.size)), "EnableIO(output)")

        // Point at the system default input device (settable only after EnableIO).
        var deviceID = AudioDeviceID(0)
        var idSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &idSize, &deviceID),
            "DefaultInputDevice")
        try check(
            AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)), "CurrentDevice")
        openedDeviceID = deviceID

        var deviceFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat,
                &fmtSize), "GetInputFormat")
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else {
            throw AudioError.invalidInputFormat(deviceFormat)
        }
        deviceSampleRate = deviceFormat.mSampleRate

        // Ask AUHAL to hand us Float32 mono at the device rate (it down-mixes channels
        // and floats for us); we do only the sample-rate conversion to 16 kHz ourselves.
        var client = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(
            AudioUnitSetProperty(
                au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "SetClientFormat")

        guard
            let clientAV = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.mSampleRate, channels: 1,
                interleaved: false),
            let conv = AVAudioConverter(from: clientAV, to: targetFormat),
            let inBuf = AVAudioPCMBuffer(pcmFormat: clientAV, frameCapacity: AVAudioFrameCount(Self.maxFrames))
        else {
            throw AudioError.cannotBuildConverter
        }
        converter = conv
        inputBuffer = inBuf

        // Alias the input PCM buffer's channel memory so AudioUnitRender writes
        // directly into it (no per-callback allocation).
        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        abl[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(Self.maxFrames * 4),
            mData: UnsafeMutableRawPointer(inBuf.floatChannelData![0]))
        renderBuffer = abl

        var cb = AURenderCallbackStruct(
            inputProc: audioRecorderInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(
            AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetInputCallback")

        try check(AudioUnitInitialize(au), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(au), "AudioOutputUnitStart")
        unit = au
        started = true
        warmEligible = Self.isWarmEligible(deviceID)
        installDeviceListeners()
        log.info(
            "AUHAL started - device \(deviceID, privacy: .public), input \(deviceFormat.mSampleRate, privacy: .public) Hz / \(deviceFormat.mChannelsPerFrame, privacy: .public) ch, warmEligible=\(self.warmEligible, privacy: .public)"
        )
    }

    private func teardownAUHAL() {
        idleTeardownItem?.cancel()
        idleTeardownItem = nil
        removeDeviceListeners()
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        unit = nil
        if let abl = renderBuffer {
            // mData is owned by `inputBuffer`; free only the list struct.
            free(abl.unsafeMutablePointer)
            renderBuffer = nil
        }
        converter = nil
        inputBuffer = nil
        deviceSampleRate = 0
        openedDeviceID = 0
        warmEligible = false
        lock.lock()
        lookbackBuffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    // Release the warm unit (and the indicator) if no new recording starts within
    // the window.
    private func scheduleIdleTeardown() {
        idleTeardownItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let recording = self.isRecording
            self.lock.unlock()
            guard !recording else { return }
            self.log.info("Mic warm window elapsed - releasing the microphone.")
            self.teardownAUHAL()
        }
        idleTeardownItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmWindow, execute: item)
    }

    private static func currentDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double {
        guard deviceID != 0 else { return 0 }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return rate
    }

    // Warm-keeping is limited to stable wired inputs. Bluetooth is excluded to avoid
    // pinning HFP/SCO mode, and so is everything that isn't a known wired transport -
    // a Bluetooth mic is frequently surfaced as an aggregate/auto-aggregate/virtual
    // device whose transport type is NOT kAudioDeviceTransportTypeBluetooth, so an
    // allowlist of wired transports is the only reliable test.
    private static func isWarmEligible(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return false
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire:
            return true
        default:
            return false
        }
    }

    // ------------------------------------------------------------------
    // Live device / sample-rate change handling
    // ------------------------------------------------------------------

    private func installDeviceListeners() {
        let queue = DispatchQueue.main
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange()
        }
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, queue, defaultBlock)
        defaultDeviceListener = defaultBlock

        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange()
        }
        _ = AudioObjectAddPropertyListenerBlock(openedDeviceID, &rateAddr, queue, rateBlock)
        sampleRateListener = rateBlock
        sampleRateListenerDeviceID = openedDeviceID
    }

    private func removeDeviceListeners() {
        reconfigureItem?.cancel()
        reconfigureItem = nil
        if let block = defaultDeviceListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
            defaultDeviceListener = nil
        }
        if let block = sampleRateListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(
                sampleRateListenerDeviceID, &addr, DispatchQueue.main, block)
            sampleRateListener = nil
            sampleRateListenerDeviceID = 0
        }
    }

    // Notifications can arrive in bursts; coalesce, then reconfigure after the
    // listener callback returns (avoids re-entrant teardown of the firing listener).
    private func handleDeviceChange() {
        reconfigureItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconfigureIfNeeded() }
        reconfigureItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func reconfigureIfNeeded() {
        guard unit != nil else { return }
        lock.lock()
        let recording = isRecording
        lock.unlock()
        // Only reconfigure to keep an active recording alive. A device change while merely
        // warm needs no rebuild - start() reopens on a changed device - and rebuilding here
        // would cancel the idle timer and strand the unit (orange indicator stuck on).
        guard recording else { return }
        let newDefault = Self.currentDefaultInputDeviceID()
        let boundRate = Self.nominalSampleRate(of: openedDeviceID)
        let changed =
            newDefault != openedDeviceID || (boundRate > 0 && abs(boundRate - deviceSampleRate) > 1)
        guard changed else { return }
        log.info(
            "Audio device/format change - reconfiguring AUHAL (device \(self.openedDeviceID, privacy: .public)→\(newDefault, privacy: .public), boundRate=\(boundRate, privacy: .public), expected=\(self.deviceSampleRate, privacy: .public))"
        )
        reconfigure(attempt: 1)
    }

    // Rebuild the AUHAL on the current default device, preserving accumulated samples
    // and isRecording. A brief indicator blink here is expected on a genuine switch
    // (Zoom does the same). Two failure modes are handled with backoff retries:
    //   1. The target device isn't render-ready yet (Bluetooth mid A2DP→HFP reports a
    //      zero nominal rate) - keep the old unit running and wait.
    //   2. The new unit "starts" but its input never connects, so AudioUnitRender
    //      returns kAudioUnitErr_NoConnection on every callback - caught by the
    //      liveness check below, which rebuilds.
    private func reconfigure(attempt: Int) {
        let target = Self.currentDefaultInputDeviceID()
        if Self.nominalSampleRate(of: target) == 0, attempt < Self.reconfigureMaxAttempts {
            log.info(
                "Reconfigure: device \(target, privacy: .public) not ready (attempt \(attempt, privacy: .public)); waiting."
            )
            scheduleReconfigure(attempt: attempt + 1, delay: Self.reconfigureRetryDelay)
            return
        }

        teardownAUHAL()
        do {
            try openAUHAL()
        } catch {
            log.error(
                "AUHAL reconfigure open failed (attempt \(attempt, privacy: .public)/\(Self.reconfigureMaxAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            if attempt < Self.reconfigureMaxAttempts {
                scheduleReconfigure(attempt: attempt + 1, delay: Self.reconfigureRetryDelay)
            }
            return
        }

        lock.lock()
        let baseline = renderSuccessCount
        lock.unlock()
        let item = DispatchWorkItem { [weak self] in
            self?.verifyReconfigureLiveness(baseline: baseline, attempt: attempt)
        }
        reconfigureItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconfigureLivenessDelay, execute: item)
    }

    private func verifyReconfigureLiveness(baseline: Int, attempt: Int) {
        guard unit != nil else { return }
        lock.lock()
        let delivered = renderSuccessCount - baseline
        lock.unlock()
        guard delivered == 0 else { return }  // audio is flowing; the unit is good.
        if attempt < Self.reconfigureMaxAttempts {
            log.error(
                "AUHAL reconfigure produced a dead unit (no frames in \(Self.reconfigureLivenessDelay, privacy: .public)s, attempt \(attempt, privacy: .public)); rebuilding."
            )
            reconfigure(attempt: attempt + 1)
        } else {
            log.error(
                "AUHAL reconfigure exhausted \(Self.reconfigureMaxAttempts, privacy: .public) attempts; mic may stay silent until the next device change."
            )
        }
    }

    private func scheduleReconfigure(attempt: Int, delay: TimeInterval) {
        reconfigureItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconfigure(attempt: attempt) }
        reconfigureItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func check(_ status: OSStatus, _ selector: String) throws {
        guard status == noErr else {
            log.error("AUHAL \(selector, privacy: .public) failed: \(status, privacy: .public)")
            throw AudioError.auhalSetup(selector: selector, status: status)
        }
    }

    // ------------------------------------------------------------------
    // Diagnostics
    // ------------------------------------------------------------------

    private func startStatsTicker() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.logStatsTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func logStatsTick() {
        guard let started = sessionStartedAt else { return }
        lock.lock()
        let count = samples.count
        lock.unlock()
        let wallClock = Date().timeIntervalSince(started)
        let audioSeconds = Double(count) / 16_000.0
        log.debug(
            "Audio tick: \(count, privacy: .public) samples (~\(String(format: "%.2f", audioSeconds), privacy: .public)s) in \(String(format: "%.2f", wallClock), privacy: .public)s wall, lastRenderErr=\(self.lastRenderError, privacy: .public), renderErrors=\(self.renderErrorCount, privacy: .public)"
        )
    }

    // ------------------------------------------------------------------
    // Real-time input callback
    // ------------------------------------------------------------------

    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        ts: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let au = unit, let abl = renderBuffer, let inBuf = inputBuffer,
            let conv = converter, deviceSampleRate > 0,
            frames > 0, Int(frames) <= Self.maxFrames
        else { return noErr }

        abl[0].mDataByteSize = frames * 4
        let err = AudioUnitRender(au, flags, ts, bus, frames, abl.unsafeMutablePointer)
        if err != noErr {
            // Usually a transient kAudioUnitErr_CannotDoInCurrentContext (-10863) during
            // a device/format switch; skip this buffer and recover on the next callback.
            lastRenderError = err
            renderErrorCount &+= 1
            return err
        }
        lastRenderError = noErr
        inBuf.frameLength = frames

        let ratio = 16_000.0 / deviceSampleRate
        let outCapacity = AVAudioFrameCount(Double(frames) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
        else { return noErr }
        var convError: NSError?
        var provided = false
        conv.convert(to: outBuf, error: &convError) { _, statusPtr in
            if provided {
                statusPtr.pointee = .noDataNow
                return nil
            }
            provided = true
            statusPtr.pointee = .haveData
            return inBuf
        }
        guard convError == nil, let channel = outBuf.floatChannelData?[0], outBuf.frameLength > 0
        else { return noErr }

        let count = Int(outBuf.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        lock.lock()
        renderSuccessCount &+= 1
        // Keep the lookback topped up whenever the unit runs (recording or warm).
        lookbackBuffer.append(contentsOf: chunk)
        if lookbackBuffer.count > Self.lookbackCapacity {
            lookbackBuffer.removeFirst(lookbackBuffer.count - Self.lookbackCapacity)
        }
        let recording = isRecording
        if recording, firstSampleHostTime == 0 {
            // mHostTime is on the system-wide mach clock, shared with the
            // system-audio tap's IOProc, so the two captures can be aligned.
            let stamp = ts.pointee
            firstSampleHostTime =
                stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0
                ? stamp.mHostTime : mach_absolute_time()
        }
        if recording {
            samples.reserveCapacity(samples.count + count)
            samples.append(contentsOf: chunk)
        }
        lock.unlock()

        guard recording else { return noErr }

        chunkContinuation?.yield(chunk)

        // RMS (not peak) of the block drives the HUD waveform: it tracks perceived
        // loudness and is steadier than a transient-driven peak. Visualization only -
        // the captured `samples` are untouched.
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        levelContinuation?.yield(rms)
        return noErr
    }

    // ------------------------------------------------------------------
    // Bluetooth detection (used to tailor warm-keeping and the wake-up hint)
    // ------------------------------------------------------------------

    static func defaultInputIsBluetooth() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0
        else { return false }

        var transport = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            AudioObjectGetPropertyData(
                deviceID, &transportAddr, 0, nil, &transportSize, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

private func audioRecorderInputCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ ts: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let recorder = Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue()
    return recorder.render(flags: flags, ts: ts, bus: bus, frames: frames)
}

enum AudioError: LocalizedError {
    case cannotBuildConverter
    case invalidInputFormat(AudioStreamBasicDescription)
    case auhalSetup(selector: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .cannotBuildConverter:
            return "Could not build the audio converter for this microphone."
        case .invalidInputFormat(let fmt):
            return
                "Microphone returned an invalid format (\(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch). Check that an input device is connected and selected in System Settings → Sound."
        case .auhalSetup(let selector, let status):
            return "Could not start the microphone (\(selector) failed: \(status))."
        }
    }
}
