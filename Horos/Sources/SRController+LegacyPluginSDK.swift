//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

// The settings of the surfaces of the fused series, which the plugin SDK of
// Horos and OsiriX declared as thirteen properties of the controller. The
// controller keeps them now as the settings of its fusion sheet; a plugin
// built for that SDK still reads and writes the properties, so each one
// answers from those settings and writes to them.
extension SRController {
    private func fusionNumber(_ key: String) -> NSNumber { blendingSettings[key] as? NSNumber ?? 0 }
    private func fusionColor(_ key: String) -> NSColor? { blendingSettings[key] as? NSColor }

    /// Writes the thirteen instance variables of that SDK from the settings of
    /// the fusion sheet.
    func copyFusionSettings() {
        fusionFirstSurfaceOfSDK = fusionFirstSurface
        fusionSecondSurfaceOfSDK = fusionSecondSurface
        fusionResolutionOfSDK = fusionResolution
        fusionFirstTransparencyOfSDK = fusionFirstTransparency
        fusionSecondTransparencyOfSDK = fusionSecondTransparency
        fusionDecimateOfSDK = fusionDecimate
        fusionSmoothOfSDK = fusionSmooth
        fusionFirstColorOfSDK = fusionFirstColor
        fusionSecondColorOfSDK = fusionSecondColor
        fusionShouldDecimateOfSDK = fusionShouldDecimate
        fusionShouldSmoothOfSDK = fusionShouldSmooth
        fusionUseFirstSurfaceOfSDK = fusionUseFirstSurface
        fusionUseSecondSurfaceOfSDK = fusionUseSecondSurface
        _fusionFirstSurface = fusionFirstSurfaceOfSDK
        _fusionSecondSurface = fusionSecondSurfaceOfSDK
        _fusionResolution = fusionResolutionOfSDK
        _fusionFirstTransparency = fusionFirstTransparencyOfSDK
        _fusionSecondTransparency = fusionSecondTransparencyOfSDK
        _fusionDecimate = fusionDecimateOfSDK
        _fusionSmooth = fusionSmoothOfSDK
        _fusionFirstColor = fusionFirstColorOfSDK
        _fusionSecondColor = fusionSecondColorOfSDK
        _fusionShouldDecimate = fusionShouldDecimateOfSDK
        _fusionShouldSmooth = fusionShouldSmoothOfSDK
        _fusionUseFirstSurface = fusionUseFirstSurfaceOfSDK
        _fusionUseSecondSurface = fusionUseSecondSurfaceOfSDK
    }

    @objc var fusionFirstSurface: Float {
        get { fusionNumber("firstSurface").floatValue }
        set {
            blendingSettings["firstSurface"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionSecondSurface: Float {
        get { fusionNumber("secondSurface").floatValue }
        set {
            blendingSettings["secondSurface"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionResolution: Float {
        get { fusionNumber("resolution").floatValue }
        set {
            blendingSettings["resolution"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionFirstTransparency: Float {
        get { fusionNumber("firstTransparency").floatValue }
        set {
            blendingSettings["firstTransparency"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionSecondTransparency: Float {
        get { fusionNumber("secondTransparency").floatValue }
        set {
            blendingSettings["secondTransparency"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionDecimate: Float {
        get { fusionNumber("decimate").floatValue }
        set {
            blendingSettings["decimate"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionSmooth: Int32 {
        get { fusionNumber("smooth").int32Value }
        set {
            blendingSettings["smooth"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionFirstColor: NSColor? {
        get { fusionColor("firstColor") }
        set {
            blendingSettings["firstColor"] = newValue
            copyFusionSettings()
        }
    }
    @objc var fusionSecondColor: NSColor? {
        get { fusionColor("secondColor") }
        set {
            blendingSettings["secondColor"] = newValue
            copyFusionSettings()
        }
    }
    @objc var fusionShouldDecimate: Bool {
        get { fusionNumber("shouldDecimate").boolValue }
        set {
            blendingSettings["shouldDecimate"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionShouldSmooth: Bool {
        get { fusionNumber("shouldSmooth").boolValue }
        set {
            blendingSettings["shouldSmooth"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionUseFirstSurface: Bool {
        get { fusionNumber("useFirstSurface").boolValue }
        set {
            blendingSettings["useFirstSurface"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }
    @objc var fusionUseSecondSurface: Bool {
        get { fusionNumber("useSecondSurface").boolValue }
        set {
            blendingSettings["useSecondSurface"] = NSNumber(value: newValue)
            copyFusionSettings()
        }
    }

    /// The surface view had a contextual menu of its tools, which this built.
    /// It has none now: the tools are on the toolbar.
    @objc(createContextualMenu) func legacyCreateContextualMenu() {
        FormerSDKFacade.inert("SRController", "-createContextualMenu", because: "the surface view has no contextual menu of tools")
    }
}
