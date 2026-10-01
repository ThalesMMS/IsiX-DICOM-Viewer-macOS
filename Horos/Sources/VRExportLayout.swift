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

/// Temporarily holds a rendering surface steady against AppKit layout.
/// A zero pixel size preserves the existing frame; positive sizes select a square target.
// Main actor: it lays out the 3D export panels.
@MainActor
@objc(HorosVRExportLayout)
public final class VRExportLayout: NSObject {
    private weak var view: NSView?
    private let savedFrame: NSRect
    private let savedMask: NSView.AutoresizingMask
    private let savedTranslation: Bool
    private var savedConstraints: [NSLayoutConstraint] = []

    @objc(initWithView:pixelSize:)
    public init(view: NSView, pixelSize: CGFloat) {
        self.view = view
        savedFrame = view.frame
        savedMask = view.autoresizingMask
        savedTranslation = view.translatesAutoresizingMaskIntoConstraints
        super.init()

        var ancestor: NSView? = view
        while let owner = ancestor {
            savedConstraints += owner.constraints.filter {
                $0.isActive && (($0.firstItem as? NSView) === view || ($0.secondItem as? NSView) === view)
            }
            ancestor = owner.superview
        }
        NSLayoutConstraint.deactivate(savedConstraints)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        guard pixelSize > 0 else { return }
        let size = view.convertFromBacking(NSSize(width: pixelSize, height: pixelSize))
        let container = view.superview?.bounds ?? savedFrame
        view.frame = NSRect(x: container.midX - size.width / 2,
                            y: container.midY - size.height / 2,
                            width: size.width, height: size.height)
    }

    @objc public func restore() {
        guard let view else { return }
        view.frame = savedFrame
        view.autoresizingMask = savedMask
        view.translatesAutoresizingMaskIntoConstraints = savedTranslation
        NSLayoutConstraint.activate(savedConstraints)
        savedConstraints.removeAll()
        self.view = nil
        view.superview?.layoutSubtreeIfNeeded()
    }
}
