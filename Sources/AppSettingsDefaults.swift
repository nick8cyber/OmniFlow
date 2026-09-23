import Foundation

/// Defaults pinned by spec 00 §2.2 for a fresh install. Centralised so the
/// test target can pin them without compiling the AppKit layer (AppState).
enum AppSettingsDefaults {
    /// Edit Mode must start OFF: with the default `.automatic` style a plain
    /// dictation must never resolve into a command that overwrites the user's
    /// selection (A-P1-1).
    static let commandModeEnabled = false

    /// Manual Edit Mode modifier raw value: Option — the default toggle
    /// binding uses Command, and the two signatures must not collide (A-P2-1).
    static let commandModeManualModifierRawValue = "option"
}
