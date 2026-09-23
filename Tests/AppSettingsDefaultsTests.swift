import Foundation

/// Pins the fresh-install defaults from spec 00 §2.2 (audit A-P1-1 / A-P2-1).
/// AppState reads `UserDefaults` through these constants, so flipping a
/// default in production code breaks this suite.
enum AppSettingsDefaultsTests {
    static func run() {
        testCommandModeIsDisabledByDefault()
        testManualModifierDefaultsToOption()
    }

    private static func testCommandModeIsDisabledByDefault() {
        expectEqual(AppSettingsDefaults.commandModeEnabled, false,
                    "Edit Mode must start OFF: a fresh install must never let a plain dictation overwrite the selection")
    }

    private static func testManualModifierDefaultsToOption() {
        expectEqual(AppSettingsDefaults.commandModeManualModifierRawValue, "option",
                    "manual Edit Mode modifier defaults to Option (Command collides with the default toggle binding)")
    }
}
