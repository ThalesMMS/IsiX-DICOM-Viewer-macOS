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

/// Whether to correct a gantry tilt before a 3D viewer opens, and the mark
/// the 3D views draw when it was corrected.
///
/// Every 3D entry of a tilted series asked, and a head CT is often tilted. The
/// question now has "Do not ask again": the answer given with it becomes the
/// policy, which the 3D preferences show and reset.
@objc(HorosGantryTiltPolicy)
public final class GantryTiltPolicy: NSObject {
    @objc public static let defaultsKey = "GantryTiltCorrectionPolicy"

    @objc public enum Policy: Int {
        case ask = 0
        case alwaysCorrect = 1
        case neverCorrect = 2
    }

    @objc public static var policy: Policy {
        Policy(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .ask
    }

    /// The policy an answer leaves: the answer itself when it is to be kept.
    @objc(policyAfterCorrecting:remember:current:)
    public static func policy(afterCorrecting correct: Bool, remember: Bool, current: Policy) -> Policy {
        guard remember else { return current }
        return correct ? .alwaysCorrect : .neverCorrect
    }

    /// Asks, unless the policy already answers; true when the series is to be corrected.
    @MainActor
    @objc(shouldCorrectTiltOfDegrees:)
    public static func shouldCorrect(degrees: Float) -> Bool {
        switch policy {
        case .alwaysCorrect: return true
        case .neverCorrect: return false
        case .ask: break
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Warning!", comment: "")
        alert.informativeText = String(format: NSLocalizedString("These images were acquired with a gantry tilt: %0.2f\u{00B0}. This gantry tilt will produce a distortion in 3D post-processing. Should I convert these images to a real 3D dataset.", comment: ""), degrees)
        alert.addButton(withTitle: NSLocalizedString("Yes", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("No", comment: ""))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NSLocalizedString("Do not ask again", comment: "")
        let correct = alert.runModal() == .alertFirstButtonReturn
        let next = policy(afterCorrecting: correct, remember: alert.suppressionButton?.state == .on, current: .ask)
        if next != .ask { UserDefaults.standard.set(next.rawValue, forKey: defaultsKey) }
        return correct
    }

    // MARK: Corrected viewers

    nonisolated(unsafe) private static let corrected = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()

    /// Records that a 2D viewer's series was corrected, by these degrees.
    @objc(setCorrectedDegrees:forViewer:)
    public static func setCorrected(degrees: Float, for viewer: AnyObject) {
        corrected.setObject(NSNumber(value: degrees), forKey: viewer)
    }

    /// The degrees a viewer's series was corrected by, while it still is: a
    /// viewer that found the tilt again (its series reverted) has none.
    @MainActor
    @objc(correctedDegreesOfViewer:)
    public static func correctedDegrees(of viewer: ViewerController?) -> NSNumber? {
        guard let viewer, !viewer.titledGantry else { return nil }
        return corrected.object(forKey: viewer)
    }

    /// The text of the mark, with the angle corrected.
    @objc(overlayTextForDegrees:)
    public static func overlayText(degrees: Float) -> String {
        String(format: NSLocalizedString("Tilt corrected (%0.1f\u{00B0})", comment: "Drawn in the lower left corner of a 3D view whose series was corrected for gantry tilt"), degrees)
    }

    /// The mark of the views drawn as 2D images (MPR, curved MPR, orthogonal MPR).
    @MainActor
    @objc(labelForDegrees:)
    public static func label(degrees: Float) -> AnnotationBox {
        let text = overlayText(degrees: degrees)
        if let box, boxText == text { return box }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let made = AnnotationBox(attributedString: NSAttributedString(string: " " + text + " ", attributes: attributes),
                                 boxColor: NSColor(calibratedWhite: 0, alpha: 0.6), borderColor: NSColor(calibratedWhite: 1, alpha: 0.5))
        box = made
        boxText = text
        return made
    }

    @MainActor private static var box: AnnotationBox?
    @MainActor private static var boxText: String?
}
