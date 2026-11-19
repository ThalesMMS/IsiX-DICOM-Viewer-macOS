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

/// C's conversion of a double to a 64-bit integer, without Swift's trap: the
/// value is truncated toward zero, and out of range or NaN saturates.
private func truncated(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9223372036854775807.0 { return Int.max }
    if value <= -9223372036854775808.0 { return Int.min }
    return Int(value)
}

/// The determinate bar of the wait panel, which the panel's -progress answers.
///
/// The headers of the plugin SDKs do not agree on what -progress answers: some
/// declare a progress indicator, others a level indicator. A plugin is built
/// against one of them and sends the bar the selectors of the class its header
/// named, and a selector the bar does not have raises «unrecognized
/// selector», which on a thread of the plugin ends the application. So the
/// bar is a progress indicator, with everything AppKit gives one, that also
/// answers the selectors AppKit declares for a level indicator, each with the
/// same types, and the value accessors a level indicator has as a control.
///
/// What a progress bar has no drawing for (thresholds, tick marks, colours,
/// the rating images, the style, whether it is editable or enabled) is kept
/// and read back, and changes nothing on screen. The values a level indicator
/// shares with a progress indicator (-doubleValue, -minValue, -maxValue) are
/// the bar's own.
///
/// It is not a kind of NSLevelIndicator: a plugin that asks the class of the
/// bar before using it sees a progress indicator.
///
/// A plugin sends these from its own thread too. What is only kept is kept
/// under a lock and answers on any thread. The value accessors reach the bar,
/// which belongs to the main thread: there they run where they are called;
/// from another thread a setter queues its work for the main thread and
/// returns, and a getter waits for the main thread to read the bar.
@objc(IsiXWaitProgressIndicator)
final class WaitProgressIndicator: NSProgressIndicator {
    // MARK: Kept and read back, with no drawing in a progress bar

    private struct Kept {
        var levelIndicatorStyle: NSLevelIndicator.Style = .continuousCapacity
        var warningValue: Double = 0
        var criticalValue: Double = 0
        var tickMarkPosition: NSSlider.TickMarkPosition = .below
        var numberOfTickMarks: Int = 0
        var numberOfMajorTickMarks: Int = 0
        var drawsTieredCapacityLevels = false
        var placeholderVisibility: NSLevelIndicator.PlaceholderVisibility = .automatic
        var ratingImage: NSImage?
        var ratingPlaceholderImage: NSImage?
        var editable = false
        var enabled = true
        var fill: NSColor?
        var warningFill: NSColor?
        var criticalFill: NSColor?
    }

    /// The kept values behind their lock. Images and colours are handed over
    /// as the objects the plugin gave, as an Objective-C property would.
    private final class KeptValues: @unchecked Sendable {
        private let lock = NSLock()
        private var kept = Kept()

        subscript<Value>(_ path: WritableKeyPath<Kept, Value>) -> Value {
            get { lock.withLock { kept[keyPath: path] } }
            set { lock.withLock { kept[keyPath: path] = newValue } }
        }
    }

    private let kept = KeptValues()

    @objc nonisolated var levelIndicatorStyle: NSLevelIndicator.Style {
        get { kept[\.levelIndicatorStyle] }
        set { kept[\.levelIndicatorStyle] = newValue }
    }

    @objc nonisolated var warningValue: Double {
        get { kept[\.warningValue] }
        set { kept[\.warningValue] = newValue }
    }

    @objc nonisolated var criticalValue: Double {
        get { kept[\.criticalValue] }
        set { kept[\.criticalValue] = newValue }
    }

    @objc nonisolated var tickMarkPosition: NSSlider.TickMarkPosition {
        get { kept[\.tickMarkPosition] }
        set { kept[\.tickMarkPosition] = newValue }
    }

    @objc nonisolated var numberOfTickMarks: Int {
        get { kept[\.numberOfTickMarks] }
        set { kept[\.numberOfTickMarks] = newValue }
    }

    @objc nonisolated var numberOfMajorTickMarks: Int {
        get { kept[\.numberOfMajorTickMarks] }
        set { kept[\.numberOfMajorTickMarks] = newValue }
    }

    @objc nonisolated var drawsTieredCapacityLevels: Bool {
        get { kept[\.drawsTieredCapacityLevels] }
        set { kept[\.drawsTieredCapacityLevels] = newValue }
    }

    @objc nonisolated var placeholderVisibility: NSLevelIndicator.PlaceholderVisibility {
        get { kept[\.placeholderVisibility] }
        set { kept[\.placeholderVisibility] = newValue }
    }

    @objc nonisolated var ratingImage: NSImage? {
        get { kept[\.ratingImage] }
        set { kept[\.ratingImage] = newValue }
    }

    @objc nonisolated var ratingPlaceholderImage: NSImage? {
        get { kept[\.ratingPlaceholderImage] }
        set { kept[\.ratingPlaceholderImage] = newValue }
    }

    @objc nonisolated var isEditable: Bool {
        @objc(isEditable) get { kept[\.editable] }
        @objc(setEditable:) set { kept[\.editable] = newValue }
    }

