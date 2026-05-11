import Foundation
import AVFoundation
import Speech

/// Live speech-to-text using Apple's `SFSpeechRecognizer` — same recognizer
/// openclaw Talk Mode uses on macOS. Runs in parallel to `StreamingRecorder`
/// so the user gets BOTH a live transcript AND a server-quality WAV (the WAV
/// is still uploaded as a fallback if Apple's recognition is empty).
///
/// Why parallel instead of replacing the whisper round-trip:
///   - Apple is on-device, free, ~0 latency for partials → great UX
///   - Apple sometimes mis-hears Italian terms (especially names, code, slang);
///     keeping whisper as a backup means we can pick the better transcript
///     server-side, or fall back if Apple returns empty
///
/// Permissions: TCC `NSSpeechRecognitionUsageDescription` declared in
/// Bundler.toml. First call kicks off the system prompt asynchronously.
@MainActor
final class VoiceTranscriber {
    /// Vocabolario tech IT+EN con cui boostare il recognizer. Apple
    /// `contextualStrings` è documentato come bias di pesatura: il modello
    /// preferisce queste frasi quando l'audio è ambiguo. Non restringe — solo
    /// aiuta. Re-iniettato a ogni session (coerente con la rebuild del
    /// recognizer descritta sotto).
    ///
    /// Lista derivata dal workflow reale:
    ///   - dev verbs (deploy/merge/commit) sia EN puri che italianizzati
    ///   - stack JS/TS che Attilio usa quotidianamente
    ///   - stack Apple/Swift per il notch stesso
    ///   - the backend ecosystem (router, tray, MCP, agents)
    ///   - progetti registrati (moonstone, topics, tida, zenda, bestime, atollo)
    ///   - termini AI/voice (TTS, STT, VAD, barge-in, Claude, Codex)
    ///
    /// Bound: ~80 termini. Apple non documenta un hard limit ma in pratica
    /// >100 inizia a degradare. Aggiornare via PR quando emerge nuovo
    /// vocabolario ricorrente nei log STT.
    private static let techVocabulary: [String] = [
        // Dev verbs (EN puri o italianizzati)
        "deploy", "deployment", "deployare", "deployato",
        "merge", "mergeare", "mergiare",
        "commit", "commitare", "commitato",
        "push", "pushare", "pull", "rebase", "revert",
        "checkout", "branch", "feature branch", "main", "master", "head",
        "rollback", "stash", "amend", "fork", "clone",
        // Stack JS/TS
        "TypeScript", "JavaScript", "TanStack", "shadcn", "Tailwind",
        "Vercel", "Supabase", "Prisma", "Drizzle", "Vite", "Next.js",
        "tRPC", "Hono", "Bun", "Node.js",
        "ESLint", "Prettier", "Vitest", "Playwright",
        // Stack Apple/macOS
        "SwiftUI", "Combine", "AVFoundation", "WebKit", "WKWebView",
        "DynamicNotchKit", "AppKit", "Xcode",
        // backend ecosystem
        "notch", "session", "agent", "tool", "dashboard",
        "Claude Code", "Codex", "Anthropic", "OpenAI",
        "ElevenLabs", "Cartesia", "Gladia", "Deepgram",
        "ChromaDB", "OMEGA", "MCP",
        // Progetti registrati (da agents/notch/CLAUDE.md)
        "moonstone", "topics", "Topics App", "tida", "zenda", "bestime", "atollo",
        "Armonia", "Guedado",
        // Concetti tecnici comuni
        "endpoint", "WebSocket", "stream", "buffer", "callback", "promise",
        "async", "await", "interface", "schema", "payload", "middleware",
        "Docker", "launchd", "launchctl",
        "PR", "issue", "review", "CI", "pipeline", "hook", "pre-commit",
        // Voice terms
        "TTS", "STT", "VAD", "barge-in", "transcript",
    ]

    /// Locale captured at init so we can rebuild a fresh `SFSpeechRecognizer`
    /// on every `start()`. Reusing the same recognizer instance across
    /// sessions is unreliable on macOS 14+: after the first task finishes,
    /// subsequent `recognitionTask(with:)` calls sometimes return a task
    /// that never fires partials or finals (Apple bug, openclaw works
    /// around it the same way). Recreating per-session adds ~5 ms and
    /// fixes the "second hover doesn't transcribe" symptom.
    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Audio-thread visible snapshot of the current recognition request.
    /// `SFSpeechAudioBufferRecognitionRequest.append(_:)` is documented
    /// thread-safe, so we hold a lock-protected reference here and let
    /// `append(buffer:)` push samples directly from the AVAudioEngine tap
    /// thread — no MainActor hop, no per-sample Task, no race on a nilled
    /// request. The lock is uncontended in steady state (one writer on
    /// start/stop, one reader per buffer). NSLock satisfies Sendable in
    /// recent SDKs.
    private let requestLock = NSLock()
    nonisolated(unsafe) private var sharedRequest: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var sharedAssistantSpeaking: Bool = false
    /// Soft barge-in: while the assistant's TTS is playing, we still
    /// receive audio buffers but skip feeding them to the recognizer so
    /// the user doesn't see the assistant transcribing its own voice. Toggled by
    /// the controller via `setAssistantSpeaking`.
    private var assistantSpeaking: Bool = false

    private(set) var isRunning: Bool = false
    private(set) var lastFinalText: String = ""
    private(set) var lastPartialText: String = ""

    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?

