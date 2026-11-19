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

extension ViewerController {
    var horos_windowsStateName: String? {
        get { _windowsStateName as String? }
        set { _windowsStateName = newValue as NSString? }
    }
    var horos_FullScreenOn: Bool {
        get { _FullScreenOn }
        set { _FullScreenOn = newValue }
    }
    var horos_FullScreenWindow: NSWindow? {
        get { _FullScreenWindow.wrappedValue }
        set { _FullScreenWindow.wrappedValue = newValue }
    }
    var horos_StartingWindow: NSWindow? {
        get { _StartingWindow.wrappedValue }
        set { _StartingWindow.wrappedValue = newValue }
    }
    func horos_assignStartingWindow(_ value: NSWindow?) { _StartingWindow.assign(value) }
    var horos_contentView: NSView? {
        get { _contentView.wrappedValue }
        set { _contentView.wrappedValue = newValue }
    }
    func horos_assignContentView(_ value: NSView?) { _contentView.assign(value) }
    var horos_standardRect: NSRect {
        get { _standardRect }
        set { _standardRect = newValue }
    }
    var horos_previousFrameRect: NSRect {
        get { _previousFrameRect }
        set { _previousFrameRect = newValue }
    }
    var horos_windowFrameToRestore: NSRect {
        get { _windowFrameToRestore }
        set { _windowFrameToRestore = newValue }
    }
    var horos_scaleFitToRestore: Bool {
        get { _scaleFitToRestore }
        set { _scaleFitToRestore = newValue }
    }
    var horos_previousFullscreenColumns: Int32 {
        get { _previousFullscreenColumns }
        set { _previousFullscreenColumns = newValue }
    }
    var horos_previousFullscreenRows: Int32 {
        get { _previousFullscreenRows }
        set { _previousFullscreenRows = newValue }
    }
    var horos_previousFullscreenCurImage: Int32 {
        get { _previousFullscreenCurImage }
        set { _previousFullscreenCurImage = newValue }
    }
    var horos_previousFullscreenViewIndex: Int32 {
        get { _previousFullscreenViewIndex }
        set { _previousFullscreenViewIndex = newValue }
    }
    var horos_previousPropagate: Int32 {
        get { _previousPropagate }
        set { _previousPropagate = newValue }
    }
    var horos_previousScaledFit: Int32 {
        get { _previousScaledFit }
        set { _previousScaledFit = newValue }
    }
    var horos_previousSliderStripHeight: CGFloat {
        get { _previousSliderStripHeight }
        set { _previousSliderStripHeight = newValue }
    }
}
