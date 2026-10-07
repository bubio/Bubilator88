import SwiftUI

struct SaveStateSheetView: View {
  let viewModel: EmulatorViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var entries: [SaveSlotEntry] = []
  @State private var query = ""
  @State private var sort: SaveSlotSort = .number

  private let columns = [
    GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)
  ]

  private var isSave: Bool { viewModel.saveStateSheetMode == .save }

  private var sections: [SaveSlotSection] {
    SaveSlotList.sections(
      entries: entries, query: query, sort: sort,
      hidesEmpty: !isSave, currentGame: viewModel.currentGameName)
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(isSave ? "Save State" : "Load State")
        .font(.headline)
        .padding(.top, 16)
        .padding(.bottom, 12)

      HStack(spacing: 8) {
        Picker("Sort", selection: $sort) {
          Text("Slot Number").tag(SaveSlotSort.number)
          Text("Newest First").tag(SaveSlotSort.recent)
          Text("Oldest First").tag(SaveSlotSort.oldest)
          Text("By Game").tag(SaveSlotSort.game)
          if isSave {
            Text("Empty Slots First").tag(SaveSlotSort.emptyFirst)
          }
        }
        .labelsHidden()
        .fixedSize()
        TextField("Search", text: $query)
          .textFieldStyle(.roundedBorder)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)

      Divider()

      ScrollView {
        if sections.isEmpty {
          Text("No Matching States")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(sections, id: \.title) { section in
            if sort == .game {
              Text(section.title ?? String(localized: "Other"))
                .font(.subheadline.bold())
                .lineLimit(1)
                .truncationMode(.middle)
            }
            LazyVGrid(columns: columns, spacing: 12) {
              ForEach(section.slots, id: \.slot) { entry in
                SlotCell(viewModel: viewModel, entry: entry) {
                  if isSave {
                    viewModel.saveState(slot: entry.slot)
                  } else {
                    viewModel.loadState(slot: entry.slot)
                  }
                  dismiss()
                }
              }
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
    .onAppear { entries = viewModel.saveSlotEntries() }
    .onChange(of: viewModel.saveStateRevision) { entries = viewModel.saveSlotEntries() }
  }
}

// MARK: - Slot Cell

private struct SlotCell: View {
  let viewModel: EmulatorViewModel
  let entry: SaveSlotEntry
  let action: () -> Void

  private var slot: Int { entry.slot }
  private var hasData: Bool { !entry.isEmpty }
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
    guard let date = entry.modified else { return "" }
    return DateFormatter.stable(pattern: "MM/dd HH:mm").string(from: date)
  }

  private var slotDiskNames: String? {
    entry.diskNames.isEmpty ? nil : entry.diskNames.joined(separator: ", ")
  }
}
