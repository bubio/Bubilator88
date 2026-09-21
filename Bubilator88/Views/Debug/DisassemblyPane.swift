import SwiftUI
@_spi(Debug) import Bubilator88Core

struct DisassemblyPane: View {
  let snapshot: MachineSnapshot
  @Bindable var session: DebugSession

  private var window: MemoryWindow {
    session.focusedCPU == .main ? snapshot.mainDisasmWindow : snapshot.subDisasmWindow
  }

  private var currentPC: UInt16 {
    session.focusedCPU == .main ? snapshot.mainPC : snapshot.subPC
  }


  @State private var cachedLines: [DisassembledInstruction] = []

  /// Width of the opcode-bytes column, wide enough for the longest Z80
  /// encoding ("DD CB dd op"). Rows are laid out independently inside a
  /// LazyVStack, so this column cannot be sized from its content the way the
  /// address column is; @ScaledMetric at least keeps it in step with the text.
  @ScaledMetric(relativeTo: .body) private var opcodeColumnWidth: CGFloat = 92

  private func computeLines() -> [DisassembledInstruction] {
    let w = window
    var out: [DisassembledInstruction] = []
    var addr = w.baseAddress
    let end = w.baseAddress &+ UInt16(w.bytes.count)
    while addr < end {
      let inst = Disassembler.decode(at: addr) { w.read($0) }
      out.append(inst)
      // Stop if the next instruction would extend past the window.
      if inst.bytes.isEmpty { break }
      let next = inst.nextAddress
      if next < addr { break }  // wrap guard
      addr = next
      if !w.contains(addr) { break }
    }
    return out
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      if session.settings.disasmEnabled {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              // Stable identity: the decoder is pure and addresses
              // don't collide within a single window. Using `\.address`
              // lets SwiftUI reuse row views when the PC advances by
              // a byte or two, instead of recreating the whole list.
              ForEach(cachedLines, id: \.address) { inst in
                row(inst)
              }
            }
            .padding(.vertical, 4)
          }
          .onChange(of: currentPC) { _, _ in
            if session.disasmFollowsPC { scrollToPC(proxy) }
          }
          .onChange(of: session.disasmFollowsPC) { _, following in
            if following { scrollToPC(proxy) }
          }
          .onChange(of: cachedLines) { _, _ in
            if session.disasmFollowsPC { scrollToPC(proxy) }
          }
        }
      } else {
        disabledPlaceholder
      }
    }
    .onAppear { cachedLines = computeLines() }
    // Watch the specific window bytes rather than the full snapshot so
    // totalTStates and register changes don't trigger a re-decode.
    .onChange(of: snapshot.mainDisasmWindow.bytes) { _, _ in
      if session.focusedCPU == .main { cachedLines = computeLines() }
    }
    .onChange(of: snapshot.subDisasmWindow.bytes) { _, _ in
      if session.focusedCPU == .sub { cachedLines = computeLines() }
    }
    .onChange(of: session.focusedCPU) { _, _ in cachedLines = computeLines() }
    .onChange(of: session.disasmFollowsPC) { _, _ in cachedLines = computeLines() }
    .onChange(of: session.disasmPinnedAddress) { _, _ in cachedLines = computeLines() }
    .onChange(of: session.settings.disasmEnabled) { _, enabled in
      if enabled {
        session.refresh()   // fill the window bytes before redecoding
        cachedLines = computeLines()
      } else {
        cachedLines = []    // drop decoded rows to free memory
      }
    }
  }

  private func scrollToPC(_ proxy: ScrollViewProxy) {
    // Find the row whose address equals currentPC. If PC is mid-instruction
    // (unlikely but possible), fall back to the nearest address.
    guard !cachedLines.isEmpty else { return }
    let pc = currentPC
    let target = cachedLines.first(where: { $0.address == pc })?.address
      ?? cachedLines.first(where: { $0.address > pc })?.address
      ?? cachedLines[0].address
    // anchor .center keeps surrounding context visible on both sides.
    withAnimation(.easeInOut(duration: 0.15)) {
      proxy.scrollTo(target, anchor: .center)
    }
  }

  private var disabledPlaceholder: some View {
    VStack(spacing: 6) {
      Image(systemName: "pause.rectangle")
        .font(.largeTitle)
        .imageScale(.large)
        .foregroundStyle(.secondary)
      Text("Disassembly is off")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("Use the toggle in the header to resume")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Toggle(isOn: Bindable(session.settings).disasmEnabled) {
        Image(systemName: session.settings.disasmEnabled ? "pause.fill" : "play.fill")
      }
      .toggleStyle(.button)
      .help("Turn disassembly on or off. Off skips the memory reads and instruction decoding, which lowers the load.")

      Picker("CPU", selection: $session.focusedCPU) {
        ForEach(DebugSettings.FocusedCPU.allCases) { cpu in
          Text(cpu.rawValue).tag(cpu)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .disabled(!session.settings.disasmEnabled)
      .help("Which CPU to disassemble. Main is the Z80 running the game, Sub is the sub board Z80 running DISK.ROM.")

      Toggle(isOn: Binding(
        get: { session.disasmFollowsPC },
        set: { following in
          // Release: freeze at current PC so the user can scroll.
          if !following { session.disasmPinnedAddress = currentPC }
          session.disasmFollowsPC = following
          session.refresh()
        }
      )) {
        Image(systemName: session.disasmFollowsPC ? "pin.fill" : "pin.slash")
      }
      .toggleStyle(.button)
      .disabled(!session.settings.disasmEnabled)
      .help("Follow the PC. On pins the view to the current PC and tracks it; off keeps the view fixed.")

      Spacer()

      Text("PC=\(String(format: "%04X", currentPC))")
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private func row(_ inst: DisassembledInstruction) -> some View {
    let isPC = inst.address == currentPC
    HStack(spacing: 8) {
      // Always laid out, hidden when it does not apply, so the rows below the
      // PC do not shift sideways as it moves.
      Text("▶")
        .opacity(isPC ? 1 : 0)
        .foregroundStyle(Color.accentColor)
        .help(isPC ? "The next instruction to run, at the current PC" : "")

      // %04X is always four monospaced characters, so every row's address
      // column comes out the same width on its own.
      Text(String(format: "%04X", inst.address))
        .help("Instruction address, in hex")

      Text(byteString(inst.bytes))
        .frame(width: opcodeColumnWidth, alignment: .leading)
        .foregroundStyle(.secondary)
        .help("Opcode bytes")

      Text(inst.mnemonic)
        .help("Right-click to set a PC breakpoint")

      Spacer(minLength: 0)
    }
    .font(.system(.body, design: .monospaced))
    .padding(.horizontal, 8)
    .padding(.vertical, 1)
    .background(isPC ? Color.accentColor.opacity(0.18) : .clear)
    .contextMenu {
      Button("Add Main CPU PC Breakpoint") {
        session.debugger.add(Breakpoint(kind: .mainPC(inst.address)))
      }
      .help("Stop the main CPU when its PC reaches this address")
      Button("Add Sub CPU PC Breakpoint") {
        session.debugger.add(Breakpoint(kind: .subPC(inst.address)))
      }
      .help("Stop the sub CPU when its PC reaches this address")
    }
  }

  private func byteString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
  }
}
