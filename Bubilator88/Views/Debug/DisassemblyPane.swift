import SwiftUI
import EmulatorCore

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
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("逆アセンブル停止中")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("ヘッダのトグルで再開")
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
            .help("逆アセンブルON/OFF。OFF時はメモリ読込と命令デコードをスキップして負荷を下げる。")

            Picker("CPU", selection: $session.focusedCPU) {
                ForEach(DebugSettings.FocusedCPU.allCases) { cpu in
                    Text(cpu.rawValue).tag(cpu)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .disabled(!session.settings.disasmEnabled)
            .help("逆アセンブル対象のCPU。Main = ゲーム実行Z80、Sub = サブボードのDISK.ROM Z80。")

            Button {
                if session.disasmFollowsPC {
                    // Release: freeze at current PC so the user can scroll.
                    session.disasmPinnedAddress = currentPC
                    session.disasmFollowsPC = false
                } else {
                    session.disasmFollowsPC = true
                }
                session.refresh()
            } label: {
                Image(systemName: session.disasmFollowsPC ? "pin.fill" : "pin.slash")
                    .foregroundStyle(session.disasmFollowsPC ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                    .frame(width: 20, height: 16)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(session.disasmFollowsPC ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!session.settings.disasmEnabled)
            .help("PC追従 ON/OFF。ONで現在PCにピン留めして追従、OFFで固定表示。")

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
            Text(isPC ? "▶" : " ")
                .frame(width: 12)
                .foregroundStyle(isPC ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .help(isPC ? "次に実行される命令 (現在のPC)" : "")

            Text(String(format: "%04X", inst.address))
                .frame(width: 44, alignment: .trailing)
                .help("命令アドレス (16進数)")

            Text(byteString(inst.bytes))
                .frame(width: 92, alignment: .leading)
                .foregroundStyle(.secondary)
                .help("オペコードバイト列")

            Text(inst.mnemonic)
                .help("右クリックでPCブレークポイントを設定")

            Spacer(minLength: 0)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(isPC ? Color.accentColor.opacity(0.18) : .clear)
        .contextMenu {
            Button("メインCPU PC ブレークポイントを追加") {
                session.debugger.add(Breakpoint(kind: .mainPC(inst.address)))
            }
            .help("PCがこのアドレスに達したときメインCPUを停止")
            Button("サブCPU PC ブレークポイントを追加") {
                session.debugger.add(Breakpoint(kind: .subPC(inst.address)))
            }
            .help("PCがこのアドレスに達したときサブCPUを停止")
        }
    }

    private func byteString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
