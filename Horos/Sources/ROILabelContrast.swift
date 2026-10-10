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

/// How a ROI label stays readable over any image: a dark box behind its
/// text, and the ROI's colour lightened just enough for the text to keep
/// WCAG's 4.5:1 contrast with that box even over a white image.
@objc(HorosROILabelContrast)
public final class ROILabelContrast: NSObject {
    @objc public static let backgroundKey = "ROILabelBackground"
    @objc public static let backgroundOpacityKey = "ROILabelBackgroundOpacity"
    @objc public static let minimumContrast: CGFloat = 4.5

    /// The box's opacity when it is drawn, kept where it can still darken the
    /// image; zero when it is switched off.
    @objc public static var backgroundOpacity: CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: backgroundKey) else { return 0 }
        let opacity = CGFloat(defaults.float(forKey: backgroundOpacityKey))
        return opacity.isFinite ? min(max(opacity, 0.2), 1) : 0.8
    }

    /// A selected ROI's box is a little more opaque and slightly red, as the
    /// selected label's box was before it was made transparent.
    @objc(boxColorSelected:opacity:)
    public static func boxColor(selected: Bool, opacity: CGFloat) -> NSColor {
        selected
            ? NSColor(deviceRed: 0.3, green: 0, blue: 0, alpha: min(1, opacity + 0.15))
            : NSColor(deviceRed: 0, green: 0, blue: 0, alpha: opacity)
    }

    /// WCAG relative luminance of a device RGB colour.
    @objc(luminanceOfRed:green:blue:)
    public static func luminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat {
            let v = min(max(c, 0), 1)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    @objc(contrastBetweenLuminance:andLuminance:)
    public static func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The box over a white pixel: the lightest background the text can get,
    /// so the contrast against it holds over any other pixel.
    @objc(worstBackgroundLuminanceForBox:)
    public static func worstBackgroundLuminance(box: NSColor) -> CGFloat {
        guard let c = box.usingColorSpace(.deviceRGB) else { return 1 }
        let a = c.alphaComponent
        return luminance(red: c.redComponent * a + (1 - a),
                         green: c.greenComponent * a + (1 - a),
                         blue: c.blueComponent * a + (1 - a))
    }

    /// `color` mixed with white in the smallest step that reaches the minimum
    /// contrast over the box, or white when no mix reaches it. The hue stays
    /// recognisable: a dark blue becomes a light blue, not a grey.
    @objc(textColorFor:overBox:)
    public static func textColor(for color: NSColor, overBox box: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color }
        let background = worstBackgroundLuminance(box: box)
        func mixed(_ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            (c.redComponent + (1 - c.redComponent) * t,
             c.greenComponent + (1 - c.greenComponent) * t,
             c.blueComponent + (1 - c.blueComponent) * t)
        }
        func enough(_ t: CGFloat) -> Bool {
            let m = mixed(t)
            return contrast(luminance(red: m.0, green: m.1, blue: m.2), background) >= minimumContrast
        }
        if enough(0) { return NSColor(deviceRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1) }
        guard enough(1) else { return NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1) }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if enough(middle) { high = middle } else { low = middle }
        }
        let m = mixed(high)
        return NSColor(deviceRed: m.0, green: m.1, blue: m.2, alpha: 1)
    }
}