    @objc nonisolated var isEnabled: Bool {
        @objc(isEnabled) get { kept[\.enabled] }
        @objc(setEnabled:) set { kept[\.enabled] = newValue }
    }

    // A level indicator's colours are never nil: nil puts the default back.
    @objc nonisolated var fillColor: NSColor! {
        get { kept[\.fill] ?? .systemGreen }
        set { kept[\.fill] = newValue }
    }

    @objc nonisolated var warningFillColor: NSColor! {
        get { kept[\.warningFill] ?? .systemYellow }
        set { kept[\.warningFill] = newValue }
    }

    @objc nonisolated var criticalFillColor: NSColor! {
        get { kept[\.criticalFill] ?? .systemRed }
        set { kept[\.criticalFill] = newValue }
    }

    /// The value a tick mark would stand for: the marks divide the range of
    /// the bar evenly, the first at the minimum and the last at the maximum.
    @objc(tickMarkValueAtIndex:)
    nonisolated func tickMarkValue(at index: Int) -> Double {
        let marks = numberOfTickMarks
        return onMainRunLoopSync {
            guard marks > 1 else { return self.minValue }
            return self.minValue + (self.maxValue - self.minValue) * Double(index) / Double(marks - 1)
        }
    }

    /// No tick mark is drawn, so none has a rectangle.
    @objc(rectOfTickMarkAtIndex:)
    nonisolated func rectOfTickMark(at index: Int) -> NSRect {
        return .zero
    }

    // MARK: The value, as a control gives it

    /// The value of the bar, read on the main thread.
    nonisolated private var barValue: Double {
        get { onMainRunLoopSync { self.doubleValue } }
        set { onWaitPanelThread { self.doubleValue = newValue } }
    }

    @objc nonisolated var intValue: Int32 {
        get { Int32(clamping: truncated(barValue)) }
        set { barValue = Double(newValue) }
    }

    @objc nonisolated var integerValue: Int {
        get { truncated(barValue) }
        set { barValue = Double(newValue) }
    }

    @objc nonisolated var floatValue: Float {
        get { Float(barValue) }
        set { barValue = Double(newValue) }
    }

    /// The value as a number. An object that is no number leaves the bar as
    /// it is.
    @objc nonisolated var objectValue: Any? {
        get { NSNumber(value: barValue) }
        set {
            if let number = newValue as? NSNumber { barValue = number.doubleValue }
        }
    }

    // MARK: In place of the bar a nib made

    /// `bar` when it is already of this class; otherwise a bar of this class
    /// with the settings of `bar`, in its place in the view and in the
    /// constraints that named it. The localized copies of the panel's nib
    /// declare a plain progress indicator, and the panel answers this one.
    static func standing(inPlaceOf bar: NSProgressIndicator) -> NSProgressIndicator {
        if bar is WaitProgressIndicator { return bar }

        let own = WaitProgressIndicator(frame: bar.frame)
        own.style = bar.style
        own.controlSize = bar.controlSize
        own.isIndeterminate = bar.isIndeterminate
        own.isDisplayedWhenStopped = bar.isDisplayedWhenStopped
        own.usesThreadedAnimation = bar.usesThreadedAnimation
        own.minValue = bar.minValue
        own.maxValue = bar.maxValue
        own.doubleValue = bar.doubleValue
        own.isHidden = bar.isHidden
        own.wantsLayer = bar.wantsLayer
        own.autoresizingMask = bar.autoresizingMask
        own.translatesAutoresizingMaskIntoConstraints = bar.translatesAutoresizingMaskIntoConstraints
        own.identifier = bar.identifier
        own.toolTip = bar.toolTip
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            own.setContentHuggingPriority(bar.contentHuggingPriority(for: orientation), for: orientation)
            own.setContentCompressionResistancePriority(bar.contentCompressionResistancePriority(for: orientation), for: orientation)
        }

        guard let parent = bar.superview else { return own }

        // The constraints that name the bar, each with the view that holds
        // it: taking the bar out of its view removes them.
        var held: [(holder: NSView, constraint: NSLayoutConstraint)] = []
        var holder: NSView? = parent
        while let view = holder {
            for constraint in view.constraints where constraint.firstItem === bar || constraint.secondItem === bar {
                held.append((view, constraint))
            }
            holder = view.superview
        }

        parent.replaceSubview(bar, with: own)

        for (view, constraint) in held {
            guard let first = constraint.firstItem else { continue }
            let second = constraint.secondItem
            let copy = NSLayoutConstraint(item: first === bar ? own : first,
                                          attribute: constraint.firstAttribute,
                                          relatedBy: constraint.relation,
                                          toItem: second === bar ? own : second,
                                          attribute: constraint.secondAttribute,
                                          multiplier: constraint.multiplier,
                                          constant: constraint.constant)
            copy.priority = constraint.priority
            copy.identifier = constraint.identifier
            view.removeConstraint(constraint)
            view.addConstraint(copy)
        }
        return own
    }
}
