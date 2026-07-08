import SwiftUI

/// The lime "Run" pill — starts the *plan* (the claude agent working through
/// it), as distinct from the run.toml *services* control. Shared by the
/// Workspaces rail cards and the workspace Overview so "run the plan" reads
/// identically wherever it appears.
struct RunPlanButton: View {
    var label: String = "Run plan"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(red: 0.64, green: 0.89, blue: 0.29)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Run this plan (provisions its worktree and starts claude)")
    }
}

/// Shown in the "Run plan" slot while a plan's agent is live — a spinning
/// ring (a stroked circle with a wedge cut out) + "Running" in a subtle
/// pill, so the card reads as actively worked rather than the button
/// vanishing. Non-interactive (stopping is done in the agent tab).
struct RunningIndicator: View {
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .trim(from: 0.16, to: 1.0)   // the wedge gap
                .stroke(Color.secondary,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false),
                           value: spinning)
                .onAppear { spinning = true }
            Text("Running")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("A claude agent is working this plan")
    }
}
