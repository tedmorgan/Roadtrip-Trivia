import Foundation
import AVFoundation
import Combine

/// Bidirectional audio streaming for the OpenAI Realtime API.
/// Captures microphone audio, resamples to 24kHz PCM16, and streams via WebSocket.
/// Receives audio from the API and plays it back in real-time.
///
/// Echo prevention: The mic is automatically muted while the AI is speaking
/// and unmuted after playback finishes (with a short grace period).
class AudioStreamingService: ObservableObject {

    @Published private(set) var isStreaming = false
    @Published private(set) var isPlayingResponse = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioManager = AudioSessionManager.shared
    private weak var sessionManager: RealtimeSessionManager?
    private var cancellables = Set<AnyCancellable>()

    /// Target format for OpenAI Realtime API: PCM16, 24kHz, mono.
    private let targetSampleRate: Double = 24000
    private let targetChannels: UInt32 = 1

    /// Audio converter for resampling mic input to 24kHz.
    private var audioConverter: AVAudioConverter?

    /// Target audio format (24kHz PCM16 mono).
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate,
                      channels: AVAudioChannelCount(targetChannels), interleaved: true)!
    }()

    /// Playback format — 24kHz Float32 mono (AVAudioPlayerNode needs float).
    private lazy var playbackFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
                      channels: AVAudioChannelCount(targetChannels), interleaved: false)!
    }()

    // MARK: - Echo Prevention

    /// When true, mic audio is not sent to the API.
    private var isMicMuted = false

    /// Track how many audio buffers are scheduled but not yet played.
    /// Used to know when playback is truly finished.
    private var scheduledBufferCount = 0
    private let bufferLock = NSLock()

    /// Timer to unmute mic after playback finishes.
    private var unmuteMicTimer: DispatchWorkItem?

    /// Grace period after AI finishes speaking before unmuting mic.
    /// Allows residual echo to die out.
    private let postPlaybackMuteDelay: TimeInterval = 0.4

    // MARK: - Setup

    func configure(sessionManager: RealtimeSessionManager) {
        self.sessionManager = sessionManager

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

        // Create audio converter: mic format → 24kHz PCM16
        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        guard audioConverter != nil else {
            throw AudioStreamError.converterCreationFailed
        }

        // Install tap on microphone input
        let bufferSize: AVAudioFrameCount = 2400 // 100ms at 24kHz
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer)
        }

        try audioEngine.start()
        playerNode.play()
        isStreaming = true
        isMicMuted = false
        scheduledBufferCount = 0
        print("[Audio] Streaming started")
    }

    func stopStreaming() {
        guard isStreaming else { return }

        unmuteMicTimer?.cancel()
        unmuteMicTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        isStreaming = false
        isPlayingResponse = false
        isMicMuted = false
        scheduledBufferCount = 0
        audioConverter = nil
        print("[Audio] Streaming stopped")
    }

    // MARK: - Mic Muting (Echo Prevention)

    private func muteMic() {
        guard !isMicMuted else { return }
        isMicMuted = true
        unmuteMicTimer?.cancel()
        unmuteMicTimer = nil
        print("[Audio] Mic muted (AI speaking)")
    }

    private func scheduleUnmuteMic() {
        unmuteMicTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isMicMuted = false
            print("[Audio] Mic unmuted (ready for user)")
        }
        unmuteMicTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + postPlaybackMuteDelay, execute: work)
    }

    // MARK: - Mic Capture → WebSocket

    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMicMuted, let converter = audioConverter else { return }

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

        // Convert to base64
        guard let base64 = pcmBufferToBase64(outputBuffer) else { return }

        // Send to Realtime API
        Task { [weak self] in
            try? await self?.sessionManager?.sendAudio(base64)
        }
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
            // AI is producing audio — mute mic to prevent echo feedback
            muteMic()
            playAudioChunk(audioBase64)

        case .responseAudioDone:
            // AI finished producing audio. Don't unmute yet —
            // wait for the playerNode to actually finish playing all buffered audio.
            // The completion handler on the last scheduled buffer will trigger unmute.
            isPlayingResponse = false
            print("[Audio] Response audio stream complete")

            // If no buffers are pending (edge case: empty response), unmute now
            bufferLock.lock()
            let pending = scheduledBufferCount
            bufferLock.unlock()
            if pending == 0 {
                scheduleUnmuteMic()
            }

        case .inputAudioBufferSpeechStarted:
            // Server VAD detected user speech — cancel any in-progress model audio
            unmuteMicTimer?.cancel()
            unmuteMicTimer = nil
            isMicMuted = false
            playerNode.stop()
            playerNode.play() // Re-arm for next audio
            isPlayingResponse = false
            bufferLock.lock()
            scheduledBufferCount = 0
            bufferLock.unlock()

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
