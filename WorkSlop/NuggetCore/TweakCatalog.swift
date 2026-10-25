import Foundation

// PORT from GoldenNugget-mobile (Nugget/Core/TweakCatalog.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// Source of truth: GoldenNugget's src/tweaks/registry.py + basic_plist_locations.py.
//
// This is the data half of the tweak port. TweakModel.swift carries the types
// (TweakSpec/TweakValue/TweakFileLocation/TweakSection/TweakKind); this file
// carries the registry array itself.

// NOTE: TweakFileLocation, TweakSection, TweakKind didefinisikan di
// TweakModel.swift agar tidak ada duplikasi.

/// Every registry-defined tweak, in the reference's own order.
///
/// Iteration order is load-bearing: the compiler merges several tweaks into
/// one plist, and GoldenNugget iterates `tweaks` in this same order, so a
/// later key wins exactly as it does upstream. Do not sort this array.
enum TweakCatalog {
    static let all: [TweakSpec] = [
        // — Liquid Glass (registry order preserved) —
        TweakSpec(
            id: "ForceSolariumFallback",
            section: .liquidGlass,
            title: "Force Solarium Fallback",
            location: .globalPreferences,
            key: "SolariumForceFallback",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "26.0",
            maxVersion: "26.99",
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Forces the older Solarium rendering path instead of the newer one. Useful for troubleshooting or for devices where the current Solarium engine misbehaves on iOS 26.",
            multiValues: nil
        ),
        TweakSpec(
            id: "IgnoreSolariumLinkedOnCheck",
            section: .liquidGlass,
            title: "Ignore Solarium Linked-On Check",
            location: .globalPreferences,
            key: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "26.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Ignores the compile-time (linked-on) SDK version check for Solarium, allowing Liquid Glass features to run that would otherwise be gated by the SDK an app was built with.",
            multiValues: nil
        ),
        TweakSpec(
            id: "ForceSolariumIntelligence",
            section: .liquidGlass,
            title: "Force Solarium Intelligence",
            location: .globalPreferences,
            key: "SolariumForceIntelligence",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Forces the experimental Solarium 'Intelligence' rendering features (adaptive, machine-driven effects) on iOS 27 where they are not enabled by default.",
            multiValues: nil
        ),
        TweakSpec(
            id: "ForceEnhancedSpeculars",
            section: .liquidGlass,
            title: "Force Enhanced Speculars",
            location: .globalPreferences,
            key: "SolariumForceEnhancedSpeculars",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Enables the enhanced specular (highlight and reflection) rendering pass that is normally only used on the most capable devices.",
            multiValues: nil
        ),
        TweakSpec(
            id: "UISolariumFallback",
            section: .liquidGlass,
            title: "UI Solarium Fallback",
            location: .globalPreferences,
            key: "UISolariumForceFallback",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Forces UIKit to use the fallback Solarium path when rendering UI. Can fix broken or glitchy system UI on some iOS 27 devices.",
            multiValues: nil
        ),
        TweakSpec(
            id: "IgnoreSolariumHardwareCheck",
            section: .liquidGlass,
            title: "Ignore Solarium Hardware Check",
            location: .globalPreferences,
            key: "com.apple.SwiftUI.IgnoreSolariumHardwareCheck",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Disables the hardware capability check for Solarium, enabling Liquid Glass effects on devices officially considered too weak.",
            multiValues: nil
        ),
        TweakSpec(
            id: "IgnoreSolariumOptOut",
            section: .liquidGlass,
            title: "Ignore Solarium Opt-Out",
            location: .globalPreferences,
            key: "com.apple.SwiftUI.IgnoreSolariumOptOut",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 999.0,
            step: 1.0,
            minVersion: "27.0",
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: "Ignores an app's explicit opt-out from Solarium, forcing Liquid Glass rendering even where the app requested the legacy appearance.",
            multiValues: nil
        ),
    ]

    /// `all` plus the daemon group carrier spec. This is what the compiler
    /// iterates — not `all` — so the launchd disabled.plist rides the same
    /// compile/apply path as the registry tweaks.
    static var allWithDaemons: [TweakSpec] {
        all + [DaemonGroups.launchdSpec]
    }
}