    init(locale: Locale = Locale(identifier: "it-IT")) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func setAssistantSpeaking(_ speaking: Bool) {
        assistantSpeaking = speaking
        requestLock.lock()
        sharedAssistantSpeaking = speaking
        requestLock.unlock()
    }

    /// Begin a recognition session. The caller feeds audio buffers via
    /// `append(buffer:)`. Partials fire as Apple updates its hypothesis,
    /// usually 5-10 Hz. Final fires once when the recognizer commits.
    /// Caller is responsible for calling `stop()` (e.g. on silence).
    func start(
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void
    ) throws {
        try requestAuthorizationSync()

        cancelExisting()
        // Reset the barge-in flag — if a previous TTS playback ended without
        // firing its `end` event (network error, page reload, etc) the flag
        // can stay true and silently drop every mic buffer for the next
        // session. Always start clean.
        assistantSpeaking = false
        // Rebuild a fresh recognizer for this session — reuse is unreliable.
        self.recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "VoiceTranscriber", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "speech recognizer not available for \(locale.identifier)"]
            )
        }
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.lastPartialText = ""
        self.lastFinalText = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Enable on-device recognition where supported. Apple's cloud variant
        // adds latency + sends audio out — both unwanted for an ambient notch.
        if #available(macOS 13.0, *) {
            req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            req.addsPunctuation = true
        }
        // Boost recognition for tech terms that the it-IT model would
        // otherwise mangle into pseudo-Italian phonetics ("deploi", "merdge",
        // "endpoint" italianizzato). `contextualStrings` is documented to
        // weight recognition toward these phrases — it does NOT restrict, it
        // biases. Re-injected per session because the recognizer is rebuilt
        // each time (Apple-bug workaround above).
        req.contextualStrings = Self.techVocabulary
        self.request = req
        // Publish to the audio-thread snapshot under the lock so the next
        // append(buffer:) call sees the new request, not a stale one.
        requestLock.lock()
        sharedRequest = req
        sharedAssistantSpeaking = false
        requestLock.unlock()

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.lastFinalText = text
                        self.onFinal?(text)
                    } else {
                        if text != self.lastPartialText {
                            self.lastPartialText = text
                            self.onPartial?(text)
                        }
                    }
                }
                if let error {
                    NotchLogger.shared.log("warn", "[stt] recognition error: \(error.localizedDescription)")
                }
            }
        }

        isRunning = true
    }

    /// Feed a buffer from the audio engine tap. Must be the same format the
    /// recognizer expects — usually 16 kHz mono Float32, but the request is
    /// format-agnostic in practice; Apple's pipeline resamples internally.
    nonisolated func append(buffer: AVAudioPCMBuffer) {
        // Hot path: runs on the AVAudioEngine tap thread, ~50-100 Hz.
        // Read the current request + barge-in flag under a tiny critical
        // section, then call `append` directly. SFSpeechAudio-
        // BufferRecognitionRequest.append(_:) is documented as
        // thread-safe, so we don't need a MainActor hop. Skipping the hop
        // avoids spawning a Task per buffer (which would starve the main
        // actor) and eliminates the previous race where cancel() niled
        // the request between the hop and the append call.
        requestLock.lock()
        let req = sharedRequest
        let speaking = sharedAssistantSpeaking
        requestLock.unlock()
        if speaking { return }
        req?.append(buffer)
    }

    /// End the current recognition session. Triggers a final result if Apple
    /// has one buffered. Returns the best text we've heard so far so the
    /// caller can ship it as the user message even before `onFinal` lands.
    @discardableResult
    func stop() -> String {
        request?.endAudio()
        // Drop the audio-thread snapshot BEFORE niling the actor-isolated
        // reference so a pending append on the engine thread doesn't push
        // one last buffer into a request that has already had `endAudio`
        // called on it.
        requestLock.lock()
        sharedRequest = nil
        requestLock.unlock()
        // Don't cancel the task — that would suppress the final callback.
        // Apple emits the final shortly after endAudio() if it has bytes.
        request = nil
        isRunning = false
        let candidate = lastFinalText.isEmpty ? lastPartialText : lastFinalText
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cancel without keeping any text — used when the recording is being
    /// discarded (e.g., grace period expired with no voice).
    func cancel() {
        cancelExisting()
        lastPartialText = ""
        lastFinalText = ""
    }

    private func cancelExisting() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        // Mirror the actor-isolated nil into the audio-thread snapshot so
        // append(buffer:) becomes a no-op immediately.
        requestLock.lock()
        sharedRequest = nil
        requestLock.unlock()
        isRunning = false
    }

    private func requestAuthorizationSync() throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return
        case .notDetermined:
            // Async — user must accept the system prompt; subsequent hover
            // sessions will find `.authorized`. Mirrors StreamingRecorder.
            SFSpeechRecognizer.requestAuthorization { _ in }
            throw NSError(
                domain: "VoiceTranscriber", code: -10,
                userInfo: [NSLocalizedDescriptionKey: "speech recognition permission requested — accept the prompt and try again"]
            )
        case .denied, .restricted:
            throw NSError(
                domain: "VoiceTranscriber", code: -11,
                userInfo: [NSLocalizedDescriptionKey: "speech recognition denied"]
            )
        @unknown default:
            throw NSError(
                domain: "VoiceTranscriber", code: -12,
                userInfo: [NSLocalizedDescriptionKey: "speech recognition unknown"]
            )
        }
    }
}
