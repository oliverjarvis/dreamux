import Foundation

/// Which write is safe into a tab, given whether a claude session is live
/// in it. Extracted as a pure function because it is the whole of the rule
/// — the two `ClaudePromptDriver` entry points write fundamentally
/// different bytes, and each is destructive in the other's context:
///
/// - `send` writes a `claude "$(cat …)"` SHELL COMMAND. Into a live agent's
///   REPL it lands as a chat message and the real prompt is eaten.
/// - `type` writes a bare REPL LINE. Into a bare `zsh` it is EXECUTED.
///
/// Liveness comes from `TabSession.binding.isBound` — the app's existing
/// answer to "is a claude alive in this tab?", whose own doc comment
/// already states the discipline ("the write path gates on `phase` — never
/// blind-type"). `ClaudePromptDriver` simply never consulted it.
enum PromptDelivery {
    /// What the caller wants to write into the tab.
    enum Intent { case launchClaude, typeIntoAgent }
    enum Mode { case launch, type, refuse }

    /// launchClaude + unbound → .launch    launchClaude + bound → .refuse
    /// typeIntoAgent + bound  → .type      typeIntoAgent + unbound → .refuse
    static func mode(intent: Intent, bound: Bool) -> Mode {
        switch (intent, bound) {
        case (.launchClaude, false): return .launch
        case (.launchClaude, true): return .refuse
        case (.typeIntoAgent, true): return .type
        case (.typeIntoAgent, false): return .refuse
        }
    }
}
