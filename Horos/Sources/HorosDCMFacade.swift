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

/// Plugin-facing DCM compatibility contract for the DCMTK parser migration (#372).
///
/// Moving parsing onto DCMTK does not authorize removing `DCM.framework`,
/// `PluginFilter`, or the class, selector and header names plugins already compile
/// against. The donor fork's plugin-system deletion is out of scope. Legacy and 2011
/// keyword spellings (`PatientsName` / `PatientName`) must resolve to the same
/// tag. A valid DICOM file whose decoder is missing is kept, not deleted or
/// silently rewritten as a different object. Original Specific Character Set
/// declarations stay on the object; Core Data is not a parser migration.
@objc(HorosDCMFacade)
public final class HorosDCMFacade: NSObject {
    @objc public static let requiredFrameworkName = "DCM.framework"
    @objc public static let donorPluginCleanupTestThatMustNotBeCopied = "test_plugin_cleanup.py"
    @objc public static let requiredPluginTypes = [
        "PluginFilter", "DCMPix", "DCMView", "ROI", "ViewerController",
    ]

    @objc(otherSpellingFor:)
    public static func otherSpelling(for name: String) -> String? {
        DICOMKeyword.otherSpelling(for: name)
    }

    @objc(tagStringForName:inDictionary:)
    public static func tagString(forName name: String, in dictionary: [String: String]) -> String? {
        if let direct = dictionary[name], direct.isEmpty == false { return direct }
        guard let other = DICOMKeyword.otherSpelling(for: name),
              let mapped = dictionary[other], mapped.isEmpty == false else {
            return nil
        }
        return mapped
    }

    @objc public static func mayRemovePluginFacingType(_ name: String) -> Bool {
        requiredPluginTypes.contains(name) == false
    }

    /// Unknown vendor tags do not receive a guessed private creator.
    @objc public static func guessedPrivateCreator(forUnknownTag tag: String) -> String? {
        _ = tag
        return nil
    }

    @objc public static func dispositionForValidFileMissingDecoder() -> String { "keep" }

    @objc public static func characterSetDisposition() -> String { "retainOriginal" }

    @objc public static func parserMigrationMayChangeCoreDataSchema() -> Bool { false }
}
