import Foundation
@testable import OpenIslandApp

@MainActor
func resetAppModelAppearanceDefaultsForTests() {
    [
        "appearance.island.v6.rightSlot",
        "appearance.island.v6.centerLabel",
        "appearance.island.v8.settingsProfile",
        "appearance.island.v8.stateIndicator",
        "appearance.island.v8.sessionGroup",
        "appearance.island.v8.sessionSort",
        "appearance.island.v8.completedStaleThreshold",
        "appearance.island.v8.notch.rightSlot",
        "appearance.island.v8.notch.centerLabel",
        "appearance.island.v8.notch.usageDisplay",
        "appearance.island.v8.notch.stateIndicator",
        "appearance.island.v8.notch.sessionGroup",
        "appearance.island.v8.notch.sessionSort",
        "appearance.island.v8.notch.completedStaleThreshold",
        "appearance.island.v8.notch.animationSpeed",
        "appearance.island.v8.notch.windowElasticity",
        "appearance.island.v8.topBar.rightSlot",
        "appearance.island.v8.topBar.centerLabel",
        "appearance.island.v8.topBar.usageDisplay",
        "appearance.island.v8.topBar.stateIndicator",
        "appearance.island.v8.topBar.sessionGroup",
        "appearance.island.v8.topBar.sessionSort",
        "appearance.island.v8.topBar.completedStaleThreshold",
        "appearance.island.v8.topBar.animationSpeed",
        "appearance.island.v8.topBar.windowElasticity",
    ].forEach(UserDefaults.standard.removeObject(forKey:))
}

@MainActor
func updateAllIslandAppearanceProfiles(
    _ model: AppModel,
    _ update: (inout IslandAppearancePreferences) -> Void
) {
    for profile in IslandAppearanceDisplayProfile.allCases {
        model.updateAppearancePreferences(for: profile, update)
    }
}
