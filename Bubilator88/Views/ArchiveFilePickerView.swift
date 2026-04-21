import SwiftUI

struct ArchiveFilePickerView: View {
    let entries: [ArchiveEntry]
    let onSelect: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Select Disk Image from Archive")
                .font(.headline)
                .padding()

            List {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack {
                            Text(entry.filename)
                            Spacer()
                            Text(formatSize(entry.data.count))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 350, minHeight: 150)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }
}
