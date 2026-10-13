//
//  GlassControls.swift
//  Screendrop
//
//  Liquid Glass building blocks, ported from upstream v0.35 (CC0). Only the
//  capsule button the inspector's popovers use is here so far; upstream's
//  icon, menu and action capsules come over when something needs them.
//  Each control is one glass shape; callers group them in a
//  `GlassEffectContainer` and give each a `glassEffectID` so controls that
//  appear or leave are born out of, and melt back into, their neighbours
//  instead of fading in place.
//
//  The container's spacing must stay below the resting gap between shapes:
//  glass closer than the container spacing merges, so a wider resting gap is
//  what lets a shape settle as its own clean capsule after the morph.
//
//  A selected or prominent control is filled with the system accent
//  (`Palette.accent`, called "inked" below); every other control is clear
//  glass with label-colored glyphs.
//

import AppKit
import SwiftUI

enum GlassMetrics {
    /// Glass closer than this melts together while shapes move.
    static let containerSpacing: CGFloat = 6
    /// Resting gap between neighbouring glass shapes; wider than
    /// `containerSpacing` so settled shapes stand apart.
    static let gap: CGFloat = 8
    /// Small icon buttons in docks and floating bars.
    static let buttonSize: CGFloat = 30
    /// Compact buttons inside forms and lists.
    static let compactHeight: CGFloat = 26
    /// Primary actions, such as an inspector footer's export capsule.
    static let actionHeight: CGFloat = 34
    /// Glyph size inside a `buttonSize` control.
    static let symbolSize: CGFloat = 12
}

private extension Glass {
    /// Clear glass, accent glass when selected or prominent, or a functional tint.
    static func screendrop(isInked: Bool, tint: Color?, isEnabled: Bool) -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        } else if isInked {
            glass = glass.tint(Palette.accent.opacity(isEnabled ? 1 : 0.35))
        }
        return glass.interactive(isEnabled)
    }
}

private func glassForeground(isInked: Bool, tint: Color?, isEnabled: Bool) -> Color {
    if tint != nil { return .white.opacity(isEnabled ? 1 : 0.5) }
    if isInked { return Palette.onAccent.opacity(isEnabled ? 1 : 0.5) }
    return isEnabled ? Palette.label : Palette.disabledLabel
}

// MARK: - Buttons

/// A glass capsule holding an optional icon and a title. `isProminent` inks
/// it solid for the one primary action of a surface.
struct GlassCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = GlassMetrics.buttonSize
    var isProminent = false
    /// A functional color such as `Palette.record`; wins over `isProminent`.
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: height < 28 ? 10.5 : GlassMetrics.symbolSize - 1, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title)
                    .font(.system(size: height < 28 ? 11.5 : 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(glassForeground(isInked: isProminent, tint: tint, isEnabled: isEnabled))
            .padding(.horizontal, height < 28 ? 11 : 13)
            .frame(height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.screendrop(isInked: isProminent, tint: tint, isEnabled: isEnabled), in: .capsule)
    }
}
