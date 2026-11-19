//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Cocoa
import IsiXImaging
import IsiXPreferences

/// What the planes of the MPR read of the preferences of the process graph, each time they draw or export.
extension MPRDCMView {
    /// The annotation level of the viewers (Settings → Viewers).
    nonisolated var preferredAnnotationLevel: Int {
        PreferencesSource.process.preferences[ViewerPreferences.annotations]
    }

    /// Whether the export of the MPR takes all its views in one image.
    nonisolated var exportsAllViewsPreference: Bool {
        PreferencesSource.process.preferences[ReconstructionPreferences.exportIncludesAllViews]
    }

    /// The right button's tool is DEFAULTRIGHTTOOL itself, as the middle
    /// button's is DEFAULTMIDDLETOOL: the planes take the tool chosen in a 2D
    /// viewer's toolbar when they are pressed, those already open included.
    /// A tool the plane has not moves it (VolumeViewButtons.planeTool).
    public override var currentToolRight: ToolMode {
        get { planeButtonTool(PreferencesSource.process.preferences[ViewerPreferences.defaultRightTool], curved: false) }
        @objc(setRightTool:) set { PreferencesSource.process.preferences.set(Int(newValue.rawValue), for: ViewerPreferences.defaultRightTool) }
    }

    /// The middle button's tool, DEFAULTMIDDLETOOL, as the plane has it.
    public override var currentToolMiddle: ToolMode {
        get { planeButtonTool(Int(super.currentToolMiddle.rawValue), curved: false) }
        @objc(setMiddleTool:) set { super.currentToolMiddle = newValue }
    }

    /// The tool the press of the right or middle button gives the hidden
    /// VRView (a button past the middle one moves the plane); nil for the
    /// left button, whose tool the VRView has.
    func volumeButtonTool(of event: NSEvent) -> ToolMode? {
        switch event.type {
        case .rightMouseDown: return self.currentToolRight
        case .otherMouseDown: return event.buttonNumber == 2 ? self.currentToolMiddle : .tTranslate
        default: return nil
        }
    }
}

/// What the planes of the CPR read of the preferences of the process graph, each time they draw.
extension CPRMPRDCMView {
    /// The annotation level of the viewers (Settings → Viewers).
    nonisolated var preferredAnnotationLevel: Int {
        PreferencesSource.process.preferences[ViewerPreferences.annotations]
    }

    /// The right button's tool, DEFAULTRIGHTTOOL, as for the MPR's planes;
    /// the curved MPR's planes also have the curved path.
    public override var currentToolRight: ToolMode {
        get { planeButtonTool(PreferencesSource.process.preferences[ViewerPreferences.defaultRightTool], curved: true) }
        @objc(setRightTool:) set { PreferencesSource.process.preferences.set(Int(newValue.rawValue), for: ViewerPreferences.defaultRightTool) }
    }

    /// The middle button's tool, DEFAULTMIDDLETOOL, as the plane has it.
    public override var currentToolMiddle: ToolMode {
        get { planeButtonTool(Int(super.currentToolMiddle.rawValue), curved: true) }
        @objc(setMiddleTool:) set { super.currentToolMiddle = newValue }
    }

    /// The tool the press of the right or middle button gives the hidden
    /// VRView (a button past the middle one moves the plane); nil for the
    /// left button, whose tool the VRView has.
    func volumeButtonTool(of event: NSEvent) -> ToolMode? {
        switch event.type {
        case .rightMouseDown: return self.currentToolRight
        case .otherMouseDown: return event.buttonNumber == 2 ? self.currentToolMiddle : .tTranslate
        default: return nil
        }
    }
}

/// The tool a plane gives its right or middle button for a stored tool.
private func planeButtonTool(_ tool: Int, curved: Bool) -> ToolMode {
    ToolMode(rawValue: VolumeViewButtons.planeTool(Int16(truncatingIfNeeded: tool), curved: curved)) ?? .tTranslate
}

/// A press of the right button as a single click: a plane takes the right
/// button's double-click as two presses, since only the left button's fills
/// the window with the plane (or opens the ROI's window), and the 2D tools and
/// the hidden VRView answer a second click with Hot Keys' and 3D point actions.
func reconstructionPlanePress(_ event: NSEvent) -> NSEvent {
    guard event.type == .rightMouseDown, event.clickCount > 1 else { return event }
    return NSEvent.mouseEvent(with: .rightMouseDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                              timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                              eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure) ?? event
}
