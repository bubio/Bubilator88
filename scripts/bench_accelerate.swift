// Microbenchmark: AIUpscaler の変換ループ (スカラー現行版 vs Accelerate 版)
//
// 調査の背景と結論は docs/ACCELERATE_EVALUATION.md を参照。
//
// 対象:
//   A) processMultiArrayOutput: CHW planar float(16/32) [0,1] -> BGRA8888
//   B) submitFrame / VideoRecorder.writeFrame: RGBA8888 -> BGRA8888 (A=255)
//
// 入力の乱数レンジは [-0.2, 1.2] にしてある。超解像モデルの出力は [0,1] を
// はみ出すことがあるため、両実装のクランプ挙動が一致するかまで検証する意図。
//
// ビルドと実行:
//   swiftc -O scripts/bench_accelerate.swift -o /tmp/bench_accelerate
//   /tmp/bench_accelerate          # vImage を単一スレッド (kvImageDoNotTile)
//   TILE=1 /tmp/bench_accelerate   # vImage の内部マルチスレッドを許可

import Foundation
import Accelerate
import QuartzCore

// MARK: - 計測ヘルパ

func bench(_ name: String, iterations: Int, _ body: () -> Void) -> Double {
  body()  // warmup
  var best = Double.infinity
  var total = 0.0
  for _ in 0..<iterations {
    let t0 = CACurrentMediaTime()
    body()
    let dt = (CACurrentMediaTime() - t0) * 1000.0
    best = min(best, dt)
    total += dt
  }
  let avg = total / Double(iterations)
  print(String(format: "  %-46@  avg %7.3f ms   best %7.3f ms", name as NSString, avg, best))
  return avg
}

func compare(_ label: String, _ a: [UInt8], _ b: [UInt8]) {
  precondition(a.count == b.count)
  var diff = 0
  var maxDelta = 0
  for i in 0..<a.count where a[i] != b[i] {
    diff += 1
    maxDelta = max(maxDelta, abs(Int(a[i]) - Int(b[i])))
  }
  if diff == 0 {
    print("  [一致] \(label): 全 \(a.count) バイト完全一致")
  } else {
    let pct = Double(diff) * 100.0 / Double(a.count)
    print(String(format: "  [差分] %@: %d / %d bytes (%.4f%%), 最大差 %d",
                 label as NSString, diff, a.count, pct, maxDelta))
  }
}

let vFlags = ProcessInfo.processInfo.environment["TILE"] != nil ? vImage_Flags(kvImageNoFlags) : vImage_Flags(kvImageDoNotTile)

// MARK: - テストデータ

// 2x モデルの出力想定 (640x400 -> 1280x800)
let outWidth = 1280
let outHeight = 800
let pixelCount = outWidth * outHeight
let dstBytesPerRow = outWidth * 4

// CHW planar, strides = [3*H*W, H*W, W, 1] (contiguous)
let chStride = outHeight * outWidth
let hStride = outWidth
let wStride = 1

var rng = SystemRandomNumberGenerator()
var srcF32 = [Float32](repeating: 0, count: 3 * pixelCount)
for i in 0..<srcF32.count {
  srcF32[i] = Float32.random(in: -0.2...1.2, using: &rng)
}
var srcF16 = srcF32.map { Float16($0) }

// 入力側 (640x400 RGBA)
let inWidth = 640
let inHeight = 400
var srcRGBA = [UInt8](repeating: 0, count: inWidth * inHeight * 4)
for i in 0..<srcRGBA.count { srcRGBA[i] = UInt8.random(in: 0...255, using: &rng) }

// MARK: - A-1) 現行スカラー版 (Float32)

func scalarF32(_ dst: inout [UInt8]) {
  srcF32.withUnsafeBufferPointer { buf in
    let ptr = buf.baseAddress!
    dst.withUnsafeMutableBufferPointer { dbuf in
      let bgra = dbuf.baseAddress!
      for y in 0..<outHeight {
        let yOff = y * hStride
        for x in 0..<outWidth {
          let base = yOff + x * wStride
          let r = min(255, max(0, Int(ptr[base] * 255.0 + 0.5)))
          let g = min(255, max(0, Int(ptr[base + chStride] * 255.0 + 0.5)))
          let b = min(255, max(0, Int(ptr[base + chStride * 2] * 255.0 + 0.5)))
          let di = y * dstBytesPerRow + x * 4
          bgra[di] = UInt8(b)
          bgra[di + 1] = UInt8(g)
          bgra[di + 2] = UInt8(r)
          bgra[di + 3] = 255
        }
      }
    }
  }
}

// MARK: - A-2) 現行スカラー版 (Float16)

