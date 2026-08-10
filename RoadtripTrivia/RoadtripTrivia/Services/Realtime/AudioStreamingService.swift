import Foundation
import AVFoundation
import Combine

/// Bidirectional audio streaming for the Gemini Live API.
/// Captures microphone audio, resamples to 16kHz PCM16, and streams via WebSocket.
/// Receives 24kHz PCM16 audio from the API and plays it back in real-time.
///
/// Token-saving mic gating: the mic is muted while the AI is speaking,
/// during tool processing, and shortly after user speech ends. It unmutes
/// only when the user is expected to speak.
class AudioStreamingService: ObservableObject {

    @Published private(set) var isStreaming = false
    @Published private(set) var isPlayingResponse = false

    // #region agent log
    private static let _logPath: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("mic_gating.log").path
    }()
    private var _micOnTime: TimeInterval = 0
    private var _micOffTime: TimeInterval = 0
    private var _lastMuteToggle: Date = Date()
    private var _audioSentCount: Int = 0
    private var _audioSuppressedCount: Int = 0
    private func _logMic(_ msg: String, _ data: [String: Any] = [:]) {
        let payload: [String: Any] = [
            "sessionId": "30dda1",
            "location": "AudioStreamingService.swift",
            "message": msg,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "hypothesisId": "MIC_GATE",
            "data": data
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let path = Self._logPath
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write((jsonStr + "\n").data(using: .utf8)!)
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: (jsonStr + "\n").data(using: .utf8))
            }
        }
    }
    // #endregion

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioManager = AudioSessionManager.shared
    private weak var sessionManager: RealtimeSessionManager?
    private var cancellables = Set<AnyCancellable>()

    /// Target format for Gemini Live API input: PCM16, 16kHz, mono.
    private let targetSampleRate: Double = 16000
    private let targetChannels: UInt32 = 1

    /// Playback sample rate — Gemini outputs 24kHz PCM16.
    private let playbackSampleRate: Double = 24000

    /// Audio converter for resampling mic input to 16kHz.
    private var audioConverter: AVAudioConverter?

    /// Target audio format (16kHz PCM16 mono) for mic capture → Gemini.
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate,
                      channels: AVAudioChannelCount(targetChannels), interleaved: true)!
    }()

    /// Playback format — 24kHz Float32 mono (AVAudioPlayerNode needs float).
    private lazy var playbackFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: playbackSampleRate,
                      channels: AVAudioChannelCount(targetChannels), interleaved: false)!
    }()

    // MARK: - Mic Gating (echo prevention + token savings)

    /// When true, mic audio is not sent to the API.
    private var isMicMuted = false

    /// Track how many audio buffers are scheduled but not yet played.
    /// Used to know when playback is truly finished.
    private var scheduledBufferCount = 0
    private let bufferLock = NSLock()

    /// Timer to unmute mic after playback finishes.
    private var unmuteMicTimer: DispatchWorkItem?

    /// Timer to mute mic after user stops speaking (saves tokens in the gap
    /// between user speech ending and AI starting to respond).
    private var postSpeechMuteTimer: DispatchWorkItem?

    /// Grace period after AI finishes speaking before unmuting mic.
    /// 150ms is sufficient for echo tail-off in a car (speaker/mic separation).
    private let postPlaybackMuteDelay: TimeInterval = 0.15

    /// Delay after user stops speaking before muting mic.
    /// Gameplay quality matters more than the small token savings here: a
    /// 300ms window can split a natural answer like "B ... the Amazon" into
    /// two utterances and suppress the tail, which looks like the host ignored
    /// the answer. Keep the mic open long enough for normal hesitation.
    private let postSpeechMuteDelay: TimeInterval = 1.0

    /// Set by the coordinator when it submits a tool result and the AI needs
    /// processing time. Cleared when the AI's next audio response arrives.
    private var suspendedForProcessing = false

    /// Hard mute for the farewell chain. While true, the mic stays muted
    /// and `scheduleUnmuteMic` is a no-op, preventing user barge-ins from
    /// interrupting farewell audio. Set via `setFarewellMute(_:)`.
    private(set) var farewellMuted = false

    /// Timestamp of the most recent mic chunk whose energy crossed the
    /// voice threshold. Used to corroborate server-side barge-in events:
    /// if WE never heard voice, the server VAD tripped on noise/echo and
    /// playback must not be interrupted (BargeInPolicy).
    private var lastLocalVoiceAt: Date?

    /// RMS threshold (Int16 scale) above which a converted mic chunk counts
    /// as voice-bearing. ~500 ≈ -36 dBFS — above steady road noise, below
    /// normal speech at arm's length.
    private let voiceRMSThreshold: Double = 500

    /// Rolling tail of mic audio captured while gated. Flushed ahead of live
    /// audio on unmute so an early answer's first words aren't lost.
    private var preRoll = PreRollBuffer(maxChunks: 6)

    /// Failsafe: the mic may never stay muted longer than this without the
    /// host actually speaking. Kills the "stuck mute → frozen game" class.
    private let maxMuteWithoutAudioSeconds: TimeInterval = 6.0
    private var muteFailsafeTimer: DispatchWorkItem?

    // MARK: - Setup

    func configure(sessionManager: RealtimeSessionManager) {
        self.sessionManager = sessionManager

        // Cancel any previous subscriptions to prevent duplicate audio processing
        cancellables.removeAll()

        // Listen for audio events from the Realtime API
        sessionManager.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleRealtimeEvent(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - Start/Stop Streaming

    func startStreaming() throws {
        guard !isStreaming else { return }

        audioManager.activateForSpeech()

        // Attach player node for output
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)

        // Get mic input format
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[Audio] Mic format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // Create audio converter: mic format → 16kHz PCM16
        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        guard audioConverter != nil else {
            throw AudioStreamError.converterCreationFailed
        }

        // Install tap on microphone input
        let bufferSize: AVAudioFrameCount = 1600 // 100ms at 16kHz
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer)
        }

        try audioEngine.start()
        playerNode.play()
        isStreaming = true
        isMicMuted = false
        scheduledBufferCount = 0
        _lastMuteToggle = Date()
        _micOnTime = 0; _micOffTime = 0; _audioSentCount = 0; _audioSuppressedCount = 0
        // #region agent log
        _logMic("STREAMING_STARTED", [:])
        // #endregion
        print("[Audio] Streaming started")
    }

    func stopStreaming() {
        guard isStreaming else { return }

        // #region agent log
        let finalOnDuration = isMicMuted ? 0.0 : Date().timeIntervalSince(_lastMuteToggle)
        let finalOffDuration = isMicMuted ? Date().timeIntervalSince(_lastMuteToggle) : 0.0
        let totalOn = _micOnTime + finalOnDuration
        let totalOff = _micOffTime + finalOffDuration
        let total = totalOn + totalOff
        let savingsPct = total > 0 ? round(totalOff / total * 1000) / 10 : 0
        _logMic("SESSION_SUMMARY", [
            "totalOnSec": round(totalOn * 10) / 10,
            "totalOffSec": round(totalOff * 10) / 10,
            "totalSessionSec": round(total * 10) / 10,
            "micOffPercent": savingsPct,
            "audioPacketsSent": _audioSentCount,
            "audioPacketsSuppressed": _audioSuppressedCount,
            "suppressionPercent": (_audioSentCount + _audioSuppressedCount) > 0
                ? round(Double(_audioSuppressedCount) / Double(_audioSentCount + _audioSuppressedCount) * 1000) / 10
                : 0
        ])
        // #endregion

        unmuteMicTimer?.cancel()
        unmuteMicTimer = nil
        postSpeechMuteTimer?.cancel()
        postSpeechMuteTimer = nil
        muteFailsafeTimer?.cancel()
        muteFailsafeTimer = nil
        preRoll.clear()
        lastLocalVoiceAt = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        isStreaming = false
        isPlayingResponse = false
        isMicMuted = false
        suspendedForProcessing = false
        farewellMuted = false
        scheduledBufferCount = 0
        audioConverter = nil
        _micOnTime = 0; _micOffTime = 0; _audioSentCount = 0; _audioSuppressedCount = 0
        print("[Audio] Streaming stopped")
    }

    /// Wait until streamed response audio has finished playing before asking
    /// Grok to continue after a tool result. This prevents adjacent model
    /// turns from overlapping in the car speakers.
    func waitForPlaybackToDrain(timeout: TimeInterval = 12) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            bufferLock.lock()
            let pending = scheduledBufferCount
            bufferLock.unlock()
            if pending == 0 && !isPlayingResponse {
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        print("[Audio] Playback-drain wait timed out after \(timeout)s")
    }

    // MARK: - Mic Gating

    private func muteMic(reason: String = "") {
        postSpeechMuteTimer?.cancel()
        postSpeechMuteTimer = nil
        guard !isMicMuted else { return }
        // #region agent log
        let onDuration = Date().timeIntervalSince(_lastMuteToggle)
        _micOnTime += onDuration
        _lastMuteToggle = Date()
        _logMic("MIC_OFF", ["reason": reason, "onDurationSec": round(onDuration * 100) / 100,
                             "totalOnSec": round(_micOnTime * 100) / 100,
                             "totalOffSec": round(_micOffTime * 100) / 100,
                             "sent": _audioSentCount, "suppressed": _audioSuppressedCount])
        // #endregion
        isMicMuted = true
        unmuteMicTimer?.cancel()
        unmuteMicTimer = nil
        // Anything captured before this mute belongs to the previous open
        // window — never replay it after the host finishes.
        preRoll.clear()
        armMuteFailsafe()
    }

    /// Failsafe: force the mic open if it has been muted for
    /// `maxMuteWithoutAudioSeconds` with no host audio playing. Without this,
    /// a missed unmute event ordering leaves the game permanently deaf
    /// ("game frozen, had to restart" reports).
    private func armMuteFailsafe() {
        muteFailsafeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isMicMuted, !self.farewellMuted else { return }
            if self.isPlayingResponse {
                // Host genuinely speaking — check again later.
                self.armMuteFailsafe()
                return
            }
            self.bufferLock.lock()
            let pending = self.scheduledBufferCount
            self.bufferLock.unlock()
            if pending > 0 {
                self.armMuteFailsafe()
                return
            }
            // #region agent log
            self._logMic("MUTE_FAILSAFE_FIRED", ["suspendedForProcessing": self.suspendedForProcessing])
            // #endregion
            print("[Audio] Mute failsafe fired — mic muted \(self.maxMuteWithoutAudioSeconds)s with no playback; force-unmuting")
            self.unmuteMicNow(reason: "failsafe")
        }
        muteFailsafeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxMuteWithoutAudioSeconds, execute: work)
    }

    private func unmuteMicNow(reason: String = "") {
        guard isMicMuted else { return }
        // #region agent log
        let offDuration = Date().timeIntervalSince(_lastMuteToggle)
        _micOffTime += offDuration
        _lastMuteToggle = Date()
        _logMic("MIC_ON", ["reason": reason, "offDurationSec": round(offDuration * 100) / 100,
                            "totalOnSec": round(_micOnTime * 100) / 100,
                            "totalOffSec": round(_micOffTime * 100) / 100])
        // #endregion
        unmuteMicTimer?.cancel()
        unmuteMicTimer = nil
        muteFailsafeTimer?.cancel()
        muteFailsafeTimer = nil
        isMicMuted = false
        suspendedForProcessing = false
    }

    private func scheduleUnmuteMic() {
        guard !farewellMuted else { return }
        unmuteMicTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.farewellMuted else { return }
            // #region agent log
            let offDuration = Date().timeIntervalSince(self._lastMuteToggle)
            self._micOffTime += offDuration
            self._lastMuteToggle = Date()
            self._logMic("MIC_ON", ["reason": "post-playback", "offDurationSec": round(offDuration * 100) / 100,
                                     "totalOnSec": round(self._micOnTime * 100) / 100,
                                     "totalOffSec": round(self._micOffTime * 100) / 100])
            // #endregion
            self.suspendedForProcessing = false
            self.isMicMuted = false
            self.muteFailsafeTimer?.cancel()
            self.muteFailsafeTimer = nil
        }
        unmuteMicTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + postPlaybackMuteDelay, execute: work)
    }

    /// Called by the coordinator after submitting a tool result.
    /// Mutes the mic during AI processing to save audio input tokens.
    /// Unmute happens automatically when the AI's next audio response arrives
    /// and finishes playing, or on responseDone if no audio.
    func suspendMicForProcessing() {
        suspendedForProcessing = true
        muteMic(reason: "tool processing")
    }

    /// Locks/unlocks mic for the farewell chain. While locked, user
    /// speech is suppressed so barge-ins cannot interrupt farewell audio.
    func setFarewellMute(_ muted: Bool) {
        farewellMuted = muted
        if muted {
            muteMic(reason: "farewell lock")
            muteFailsafeTimer?.cancel()
            muteFailsafeTimer = nil
        }
    }

    /// Evaluates whether a server-side `interrupted` event should be treated
    /// as a genuine user barge-in given the current gating state. The
    /// coordinator uses the same verdict to decide whether to flip the game
    /// phase to `.listening` — both layers must agree.
    func currentBargeInVerdict() -> BargeInPolicy.Verdict {
        BargeInPolicy.decide(
            micMuted: isMicMuted,
            utteranceLockActive: farewellMuted,
            secondsSinceLocalVoice: lastLocalVoiceAt.map { Date().timeIntervalSince($0) }
        )
    }

    // MARK: - Mic Capture → WebSocket

    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        // #region agent log
        if isMicMuted { _audioSuppressedCount += 1 } else { _audioSentCount += 1 }
        // #endregion
        guard let converter = audioConverter else { return }

        // During the farewell lock nothing is captured at all — that audio
        // must never reach the model.
        if isMicMuted && farewellMuted { return }

        // Calculate output frame count based on sample rate ratio
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: outputFrameCount) else { return }

        // Resample
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            print("[Audio] Conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        // Voice-energy tracking — feeds BargeInPolicy corroboration and the
        // pre-roll voice flag.
        let rms = Self.rmsOfInt16Buffer(outputBuffer)
        let hasVoice = rms >= voiceRMSThreshold
        if hasVoice && !isMicMuted {
            lastLocalVoiceAt = Date()
        }

        // Convert to base64
        guard let base64 = pcmBufferToBase64(outputBuffer) else { return }

        if isMicMuted {
            // Gated: keep a short rolling tail instead of dropping it.
            // If the player answers a beat before the unmute, the first
            // words are flushed from here once the mic opens.
            preRoll.append(base64Audio: base64, hasVoice: hasVoice)
            return
        }

        // Mic open: flush any pre-roll tail captured just before unmute,
        // then the live chunk, preserving order.
        let buffered = preRoll.drainForFlush()
        if !buffered.isEmpty {
            // The tail contained voice — count it as local voice evidence.
            lastLocalVoiceAt = Date()
            // #region agent log
            _logMic("PREROLL_FLUSH", ["chunks": buffered.count])
            // #endregion
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                for chunk in buffered {
                    try await self.sessionManager?.sendAudio(chunk)
                }
                try await self.sessionManager?.sendAudio(base64)
            } catch {
                // Logged/handled by session manager's consecutive failure watchdog
            }
        }
    }

    /// Mean-square energy of a PCM16 buffer, in Int16 amplitude units.
    private static func rmsOfInt16Buffer(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.int16ChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Double = 0
        let samples = data[0]
        // Stride to keep this cheap (every 4th sample is plenty for VAD-ish energy).
        var count = 0
        var i = 0
        while i < n {
            let v = Double(samples[i])
            sum += v * v
            count += 1
            i += 4
        }
        guard count > 0 else { return 0 }
        return (sum / Double(count)).squareRoot()
    }

    private func pcmBufferToBase64(_ buffer: AVAudioPCMBuffer) -> String? {
        guard let int16Data = buffer.int16ChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Data[0], count: byteCount)
        return data.base64EncodedString()
    }

    // MARK: - WebSocket → Speaker Playback

    private func handleRealtimeEvent(_ event: RealtimeServerEvent) {
        switch event {
        case .responseAudioDelta(_, let audioBase64):
            // AI is producing audio — mute mic (echo prevention + token savings)
            muteMic(reason: "AI speaking")
            playAudioChunk(audioBase64)

        case .responseAudioDone:
            // AI finished producing audio. Don't unmute yet —
            // wait for the playerNode to actually finish playing all buffered audio.
            isPlayingResponse = false
            print("[Audio] Response audio stream complete")

            bufferLock.lock()
            let pending = scheduledBufferCount
            bufferLock.unlock()
            if pending == 0 {
                scheduleUnmuteMic()
            }

        case .responseDone:
            // AI's full turn is complete (including any text-only responses).
            // If mic is still muted from processing suspend and no audio was played,
            // unmute now so the user can speak.
            if suspendedForProcessing && !isPlayingResponse {
                bufferLock.lock()
                let pending = scheduledBufferCount
                bufferLock.unlock()
                if pending == 0 {
                    scheduleUnmuteMic()
                }
            }

        case .inputAudioBufferSpeechStarted:
            // Server VAD claims the user started speaking. This event also
            // fires from cabin noise, speaker echo, and stale audio in the
            // pipeline — honoring every one with `playerNode.stop()` was the
            // root cause of the "host cut off" regression family
            // (debug-f3b222 3.log, 6.log and many more). Only a corroborated
            // barge-in (mic open + our own energy detector heard voice) is
            // allowed to interrupt playback.
            let verdict = currentBargeInVerdict()
            guard verdict == .honor else {
                _logMic("BARGE_BLOCKED", ["verdict": "\(verdict)"])
                break
            }

            // Genuine barge-in — cancel pending timers, force mic open
            postSpeechMuteTimer?.cancel()
            postSpeechMuteTimer = nil
            unmuteMicTimer?.cancel()
            unmuteMicTimer = nil
            muteFailsafeTimer?.cancel()
            muteFailsafeTimer = nil
            if isMicMuted {
                // #region agent log
                let offDuration = Date().timeIntervalSince(_lastMuteToggle)
                _micOffTime += offDuration
                _lastMuteToggle = Date()
                _logMic("MIC_ON", ["reason": "barge-in", "offDurationSec": round(offDuration * 100) / 100,
                                    "totalOnSec": round(_micOnTime * 100) / 100,
                                    "totalOffSec": round(_micOffTime * 100) / 100])
                // #endregion
            }
            suspendedForProcessing = false
            isMicMuted = false
            playerNode.stop()
            playerNode.play()
            isPlayingResponse = false
            bufferLock.lock()
            scheduledBufferCount = 0
            bufferLock.unlock()

        case .inputAudioBufferSpeechStopped:
            guard !farewellMuted else { break }
            postSpeechMuteTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.muteMic(reason: "post-speech gap")
            }
            postSpeechMuteTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + postSpeechMuteDelay, execute: work)

        // #region agent log
        case .usageMetadata(let prompt, let response, let total, let raw):
            _logMic("TOKEN_USAGE", [
                "promptTokens": prompt,
                "responseTokens": response,
                "totalTokens": total,
                "raw": "\(raw)"
            ])
        // #endregion

        default:
            break
        }
    }

    private func playAudioChunk(_ base64Audio: String) {
        guard let audioData = Data(base64Encoded: base64Audio) else { return }

        isPlayingResponse = true

        // Convert PCM16 Int16 data → Float32 for AVAudioPlayerNode
        let frameCount = audioData.count / MemoryLayout<Int16>.size
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                                frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let floatData = pcmBuffer.floatChannelData?[0] else { return }

        audioData.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<frameCount {
                floatData[i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        // Track scheduled buffers so we know when playback is truly done
        bufferLock.lock()
        scheduledBufferCount += 1
        bufferLock.unlock()

        // Schedule buffer for playback with completion handler
        playerNode.scheduleBuffer(pcmBuffer) { [weak self] in
            guard let self else { return }
            self.bufferLock.lock()
            self.scheduledBufferCount -= 1
            let remaining = self.scheduledBufferCount
            self.bufferLock.unlock()

            // When all buffers have played and no more audio is streaming, unmute mic
            if remaining == 0 {
                DispatchQueue.main.async {
                    if !self.isPlayingResponse {
                        self.scheduleUnmuteMic()
                        print("[Audio] All playback buffers drained — scheduling mic unmute")
                    }
                }
            }
        }
    }
    // MARK: - Bundled Sound Playback (AUDIO-01)

    /// Play a short bundled audio file (e.g., thinking stinger).
    /// The sound plays through the same audio engine used for streaming.
    func playBundledSound(named name: String, ext: String = "mp3") {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            print("[Audio] Bundled sound not found: \(name).\(ext)")
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let fileFormat = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else { return }
            try audioFile.read(into: buffer)

            // If the engine is running, schedule on the player node.
            // Otherwise, use a one-shot AVAudioPlayer.
            if audioEngine.isRunning {
                // Need to convert to playback format if different
                if fileFormat.sampleRate == playbackFormat.sampleRate &&
                   fileFormat.channelCount == playbackFormat.channelCount {
                    playerNode.scheduleBuffer(buffer, completionHandler: nil)
                } else {
                    // Convert format
                    guard let converter = AVAudioConverter(from: fileFormat, to: playbackFormat) else { return }
                    let ratio = playbackFormat.sampleRate / fileFormat.sampleRate
                    let outFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
                    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: outFrameCount) else { return }
                    var error: NSError?
                    converter.convert(to: outBuffer, error: &error) { _, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if error == nil {
                        playerNode.scheduleBuffer(outBuffer, completionHandler: nil)
                    }
                }
            }
            print("[Audio] Playing bundled sound: \(name)")
        } catch {
            print("[Audio] Error loading bundled sound: \(error)")
        }
    }
}

// MARK: - Errors

enum AudioStreamError: LocalizedError {
    case converterCreationFailed
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed: return "Failed to create audio format converter"
        case .engineStartFailed: return "Failed to start audio engine"
        }
    }
}
