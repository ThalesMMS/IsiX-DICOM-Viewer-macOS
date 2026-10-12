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

import Foundation

/// The name of the series that "Save as DICOM SC and mark as Key Image" adds
/// its captures to: the one set in the Viewer preferences, or a default.
///
/// The name is written as the Series Description of the capture and read back
/// to find the series of an earlier capture of the same study, so both ask
/// here. It is ASCII only: the description is encoded with the character set
/// of the study the capture comes from, which cannot be counted on to hold an
/// accent, and the archive the captures are sent to may show it wrongly.
@objc(HorosScreenCaptureSeriesName)
public final class ScreenCaptureSeriesName: NSObject {
    @objc public static let defaultsKey = "screenCaptureKeyImageSeriesName"

    /// The default name where the application's language cannot give one.
    @objc public static let englishName = "IsiX Screen Captures"

    /// What a DICOM Long String holds.
    @objc public static let maximumLength = 64

    /// `text` as a series can be named: accents removed ("Reconstruções" gives
    /// "Reconstrucoes"), nothing outside printable ASCII, no backslash, which
    /// separates the values of a DICOM element, no space at either end and no
    /// more than a Long String holds. Empty when nothing of it is left.
    @objc(sanitizedName:)
    public static func sanitized(_ text: String?) -> String {
        guard let text else { return "" }
        var name = ""
        for scalar in withoutAccents(text).unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                name.append(" ")
            } else if isAllowed(scalar) {
                name.unicodeScalars.append(scalar)
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > maximumLength {
            name = String(name.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// The default name in the application's language. A translation written
    /// in another script would leave only its Latin words, so the English name
    /// stands in for it.
    @objc public static func defaultName() -> String {
        return defaultName(localized: NSLocalizedString("IsiX Screen Captures", comment: ""))
    }

    static func defaultName(localized: String) -> String {
        let latin = withoutAccents(localized)
        let name = sanitized(latin)
        if name.isEmpty || latin.unicodeScalars.contains(where: { $0.isASCII == false }) {
            return englishName
        }
        return name
    }

    /// The name in use: the preference, or the default when it is not set or
    /// nothing of it can be written.
    @objc public static func current() -> String {
        return name(preference: UserDefaults.standard.string(forKey: defaultsKey))
    }

    static func name(preference: String?) -> String {
        let name = sanitized(preference)
        return name.isEmpty ? defaultName() : name
    }

    /// Stores the preference as it will be written, so that the field of the
    /// preferences shows the name a capture gets; one that leaves nothing is
    /// removed, and the field shows the default again.
    @objc public static func normalizePreference() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: defaultsKey) else { return }
        let name = sanitized(stored)
        if name.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if name != stored {
            defaults.set(name, forKey: defaultsKey)
        }
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.value >= 0x20 && scalar.value <= 0x7E && scalar != "\\"
    }

    /// Latin letters without their accents, ligatures spelled out and
    /// typographic punctuation as its ASCII equivalent; other scripts are left
    /// as they are.
    private static func withoutAccents(_ text: String) -> String {
        return text.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? text
    }
}
