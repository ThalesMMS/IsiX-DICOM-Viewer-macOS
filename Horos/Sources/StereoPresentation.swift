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
import QuartzCore

/// The stereo modes of the 3D views' Stereo menu, by the tags of its items.
@objc(HorosStereoMode)
public enum StereoMode: Int {
    case off = 0, anaglyph = 1, redBlue = 2, interlaced = 3, twoScreens = 4, oneScreen = 5
}

/// Where a 3D view shows its two eyes (#734). The view's VTK window renders
/// both, as VTK's two-buffer stereo did; the left eye stays in the view's own
/// picture and the right one goes to the eye presenter, whose layer sits in
/// the right half of the view, or fills a second screen. Anaglyph, red/blue and
/// interlaced are VTK's own combinations of the two eyes in the view's picture.
@objc(HorosStereoPresentation)
public final class StereoPresentation: NSObject {
    @objc public private(set) var mode: StereoMode = .off
    @objc public private(set) var eyePresenter: VRPresenter?
    /// Asked to switch stereo off: Escape on either screen of the two-screen mode.
    @objc public var turnOff: (() -> Void)?

    private weak var view: NSView?
    private var eyeLayer: CAMetalLayer?
    private var leftWindow: NSWindow?, rightWindow: NSWindow?
    private weak var rootWindow: NSWindow?
    private var rootContent: NSView?

    @objc public init(view: NSView) {
        self.view = view
        super.init()
    }

    deinit { leaveScreens() }

    /// Whether each eye has a picture of its own.
    @objc public var twoPictures: Bool { mode == .twoScreens || mode == .oneScreen }

    /// Switches to `requested` and returns the mode in effect: two screens
    /// fall back to one when there is only one, as the original mode did.
    @objc(switchToMode:) @discardableResult
    public func switchTo(_ requested: StereoMode) -> StereoMode {
        var next = requested
        if next == .twoScreens && NSScreen.screens.count < 2 { next = .oneScreen }
        if next == mode { return mode }
        if mode == .twoScreens { leaveScreens() }
        mode = next
        if twoPictures {
            if eyePresenter == nil { makeEyePresenter() }
        } else {
            eyeLayer?.removeFromSuperlayer()
            eyeLayer = nil
            eyePresenter = nil
        }
        if mode == .twoScreens { enterScreens() }
        return mode
    }

    /// The size the view's VTK window renders at, in pixels, for a view of
    /// `backing` pixels: half its width when the two eyes share it.
    @objc(renderSizeForBacking:)
    public func renderSize(forBacking backing: CGSize) -> CGSize {
        let width = max(1, backing.width.rounded()), height = max(1, backing.height.rounded())
        return mode == .oneScreen ? CGSize(width: max(1, (width / 2).rounded(.down)), height: height)
                                  : CGSize(width: width, height: height)
    }

    /// Frames the view's picture and the eye's for a render of `size` pixels.
    @objc(layoutPicture:bounds:scale:renderSize:)
    public func layout(picture: CAMetalLayer, bounds: CGRect, scale: CGFloat, renderSize size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var left = bounds
        if mode == .oneScreen { left.size.width = size.width / scale }
        picture.frame = left
        if let eyeLayer {
            eyeLayer.contentsScale = scale
            eyeLayer.colorspace = picture.colorspace
            if mode == .oneScreen {
                if eyeLayer.superlayer !== picture.superlayer { picture.superlayer?.insertSublayer(eyeLayer, above: picture) }
                eyeLayer.frame = CGRect(x: left.maxX, y: bounds.minY, width: left.width, height: bounds.height)
            } else if let host = rightWindow?.contentView?.layer {
                if eyeLayer.superlayer !== host { host.addSublayer(eyeLayer) }
                eyeLayer.frame = host.bounds
            }
        }
        CATransaction.commit()
        if let eyeLayer, eyeLayer.drawableSize != size { eyeLayer.drawableSize = size }
    }

    private func makeEyePresenter() {
        let layer = CAMetalLayer()
        layer.device = PlanarHostRenderer.device
        layer.presentsWithTransaction = true
        layer.isOpaque = true
        layer.anchorPoint = .zero
        // On a second screen of another size, the eye is shown whole.
        layer.contentsGravity = .resizeAspect
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        eyeLayer = layer
        eyePresenter = VRPresenter(layer: layer)
    }

    // MARK: Two screens

    /// The view's window content fills the first screen, and the right eye the
    /// second, in borderless windows above the others, as the original did.
    private func enterScreens() {
        guard let view, let root = view.window, let content = root.contentView else { return }
        let screens = NSScreen.screens
        func cover(_ screen: NSScreen) -> NSWindow {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            window.setFrame(screen.frame, display: false)
            return window
        }
        rootWindow = root
        rootContent = content
        let left = cover(screens[0]), right = cover(screens[1])
        root.contentView = NSView(frame: content.frame)
        left.contentView = content
        let eye = StereoEyeView(frame: NSRect(origin: .zero, size: screens[1].frame.size))
        eye.source = view
        eye.escape = { [weak self] in self?.turnOff?() }
        right.contentView = eye
        leftWindow = left
        rightWindow = right
        right.orderFront(nil)
        left.makeKeyAndOrderFront(nil)
        left.makeFirstResponder(view)
        NSCursor.hide()
    }

    private func leaveScreens() {
        guard let left = leftWindow else { return }
        NSCursor.unhide()
        eyeLayer?.removeFromSuperlayer()
        if let root = rootWindow, let content = rootContent {
            left.contentView = NSView()
            root.contentView = content
            root.makeKeyAndOrderFront(nil)
            if let view { root.makeFirstResponder(view) }
        }
        left.orderOut(nil)
        rightWindow?.orderOut(nil)
        leftWindow = nil
        rightWindow = nil
        rootContent = nil
    }

    // MARK: Geometry

    /// The view angle, in degrees, of a screen `height` high seen from `distance`.
    @objc(viewAngleForScreenHeight:distance:)
    public static func viewAngle(screenHeight height: Double, distance: Double) -> Double {
        2 * atan(max(height, 0.01) / (2 * max(distance, 0.01))) * 180 / .pi
    }

    /// The angle between the eyes, in degrees, `separation` apart at `distance` from the screen.
    @objc(eyeAngleForSeparation:distance:)
    public static func eyeAngle(separation: Double, distance: Double) -> Double {
        2 * atan(separation / (2 * max(distance, 0.01))) * 180 / .pi
    }
}

/// The right eye on the second screen: the mouse and the keys go to the view
/// it shows, and Escape leaves the two screens.
final class StereoEyeView: NSView {
    weak var source: NSView?
    var escape: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() } else { source?.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) { source?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { source?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { source?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { source?.rightMouseDown(with: event) }
    override func rightMouseDragged(with event: NSEvent) { source?.rightMouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { source?.rightMouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { source?.otherMouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { source?.otherMouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { source?.otherMouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) { source?.scrollWheel(with: event) }
}
