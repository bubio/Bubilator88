import SwiftUI

struct MemoryPane: View {
  let snapshot: MachineSnapshot
  @Bindable var session: DebugSession

  @State private var addressInput: String = "0000"
  @State private var cachedRows: [Row] = []

  /// One row's worth of data, precomputed once per body so `ForEach`
  /// can key by stable address identity (not row index).
  private struct Row: Identifiable {
    let id: UInt16        // base address of the row — stable across scrolls
    let hex: String
    let ascii: String
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(cachedRows) { row in
            rowView(row)
          }
        }
        .padding(.vertical, 4)
      }
    }
    .onAppear { cachedRows = buildRows() }
    .onChange(of: snapshot.hexWindow.bytes) { _, _ in cachedRows = buildRows() }
  }

  // MARK: - Header / address input

  private var header: some View {
    HStack {
      Text("Address:")
      TextField("0000", text: $addressInput)
        .textFieldStyle(.roundedBorder)
        .frame(width: 80)
        .font(.system(.body, design: .monospaced))
        .onSubmit(applyAddress)
        .help("16-bit address to display, in hex. Accepts 1234, 0x1234 and 1234H.")

      Button("Go", action: applyAddress)
        .help("Jump to the entered address")

      Spacer()

      Stepper(
        "Rows: \(session.hexRowCount)",
        value: $session.hexRowCount,
        in: 4...64,
        step: 4
      )
      .frame(width: 160)
      .help("Number of 16-byte rows to show")
    }
    .padding(8)
  }

  private func applyAddress() {
    if let addr = DebugSession.parseHex(addressInput) {
      session.hexBaseAddress = addr
      session.refresh()
    }
  }

  // MARK: - Rows

  private func buildRows() -> [Row] {
    let bytes = snapshot.hexWindow.bytes
    let base  = snapshot.hexWindow.baseAddress
    let count = bytes.count / 16
    var out: [Row] = []
    out.reserveCapacity(count)
    for r in 0..<count {
      let start = r * 16
      let end   = min(start + 16, bytes.count)
      let slice = Array(bytes[start..<end])
      out.append(Row(
        id: base &+ UInt16(start),
        hex: slice.map { String(format: "%02X", $0) }.joined(separator: " "),
        ascii: asciiView(slice)
      ))
    }
    return out
  }

  @ViewBuilder
  private func rowView(_ row: Row) -> some View {
    HStack(spacing: 12) {
      Text(String(format: "%04X", row.id))
        .foregroundStyle(.secondary)
        .help("Address at the start of the row")
      Text(row.hex)
        .help("16 bytes from this address, read through the main Z80 bus")
      Text(row.ascii)
        .foregroundStyle(.secondary)
        .help("ASCII preview; unprintable bytes show as '.'")
    }
    .font(.system(.body, design: .monospaced))
    .padding(.horizontal, 8)
    .padding(.vertical, 1)
  }

  private func asciiView(_ bytes: [UInt8]) -> String {
    String(bytes.map { byte -> Character in
      (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    })
  }
}
