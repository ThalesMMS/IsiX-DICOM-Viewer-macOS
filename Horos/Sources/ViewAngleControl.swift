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
import ObjectiveC

/// The field of view of a 3D view's camera, in degrees: a slider and a field
/// for Volume Rendering in perspective and for the 3D Endoscopy. It edits the
/// `viewAngle` of the view it is given (`-[VRView viewAngle]`), follows it when
/// the view changes it (a projection mode, a saved state, a Fly Thru camera),
/// and is inactive while the view says the angle cannot be set: in parallel
/// projection the camera has none.
@objc(HorosViewAngleControl)
public final class ViewAngleControl: NSView {
    @objc nonisolated public static let minimumAngle = 10.0
    @objc nonisolated public static let maximumAngle = 120.0
    /// Posted by the view, as the object, whenever its angle or its projection
    /// may have changed.
    @objc nonisolated public static let didChangeNotification = "HorosVRViewAngleDidChange"

    private static let viewAngleKey = "viewAngle"
    private static let adjustableKey = "viewAngleAdjustable"
    private static var wrapperKey = 0

    private weak var host: NSObject?
    private let title = NSTextField(labelWithString: NSLocalizedString("View angle", comment: "Field of view of the 3D camera"))
    private let slider = NSSlider(value: 30, minValue: ViewAngleControl.minimumAngle, maxValue: ViewAngleControl.maximumAngle,
                                  target: nil, action: nil)
    private let field = NSTextField()
    private let degrees = NSTextField(labelWithString: "\u{00B0}")
    private var observers: [NSObjectProtocol] = []

    /// The angle a slider or a typed value asks for, inside the range.
    nonisolated public static func clamped(_ angle: Double) -> Double? {
        guard angle.isFinite else { return nil }
        return min(max(angle, minimumAngle), maximumAngle)
    }

    @objc public init(host: NSObject) {
        self.host = host
        super.init(frame: NSRect(x: 0, y: 0, width: 132, height: 44))
        let tip = NSLocalizedString("Field of view of the camera, in degrees. Parallel projection has none.",
                                    comment: "Tooltip of the 3D view angle control")
        toolTip = tip

        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.textColor = .labelColor
        title.frame = NSRect(x: 0, y: 26, width: 132, height: 14)
        title.lineBreakMode = .byTruncatingTail

        slider.controlSize = .small
        slider.isContinuous = true
        slider.frame = NSRect(x: 0, y: 4, width: 88, height: 18)
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.toolTip = tip

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = NSNumber(value: Self.minimumAngle)
        formatter.maximum = NSNumber(value: Self.maximumAngle)
        // The degree sign is a label of its own: a formatter with a suffix
        // refuses a number typed without it.
        formatter.isLenient = true
        field.formatter = formatter
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .right
        field.frame = NSRect(x: 92, y: 3, width: 32, height: 19)
        degrees.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        degrees.frame = NSRect(x: 125, y: 5, width: 8, height: 14)
        field.target = self
        // A value typed and left by a click elsewhere is applied too.
        field.cell?.sendsActionOnEndEditing = true
        field.action = #selector(fieldEdited(_:))
        field.toolTip = tip

        for view in [title, slider, field, degrees] { addSubview(view) }
        // A pinch in perspective zooms by narrowing the angle: any change of
        // the camera is read back.
        for name in [Notification.Name(Self.didChangeNotification), NSNotification.Name.OsirixVRCameraDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The view's angle and whether it can be set, read again.
    @objc public func refresh() {
        let adjustable = (host?.value(forKey: Self.adjustableKey) as? NSNumber)?.boolValue ?? false
        let angle = (host?.value(forKey: Self.viewAngleKey) as? NSNumber)?.doubleValue ?? 30
        // Every camera move is announced: the controls are touched only when
        // what they show changes.
        if slider.doubleValue != angle { slider.doubleValue = angle }
        let shown = NSNumber(value: angle.rounded())
        if (field.objectValue as? NSNumber) != shown { field.objectValue = shown }
        guard slider.isEnabled != adjustable else { return }
        slider.isEnabled = adjustable
        field.isEnabled = adjustable
        title.textColor = adjustable ? .labelColor : .disabledControlTextColor
        degrees.textColor = title.textColor
    }

    @objc private func sliderMoved(_ sender: NSSlider) { apply(sender.doubleValue.rounded()) }

    @objc private func fieldEdited(_ sender: NSTextField) {
        apply((sender.objectValue as? NSNumber)?.doubleValue ?? .nan)
    }

    private func apply(_ value: Double) {
        if let angle = Self.clamped(value) { host?.setValue(NSNumber(value: angle), forKey: Self.viewAngleKey) }
        refresh()
    }

    /// `view` followed by the control, in one view for a toolbar item: made
    /// once per view, so every item that shows `view` shows the same pair.
    @objc(wrapping:host:)
    public static func wrapping(_ view: NSView, host: NSObject) -> NSView {
        if let wrapper = objc_getAssociatedObject(view, &wrapperKey) as? NSView { return wrapper }
        let control = ViewAngleControl(host: host)
        let gap: CGFloat = 8
        let height = max(view.frame.height, control.frame.height)
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: view.frame.width + gap + control.frame.width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = true
        view.setFrameOrigin(NSPoint(x: 0, y: (height - view.frame.height) / 2))
        control.setFrameOrigin(NSPoint(x: view.frame.width + gap, y: (height - control.frame.height) / 2))
        wrapper.addSubview(view)
        wrapper.addSubview(control)
        objc_setAssociatedObject(view, &wrapperKey, wrapper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return wrapper
    }

    /// A toolbar that remembers its items does not show one added to its
    /// defaults later: the item is inserted once, after `neighbour`, and a
    /// toolbar where it was removed afterwards is left as it is.
    @objc(revealItem:inToolbar:after:defaultsKey:)
    public static func reveal(item identifier: String, in toolbar: NSToolbar, after neighbour: String, defaultsKey: String) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsKey) else { return }
        defaults.set(true, forKey: defaultsKey)
        let identifiers = toolbar.items.map(\.itemIdentifier.rawValue)
        guard !identifiers.contains(identifier) else { return }
        let index = identifiers.firstIndex(of: neighbour).map { $0 + 1 } ?? identifiers.count
        toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(identifier), at: index)
    }
}
