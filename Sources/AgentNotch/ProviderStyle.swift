import SwiftUI

/// Per-provider visual style for sidebar badges.
///
/// `agent-conductor` v0.4+ tags every session with a `provider` field
/// (`claude-code`, `aider`, `cursor-cli`, or custom). This translates that
/// identifier into a colour that the sidebar dot uses to differentiate
/// providers at a glance, regardless of refined status.
///
/// Unknown / missing providers fall back to a neutral grey so the sidebar
/// keeps working with older backends that don't emit the field.
///
/// Customisation: add more cases for your own providers, or fork this file
/// in your consumer app and pass colours via init.
public enum ProviderStyle {
    /// Brand accent colour for a provider.
    public static func accent(forProvider name: String?) -> Color {
        guard let raw = name?.lowercased() else { return .gray }
        switch raw {
        case "claude-code", "claude":
            return Color(red: 0.91, green: 0.45, blue: 0.16) // Claude orange-amber
        case "aider":
            return Color(red: 0.34, green: 0.71, blue: 0.55) // Aider green
        case "cursor-cli", "cursor":
            return Color(red: 0.42, green: 0.55, blue: 0.96) // Cursor blue
        case "chatgpt", "chatgpt-cli", "openai":
            return Color(red: 0.10, green: 0.66, blue: 0.55) // OpenAI green
        default:
            return Color(red: 0.65, green: 0.65, blue: 0.65)
        }
    }

    /// Short display label (e.g. for tooltips, popovers, status footers).
    public static func displayName(forProvider name: String?) -> String {
        guard let raw = name?.lowercased() else { return "Unknown" }
        switch raw {
        case "claude-code", "claude":  return "Claude Code"
        case "aider":                   return "Aider"
        case "cursor-cli", "cursor":    return "Cursor CLI"
        case "chatgpt", "chatgpt-cli", "openai": return "ChatGPT"
        default:                        return name ?? "Unknown"
        }
    }
}
