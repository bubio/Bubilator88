import SwiftUI

/// Renders an 8×8 PC-8801 font glyph (one byte per row, MSB = leftmost pixel)
/// as crisp filled squares, scaled to fit its frame.
///
/// Used to print GRPH graphic-character legends on the software keyboard
/// directly from the currently-loaded `FontROM`, so the engraving always
/// matches what the emulator actually displays for that character code. No
/// external font asset is bundled — the glyph comes from the user's FONT.ROM
/// (and is blank when no font ROM is loaded, since the built-in fallback font
/// has no graphics characters).
struct FontGlyphView: View {
  /// Eight rows of 8 pixels. MSB (bit 7) is the leftmost pixel.
  let rows: [UInt8]
  var color: Color = .primary

  var body: some View {
    Canvas { context, size in
      let cell = min(size.width, size.height) / 8
      // Center the 8×8 block within the frame.
      let originX = (size.width - cell * 8) / 2
      let originY = (size.height - cell * 8) / 2
      let paint = GraphicsContext.Shading.color(color)
      for (r, bits) in rows.prefix(8).enumerated() {
        for c in 0..<8 where (bits & (0x80 >> c)) != 0 {
          let rect = CGRect(x: originX + CGFloat(c) * cell,
                            y: originY + CGFloat(r) * cell,
                            width: cell + 0.5,   // +0.5 avoids hairline
                            height: cell + 0.5)  // gaps between cells
          context.fill(Path(rect), with: paint)
        }
      }
    }
    .allowsHitTesting(false)
  }
}
