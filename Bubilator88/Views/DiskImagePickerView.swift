import SwiftUI
import EmulatorCore

struct DiskImagePickerView: View {
  let images: [D88Disk]
  let onSelect: (Int) -> Void
  let onCancel: () -> Void

  private func diskTypeLabel(_ type: D88Disk.DiskType) -> String {
    switch type {
    case .twoD:  return "2D"
    case .twoDD: return "2DD"
    case .twoHD: return "2HD"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Select Disk Image")
        .font(.headline)
        .padding()

      List {
        ForEach(Array(images.enumerated()), id: \.offset) { index, disk in
          Button {
            onSelect(index)
          } label: {
            HStack {
              Text("#\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
              Text(disk.name.isEmpty ? "(unnamed)" : disk.name)
              Spacer()
              Text(diskTypeLabel(disk.diskType))
                .font(.caption)
                .foregroundStyle(.secondary)
              if disk.writeProtected {
                Image(systemName: "lock.fill")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .frame(minWidth: 300, minHeight: 150)

      HStack {
        Spacer()
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
      }
      .padding()
    }
  }
}
