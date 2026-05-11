import XCTest
import AVFoundation
@testable import AgentNotch

/// Lifecycle + lock-snapshot tests for `VoiceTranscriber`.
///
/// We cannot drive `start()` in CI: it calls
/// `SFSpeechRecognizer.requestAuthorization` and throws when permission
/// has not been granted. Instead we cover:
///
///   - Initial public-surface invariants.
///   - `setAssistantSpeaking(_:)` toggle reaches the
///     audio-thread snapshot without crashing.
///   - `append(buffer:)` is a no-op when there is no active request
///     (lock-protected snapshot returns nil → early return). This is
///     the PR #1 fix that replaced the per-buffer Task hop.
final class VoiceTranscriberStateTests: XCTestCase {
    @MainActor
    func testInitialState() {
        let t = VoiceTranscriber()
        XCTAssertFalse(t.isRunning)
        XCTAssertEqual(t.lastFinalText, "")
        XCTAssertEqual(t.lastPartialText, "")
    }

    @MainActor
    func testSetAssistantSpeakingIsLockSafe() {
        let t = VoiceTranscriber()
        // Toggle aggressively to exercise the lock acquire/release path.
        for i in 0..<100 {
            t.setAssistantSpeaking(i.isMultiple(of: 2))
        }
        XCTAssertFalse(t.isRunning)
    }

    /// `append(buffer:)` is called from the AVAudioEngine tap thread.
    /// When no recognition session is active, the lock-protected
    /// snapshot returns nil and the call must return without touching
    /// any actor-isolated state. Calling it before `start()` (and from
    /// a background queue, to mimic the engine thread) must therefore
    /// be a silent no-op.
    func testAppendBufferBeforeStartIsNoOp() {
        let t = VoiceTranscriber()

        // Build a minimal valid PCM buffer. The 16 kHz mono Float32
        // format matches what the recorder produces post-downmix.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else {
            return XCTFail("could not allocate test PCM buffer")
        }
        buffer.frameLength = 128

        let exp = expectation(description: "append from background queue returned")
        DispatchQueue.global(qos: .userInitiated).async {
            // Call from a background thread to mirror the real engine
            // tap callback. Must not crash, must not assert.
            t.append(buffer: buffer)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
