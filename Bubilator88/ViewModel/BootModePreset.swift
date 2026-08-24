import Foundation

enum BootModePreset: String, CaseIterable, Identifiable {
  case n88v2  = "N88-BASIC V2"
  case n88v1h = "N88-BASIC V1H"
  case n88v1s = "N88-BASIC V1S"
  case n      = "N-BASIC"
  case custom = "Custom"

  var id: String { rawValue }
  var displayName: String { rawValue }

  /// DIP switch values for this preset, nil for custom.
  var dipValues: (dipSw1: UInt8, dipSw2Base: UInt8)? {
    switch self {
    case .n88v2:  return (0xC3, 0x71)
    case .n88v1h: return (0xC3, 0xF1)
    case .n88v1s: return (0xC3, 0xB1)
    case .n:      return (0xC2, 0xB1)
    case .custom: return nil
    }
  }

  /// Match current DIP values to a preset (mask out bit 3 of SW2).
  static func from(dipSw1: UInt8, dipSw2Base: UInt8) -> BootModePreset {
    let sw2Masked = dipSw2Base | 0x08  // normalize bit 3 to 1 for comparison
    for preset in [n88v2, n88v1h, n88v1s, n] {
      guard let (expectedSw1, expectedSw2) = preset.dipValues else { continue }
      if dipSw1 == expectedSw1 && (expectedSw2 | 0x08) == sw2Masked {
        return preset
      }
    }
    return .custom
  }
}
