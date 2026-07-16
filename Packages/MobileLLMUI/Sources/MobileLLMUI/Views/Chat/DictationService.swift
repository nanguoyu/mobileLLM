// SPDX-License-Identifier: MIT

import Foundation
import Observation
import Speech
import AVFoundation

/// On-device dictation for the composer (DESIGN §4): `SFSpeechRecognizer` fed by an `AVAudioEngine` tap,
/// preferring offline recognition where the device supports it. Tap the mic to start/stop; `transcript`
/// updates live as partial results land, and the composer merges it into the draft.
///
/// Cross-platform (iOS + macOS). The Info.plist usage strings (`NSMicrophoneUsageDescription` /
/// `NSSpeechRecognitionUsageDescription`) are the app target's job — `swift test` never launches the
/// app, so this composes and unit-tests without them.
@MainActor
@Observable
public final class DictationService {

    public enum State: Equatable {
        case idle          // not recording
        case recording     // capturing + transcribing
        case denied        // mic or speech permission refused
        case unavailable   // no recognizer for this locale / recognizer offline
    }

    public private(set) var state: State = .idle
    /// The best transcription so far this session (empty between sessions).
    public private(set) var transcript: String = ""

    public var isRecording: Bool { state == .recording }

    private let recognizer = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public func toggle() { isRecording ? stop() : start() }

    /// Begin dictation: ask for speech (then, on iOS, mic) permission, then stream audio into recognition.
    public func start() {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else { self.state = .denied; return }
                self.requestMicrophoneThenRun()
            }
        }
    }

    private func requestMicrophoneThenRun() {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                granted ? self.run() : (self.state = .denied)
            }
        }
        #else
        // macOS surfaces the mic TCC prompt when the audio engine starts; a refusal shows up as a start error.
        run()
        #endif
    }

    private func run() {
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep it on-device where the model exists — no audio leaves the phone (DESIGN's privacy promise).
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // A denied/absent input device reports 0 channels, and installTap raises an ObjC exception on
            // such a format (uncatchable from Swift) — bail to the unavailable state instead of crashing.
            guard format.channelCount > 0, format.sampleRate > 0 else {
                teardown()
                state = .unavailable
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            teardown()
            state = .idle
            return
        }

        audioEngine = engine
        self.request = request
        transcript = ""
        state = .recording
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) {
                    self.teardown()
                    if self.state == .recording { self.state = .idle }
                }
            }
        }
    }

    /// Stop dictation, keeping whatever was transcribed.
    public func stop() {
        request?.endAudio()
        teardown()
        if state == .recording { state = .idle }
    }

    private func teardown() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        task?.cancel()
        audioEngine = nil
        request = nil
        task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
