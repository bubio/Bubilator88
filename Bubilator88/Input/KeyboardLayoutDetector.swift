import Carbon
import Foundation

enum KeyboardLayoutDetector {
  static func currentLayout() -> KeyboardLayout {
    let type = Int(KBGetLayoutType(Int16(LMGetKbdType())))
    return type == kKeyboardJIS ? .jis : .us
  }

  static func effectiveLayout() -> KeyboardLayout {
    let setting = Settings.shared.keyboardLayout
    return setting == .auto ? currentLayout() : setting
  }
}
