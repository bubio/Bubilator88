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
            .help("Program counter — address of the next instruction")
          regCell("SP", word: sp)
            .help("Stack pointer; the stack grows downwards")
        }
        GridRow {
          regCell("AF", word: af, byteHigh: "A", byteLow: "F")
            .help("Accumulator (A) and flags (F). ALU results land in A.")
          regCell("BC", word: bc, byteHigh: "B", byteLow: "C")
            .help("Register pair BC. C commonly holds the port number for IN/OUT.")
        }
        GridRow {
          regCell("DE", word: de, byteHigh: "D", byteLow: "E")
            .help("Register pair DE. Commonly the source pointer for block transfer instructions.")
          regCell("HL", word: hl, byteHigh: "H", byteLow: "L")
            .help("Register pair HL. The general-purpose 16-bit address register.")
        }
        if let ix, let iy {
          GridRow {
            regCell("IX", word: ix)
              .help("Index register IX — used by (IX+d) addressing")
            regCell("IY", word: iy)
              .help("Index register IY — used by (IY+d) addressing")
          }
        }
        if let af2, let bc2 {
          GridRow {
            regCell("AF'", word: af2)
              .help("Shadow AF — exchanged by EX AF,AF'")
            regCell("BC'", word: bc2)
              .help("Shadow BC — exchanged by EXX")
          }
        }
        if let de2, let hl2 {
          GridRow {
            regCell("DE'", word: de2)
              .help("Shadow DE — exchanged by EXX")
            regCell("HL'", word: hl2)
              .help("Shadow HL — exchanged by EXX")
          }
        }
        if let i, let r {
          GridRow {
            regCell("I", byte: i)
              .help("Interrupt vector page register. In IM 2 it forms the high byte of the vector table address.")
            regCell("R", byte: r)
              .help("Memory refresh counter, incremented on every instruction fetch. Some games use it as a pseudo-random source (LD A,R).")
          }
        }
      }

      HStack(spacing: 12) {
        Text("F:").bold()
        Text(flagsString(f: UInt8(af & 0xFF)))
          .font(.system(.body, design: .monospaced))
      }
      .help("Flag register: S = sign, Z = zero, H = half carry, P = parity/overflow, N = subtract, C = carry. Uppercase means set, · means clear.")

      HStack(spacing: 12) {
        if let im {
          Text("IM \(im)")
            .help("Interrupt mode. PC-8801 games use IM 2, where the vector comes from the I register plus a byte from the bus.")
        }
        Text("IFF1=\(iff1 ? "1" : "0")")
          .help("Interrupt flip-flop 1 — maskable interrupts are accepted when set. DI clears it, EI sets it.")
        if let iff2 {
          Text("IFF2=\(iff2 ? "1" : "0")")
            .help("Interrupt flip-flop 2 — a copy of IFF1, read by LD A,I / LD A,R and during NMI handling.")
        }
        if halted {
          Text("HALTED").foregroundStyle(.orange)
            .help("Halted — waiting for an interrupt")
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
