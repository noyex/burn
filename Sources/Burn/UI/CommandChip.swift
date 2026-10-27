import AppKit
import SwiftUI

/// A shell command in monospace with a copy button.
struct CommandChip: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 6) {
                Text(command).font(.system(size: 11, design: .monospaced))
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .glass(in: Capsule(), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTip("Copy")
        .accessibilityLabel("Copy command \(command)")
    }
}
