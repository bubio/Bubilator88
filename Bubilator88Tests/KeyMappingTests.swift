import Testing
@testable import Bubilator88
import Bubilator88Core

struct KeyMappingTests {

  // MARK: - Letters A-Z

  @Test("letter keys A-Z map to correct PC-8801 keys")
  func letterKeys() {
    let mappings: [(UInt16, PC88Key)] = [
      (0x00, PC88Key.a), (0x0B, PC88Key.b), (0x08, PC88Key.c),
      (0x02, PC88Key.d), (0x0E, PC88Key.e), (0x03, PC88Key.f),
      (0x05, PC88Key.g), (0x04, PC88Key.h), (0x22, PC88Key.i),
      (0x26, PC88Key.j), (0x28, PC88Key.k), (0x25, PC88Key.l),
      (0x2E, PC88Key.m), (0x2D, PC88Key.n), (0x1F, PC88Key.o),
      (0x23, PC88Key.p), (0x0C, PC88Key.q), (0x0F, PC88Key.r),
      (0x01, PC88Key.s), (0x11, PC88Key.t), (0x20, PC88Key.u),
      (0x09, PC88Key.v), (0x0D, PC88Key.w), (0x07, PC88Key.x),
      (0x10, PC88Key.y), (0x06, PC88Key.z),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected,
              "keyCode 0x\(String(keyCode, radix: 16)) should map correctly")
    }
  }

  // MARK: - Numbers 0-9

  @Test("number keys 0-9 map correctly")
  func numberKeys() {
    let mappings: [(UInt16, PC88Key)] = [
      (0x1D, PC88Key.key0), (0x12, PC88Key.key1), (0x13, PC88Key.key2),
      (0x14, PC88Key.key3), (0x15, PC88Key.key4), (0x17, PC88Key.key5),
      (0x16, PC88Key.key6), (0x1A, PC88Key.key7), (0x1C, PC88Key.key8),
      (0x19, PC88Key.key9),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected)
    }
  }

  // MARK: - Symbols

  @Test("symbol keys map correctly")
  func symbolKeys() {
    #expect(KeyMapping.pc88Key(for: 0x1B, options: .standard) == PC88Key.minus)
    #expect(KeyMapping.pc88Key(for: 0x18, options: .standard) == PC88Key.caret)
    #expect(KeyMapping.pc88Key(for: 0x21, options: .standard) == PC88Key.leftBracket)
    #expect(KeyMapping.pc88Key(for: 0x1E, options: .standard) == PC88Key.rightBracket)
    #expect(KeyMapping.pc88Key(for: 0x29, options: .standard) == PC88Key.semicolon)
    #expect(KeyMapping.pc88Key(for: 0x27, options: .standard) == PC88Key.colon)
    #expect(KeyMapping.pc88Key(for: 0x2B, options: .standard) == PC88Key.comma)
    #expect(KeyMapping.pc88Key(for: 0x2F, options: .standard) == PC88Key.period)
    #expect(KeyMapping.pc88Key(for: 0x2C, options: .standard) == PC88Key.slash)
    #expect(KeyMapping.pc88Key(for: 0x2A, options: .standard) == PC88Key.yen)
    #expect(KeyMapping.pc88Key(for: 0x32, options: .standard) == PC88Key.at)
  }

  // MARK: - Control keys

  @Test("control keys map correctly")
  func controlKeys() {
    #expect(KeyMapping.pc88Key(for: 0x24, options: .standard) == PC88Key(1, 7))  // Return
    #expect(KeyMapping.pc88Key(for: 0x31, options: .standard) == PC88Key.space)
    #expect(KeyMapping.pc88Key(for: 0x35, options: .standard) == PC88Key.esc)
    #expect(KeyMapping.pc88Key(for: 0x33, options: .standard) == PC88Key.del)
    #expect(KeyMapping.pc88Key(for: 0x30, options: .standard) == PC88Key.tab)
    #expect(KeyMapping.pc88Key(for: 0x39, options: .standard) == PC88Key.capsLock)
  }

  // MARK: - Modifiers

  @Test("left and right shift both map to shift")
  func shiftKeys() {
    #expect(KeyMapping.pc88Key(for: 0x38, options: .standard) == PC88Key.shift)
    #expect(KeyMapping.pc88Key(for: 0x3C, options: .standard) == PC88Key.shift)
  }

  @Test("left and right control both map to ctrl")
  func ctrlKeys() {
    #expect(KeyMapping.pc88Key(for: 0x3B, options: .standard) == PC88Key.ctrl)
    #expect(KeyMapping.pc88Key(for: 0x3E, options: .standard) == PC88Key.ctrl)
  }

  @Test("left and right option both map to grph")
  func grphKeys() {
    #expect(KeyMapping.pc88Key(for: 0x3A, options: .standard) == PC88Key.grph)
    #expect(KeyMapping.pc88Key(for: 0x3D, options: .standard) == PC88Key.grph)
  }

  // MARK: - Arrow keys

  @Test("arrow keys map correctly")
  func arrowKeys() {
    #expect(KeyMapping.pc88Key(for: 0x7E, options: .standard) == PC88Key.up)
    #expect(KeyMapping.pc88Key(for: 0x7D, options: .standard) == PC88Key.down)
    #expect(KeyMapping.pc88Key(for: 0x7B, options: .standard) == PC88Key.left)
    #expect(KeyMapping.pc88Key(for: 0x7C, options: .standard) == PC88Key.right)
  }

  // MARK: - Function keys

  @Test("function keys F1-F10 map correctly")
  func functionKeys() {
    let mappings: [(UInt16, PC88Key)] = [
      (0x7A, PC88Key.f1), (0x78, PC88Key.f2), (0x63, PC88Key.f3),
      (0x76, PC88Key.f4), (0x60, PC88Key.f5), (0x61, PC88Key.f6),
      (0x62, PC88Key.f7), (0x64, PC88Key.f8), (0x65, PC88Key.f9),
      (0x6D, PC88Key.f10),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected)
    }
  }

  // MARK: - Numpad

  @Test("numpad keys map correctly")
  func numpadKeys() {
    let mappings: [(UInt16, PC88Key)] = [
      (0x52, PC88Key.kp0), (0x53, PC88Key.kp1), (0x54, PC88Key.kp2),
      (0x55, PC88Key.kp3), (0x56, PC88Key.kp4), (0x57, PC88Key.kp5),
      (0x58, PC88Key.kp6), (0x59, PC88Key.kp7), (0x5B, PC88Key.kp8),
      (0x5C, PC88Key.kp9),
      (0x43, PC88Key.kpMultiply), (0x45, PC88Key.kpPlus),
      (0x4E, PC88Key.kpMinus), (0x41, PC88Key.kpPeriod),
      (0x4B, PC88Key.kpDivide), (0x4C, PC88Key.kpReturn),
      (0x51, PC88Key.kpEqual),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected)
    }
  }

  // MARK: - Special keys

  @Test("special keys map correctly")
  func specialKeys() {
    #expect(KeyMapping.pc88Key(for: 0x73, options: .standard) == PC88Key.clr)       // Home → CLR
    #expect(KeyMapping.pc88Key(for: 0x77, options: .standard) == PC88Key.stop)      // End → STOP
    #expect(KeyMapping.pc88Key(for: 0x74, options: .standard) == PC88Key.rollUp)    // PageUp → ROLL UP
    #expect(KeyMapping.pc88Key(for: 0x79, options: .standard) == PC88Key.rollDown)  // PageDown → ROLL DOWN
    #expect(KeyMapping.pc88Key(for: 0x72, options: .standard) == PC88Key.ins)       // Help/Insert → INS
    #expect(KeyMapping.pc88Key(for: 0x75, options: .standard) == PC88Key.bs)        // ForwardDelete → BS
  }

  // MARK: - Unmapped

  @Test("unmapped keycode returns nil")
  func unmappedKeyReturnsNil() {
    #expect(KeyMapping.pc88Key(for: 0xFF, options: .standard) == nil)
    #expect(KeyMapping.pc88Key(for: 0xFE, options: .standard) == nil)
    #expect(KeyMapping.pc88Key(for: 0x50, options: .standard) == nil)
  }
}