func scalarF16(_ dst: inout [UInt8]) {
  srcF16.withUnsafeBufferPointer { buf in
    let ptr = buf.baseAddress!
    dst.withUnsafeMutableBufferPointer { dbuf in
      let bgra = dbuf.baseAddress!
      for y in 0..<outHeight {
        let yOff = y * hStride
        for x in 0..<outWidth {
          let base = yOff + x * wStride
          let r = min(255, max(0, Int(Float(ptr[base]) * 255.0 + 0.5)))
          let g = min(255, max(0, Int(Float(ptr[base + chStride]) * 255.0 + 0.5)))
          let b = min(255, max(0, Int(Float(ptr[base + chStride * 2]) * 255.0 + 0.5)))
          let di = y * dstBytesPerRow + x * 4
          bgra[di] = UInt8(b)
          bgra[di + 1] = UInt8(g)
          bgra[di + 2] = UInt8(r)
          bgra[di + 3] = 255
        }
      }
    }
  }
}

// MARK: - A-3) vImage 版 (Float32)
//
// planar float 3枚 -> planar8 3枚 -> chunky BGRA。
// alpha プレーンは 255 固定なので毎回作らず使い回す。

// 使い回しバッファ (実コードでも ensureOutputTexture 同様に一度だけ確保する想定)
var plane8R = [UInt8](repeating: 0, count: pixelCount)
var plane8G = [UInt8](repeating: 0, count: pixelCount)
var plane8B = [UInt8](repeating: 0, count: pixelCount)
var plane8A = [UInt8](repeating: 255, count: pixelCount)

func vimageF32(_ dst: inout [UInt8]) {
  srcF32.withUnsafeMutableBufferPointer { sbuf in
    let sp = sbuf.baseAddress!
    plane8R.withUnsafeMutableBufferPointer { rp in
    plane8G.withUnsafeMutableBufferPointer { gp in
    plane8B.withUnsafeMutableBufferPointer { bp in
    plane8A.withUnsafeMutableBufferPointer { ap in
    dst.withUnsafeMutableBufferPointer { dp in
      let h = vImagePixelCount(outHeight)
      let w = vImagePixelCount(outWidth)
      let srcRowBytes = hStride * MemoryLayout<Float32>.size

      // CHW の各チャネルを vImage_Buffer として見る
      var srcR = vImage_Buffer(data: sp,               height: h, width: w, rowBytes: srcRowBytes)
      var srcG = vImage_Buffer(data: sp + chStride,     height: h, width: w, rowBytes: srcRowBytes)
      var srcB = vImage_Buffer(data: sp + chStride * 2, height: h, width: w, rowBytes: srcRowBytes)

      var d8R = vImage_Buffer(data: rp.baseAddress!, height: h, width: w, rowBytes: outWidth)
      var d8G = vImage_Buffer(data: gp.baseAddress!, height: h, width: w, rowBytes: outWidth)
      var d8B = vImage_Buffer(data: bp.baseAddress!, height: h, width: w, rowBytes: outWidth)
      var d8A = vImage_Buffer(data: ap.baseAddress!, height: h, width: w, rowBytes: outWidth)

      // [0,1] -> [0,255] のスケーリングとクランプが maxFloat/minFloat で完結する
      vImageConvert_PlanarFtoPlanar8(&srcR, &d8R, 1.0, 0.0, vFlags)
      vImageConvert_PlanarFtoPlanar8(&srcG, &d8G, 1.0, 0.0, vFlags)
      vImageConvert_PlanarFtoPlanar8(&srcB, &d8B, 1.0, 0.0, vFlags)

      var out = vImage_Buffer(data: dp.baseAddress!, height: h, width: w, rowBytes: dstBytesPerRow)
      // 引数順がそのままバイト順になる: (B, G, R, A) -> BGRA
      vImageConvert_Planar8toARGB8888(&d8B, &d8G, &d8R, &d8A, &out, vFlags)
    }}}}}
  }
}

// MARK: - A-4) vImage 版 (Float16)

func vimageF16(_ dst: inout [UInt8]) {
  srcF16.withUnsafeMutableBufferPointer { sbuf in
    let sp = UnsafeMutableRawPointer(sbuf.baseAddress!)
    plane8R.withUnsafeMutableBufferPointer { rp in
    plane8G.withUnsafeMutableBufferPointer { gp in
    plane8B.withUnsafeMutableBufferPointer { bp in
    plane8A.withUnsafeMutableBufferPointer { ap in
    dst.withUnsafeMutableBufferPointer { dp in
      let h = vImagePixelCount(outHeight)
      let w = vImagePixelCount(outWidth)
      let srcRowBytes = hStride * 2
      let chByteStride = chStride * 2

      var srcR = vImage_Buffer(data: sp,                            height: h, width: w, rowBytes: srcRowBytes)
      var srcG = vImage_Buffer(data: sp + chByteStride,             height: h, width: w, rowBytes: srcRowBytes)
      var srcB = vImage_Buffer(data: sp + chByteStride * 2,         height: h, width: w, rowBytes: srcRowBytes)

      var d8R = vImage_Buffer(data: rp.baseAddress!, height: h, width: w, rowBytes: outWidth)
      var d8G = vImage_Buffer(data: gp.baseAddress!, height: h, width: w, rowBytes: outWidth)
      var d8B = vImage_Buffer(data: bp.baseAddress!, height: h, width: w, rowBytes: outWidth)
      var d8A = vImage_Buffer(data: ap.baseAddress!, height: h, width: w, rowBytes: outWidth)

      // 16F -> 8bit は [0,1] -> [0,255] 固定スケール
      vImageConvert_Planar16FtoPlanar8(&srcR, &d8R, vFlags)
      vImageConvert_Planar16FtoPlanar8(&srcG, &d8G, vFlags)
      vImageConvert_Planar16FtoPlanar8(&srcB, &d8B, vFlags)

      var out = vImage_Buffer(data: dp.baseAddress!, height: h, width: w, rowBytes: dstBytesPerRow)
      vImageConvert_Planar8toARGB8888(&d8B, &d8G, &d8R, &d8A, &out, vFlags)
    }}}}}
  }
}

