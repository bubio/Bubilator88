import Testing
@testable import Bubilator88
import EmulatorCore

struct EmulatorViewModelTests {

    @Test("attribute graphics ignore stale attrs when text display is disabled")
    func attributeGraphAttributesNeutralizedWhenTextDisplayDisabled() {
        let attrData = Array(repeating: UInt8(0xFF), count: 80 * 25)

        let result = EmulatorViewModel.attributeGraphAttributes(
            from: attrData,
            textDisplayMode: .disabled,
            textRows: 25,
            reverseDisplay: false
        )

        #expect(result.count == 80 * 25)
        #expect(result[0] == 0xE0)
        #expect(result[79] == 0xE0)
    }

    @Test("attribute graphics keep attrs in attributes-only mode")
    func attributeGraphAttributesPreserveAttributesOnlyMode() {
        var attrData = Array(repeating: UInt8(0xE0), count: 80 * 25)
        attrData[0] = 0xE1

        let result = EmulatorViewModel.attributeGraphAttributes(
            from: attrData,
            textDisplayMode: .attributesOnly,
            textRows: 25,
            reverseDisplay: false
        )

        #expect(result == attrData)
    }

    @Test("attribute graphics keep reverse default when display is disabled")
    func attributeGraphAttributesCarryReverseDisplayIntoNeutralState() {
        let result = EmulatorViewModel.attributeGraphAttributes(
            from: [],
            textDisplayMode: .disabled,
            textRows: 20,
            reverseDisplay: true
        )

        #expect(result.count == 80 * 20)
        #expect(result[0] == 0xE1)
    }

    @Test("debug text toggle suppresses overlay rendering")
    func effectiveTextDisplayEnabledRespectsDebugToggle() {
        #expect(
            EmulatorViewModel.effectiveTextDisplayEnabled(
                busTextDisplayEnabled: true,
                debugTextLayerEnabled: true
            ) == true
        )
        #expect(
            EmulatorViewModel.effectiveTextDisplayEnabled(
                busTextDisplayEnabled: true,
                debugTextLayerEnabled: false
            ) == false
        )
        #expect(
            EmulatorViewModel.effectiveTextDisplayEnabled(
                busTextDisplayEnabled: false,
                debugTextLayerEnabled: true
            ) == false
        )
    }

    @Test("color graphics off forces render palette index 0 to black")
    func effectiveRenderPaletteForcesBlackBackgroundWhenColorGraphicsOff() {
        let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
            (b: 0, r: 7, g: 0), // palette 0 = red
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
        ]

        let palette = EmulatorViewModel.effectiveRenderPalette(
            busPalette: busPalette,
            graphicsColorMode: true,
            graphicsDisplayEnabled: false,
            analogPalette: false,
            borderColor: 0x70
        )

        #expect(palette[0].r == 0x00)
        #expect(palette[0].g == 0x00)
        #expect(palette[0].b == 0x00)
    }

    @Test("graphics display palette 0 remains programmable when color graphics are visible")
    func effectiveRenderPalettePreservesPaletteWhenGraphicsVisible() {
        let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
            (b: 7, r: 0, g: 7),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
        ]

        let palette = EmulatorViewModel.effectiveRenderPalette(
            busPalette: busPalette,
            graphicsColorMode: true,
            graphicsDisplayEnabled: true,
            analogPalette: false,
            borderColor: 0x00
        )

        #expect(palette[0].r == 0x00)
        #expect(palette[0].g == 0xFF)
        #expect(palette[0].b == 0xFF)
    }

    @Test("attribute graphics use port 0x52 background for palette entry 0")
    func effectiveRenderPaletteUsesPort52BackgroundOutsideHiColor() {
        let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
            (b: 7, r: 7, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
        ]

        let palette = EmulatorViewModel.effectiveRenderPalette(
            busPalette: busPalette,
            graphicsColorMode: false,
            graphicsDisplayEnabled: true,
            analogPalette: false,
            borderColor: 0x50
        )

        #expect(palette[0].r == 0x00)
        #expect(palette[0].g == 0xFF)
        #expect(palette[0].b == 0xFF)
    }

    @Test("hi-color text keeps programmable background but fixed digital foreground colors")
    func effectiveTextPaletteUsesProgrammableBackgroundAndFixedDigitalForegroundInHiColor() {
        let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
            (b: 7, r: 7, g: 0), // programmable magenta
            (b: 0, r: 0, g: 0), // would be black if we incorrectly used programmable colors
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
        ]

        let palette = EmulatorViewModel.effectiveTextPalette(
            busPalette: busPalette,
            graphicsColorMode: true,
            analogPalette: false,
            borderColor: 0x00
        )

        #expect(palette[0].r == 0xFF)
        #expect(palette[0].g == 0x00)
        #expect(palette[0].b == 0xFF)
        #expect(palette[1].r == 0x00)
        #expect(palette[1].g == 0x00)
        #expect(palette[1].b == 0xFF)
    }

    @Test("analog attribute text keeps programmable palette")
    func effectiveTextPaletteUsesProgrammablePaletteInAnalogAttributeMode() {
        let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
            (b: 7, r: 0, g: 7),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
            (b: 0, r: 0, g: 0),
        ]

        let palette = EmulatorViewModel.effectiveTextPalette(
            busPalette: busPalette,
            graphicsColorMode: false,
            analogPalette: true,
            borderColor: 0x00
        )

        #expect(palette[0].r == 0x00)
        #expect(palette[0].g == 0x00)
        #expect(palette[0].b == 0x00)
        #expect(palette[1].r == 0x00)
        #expect(palette[1].g == 0x00)
        #expect(palette[1].b == 0x00)
    }
}
