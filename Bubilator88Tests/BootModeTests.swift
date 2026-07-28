import Testing
@testable import Bubilator88

struct BootModeTests {

  typealias BootMode = EmulatorViewModel.BootMode

  // MARK: - is8MHz

  @Test("only N88-BASIC V2 defaults to 8MHz")
  func is8MHzOnlyForN88V2() {
    #expect(BootMode.n88v2.is8MHz == true)
    #expect(BootMode.n88v1h.is8MHz == false)
    #expect(BootMode.n88v1s.is8MHz == false)
    #expect(BootMode.n.is8MHz == false)
  }

  // MARK: - dipSw1

  @Test("N-BASIC uses dipSw1 0xC2, others use 0xC3")
  func dipSw1Values() {
    #expect(BootMode.n.dipSw1 == 0xC2)
    #expect(BootMode.n88v2.dipSw1 == 0xC3)
    #expect(BootMode.n88v1h.dipSw1 == 0xC3)
    #expect(BootMode.n88v1s.dipSw1 == 0xC3)
  }

  // MARK: - dipSw2

  // Bit 3 is the boot strap and reads 0 here, meaning FDD boot. It is no longer
  // a fixed part of the mode: `Machine.applyBootStrap()` derives it at reset from
  // whether drive 0 holds a disk. These expectations used to be 0x79/0xF9/0xB9,
  // from before that automatic switch existed.
  @Test("dipSw2 encodes V1 and H flags per mode, with bit 3 defaulting to FDD boot")
  func dipSw2Values() {
    #expect(BootMode.n88v2.dipSw2 == 0x71)
    #expect(BootMode.n88v1h.dipSw2 == 0xF1)
    #expect(BootMode.n88v1s.dipSw2 == 0xB1)
    #expect(BootMode.n.dipSw2 == 0xB1)
    for mode in [BootMode.n88v2, .n88v1h, .n88v1s, .n] {
      #expect(mode.dipSw2 & 0x08 == 0, "bit 3 must default to FDD boot")
    }
  }

  // MARK: - allCases

  @Test("BootMode has 4 standard cases plus custom")
  func allCasesCount() {
    #expect(BootMode.standardCases.count == 4)
    #expect(BootMode.allCases.count == 5)
    #expect(BootMode.allCases.contains(.custom))
    #expect(!BootMode.standardCases.contains(.custom))
  }

  // MARK: - rawValue

  @Test("rawValue strings match display labels")
  func rawValues() {
    #expect(BootMode.n88v2.rawValue == "N88-BASIC V2")
    #expect(BootMode.n88v1h.rawValue == "N88-BASIC V1H")
    #expect(BootMode.n88v1s.rawValue == "N88-BASIC V1S")
    #expect(BootMode.n.rawValue == "N-BASIC")
  }

  @Test("BootMode round-trips through rawValue")
  func rawValueRoundTrip() {
    for mode in BootMode.allCases {
      #expect(BootMode(rawValue: mode.rawValue) == mode)
    }
  }
}
