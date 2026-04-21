import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmulatorCore

/// Instruction trace ring buffer viewer.
///
/// Pulls snapshots straight from the underlying ``Debugger`` rather
/// than from ``MachineSnapshot``, because the trace can be hundreds
/// of entries long and we don't want to republish it 7 Hz inside the
/// general snapshot. Instead the pane refreshes on demand (manual
/// button, and automatically when the emulator pauses).
///
/// Register cells that differ from the previous (older → newer)
/// entry are highlighted so Z80 state evolution is visible at a
/// glance — this was the specific feature called out during the
/// RIGLAS investigation, where a single-bit difference in register A
/// across the main and sub CPUs was the eventual root cause.
struct TracePane: View {
    @Bindable var session: DebugSession

    @State private var mainEntries: [InstructionTraceEntry] = []
    @State private var subEntries:  [InstructionTraceEntry] = []
    @State private var cachedEntries: [IndexedEntry] = []
    @State private var selectedRowID: Int?

    private var entries: [InstructionTraceEntry] {
        session.settings.traceWhichCPU == .main ? mainEntries : subEntries
    }

    private func buildIndexedEntries(_ source: [InstructionTraceEntry]) -> [IndexedEntry] {
        var out: [IndexedEntry] = []
        out.reserveCapacity(source.count)
        for i in stride(from: source.count - 1, through: 0, by: -1) {
            let prev = i > 0 ? source[i - 1] : nil
            out.append(IndexedEntry(id: i, index: i, entry: source[i], prev: prev))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if cachedEntries.isEmpty {
                ContentUnavailableView(
                    "トレースなし",
                    systemImage: "list.bullet.indent",
                    description: Text("デバッガを接続した状態でエミュレータを実行すると命令履歴がキャプチャされます。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(cachedEntries, selection: $selectedRowID) {
                    TableColumn("#") { row in
                        Text("\(row.index)")
                            .foregroundStyle(.secondary)
                            .help("リングバッファインデックス (0 = 最古の命令)")
                    }
                    .width(min: 40, ideal: 50, max: 70)

                    TableColumn("PC") { row in
                        diffCell(row.entry.pc, prev: row.prev?.pc)
                            .help("命令実行時のPC。行を選択すると逆アセンブルペインをここにピン留め。")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("AF") { row in
                        diffCell(row.entry.af, prev: row.prev?.af)
                            .help("命令実行前のAF。変化したセルはオレンジでハイライト。")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("BC") { row in
                        diffCell(row.entry.bc, prev: row.prev?.bc)
                            .help("命令実行前のBC")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("DE") { row in
                        diffCell(row.entry.de, prev: row.prev?.de)
                            .help("命令実行前のDE")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("HL") { row in
                        diffCell(row.entry.hl, prev: row.prev?.hl)
                            .help("命令実行前のHL")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("IX") { row in
                        diffCell(row.entry.ix, prev: row.prev?.ix)
                            .help("命令実行前のIX")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("IY") { row in
                        diffCell(row.entry.iy, prev: row.prev?.iy)
                            .help("命令実行前のIY")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("SP") { row in
                        diffCell(row.entry.sp, prev: row.prev?.sp)
                            .help("命令実行前のSP")
                    }
                    .width(min: 50, ideal: 56, max: 70)

                    TableColumn("Δ") { row in
                        Text(Self.deltaSummary(row.entry, prev: row.prev))
                            .foregroundStyle(Color.orange)
                            .textSelection(.enabled)
                            .help("前の命令からの変化レジスタのサマリ (旧値→新値)")
                    }
                    .width(min: 80, ideal: 180, max: 400)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .font(.system(.caption, design: .monospaced))
            }
        }
        .onAppear { refresh() }
        .onChange(of: mainEntries) { _, new in
            if session.settings.traceWhichCPU == .main { cachedEntries = buildIndexedEntries(new) }
        }
        .onChange(of: subEntries) { _, new in
            if session.settings.traceWhichCPU == .sub { cachedEntries = buildIndexedEntries(new) }
        }
        .onChange(of: selectedRowID) { _, newID in
            guard let newID, newID >= 0, newID < entries.count else { return }
            session.jumpDisasm(
                to: entries[newID].pc,
                cpu: session.settings.traceWhichCPU == .main ? .main : .sub
            )
        }
        .onChange(of: session.settings.traceWhichCPU) { _, cpu in
            selectedRowID = nil
            cachedEntries = buildIndexedEntries(cpu == .main ? mainEntries : subEntries)
        }
        .onChange(of: session.debuggerRunState) { _, newState in
            // Automatically refresh when we enter a paused state so
            // the user sees the lead-up instructions without extra
            // clicks. Running-state churn is ignored to avoid 7 Hz
            // table rebuilds.
            if session.settings.traceAutoFollow, case .paused = newState {
                refresh()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Trace").font(.headline)

            Text("\(cachedEntries.count)件")
                .foregroundStyle(.secondary)
                .font(.caption)

            Spacer()

            Picker("CPU", selection: Bindable(session.settings).traceWhichCPU) {
                ForEach(DebugSettings.TraceWhichCPU.allCases) { cpu in
                    Text(cpu.rawValue).tag(cpu)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("表示するCPUの命令履歴。MainとSubはそれぞれ1024エントリのリングバッファを持つ。")

            Toggle("Auto", isOn: Bindable(session.settings).traceAutoFollow)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("一時停止時に自動更新")

            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("トレーススナップショットを取得")

            Button {
                exportJSONL()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(cachedEntries.isEmpty)
            .help("トレースをJSONLとしてエクスポート (クロスエミュレータ比較用)")

            Button(role: .destructive) {
                if session.settings.traceWhichCPU == .main {
                    session.debugger.clearTrace()
                    mainEntries = []
                } else {
                    session.debugger.clearSubTrace()
                    subEntries = []
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("トレースバッファをクリア")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Data

    /// Wraps a trace entry with an ordering index for Identifiable
    /// so the SwiftUI `Table` has a stable id column-free.
    ///
    /// `prev` is the chronologically *earlier* entry (the one executed
    /// right before this one), used to compute per-cell diffs.
    private struct IndexedEntry: Identifiable {
        let id: Int
        let index: Int
        let entry: InstructionTraceEntry
        let prev: InstructionTraceEntry?
    }

    private func refresh() {
        let newMain = session.debugger.traceSnapshot()
        let newSub  = session.debugger.subTraceSnapshot()
        // Skip the O(n) IndexedEntry rebuild when nothing changed.
        let changed = (newMain.count != mainEntries.count || newMain.last?.pc != mainEntries.last?.pc
                    || newSub.count  != subEntries.count  || newSub.last?.pc  != subEntries.last?.pc)
        mainEntries = newMain
        subEntries  = newSub
        if changed { cachedEntries = buildIndexedEntries(entries) }
    }

    // MARK: - Diff-aware cell

    @ViewBuilder
    private func diffCell(_ value: UInt16, prev: UInt16?) -> some View {
        let changed = prev.map { $0 != value } ?? false
        Text(String(format: "%04X", value))
            .foregroundStyle(changed ? Color.orange : .primary)
            .fontWeight(changed ? .semibold : .regular)
    }

    // MARK: - Delta summary

    /// Compact human-readable summary of which registers changed
    /// between `prev` (older) and `entry` (newer). Words are shown
    /// as 4-hex; the PC-only "no-op" row (where the PC advanced by
    /// one instruction but nothing else changed) returns an empty
    /// string so the column stays visually quiet for NOP chains.
    ///
    /// Note: PC is intentionally excluded from the summary. Every
    /// instruction advances PC, so listing it in every row would
    /// drown out the interesting deltas.
    static func deltaSummary(
        _ entry: InstructionTraceEntry,
        prev: InstructionTraceEntry?
    ) -> String {
        guard let prev else { return "" }
        var parts: [String] = []
        func check16(_ name: String, _ now: UInt16, _ was: UInt16) {
            if now != was {
                parts.append(String(format: "%@:%04X→%04X", name, was, now))
            }
        }
        func check8(_ name: String, _ now: UInt8, _ was: UInt8) {
            if now != was {
                parts.append(String(format: "%@:%02X→%02X", name, was, now))
            }
        }
        check16("AF",  entry.af,  prev.af)
        check16("BC",  entry.bc,  prev.bc)
        check16("DE",  entry.de,  prev.de)
        check16("HL",  entry.hl,  prev.hl)
        check16("IX",  entry.ix,  prev.ix)
        check16("IY",  entry.iy,  prev.iy)
        check16("SP",  entry.sp,  prev.sp)
        check16("AF'", entry.af2, prev.af2)
        check16("BC'", entry.bc2, prev.bc2)
        check16("DE'", entry.de2, prev.de2)
        check16("HL'", entry.hl2, prev.hl2)
        check8("I",    entry.i,   prev.i)
        check8("R",    entry.r,   prev.r)
        return parts.joined(separator: "  ")
    }

    // MARK: - Export

    /// Write the currently displayed trace as JSONL to a user-selected
    /// file. Format matches `InstructionTraceJSONL.render(_:)` so the
    /// same file produced by another emulator can be `diff`ed directly.
    private func exportJSONL() {
        let cpuLabel = session.settings.traceWhichCPU.rawValue.lowercased()
        let panel = NSSavePanel()
        panel.title = "Export \(session.settings.traceWhichCPU.rawValue) Trace"
        panel.nameFieldStringValue = "bubilator88-trace-\(cpuLabel).jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.canCreateDirectories = true

        let currentEntries = entries
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = InstructionTraceJSONL.render(currentEntries)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                session.viewModel.showToast("Exported \(currentEntries.count) trace entries")
            } catch {
                session.viewModel.showAlert(
                    title: "Export Failed",
                    message: error.localizedDescription
                )
            }
        }
    }
}