// MARK: - B) RGBA -> BGRA スウィズル

func scalarSwizzle(_ dst: inout [UInt8]) {
  srcRGBA.withUnsafeBufferPointer { sbuf in
    let src = sbuf.baseAddress!
    dst.withUnsafeMutableBufferPointer { dbuf in
      let dstBase = dbuf.baseAddress!
      let stride = inWidth * 4
      for y in 0..<inHeight {
        let srcRow = src.advanced(by: y * stride)
        let dstRow = dstBase.advanced(by: y * stride)
        for x in 0..<inWidth {
          let s = srcRow.advanced(by: x * 4)
          let d = dstRow.advanced(by: x * 4)
          d[0] = s[2]
          d[1] = s[1]
          d[2] = s[0]
          d[3] = 0xFF
        }
      }
    }
  }
}

func vimageSwizzle(_ dst: inout [UInt8]) {
  srcRGBA.withUnsafeMutableBufferPointer { sbuf in
    dst.withUnsafeMutableBufferPointer { dbuf in
      let h = vImagePixelCount(inHeight)
      let w = vImagePixelCount(inWidth)
      var src = vImage_Buffer(data: sbuf.baseAddress!, height: h, width: w, rowBytes: inWidth * 4)
      var out = vImage_Buffer(data: dbuf.baseAddress!, height: h, width: w, rowBytes: inWidth * 4)
      // RGBA -> BGRA: 0->2, 1->1, 2->0, 3->3
      let map: [UInt8] = [2, 1, 0, 3]
      vImagePermuteChannels_ARGB8888(&src, &out, map, vFlags)
      // A を 0xFF で潰す (現行コードと同じ挙動にする)
      vImageOverwriteChannelsWithScalar_ARGB8888(255, &out, &out, 0x1, vFlags)
    }
  }
}

// MARK: - 実行

let iterations = 50

print("=== A) MLMultiArray (CHW planar) -> BGRA8888 : \(outWidth)x\(outHeight) ===")
var dstScalarF32 = [UInt8](repeating: 0, count: dstBytesPerRow * outHeight)
var dstVImageF32 = [UInt8](repeating: 0, count: dstBytesPerRow * outHeight)
var dstScalarF16 = [UInt8](repeating: 0, count: dstBytesPerRow * outHeight)
var dstVImageF16 = [UInt8](repeating: 0, count: dstBytesPerRow * outHeight)

let a1 = bench("Float32 scalar (現行)",  iterations: iterations) { scalarF32(&dstScalarF32) }
let a2 = bench("Float32 vImage",         iterations: iterations) { vimageF32(&dstVImageF32) }
let a3 = bench("Float16 scalar (現行)",  iterations: iterations) { scalarF16(&dstScalarF16) }
let a4 = bench("Float16 vImage",         iterations: iterations) { vimageF16(&dstVImageF16) }
print(String(format: "  -> Float32: %.2fx 高速化 / Float16: %.2fx 高速化", a1 / a2, a3 / a4))
compare("Float32 scalar vs vImage", dstScalarF32, dstVImageF32)
compare("Float16 scalar vs vImage", dstScalarF16, dstVImageF16)

print("")
print("=== B) RGBA8888 -> BGRA8888 (A=255) : \(inWidth)x\(inHeight) ===")
var dstScalarSw = [UInt8](repeating: 0, count: srcRGBA.count)
var dstVImageSw = [UInt8](repeating: 0, count: srcRGBA.count)
let b1 = bench("scalar (現行)", iterations: iterations) { scalarSwizzle(&dstScalarSw) }
let b2 = bench("vImage",        iterations: iterations) { vimageSwizzle(&dstVImageSw) }
print(String(format: "  -> %.2fx 高速化", b1 / b2))
compare("swizzle scalar vs vImage", dstScalarSw, dstVImageSw)
