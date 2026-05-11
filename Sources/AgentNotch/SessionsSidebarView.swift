import SwiftUI
import AppKit

/// ORC-11 — Right-peek sessions sidebar. Renders one row per active Claude
/// Code session with a status-coloured badge, repo name, and pid. Clicking a
/// row opens the dashboard's Orchestrator tab filtered on that pid.
///
/// Subscribes to `NotchEventBus.shared` for `sessions:update` events; the
/// bus replays the last-known snapshot on subscribe + on reconnect (ORC-14)
/// so the sidebar never goes perma-empty.
public struct SessionsSidebarView: View {
    @Binding var sessions: [SessionStatusEntry]

    /// Captured unsubscribe closure from `NotchEventBus.subscribe`. Stored
    /// in `@State` so the view can call it in `onDisappear`.
    @State private var unsubscribe: (() -> Void)?

    public init(sessions: Binding<[SessionStatusEntry]>) {
        self._sessions = sessions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sessions.isEmpty {
                Text("No sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(6)
            } else {
                ForEach(sessions, id: \.pid) { s in
                    HStack(spacing: 6) {
                        // Outer ring tinted by provider; inner dot by status.
                        // Net effect: a glance shows BOTH provider and state.
                        ZStack {
                            Circle()
                                .stroke(ProviderStyle.accent(forProvider: s.provider), lineWidth: 2)
                                .frame(width: 10, height: 10)
                            Circle()
                                .fill(badgeColor(for: s.status))
                                .frame(width: 6, height: 6)
                        }
                        // VoiceOver: the two-circle badge is purely
                        // decorative — the label below carries the
                        // semantic state. Hide the badge from AT.
                        .accessibilityHidden(true)

                        Text(s.repo)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(s.pid)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let c = s.conflict {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption2)
                                .help("Conflict with pid \(c)")
                                .accessibilityLabel("Conflict with process \(c)")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .help(ProviderStyle.displayName(forProvider: s.provider))
                    // Compose a single semantic line for VoiceOver users
                    // instead of letting each child element be read in
                    // sequence ("two-decimal-place pid number, repo,
                    // image triangle"). Provider + repo + status reads
                    // as one chunk, mirroring how the row is meant to
                    // be scanned visually.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(ProviderStyle.displayName(forProvider: s.provider)) session for \(s.repo), \(humanReadableStatus(s.status)), process \(s.pid)"
                    )
                    .accessibilityHint("Activate to open the orchestrator dashboard for this session")
                    .accessibilityAddTraits(.isButton)
                    .onTapGesture { openDashboardOrchestratorTab(pid: s.pid) }
                }
            }
        }
        .padding(4)
        .frame(minWidth: 120, maxWidth: 180)
        .background(Color(white: 0.05).opacity(0.6))
        .cornerRadius(6)
        .onAppear {
            // Subscribe on appear — the bus replays the last `sessions:update`
            // payload synchronously so the sidebar materializes with the
            // last-known state instead of flashing empty (ORC-14).
            let unsub = NotchEventBus.shared.subscribe { event in
                if case .sessionsUpdate(let payload) = event,
                   let sess = payload.sessions {
                    DispatchQueue.main.async {
                        self.sessions = sess
                    }
                }
            }
            self.unsubscribe = unsub
        }
        .onDisappear {
            unsubscribe?()
            unsubscribe = nil
        }
    }

    /// Per-status colour mapping — matches CONTEXT.md's locked decisions:
    /// awaiting_user_input → orange (needs attention), tool_pending → blue
    /// (in flight), crashed → red (dead), working → green (alive),
    /// idle → gray (alive but quiet).
    private func badgeColor(for status: String) -> Color {
        switch status {
        case "awaiting_user_input": return .orange
        case "tool_pending":        return .blue
        case "crashed":             return .red
        case "working":             return .green
        case "idle":                return .gray
        default:                    return .gray
        }
    }

    /// VoiceOver-friendly status string. The raw wire value
    /// (`"awaiting_user_input"`) is fine in JSON but reads terribly out
    /// loud; the human-readable form makes the row understandable
    /// without sighted access to the colour-coded badge.
    private func humanReadableStatus(_ status: String) -> String {
        switch status {
        case "awaiting_user_input": return "awaiting user input"
        case "tool_pending":        return "tool call pending"
        case "crashed":             return "crashed"
        case "working":             return "working"
        case "idle":                return "idle"
        default:                    return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func openDashboardOrchestratorTab(pid: Int) {
        NSWorkspace.shared.open(NotchEndpoints.orchestratorWeb(pid: pid))
    }
}

// MARK: - Test affordances (#if DEBUG)
//
// SwiftUI does not run `.onAppear` when a body is materialized in a unit
// test (no view hierarchy attaches the view). This helper registers the
// same subscription the production `.onAppear` does, so the reactivity
// test can drive the bus and assert on the binding.

#if DEBUG
extension SessionsSidebarView {
    /// Install the same subscription `.onAppear` registers in production,
    /// targeting an externally-owned binding setter. Used by
    /// `SessionsSidebarTests.testReactsToSessionsUpdateEvent`.
    public static func _test_installSubscription(setSessions: @escaping ([SessionStatusEntry]) -> Void) -> () -> Void {
        return NotchEventBus.shared.subscribe { event in
            if case .sessionsUpdate(let payload) = event,
               let sess = payload.sessions {
                DispatchQueue.main.async {
                    setSessions(sess)
                }
            }
        }
    }
}
#endif
