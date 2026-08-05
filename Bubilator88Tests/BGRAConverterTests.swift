import Testing
import CoreML
@testable import Bubilator88

/// `AIUpscaler.BGRAConverter` replaced a hand-written scalar loop with vImage on
/// the promise that the bytes are *identical*, not merely close. These check that
/// promise against the loop's exact arithmetic, `Int(v * 255 + 0.5)` clamped to
/// 0...255, over every finite `Float16` a model can emit.
struct BGRAConverterTests {

  /// Every finite `Float16` bit pattern — 63,488 of them.
  private static let finiteFloat16s: [Float16] = (0..<65536).compactMap {
    let v = Float16(bitPattern: UInt16($0))
    return v.isFinite ? v : nil
  }

  /// What the replaced scalar loop produced for one channel value.
  private static func scalarByte(_ v: Float16) -> UInt8 {
    UInt8(min(255, max(0, Int(Float(v) * 255.0 + 0.5))))
  }

  /// Packs `values` into a [1, 3, height, width] Float16 array, each channel
  /// rotated so a pixel's three channels rarely agree.
  private static func makeArray(_ values: [Float16], width: Int, height: Int) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
                                 dataType: .float16)
    let ptr = array.dataPointer.assumingMemoryBound(to: Float16.self)
    let count = width * height
    for c in 0..<3 {
      let rotation = c * 7919  // coprime-ish with count, so channels differ
      for i in 0..<count {
        ptr[c * count + i] = values[(i + rotation) % values.count]
      }
    }
    return array
  }

  @Test("every finite Float16 converts to the same byte as the scalar loop")
  func matchesScalarLoopExhaustively() throws {
    // 256 × 248 = 63,488 — exactly one pixel per finite Float16 value.
    let width = 256, height = 248
    let values = Self.finiteFloat16s
    #expect(values.count == width * height)

    let array = try Self.makeArray(values, width: width, height: height)
    let converter = AIUpscaler.BGRAConverter()
    let raw = try #require(converter.convert(array, width: width, height: height))
    let out = raw.assumingMemoryBound(to: UInt8.self)

    let count = width * height
    var mismatches = 0
    for i in 0..<count {
      // BGRA in memory; the array is [R, G, B] by channel.
      let expected = (
        b: Self.scalarByte(values[(i + 2 * 7919) % values.count]),
        g: Self.scalarByte(values[(i + 7919) % values.count]),
        r: Self.scalarByte(values[i])
      )
      if out[i * 4] != expected.b || out[i * 4 + 1] != expected.g
        || out[i * 4 + 2] != expected.r || out[i * 4 + 3] != 255 {
        mismatches += 1
      }
    }
    #expect(mismatches == 0)
  }

  @Test("out-of-range values clamp rather than wrap")
  func clampsOutsideUnitRange() throws {
    // The model is not supposed to leave [0,1], but nothing enforces it.
    let values: [Float16] = [-4, -1, -0.5, -0.001, 0, 0.5, 1, 1.001, 2, 40]
    let width = values.count, height = 1
    let array = try Self.makeArray(values, width: width, height: height)
    let converter = AIUpscaler.BGRAConverter()
    let raw = try #require(converter.convert(array, width: width, height: height))
    let out = raw.assumingMemoryBound(to: UInt8.self)

    for i in 0..<width {
      #expect(out[i * 4 + 2] == Self.scalarByte(values[i]))
    }
  }

  @Test("reusing one converter across sizes rebuilds its buffers")
  func handlesSizeChange() throws {
    let converter = AIUpscaler.BGRAConverter()
    let values: [Float16] = [0, 0.25, 0.5, 0.75, 1, 0.125]

    for (w, h) in [(3, 2), (6, 1), (2, 3)] {
      let array = try Self.makeArray(values, width: w, height: h)
      let raw = try #require(converter.convert(array, width: w, height: h))
      let out = raw.assumingMemoryBound(to: UInt8.self)
      for i in 0..<(w * h) {
        #expect(out[i * 4 + 2] == Self.scalarByte(values[i % values.count]))
      }
    }
  }

  @Test("a non-contiguous row is declined so the caller can fall back")
  func declinesUnsupportedLayout() throws {
    // Float64 is a layout vImage has no path for here; the converter must say so
    // rather than reinterpret the bytes.
    let array = try MLMultiArray(shape: [1, 3, 2, 2], dataType: .double)
    #expect(AIUpscaler.BGRAConverter().convert(array, width: 2, height: 2) == nil)
  }
}
