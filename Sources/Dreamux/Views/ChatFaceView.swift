import SwiftUI

/// The Chat face of a terminal tab bound to a live Claude Code session:
/// live conversation from the transcript tailer, honest status chip,
/// question/permission banners, and a composer that types into the PTY.
/// The Terminal face is always one flip away — and is the mandatory
/// fallback for anything this face doesn't positively recognize.
struct ChatFaceView: View {
    let tab: TabSession
    let onFlipToTerminal: () -> Void
    let onOpenTranscript: (URL) -> Void

    @State private var draft = ""
    @State private var otherText = ""
    @State private var multiSelection: Set<Int> = []
    /// Set when a question answer is injected; if the pendingQuestion
    /// hasn't cleared ~3s later, the banner adds a "that didn't seem to
    /// land — respond in terminal" note (spec: watch for the expected
    /// state advance after every injection).
    @State private var answerInjectedAt: Date?

    private var binding: ClaudeSessionBinding { tab.binding }

    private typealias PendingQuestion = TranscriptAccumulator.PendingQuestion

    /// Column width shared by the conversation and the footer so the
    /// composer lines up under the messages instead of sprawling across a
    /// wide window.
    private static let columnWidth: CGFloat = 860

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A new (or cleared) question resets any half-made answer: a stale
        // multi-select or "did not land" note must never bleed across
        // questions.
        .onChange(of: activePendingQuestion?.toolUseID) {
            answerInjectedAt = nil
            multiSelection = []
            otherText = ""
        }
    }

    // MARK: - Derived state

    private var items: [TranscriptItem] { binding.conversation?.items ?? [] }

    /// The question to render in the banner — only while we're actually
    /// waiting on the user for it.
    private var activePendingQuestion: PendingQuestion? {
        guard binding.phase == .waitingForUser else { return nil }
        return binding.conversation?.pendingQuestion
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch binding.phase {
        case .working: .orange
        case .waitingForUser: .blue
        case .idle: .green
        case .ended, .unbound: .secondary
        }
    }

    private var statusLabel: String {
        switch binding.phase {
        case .working: "Working…"
        case .waitingForUser: "Waiting for you"
        case .idle: "Idle"
        case .ended: "Session ended"
        case .unbound: "No active session"
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(items) { row(for: $0) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if items.isEmpty { emptyState }
            }
            .onChange(of: items.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text(binding.conversation?.fileFound == true
             ? "No messages yet."
             : "Waiting for the session transcript…")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Every item is a `TranscriptRow`; an Agent/Task tool call additionally
    /// gets a link row that resolves the subagent's own transcript on click.
    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        if case .toolUse(let id?, let name, _) = item.kind, name == "Agent" || name == "Task" {
            VStack(alignment: .leading, spacing: 6) {
                TranscriptRow(item: item)
                subagentLink(toolUseID: id)
            }
        } else {
            TranscriptRow(item: item)
        }
    }

    private func subagentLink(toolUseID: String) -> some View {
        BorderlessActionRow(systemImage: "arrow.up.right", title: "Open subagent transcript") {
            guard let parent = binding.conversation?.url,
                  let url = SubagentTranscriptLocator.transcript(
                    forToolUseID: toolUseID, parentTranscript: parent)
            else { return } // may not have written its transcript yet — silent no-op
            onOpenTranscript(url)
        }
    }

    // MARK: - Footer (banners + composer)

    private var footer: some View {
        VStack(spacing: 10) {
            if let pending = activePendingQuestion {
                questionBanner(pending)
            } else if binding.lastNotification != nil, binding.phase == .waitingForUser {
                notificationBanner
            } else if binding.phase == .ended {
                endedBanner
            }
            if binding.phase != .ended {
                composer
            }
        }
        .frame(maxWidth: Self.columnWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    // MARK: Question banner

    @ViewBuilder
    private func questionBanner(_ pending: PendingQuestion) -> some View {
        if pending.questions.count > 1 {
            // Task 7 note: the recipes only drive the first question; more
            // than one is an honest hand-off to the terminal.
            VStack(alignment: .leading, spacing: 8) {
                Text("Multiple questions — respond in terminal")
                    .font(.system(size: 15, weight: .medium))
                flipRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let question = pending.questions.first {
            VStack(alignment: .leading, spacing: 10) {
                Text(question.text)
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionButton(option, index: index, multiSelect: question.multiSelect)
                }

                if question.multiSelect {
                    Button("Submit") { submitMulti() }
                        .buttonStyle(.soft)
                        .disabled(multiSelection.isEmpty)
                }

                HStack(spacing: 8) {
                    TextField("Other…", text: $otherText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.secondary.opacity(0.3)))
                        .onSubmit { submitOther() }
                    Button("Send") { submitOther() }
                        .buttonStyle(.soft)
                        .disabled(otherText.isEmpty)
                }

                didNotLandNote
                flipRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func optionButton(
        _ option: PendingQuestion.Question.Option, index: Int, multiSelect: Bool
    ) -> some View {
        Button {
            if multiSelect { toggle(index) } else { submitSingle(index) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if multiSelect {
                    Image(systemName: multiSelection.contains(index)
                          ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(multiSelection.contains(index) ? Color.accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 14)).foregroundStyle(.primary)
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soft)
    }

    /// The injection watchdog: after a successful answer, if the same
    /// question is still on screen >3s later, the keystrokes didn't land.
    /// Ticks every second so the note appears without further interaction.
    private var didNotLandNote: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let injectedAt = answerInjectedAt,
               context.date.timeIntervalSince(injectedAt) > 3 {
                Text("That didn't seem to land — respond in terminal")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Notification / ended banners

    private var notificationBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.bubble").foregroundStyle(.secondary)
                Text(binding.lastNotification ?? "")
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Permission recipes ship empty (v1) — this branch is dormant
            // until a pattern is verified, but kept wired so it lights up
            // the moment one lands.
            if let message = binding.lastNotification,
               let recipe = PromptKeystrokeRecipes.permissionRecipe(forNotification: message) {
                Button("Allow") { tab.send(recipe) }
                    .buttonStyle(.soft)
            }
            flipRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var endedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text("Session ended — start ")
             + Text("claude").font(.system(size: 14, design: .monospaced))
             + Text(" in the terminal to begin a new one."))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            flipRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.3)))
                .onSubmit { sendDraft() }

            if binding.phase == .working {
                Button { tab.interruptClaude() } label: {
                    Image(systemName: "stop.circle").font(.system(size: 20))
                }
                .buttonStyle(.soft)
            } else {
                Button { sendDraft() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.soft)
                .disabled(!canSend)
            }
        }
    }

    // MARK: - Actions (every send routes through the gated TabSession API)

    private var flipRow: some View {
        BorderlessActionRow(systemImage: "terminal", title: "Respond in terminal", action: onFlipToTerminal)
    }

    /// Mirrors `TabSession.sendChatPrompt`'s gate so the send button is
    /// disabled exactly when a send would be a no-op.
    private var canSend: Bool {
        (binding.phase == .idle || binding.phase == .waitingForUser)
            && binding.conversation?.pendingQuestion == nil
            && !draft.isEmpty
    }

    private func sendDraft() {
        if tab.sendChatPrompt(draft) { draft = "" }
    }

    private func submitSingle(_ index: Int) {
        if tab.answerQuestion(selecting: [index]) { answerInjectedAt = Date() }
    }

    private func submitMulti() {
        if tab.answerQuestion(selecting: Array(multiSelection)) {
            answerInjectedAt = Date()
            multiSelection = []
        }
    }

    private func submitOther() {
        if tab.answerQuestionOther(text: otherText) {
            answerInjectedAt = Date()
            otherText = ""
        }
    }

    private func toggle(_ index: Int) {
        if multiSelection.contains(index) { multiSelection.remove(index) }
        else { multiSelection.insert(index) }
    }
}

/// A borderless, hover-lit action row — plain glyph + 13pt label, no box —
/// used for the "Respond in terminal" flip and the subagent-transcript
/// links. Hover-only wash per the sidebar's add-action rows.
private struct BorderlessActionRow: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { hovering = $0 }
    }
}
