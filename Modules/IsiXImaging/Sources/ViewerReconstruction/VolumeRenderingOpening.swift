//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The presentation a volume rendering window (VR or MIP) gives a series it
/// opens on when no 3D state is saved for that series in its mode: the 2D
/// viewer's colour table and window level, then the defaults of the mode. A
/// saved state replaces what it holds. Revert Series brings the window back
/// to this presentation; the camera, the crop box and the clipping range are
/// left to Reset to Initial View.
///
/// The window opens with the 2D viewer's colour table and its window level,
/// the opacity table "Linear Table" it is made with ("Logarithmic Table" for a
/// greyscale PET series) and the shading values it is made with. The volume
/// rendering mode then gives a greyscale series "VR Muscles-Bones" and
/// "Logarithmic Inverse Table", and turns the shading on or off as the
/// preference says; the projection modes (MIP) keep the 2D viewer's table and
/// leave the shading flag, which they do not draw.
///
/// The floating 3D panel (a MIP window of its own) opens otherwise
/// (`panel(...)`): on the colour table the window is made with, not the 2D
/// viewer's.
public struct VolumeRenderingOpening: Equatable, Sendable {

    /// An opacity table of the opening; the window names each as its menu does.
    public enum OpacityTable: Equatable, Sendable {
        /// "Linear Table", the one the window is made with.
        case linear
        /// "Logarithmic Table", which a greyscale PET series opens with.
        case logarithmic
        /// "Logarithmic Inverse Table", the volume rendering mode's.
        case logarithmicInverse
    }

    /// The ambient, diffuse and specular coefficients of the shading and its
    /// specular power.
    public struct ShadingValues: Equatable, Sendable {
        public var ambient: Float
        public var diffuse: Float
        public var specular: Float
        public var specularPower: Float

        public init(ambient: Float, diffuse: Float, specular: Float, specularPower: Float) {
            self.ambient = ambient
            self.diffuse = diffuse
            self.specular = specular
            self.specularPower = specularPower
        }
    }

    /// The colour table of the volume rendering mode for a greyscale series.
    public static let volumeRenderingColourTable = "VR Muscles-Bones"

    /// The shading values a window is made with; a saved state replaces them.
    public static let shadingValues = ShadingValues(ambient: 0.15, diffuse: 0.9, specular: 0.3, specularPower: 15)

    /// The colour table the window applies.
    public let colourTable: String
    /// The opacity table the window applies after its colour table.
    public let opacityTable: OpacityTable
    /// The window level and width: the 2D viewer's.
    public let windowLevel: Float
    public let windowWidth: Float
    /// The shading on or off in the volume rendering mode; nil in the
    /// projection modes, whose opening leaves it as it is.
    public let shading: Bool?

    /// The colour table the mode gives in place of the 2D viewer's: "VR
    /// Muscles-Bones" in the volume rendering mode for a greyscale series, nil
    /// otherwise (the 2D viewer's stays).
    public static func modeColourTable(volumeRendering: Bool, isRGB: Bool) -> String? {
        volumeRendering && !isRGB ? volumeRenderingColourTable : nil
    }

    /// The opacity table the mode gives in place of the window's: "Logarithmic
    /// Inverse Table" in the volume rendering mode for a greyscale series, nil
    /// otherwise (the window's stays).
    public static func modeOpacityTable(volumeRendering: Bool, isRGB: Bool) -> OpacityTable? {
        volumeRendering && !isRGB ? .logarithmicInverse : nil
    }

    /// The shading preset of the endoscopy's own look.
    public static let endoscopyShadingPreset = "Endoscopy"

    /// The shading preset the endoscopy window applies when it opens: the one
    /// its saved state names; none when the state holds shading values, which
    /// the view has taken and a preset would replace; the endoscopy's own
    /// otherwise, as for a series without a saved state.
    public static func endoscopyShadingPreset(savedName: String?, stateHoldsShadingValues: Bool) -> String? {
        if let savedName, !savedName.isEmpty { return savedName }
        return stateHoldsShadingValues ? nil : endoscopyShadingPreset
    }

