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

/// The layout of the window: the full screen (its window, the window and content view it replaced, the tiling, image and frames to restore), the standard frame of the zoom button and the name of the saved layout of the viewers.
final class ViewerWindowLayoutState: @unchecked Sendable {
    var windowsStateName: String?
    var FullScreenOn: Bool = false
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var FullScreenWindow: NSWindow?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var StartingWindow: NSWindow?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var contentView: NSView?
    var standardRect: NSRect = .zero
    var previousFrameRect: NSRect = .zero
    var windowFrameToRestore: NSRect = .zero
    var scaleFitToRestore: Bool = false
    var previousFullscreenColumns: Int32 = 0
    var previousFullscreenRows: Int32 = 0
    var previousFullscreenCurImage: Int32 = 0
    var previousFullscreenViewIndex: Int32 = 0
    var previousPropagate: Int32 = 0
    var previousScaledFit: Int32 = 0
    var previousSliderStripHeight: CGFloat = 0
}

extension ViewerController {
    var horos_windowsStateName: String? {
        get { windowLayoutState.windowsStateName }
        set { windowLayoutState.windowsStateName = newValue }
    }
    var horos_FullScreenOn: Bool {
        get { windowLayoutState.FullScreenOn }
        set { windowLayoutState.FullScreenOn = newValue }
    }
    var horos_FullScreenWindow: NSWindow? {
        get { windowLayoutState.FullScreenWindow }
        set { windowLayoutState.FullScreenWindow = newValue }
    }
    var horos_StartingWindow: NSWindow? {
        get { windowLayoutState.StartingWindow }
        set { windowLayoutState.StartingWindow = newValue }
    }
    func horos_assignStartingWindow(_ value: NSWindow?) { windowLayoutState.$StartingWindow.assign(value) }
    var horos_contentView: NSView? {
        get { windowLayoutState.contentView }
        set { windowLayoutState.contentView = newValue }
    }
    func horos_assignContentView(_ value: NSView?) { windowLayoutState.$contentView.assign(value) }
    var horos_standardRect: NSRect {
        get { windowLayoutState.standardRect }
        set { windowLayoutState.standardRect = newValue }
    }
    var horos_previousFrameRect: NSRect {
        get { windowLayoutState.previousFrameRect }
        set { windowLayoutState.previousFrameRect = newValue }
    }
    var horos_windowFrameToRestore: NSRect {
        get { windowLayoutState.windowFrameToRestore }
        set { windowLayoutState.windowFrameToRestore = newValue }
    }
    var horos_scaleFitToRestore: Bool {
        get { windowLayoutState.scaleFitToRestore }
        set { windowLayoutState.scaleFitToRestore = newValue }
    }
    var horos_previousFullscreenColumns: Int32 {
        get { windowLayoutState.previousFullscreenColumns }
        set { windowLayoutState.previousFullscreenColumns = newValue }
    }
    var horos_previousFullscreenRows: Int32 {
        get { windowLayoutState.previousFullscreenRows }
        set { windowLayoutState.previousFullscreenRows = newValue }
    }
    var horos_previousFullscreenCurImage: Int32 {
        get { windowLayoutState.previousFullscreenCurImage }
        set { windowLayoutState.previousFullscreenCurImage = newValue }
    }
    var horos_previousFullscreenViewIndex: Int32 {
        get { windowLayoutState.previousFullscreenViewIndex }
        set { windowLayoutState.previousFullscreenViewIndex = newValue }
    }
    var horos_previousPropagate: Int32 {
        get { windowLayoutState.previousPropagate }
        set { windowLayoutState.previousPropagate = newValue }
    }
    var horos_previousScaledFit: Int32 {
        get { windowLayoutState.previousScaledFit }
        set { windowLayoutState.previousScaledFit = newValue }
    }
    var horos_previousSliderStripHeight: CGFloat {
        get { windowLayoutState.previousSliderStripHeight }
        set { windowLayoutState.previousSliderStripHeight = newValue }
    }
}
