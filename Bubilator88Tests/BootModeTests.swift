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

    @Test("dipSw2 encodes V1 and H flags per mode")
    func dipSw2Values() {
        #expect(BootMode.n88v2.dipSw2 == 0x79)
        #expect(BootMode.n88v1h.dipSw2 == 0xF9)
        #expect(BootMode.n88v1s.dipSw2 == 0xB9)
        #expect(BootMode.n.dipSw2 == 0xB9)
    }

    // MARK: - allCases

    @Test("BootMode has exactly 4 cases")
    func allCasesCount() {
        #expect(BootMode.allCases.count == 4)
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
