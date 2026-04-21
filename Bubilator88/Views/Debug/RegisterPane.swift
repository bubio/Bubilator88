import SwiftUI
import EmulatorCore

struct RegisterPane: View {
    let snapshot: MachineSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                cpuSection(
                    title: "Main Z80",
                    pc: snapshot.mainPC, sp: snapshot.mainSP,
                    af: snapshot.mainAF, bc: snapshot.mainBC,
                    de: snapshot.mainDE, hl: snapshot.mainHL,
                    ix: snapshot.mainIX, iy: snapshot.mainIY,
                    af2: snapshot.mainAF2, bc2: snapshot.mainBC2,
                    de2: snapshot.mainDE2, hl2: snapshot.mainHL2,
                    i: snapshot.mainI, r: snapshot.mainR,
                    iff1: snapshot.mainIff1, iff2: snapshot.mainIff2,
                    im: snapshot.mainIM, halted: snapshot.mainHalted
                )

                Divider()

                cpuSection(
                    title: "Sub Z80",
                    pc: snapshot.subPC, sp: snapshot.subSP,
                    af: snapshot.subAF, bc: snapshot.subBC,
                    de: snapshot.subDE, hl: snapshot.subHL,
                    ix: snapshot.subIX, iy: snapshot.subIY,
                    af2: snapshot.subAF2, bc2: snapshot.subBC2,
                    de2: snapshot.subDE2, hl2: snapshot.subHL2,
                    i: snapshot.subI, r: snapshot.subR,
                    iff1: snapshot.subIff1, iff2: snapshot.subIff2,
                    im: snapshot.subIM, halted: snapshot.subHalted
                )

            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func cpuSection(
        title: String,
        pc: UInt16, sp: UInt16,
        af: UInt16, bc: UInt16, de: UInt16, hl: UInt16,
        ix: UInt16?, iy: UInt16?,
        af2: UInt16?, bc2: UInt16?, de2: UInt16?, hl2: UInt16?,
        i: UInt8?, r: UInt8?,
        iff1: Bool, iff2: Bool?,
        im: UInt8?, halted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    regCell("PC", word: pc)
                        .help("プログラムカウンタ — 次の命令アドレス")
                    regCell("SP", word: sp)
                        .help("スタックポインタ (下方向に伸びる)")
                }
                GridRow {
                    regCell("AF", word: af, byteHigh: "A", byteLow: "F")
                        .help("アキュムレータ(A)＋フラグ(F)。ALU演算結果はAに格納される。")
                    regCell("BC", word: bc, byteHigh: "B", byteLow: "C")
                        .help("レジスタペアBC。CはIN/OUTのポート番号によく使われる。")
                }
                GridRow {
                    regCell("DE", word: de, byteHigh: "D", byteLow: "E")
                        .help("レジスタペアDE。ブロック転送命令の送り元ポインタによく使われる。")
                    regCell("HL", word: hl, byteHigh: "H", byteLow: "L")
                        .help("レジスタペアHL。汎用の16ビットアドレスレジスタ。")
                }
                if let ix, let iy {
                    GridRow {
                        regCell("IX", word: ix)
                            .help("インデックスレジスタIX — (IX+d)アドレッシングで使用")
                        regCell("IY", word: iy)
                            .help("インデックスレジスタIY — (IY+d)アドレッシングで使用")
                    }
                }
                if let af2, let bc2 {
                    GridRow {
                        regCell("AF'", word: af2)
                            .help("シャドウAF — EX AF,AF' で交換")
                        regCell("BC'", word: bc2)
                            .help("シャドウBC — EXX で交換")
                    }
                }
                if let de2, let hl2 {
                    GridRow {
                        regCell("DE'", word: de2)
                            .help("シャドウDE — EXX で交換")
                        regCell("HL'", word: hl2)
                            .help("シャドウHL — EXX で交換")
                    }
                }
                if let i, let r {
                    GridRow {
                        regCell("I", byte: i)
                            .help("割り込みベクタページレジスタ。IM 2ではベクタテーブルアドレスの上位バイトを形成。")
                        regCell("R", byte: r)
                            .help("メモリリフレッシュカウンタ。命令フェッチごとに自動インクリメント。擬似乱数として使うゲームもある (LD A,R)。")
                    }
                }
            }

            HStack(spacing: 12) {
                Text("F:").bold()
                Text(flagsString(f: UInt8(af & 0xFF)))
                    .font(.system(.body, design: .monospaced))
            }
            .help("フラグレジスタ: S=符号, Z=ゼロ, H=半桁キャリ, P=パリティ/オーバーフロー, N=減算, C=キャリ。大文字=セット、·=クリア。")

            HStack(spacing: 12) {
                if let im {
                    Text("IM \(im)")
                        .help("割り込みモード。PC-8801のゲームはIM 2を使用し、割り込みベクタはIレジスタ+バスバイトで決まる。")
                }
                Text("IFF1=\(iff1 ? "1" : "0")")
                    .help("割り込みフリップフロップ1 — 1のとき可マスク割り込みを受け付ける。DIでクリア、EIでセット。")
                if let iff2 {
                    Text("IFF2=\(iff2 ? "1" : "0")")
                        .help("割り込みフリップフロップ2 — IFF1のコピー。LD A,I / LD A,R およびNMI処理で参照。")
                }
                if halted {
                    Text("HALTED").foregroundStyle(.orange)
                        .help("HALT状態 — 割り込み待ち")
                }
            }
            .font(.system(.callout, design: .monospaced))
        }
    }

    // MARK: - Helpers

    private func regCell(_ name: String, word: UInt16, byteHigh: String? = nil, byteLow: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text("\(name):").bold().frame(width: 36, alignment: .trailing)
            Text(String(format: "%04X", word))
                .font(.system(.body, design: .monospaced))
            if let byteHigh, let byteLow {
                Text("(\(byteHigh)=\(String(format: "%02X", word >> 8)) \(byteLow)=\(String(format: "%02X", word & 0xFF)))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func regCell(_ name: String, byte: UInt8) -> some View {
        HStack(spacing: 4) {
            Text("\(name):").bold().frame(width: 36, alignment: .trailing)
            Text(String(format: "%02X", byte))
                .font(.system(.body, design: .monospaced))
        }
    }

    /// Format the F register as `S Z - H - P N C`, with set bits in
    /// uppercase and clear bits as `·`. Bits 5/3 are undocumented and
    /// shown as `-` to keep the display readable.
    private func flagsString(f: UInt8) -> String {
        let labels: [Character] = ["S", "Z", "-", "H", "-", "P", "N", "C"]
        return String((0..<8).map { i -> Character in
            let bit = (f >> (7 - i)) & 1
            if labels[i] == "-" { return "-" }
            return bit == 1 ? labels[i] : "·"
        })
    }
}
