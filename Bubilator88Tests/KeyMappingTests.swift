import Testing
@testable import Bubilator88
import EmulatorCore

struct KeyMappingTests {

  // MARK: - Letters A-Z

  @Test("letter keys A-Z map to correct PC-8801 keys")
  func letterKeys() {
    let mappings: [(UInt16, Keyboard.Key)] = [
      (0x00, Keyboard.a), (0x0B, Keyboard.b), (0x08, Keyboard.c),
      (0x02, Keyboard.d), (0x0E, Keyboard.e), (0x03, Keyboard.f),
      (0x05, Keyboard.g), (0x04, Keyboard.h), (0x22, Keyboard.i),
      (0x26, Keyboard.j), (0x28, Keyboard.k), (0x25, Keyboard.l),
      (0x2E, Keyboard.m), (0x2D, Keyboard.n), (0x1F, Keyboard.o),
      (0x23, Keyboard.p), (0x0C, Keyboard.q), (0x0F, Keyboard.r),
      (0x01, Keyboard.s), (0x11, Keyboard.t), (0x20, Keyboard.u),
      (0x09, Keyboard.v), (0x0D, Keyboard.w), (0x07, Keyboard.x),
      (0x10, Keyboard.y), (0x06, Keyboard.z),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected,
              "keyCode 0x\(String(keyCode, radix: 16)) should map correctly")
    }
  }

  // MARK: - Numbers 0-9

  @Test("number keys 0-9 map correctly")
  func numberKeys() {
    let mappings: [(UInt16, Keyboard.Key)] = [
      (0x1D, Keyboard.key0), (0x12, Keyboard.key1), (0x13, Keyboard.key2),
      (0x14, Keyboard.key3), (0x15, Keyboard.key4), (0x17, Keyboard.key5),
      (0x16, Keyboard.key6), (0x1A, Keyboard.key7), (0x1C, Keyboard.key8),
      (0x19, Keyboard.key9),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected)
    }
  }

  // MARK: - Symbols

  @Test("symbol keys map correctly")
  func symbolKeys() {
    #expect(KeyMapping.pc88Key(for: 0x1B, options: .standard) == Keyboard.minus)
    #expect(KeyMapping.pc88Key(for: 0x18, options: .standard) == Keyboard.caret)
    #expect(KeyMapping.pc88Key(for: 0x21, options: .standard) == Keyboard.leftBracket)
    #expect(KeyMapping.pc88Key(for: 0x1E, options: .standard) == Keyboard.rightBracket)
    #expect(KeyMapping.pc88Key(for: 0x29, options: .standard) == Keyboard.semicolon)
    #expect(KeyMapping.pc88Key(for: 0x27, options: .standard) == Keyboard.colon)
    #expect(KeyMapping.pc88Key(for: 0x2B, options: .standard) == Keyboard.comma)
    #expect(KeyMapping.pc88Key(for: 0x2F, options: .standard) == Keyboard.period)
    #expect(KeyMapping.pc88Key(for: 0x2C, options: .standard) == Keyboard.slash)
    #expect(KeyMapping.pc88Key(for: 0x2A, options: .standard) == Keyboard.yen)
    #expect(KeyMapping.pc88Key(for: 0x32, options: .standard) == Keyboard.at)
  }

  // MARK: - Control keys

  @Test("control keys map correctly")
  func controlKeys() {
    #expect(KeyMapping.pc88Key(for: 0x24, options: .standard) == Keyboard.Key(1, 7))  // Return
    #expect(KeyMapping.pc88Key(for: 0x31, options: .standard) == Keyboard.space)
    #expect(KeyMapping.pc88Key(for: 0x35, options: .standard) == Keyboard.esc)
    #expect(KeyMapping.pc88Key(for: 0x33, options: .standard) == Keyboard.del)
    #expect(KeyMapping.pc88Key(for: 0x30, options: .standard) == Keyboard.tab)
    #expect(KeyMapping.pc88Key(for: 0x39, options: .standard) == Keyboard.capsLock)
  }

  // MARK: - Modifiers

  @Test("left and right shift both map to shift")
  func shiftKeys() {
    #expect(KeyMapping.pc88Key(for: 0x38, options: .standard) == Keyboard.shift)
    #expect(KeyMapping.pc88Key(for: 0x3C, options: .standard) == Keyboard.shift)
  }

  @Test("left and right control both map to ctrl")
  func ctrlKeys() {
    #expect(KeyMapping.pc88Key(for: 0x3B, options: .standard) == Keyboard.ctrl)
    #expect(KeyMapping.pc88Key(for: 0x3E, options: .standard) == Keyboard.ctrl)
  }

  @Test("left and right option both map to grph")
  func grphKeys() {
    #expect(KeyMapping.pc88Key(for: 0x3A, options: .standard) == Keyboard.grph)
    #expect(KeyMapping.pc88Key(for: 0x3D, options: .standard) == Keyboard.grph)
  }

  // MARK: - Arrow keys

  @Test("arrow keys map correctly")
  func arrowKeys() {
    #expect(KeyMapping.pc88Key(for: 0x7E, options: .standard) == Keyboard.up)
    #expect(KeyMapping.pc88Key(for: 0x7D, options: .standard) == Keyboard.down)
    #expect(KeyMapping.pc88Key(for: 0x7B, options: .standard) == Keyboard.left)
    #expect(KeyMapping.pc88Key(for: 0x7C, options: .standard) == Keyboard.right)
  }

  // MARK: - Function keys

  @Test("function keys F1-F10 map correctly")
  func functionKeys() {
    let mappings: [(UInt16, Keyboard.Key)] = [
      (0x7A, Keyboard.f1), (0x78, Keyboard.f2), (0x63, Keyboard.f3),
      (0x76, Keyboard.f4), (0x60, Keyboard.f5), (0x61, Keyboard.f6),
      (0x62, Keyboard.f7), (0x64, Keyboard.f8), (0x65, Keyboard.f9),
      (0x6D, Keyboard.f10),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected)
    }
  }

  // MARK: - Numpad

  @Test("numpad keys map correctly")
  func numpadKeys() {
    let mappings: [(UInt16, Keyboard.Key)] = [
      (0x52, Keyboard.kp0), (0x53, Keyboard.kp1), (0x54, Keyboard.kp2),
      (0x55, Keyboard.kp3), (0x56, Keyboard.kp4), (0x57, Keyboard.kp5),
      (0x58, Keyboard.kp6), (0x59, Keyboard.kp7), (0x5B, Keyboard.kp8),
      (0x5C, Keyboard.kp9),
      (0x43, Keyboard.kpMultiply), (0x45, Keyboard.kpPlus),
      (0x4E, Keyboard.kpMinus), (0x41, Keyboard.kpPeriod),
      (0x4B, Keyboard.kpDivide), (0x4C, Keyboard.kpReturn),
      (0x51, Keyboard.kpEqual),
    ]
    for (keyCode, expected) in mappings {
      #expect(KeyMapping.pc88Key(for: keyCode, options: .standard) == expected)
    }
  }

  // MARK: - Special keys

  @Test("special keys map correctly")
  func specialKeys() {
    #expect(KeyMapping.pc88Key(for: 0x73, options: .standard) == Keyboard.clr)       // Home → CLR
    #expect(KeyMapping.pc88Key(for: 0x77, options: .standard) == Keyboard.stop)      // End → STOP
    #expect(KeyMapping.pc88Key(for: 0x74, options: .standard) == Keyboard.rollUp)    // PageUp → ROLL UP
    #expect(KeyMapping.pc88Key(for: 0x79, options: .standard) == Keyboard.rollDown)  // PageDown → ROLL DOWN
    #expect(KeyMapping.pc88Key(for: 0x72, options: .standard) == Keyboard.ins)       // Help/Insert → INS
    #expect(KeyMapping.pc88Key(for: 0x75, options: .standard) == Keyboard.bs)        // ForwardDelete → BS
  }

  // MARK: - Unmapped

  @Test("unmapped keycode returns nil")
  func unmappedKeyReturnsNil() {
    #expect(KeyMapping.pc88Key(for: 0xFF, options: .standard) == nil)
    #expect(KeyMapping.pc88Key(for: 0xFE, options: .standard) == nil)
    #expect(KeyMapping.pc88Key(for: 0x50, options: .standard) == nil)
  }
}