    /// The opening of a window in the volume rendering mode (`volumeRendering`)
    /// or a projection mode, on an RGB or greyscale series, a PET series or
    /// not, from a 2D viewer that shows `viewerColourTable` at
    /// `viewerWindowLevel` and `viewerWindowWidth`; `defaultShading` is the
    /// preference that turns the shading on in volume rendering.
    public init(volumeRendering: Bool, isRGB: Bool, isPET: Bool, viewerColourTable: String,
                viewerWindowLevel: Float, viewerWindowWidth: Float, defaultShading: Bool) {
        self.init(colourTable: Self.modeColourTable(volumeRendering: volumeRendering, isRGB: isRGB) ?? viewerColourTable,
                  opacityTable: Self.modeOpacityTable(volumeRendering: volumeRendering, isRGB: isRGB)
                      ?? (isPET && !isRGB ? .logarithmic : .linear),
                  windowLevel: viewerWindowLevel, windowWidth: viewerWindowWidth,
                  shading: volumeRendering ? defaultShading : nil)
    }

    private init(colourTable: String, opacityTable: OpacityTable, windowLevel: Float, windowWidth: Float, shading: Bool?) {
        self.colourTable = colourTable
        self.opacityTable = opacityTable
        self.windowLevel = windowLevel
        self.windowWidth = windowWidth
        self.shading = shading
    }

    // MARK: - The floating 3D panel

    /// The PET colour table of the preferences, which the floating 3D panel
    /// gives a greyscale PET series: "B/W Inverse" when the PET colour table
    /// mode is "B/W Inverse", otherwise the default PET table (nil when the
    /// preference has none: the panel then keeps the table it is made with).
    public static func petColourTable(clutMode: String?, defaultTable: String?) -> String? {
        clutMode == "B/W Inverse" ? "B/W Inverse" : defaultTable
    }

    /// The window level and width the floating 3D panel gives a greyscale PET
    /// series: 3 and 6 for values converted to SUV, otherwise a quarter and a
    /// half of the series' maximum.
    public static func panelPETWindow(suvConverted: Bool, maximumValue: Float) -> (level: Float, width: Float) {
        suvConverted ? (3, 6) : (maximumValue / 4, maximumValue / 2)
    }

    /// The opening of the floating 3D panel, which applies neither the 2D
    /// viewer's colour table nor the mode's tables: the colour table it is
    /// made with (`noColourTable`), "Linear Table" and the 2D viewer's window
    /// level; a greyscale PET series gets the PET colour table of the
    /// preferences (`petColourTable`, nil for none), "Logarithmic Table" and
    /// the PET window of `panelPETWindow` (`suvConverted`, `maximumValue`).
    /// The shading flag is the volume rendering mode's when the panel shows
    /// it, left as it is in a projection mode.
    public static func panel(volumeRendering: Bool, isRGB: Bool, isPET: Bool, noColourTable: String, petColourTable: String?,
                             suvConverted: Bool, maximumValue: Float, viewerWindowLevel: Float, viewerWindowWidth: Float,
                             defaultShading: Bool) -> VolumeRenderingOpening {
        let shading: Bool? = volumeRendering ? defaultShading : nil
        guard isPET && !isRGB else {
            return VolumeRenderingOpening(colourTable: noColourTable, opacityTable: .linear,
                                          windowLevel: viewerWindowLevel, windowWidth: viewerWindowWidth, shading: shading)
        }
        let window = panelPETWindow(suvConverted: suvConverted, maximumValue: maximumValue)
        return VolumeRenderingOpening(colourTable: petColourTable ?? noColourTable, opacityTable: .logarithmic,
                                      windowLevel: window.level, windowWidth: window.width, shading: shading)
    }
}
