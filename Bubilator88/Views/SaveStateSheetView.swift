import SwiftUI

struct SaveStateSheetView: View {
    let viewModel: EmulatorViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text(viewModel.saveStateSheetMode == .save ? "Save State" : "Load State")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(1...10, id: \.self) { slot in
                        SlotCell(viewModel: viewModel, slot: slot) {
                            if viewModel.saveStateSheetMode == .save {
                                viewModel.saveState(slot: slot)
                            } else {
                                viewModel.loadState(slot: slot)
                            }
                            dismiss()
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 520)
    }
}

// MARK: - Slot Cell

private struct SlotCell: View {
    let viewModel: EmulatorViewModel
    let slot: Int
    let action: () -> Void

    private var hasData: Bool { viewModel.hasState(slot: slot) }
    private var isLoad: Bool { viewModel.saveStateSheetMode == .load }

    private let cellAspect: CGFloat = 160.0 / 100.0  // 8:5 like PC-8801 screen

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                // Background: thumbnail or empty placeholder
                if let thumb = viewModel.slotThumbnail(slot) {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(cellAspect, contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.black.opacity(0.7))
                        .aspectRatio(cellAspect, contentMode: .fill)
                        .overlay {
                            Text("Empty")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                }

                // Info overlay with glass background
                HStack(spacing: 4) {
                    Text("Slot \(slot)")
                        .font(.caption.bold())
                        .foregroundStyle(Color(nsColor: .labelColor))

                    if hasData {
                        Text(slotDateString)
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                        if let diskNames = slotDiskNames {
                            Spacer(minLength: 2)
                            Text(diskNames)
                                .font(.caption2.bold())
                                .foregroundStyle(Color(nsColor: .labelColor))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular.tint(.black.opacity(0.3)),
                             in: UnevenRoundedRectangle(
                                topLeadingRadius: 6, bottomLeadingRadius: 0,
                                bottomTrailingRadius: 0, topTrailingRadius: 6))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoad && !hasData)
        .opacity(isLoad && !hasData ? 0.4 : 1.0)
    }

    private var slotDateString: String {
        let path = viewModel.saveStatePath(forSlot: slot)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let date = attrs[.modificationDate] as? Date else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    private var slotDiskNames: String? {
        guard let meta = viewModel.loadSlotMeta(slot) else { return nil }
        let name0: String? = meta.drive0FileName ?? meta.drive0Name
        let name1: String? = meta.drive1FileName ?? meta.drive1Name
        var names: [String] = []
        if let n = name0, !n.isEmpty { names.append(n) }
        if let n = name1, !n.isEmpty, n != name0 { names.append(n) }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}
