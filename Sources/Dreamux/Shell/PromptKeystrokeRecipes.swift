import Foundation

/// Keystroke recipes for Claude Code's interactive TUI. THE deliberately
/// version-fragile file: everything that assumes how claude's dialogs
/// respond to keys lives here, unit tested, and gets re-verified against
/// each Claude Code upgrade (docs/claude-chat-face-smoke.md). Senders
/// must gate on ClaudeSessionBinding state — never blind-type.
enum PromptKeystrokeRecipes {
    private static let esc = "\u{1B}"
    private static let down = "\u{1B}[B"
    private static let enter = "\r"

    /// Main composer: bracketed paste keeps multi-line prompts one
    /// input event, then Enter submits.
    static func promptSend(_ text: String) -> String {
        esc + "[200~" + text + esc + "[201~" + enter
    }

    /// Single-select question; cursor starts on option 0.
    static func selectOption(at index: Int) -> String {
        String(repeating: down, count: max(0, index)) + enter
    }

    /// Multi-select question: walk downward toggling with Space, then
    /// submit. Indices beyond the cursor only — one pass, no wrapping.
    static func selectOptions(at indices: [Int]) -> String {
        var out = ""
        var cursor = 0
        for index in Set(indices).sorted() {
            out += String(repeating: down, count: index - cursor) + " "
            cursor = index
        }
        return out + enter
    }

    /// "Other" sits one past the last listed option; selecting it opens
    /// a free-text field.
    static func selectOtherAndType(optionCount: Int, text: String) -> String {
        String(repeating: down, count: optionCount) + enter + text + enter
    }

    /// Permission dialogs: recipes keyed on recognized Notification
    /// messages. Ships EMPTY on purpose — every permission request
    /// degrades to the "Respond in terminal" banner until a pattern has
    /// been verified against real payloads. Add entries here only with
    /// a matching smoke-checklist run.
    static func permissionRecipe(forNotification message: String) -> String? {
        nil
    }

    /// The reject half of a permission dialog. Ships EMPTY for the same
    /// reason `permissionRecipe` does — a recipe that has not been
    /// verified against a real payload is a keystroke fired blind. Add
    /// entries here only with a matching smoke-checklist run, and only
    /// in the same commit as the matching approve entry: a banner that
    /// can approve but not deny is worse than one that can do neither.
    static func permissionDenyRecipe(forNotification message: String) -> String? {
        nil
    }

    static let interrupt = esc
}
