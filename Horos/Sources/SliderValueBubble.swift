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

/// The value of a slider, written above its knob while the pointer is on the
/// slider or drags it.
///
/// A toolbar slider has no room of its own above the track, so the text is in
/// a small window of its own, a child of the slider's, which takes no click
/// and never becomes key.
@MainActor
final class SliderValueBubble {
    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "")

    /// The text shown; nil while nothing is.
    var shownText: String? { window?.isVisible == true ? label.stringValue : nil }

    /// The bubble's frame on screen; nil while it is not shown.
    var shownFrame: NSRect? { window?.isVisible == true ? window?.frame : nil }

    /// Shows `text` centred above `anchor`, a point of `view` (its knob's
    /// centre), clear of the view's own bounds.
    func show(_ text: String, above anchor: NSPoint, of view: NSView) {
        guard let parent = view.window else { hide(); return }
        let bubble = window ?? makeWindow()
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 10, height: ceil(label.frame.height) + 4)
        label.setFrameOrigin(NSPoint(x: 5, y: 2))

        // The top edge of the slider on screen, whichever way the view is flipped.
        let bounds = view.bounds
        let top = view.convert(NSPoint(x: anchor.x, y: view.isFlipped ? bounds.minY : bounds.maxY), to: nil)
        let onScreen = parent.convertPoint(toScreen: top)
        bubble.setFrame(NSRect(x: (onScreen.x - size.width / 2).rounded(), y: onScreen.y + 2, width: size.width, height: size.height),
                        display: true)
        if bubble.parent !== parent {
            bubble.parent?.removeChildWindow(bubble)
            parent.addChildWindow(bubble, ordered: .above)
        }
        bubble.orderFront(nil)
    }

    func hide() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let bubble = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        bubble.isReleasedWhenClosed = false
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.ignoresMouseEvents = true
        bubble.animationBehavior = .none

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 4
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.fillColor = .windowBackgroundColor
        box.contentViewMargins = .zero
        box.autoresizingMask = [.width, .height]
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        label.textColor = .labelColor
        box.contentView?.addSubview(label)
        bubble.contentView = box
        window = bubble
        return bubble
    }
}
