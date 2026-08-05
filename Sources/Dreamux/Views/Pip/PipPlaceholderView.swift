import SwiftUI

/// What a pane shows while its content is out in a pip. Same shape as
/// `ContentView.appletMissingState`: 36pt tertiary glyph, secondary
/// headline, tertiary callout — so an absent pane reads as a state, not
/// as an error.
struct PipPlaceholderView: View {
    let onBringBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pip.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("In Picture in Picture")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This tab is open in a floating window.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Bring back", action: onBringBack)
                .buttonStyle(.soft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
