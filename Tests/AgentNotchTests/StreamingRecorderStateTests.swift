import XCTest
import AVFoundation
@testable import AgentNotch

/// State / lifecycle tests for `StreamingRecorder` that do NOT require
/// actually starting the AVAudioEngine. The CI runner has no microphone
/// and no TCC grant, so a real `start()` would either prompt or fail.
///
/// We exercise:
///   - Default state right after init.
///   - `setAssistantSpeaking(_:)` toggle.
///   - `fileURL` invariant.
///
/// PR #1 added a `writeFailure: Error?` property that surfaces an
/// AVAudioFile write error to the caller. This file asserts that the
/// property starts nil and is reachable on the public surface — without
/// it the audit's "silent corruption" gap would re-open.
final class StreamingRecorderStateTests: XCTestCase {
    @MainActor
    func testInitialStateIsIdle() {
        let recorder = StreamingRecorder()
        XCTAssertFalse(recorder.isRunning, "fresh recorder must not be running")
        XCTAssertFalse(recorder.hadVoice, "fresh recorder must report no voice yet")
        XCTAssertNil(recorder.writeFailure, "fresh recorder must have no write failure")
    }

    @MainActor
    func testFileURLIsStableAcrossInstances() {
        let a = StreamingRecorder()
        let b = StreamingRecorder()
        XCTAssertEqual(a.fileURL, b.fileURL, "output URL is a singleton path")
        XCTAssertEqual(a.fileURL.path, "/tmp/jarvis-notch-stream.wav")
    }

    /// `setAssistantSpeaking` flips a Bool the audio tap reads to drop
    /// frames during TTS playback. Without it, the WAV would record the
    /// assistant's own voice and the server would transcribe it back as
    /// user input.
    @MainActor
    func testSetAssistantSpeakingDoesNotCrash() {
        let recorder = StreamingRecorder()
        recorder.setAssistantSpeaking(true)
        recorder.setAssistantSpeaking(false)
        recorder.setAssistantSpeaking(true)
        // No crash + still idle.
        XCTAssertFalse(recorder.isRunning)
    }
}
