import SwiftUI
import EmulatorCore

struct BreakpointPane: View {
    @Bindable var session: DebugSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            list
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Breakpoints").font(.headline)

            HStack(spacing: 6) {
                Picker("", selection: $session.newBPKind) {
                    ForEach(DebugSettings.NewBPKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .help("監視対象。Main/Sub PC = アドレスでの命令フェッチ、Mem R/W = バスアクセス、IO R/W = ポートアクセス。")

                TextField("addr (hex)", text: $session.newBPAddressText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit { session.addNewBreakpoint() }
                    .help("ブレークポイントのアドレス (16進数)。IOポートは下位1バイトのみ有効。")

                if session.newBPKind == .memW || session.newBPKind == .ioW {
                    Text("==")
                        .foregroundStyle(.secondary)
                    TextField("val", text: $session.newBPValueText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50)
                        .onSubmit { session.addNewBreakpoint() }
                        .help("バイト一致フィルタ (省略可)。設定時は書き込み値が一致した場合のみ発火。空欄で任意の書き込みに反応。")
                }

                Button("Add") { session.addNewBreakpoint() }
                    .disabled(session.newBPAddressText.isEmpty)
                    .help("現在のパラメータでブレークポイントを追加")

                Spacer()

                bulkEnableButton

                Button(role: .destructive) {
                    session.removeAllBreakpoints()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(session.debugger.breakpoints.isEmpty)
                .help("すべてのブレークポイントを削除")
            }
        }
        .padding(8)
    }

    private var list: some View {
        // Read bpVersion so SwiftUI re-renders when breakpoints change.
        // Debugger is not @Observable; this indirection is the observer hook.
        let _ = session.bpVersion
        return List {
            ForEach(session.debugger.breakpoints) { bp in
                row(bp)
            }
        }
        .listStyle(.plain)
    }

    /// Bulk enable/disable, styled like the Disassembly PINNED toggle.
    /// ON (accent background) = all BPs enabled / armed.
    /// OFF (clear background) = at least one BP disabled → click re-enables all.
    /// Reading `bpVersion` keeps the visual state in sync after per-row toggles.
    private var bulkEnableButton: some View {
        let _ = session.bpVersion
        let armed = session.allBreakpointsEnabled
        return Button {
            session.setAllBreakpointsEnabled(!armed)
        } label: {
            Image(systemName: "arrowshape.right.fill")
                .foregroundStyle(armed ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .frame(width: 20, height: 16)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(armed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(session.debugger.breakpoints.isEmpty)
        .help("すべてのブレークポイントを一括で有効/無効切替。")
    }

    @ViewBuilder
    private func row(_ bp: Breakpoint) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { bp.isEnabled },
                set: { session.setBreakpointEnabled($0, id: bp.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("有効/無効を切り替え (削除しない)")

            Text(bp.kind.displayName)
                .font(.system(.body, design: .monospaced))
                .help("ブレークポイントの対象。このアクセスが発生した時点でエミュレータが停止する。")

            if let filter = bp.valueFilter {
                Text(String(format: "== %02X", filter))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.orange)
                    .help("書き込み値がこのバイトと一致した場合のみ発火")
            }

            Spacer()

            Button(role: .destructive) {
                session.removeBreakpoint(id: bp.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("このブレークポイントを削除")
        }
    }
}
