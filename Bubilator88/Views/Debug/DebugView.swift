import SwiftUI
import EmulatorCore

/// Root view for the Debug Window. Owns the ``DebugSession`` lifecycle
/// — starting polling on appear and detaching on disappear so the
/// emulator's hot path returns to full speed when the window is closed.
struct DebugView: View {
    @State private var session: DebugSession

    init(viewModel: EmulatorViewModel) {
        self._session = State(initialValue: DebugSession(viewModel: viewModel))
    }

    var body: some View {
        // Layout: 3-column state row on top (Disasm | Register | Breakpoints),
        // full-width TabView below for the wide tables (Memory / Trace / PIO /
        // GVRAM / Text / Audio). The CPU picker lives in the Disasm header
        // now — its scope is self-evident there, and the toolbar gets
        // a run-state badge in the principal slot instead.
        VSplitView {
            HSplitView {
                DisassemblyPane(snapshot: session.snapshot, session: session)
                    .frame(minWidth: 300, idealWidth: 360)

                RegisterPane(snapshot: session.snapshot)
                    .frame(minWidth: 220, idealWidth: 260)

                BreakpointPane(session: session)
                    .frame(minWidth: 260, idealWidth: 320)
            }
            .frame(minHeight: 260)

            TabView {
                MemoryPane(snapshot: session.snapshot, session: session)
                    .tabItem { Label("Memory", systemImage: "memorychip") }
                TracePane(session: session)
                    .tabItem { Label("Trace", systemImage: "list.bullet.indent") }
                PIOFlowPane(session: session)
                    .tabItem { Label("PIO", systemImage: "arrow.left.arrow.right") }
                GVRAMPane(session: session)
                    .tabItem { Label("GVRAM", systemImage: "photo.on.rectangle") }
                TextVRAMPane(session: session)
                    .tabItem { Label("Text", systemImage: "textformat") }
                AudioPane(session: session, viewModel: session.viewModel)
                    .tabItem { Label(String("Audio"), systemImage: "waveform") }
            }
            .frame(minHeight: 220)
        }
        .frame(minWidth: 960, minHeight: 620)
        .toolbar { toolbarContent }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                session.resume()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .disabled(!session.debugger.isPaused)
            .help("実行を再開")

            Button {
                session.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(session.debugger.isPaused)
            .help("一時停止")

            Button {
                session.stepMain()
            } label: {
                Label("Step", systemImage: "forward.frame.fill")
            }
            .disabled(!session.debugger.isPaused)
            .help("メインCPU を1命令ステップ実行")

            Button {
                session.stepSub()
            } label: {
                Label("Step Sub", systemImage: "forward.frame")
            }
            .disabled(!session.debugger.isPaused)
            .help("サブCPU を1命令ステップ実行")
        }

        ToolbarItem(placement: .principal) {
            runStateBadge
                .help("エミュレータの実行状態 (緑=実行中、オレンジ=停止中)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                session.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("マシン状態スナップショットを即時更新")
        }
    }

    /// Compact run-state + T-state indicator shown in the toolbar's
    /// principal slot.
    @ViewBuilder
    private var runStateBadge: some View {
        let state = session.debuggerRunState   // fast-polled (50 ms), not snapshot-bound
        let label = state.displayLabel
        let tStates = session.snapshot.totalTStates
        HStack(spacing: 8) {
            switch state {
            case .running:
                Label(label, systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            case .paused:
                Label(label, systemImage: "pause.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
            }
            Text("T: \(tStates)")
                .foregroundStyle(.secondary)
        }
        .font(.callout.monospaced())
    }
}
