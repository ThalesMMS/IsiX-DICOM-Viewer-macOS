//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

@objc(HorosVRInteractionGeometry)
public final class VRInteractionGeometry: NSObject {
    /// VTK consumes view-local backing pixels; NSEvent locations are window points.
    @objc(backingPoint:inView:)
    @MainActor public static func backingPoint(_ windowPoint: NSPoint, in view: NSView) -> NSPoint {
        view.convertToBacking(view.convert(windowPoint, from: nil))
    }

    /// The engine a 3D view draws with now that VTK draws nothing (#731):
    /// Metal (2) on screen, whatever was asked, and the CPU ray cast (0) in
    /// the MPR's hidden view, which reads the image without showing it.
    /// VTK's GPU mapper (1) needed an OpenGL window.
    @objc(drawnEngineFor:hidden:)
    public static func drawnEngine(for requested: Int, hidden: Bool) -> Int {
        if hidden { return requested == 2 ? 2 : 0 }
        return 2
    }

    /// The camera zoom factor of a trackpad pinch: a magnification of 0.1
    /// brings the image 10 % closer, as the 3D MPR does. Zero when the event
    /// carries nothing usable, so the caller leaves the camera alone.
    @objc(zoomFactorForMagnification:)
    public static func zoomFactor(forMagnification magnification: CGFloat) -> Double {
        let factor = 1 + Double(magnification)
        guard magnification != 0, factor.isFinite, factor > 0.1, factor < 10 else { return 0 }
        return factor
    }

    /// The camera roll, in degrees, of a trackpad rotation. NSEvent's rotation
    /// is counterclockwise in degrees; rolling the camera by it about its
    /// direction of projection turns the image with the fingers, as the 3D
    /// MPR turns its view-up vector.
    @objc(rollDegreesForRotation:)
    public static func rollDegrees(forRotation rotation: Float) -> Double {
        let degrees = Double(rotation)
        guard degrees.isFinite, degrees != 0, abs(degrees) < 180 else { return 0 }
        return degrees
    }
}
