import Testing
@testable import Bubilator88

struct RenderingHelperTests {

    // MARK: - port52BackgroundColor

    @Test("all bits off produces black")
    func port52AllOff() {
        let c = EmulatorViewModel.port52BackgroundColor(0x00)
        #expect(c.r == 0x00)
        #expect(c.g == 0x00)
        #expect(c.b == 0x00)
    }

    @Test("bit 0x20 enables red")
    func port52RedOnly() {
        let c = EmulatorViewModel.port52BackgroundColor(0x20)
        #expect(c.r == 0xFF)
        #expect(c.g == 0x00)
        #expect(c.b == 0x00)
    }

    @Test("bit 0x40 enables green")
    func port52GreenOnly() {
        let c = EmulatorViewModel.port52BackgroundColor(0x40)
        #expect(c.r == 0x00)
        #expect(c.g == 0xFF)
        #expect(c.b == 0x00)
    }

    @Test("bit 0x10 enables blue")
    func port52BlueOnly() {
        let c = EmulatorViewModel.port52BackgroundColor(0x10)
        #expect(c.r == 0x00)
        #expect(c.g == 0x00)
        #expect(c.b == 0xFF)
    }

    @Test("red + green = 0x60")
    func port52RedGreen() {
        let c = EmulatorViewModel.port52BackgroundColor(0x60)
        #expect(c.r == 0xFF)
        #expect(c.g == 0xFF)
        #expect(c.b == 0x00)
    }

    @Test("red + blue = 0x30")
    func port52RedBlue() {
        let c = EmulatorViewModel.port52BackgroundColor(0x30)
        #expect(c.r == 0xFF)
        #expect(c.g == 0x00)
        #expect(c.b == 0xFF)
    }

    @Test("green + blue = 0x50")
    func port52GreenBlue() {
        let c = EmulatorViewModel.port52BackgroundColor(0x50)
        #expect(c.r == 0x00)
        #expect(c.g == 0xFF)
        #expect(c.b == 0xFF)
    }

    @Test("all color bits = 0x70 produces white")
    func port52AllColors() {
        let c = EmulatorViewModel.port52BackgroundColor(0x70)
        #expect(c.r == 0xFF)
        #expect(c.g == 0xFF)
        #expect(c.b == 0xFF)
    }

    @Test("irrelevant bits (0x8F) are ignored, result is black")
    func port52IgnoresIrrelevantBits() {
        let c = EmulatorViewModel.port52BackgroundColor(0x8F)
        #expect(c.r == 0x00)
        #expect(c.g == 0x00)
        #expect(c.b == 0x00)
    }

    @Test("0xFF has all color bits set, produces white")
    func port52AllBitsSet() {
        let c = EmulatorViewModel.port52BackgroundColor(0xFF)
        #expect(c.r == 0xFF)
        #expect(c.g == 0xFF)
        #expect(c.b == 0xFF)
    }
}
