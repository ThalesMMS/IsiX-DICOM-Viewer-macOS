//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXContracts
import IsiXPreferences

/// What an import of files into the database was asked for: the files of a
/// medium, a drop or an open panel, copied into the database folder or indexed
/// where they are. Values only, so it goes to the thread that does the work.
public struct MediaImportRequest: Hashable, Sendable {
    public let files: [String]
    /// Into the database folder; otherwise indexed where they are.
    public let copyFiles: Bool
    /// From a medium, which is not read twice: no validation before indexing.
    public let mountedVolume: Bool
    public let onlyDICOM: Bool
    /// Into the album the browser shows, when it shows this database.
    public let addToAlbum: Bool
    /// Selects the first study indexed.
    public let selectStudy: Bool
    /// Ejects the medium at the end, as the EJECTCDDVD preference allows.
    public let ejectCDDVD: Bool

    public init(files: [String], copyFiles: Bool, mountedVolume: Bool, onlyDICOM: Bool = false,
                addToAlbum: Bool = false, selectStudy: Bool = false, ejectCDDVD: Bool = false) {
        self.files = files
        self.copyFiles = copyFiles
        self.mountedVolume = mountedVolume
        self.onlyDICOM = onlyDICOM
        self.addToAlbum = addToAlbum
        self.selectStudy = selectStudy
        self.ejectCDDVD = ejectCDDVD
    }

    /// The dictionary of -[DicomDatabase copyFilesThread:], whose keys plugins
    /// write. What is not a path in "filesInput" is left out, and only that; a
    /// switch that is absent is off.
    public init(options: [AnyHashable: Any]) {
        func isOn(_ key: String) -> Bool { (options[key] as? NSNumber)?.boolValue ?? false }
        self.init(files: (options["filesInput"] as? [Any] ?? []).compactMap { $0 as? String },
                  copyFiles: isOn("copyFiles"), mountedVolume: isOn("mountedVolume"), onlyDICOM: isOn("onlyDICOM"),
                  addToAlbum: isOn("addToAlbum"), selectStudy: isOn("selectStudy"), ejectCDDVD: isOn("ejectCDDVD"))
    }

    /// The dictionary of a drop on the browser: asynchronous, into the album
    /// it shows, its first study selected, and "onlyDICOM" as the typed key
    /// reads the preference. The registered value is the text "1" and the
    /// preferences pane writes a number, and `init(options:)` takes only a
    /// number, so the value goes as a number: a file that is not DICOM has
    /// the same fate whether the pane ever wrote the preference or not.
    /// Without any value for the preference the dictionary is empty, as it
    /// always was.
    public static func dropOptions(preferences: any PreferenceStore) -> [AnyHashable: Any] {
        guard preferences.object(forKey: DatabasePreferences.onlyDICOM.name) != nil else { return [:] }
        return ["onlyDICOM": NSNumber(value: preferences[DatabasePreferences.onlyDICOM]), "async": NSNumber(value: true),
                "addToAlbum": NSNumber(value: true), "selectStudy": NSNumber(value: true)]
    }

    /// The files in the order they are read: sorted, which is faster on optical media.
    public var orderedFiles: [String] {
        files.sorted { ($0 as NSString).compare($1) == .orderedAscending }
    }

    /// The options of the indexing: those of a copy, under the name of where it came from.
    public var preset: IngestPreset {
        switch (mountedVolume, onlyDICOM) {
        case (true, true): return .mediaCopyDICOM
        case (true, false): return .mediaCopyAnything
        case (false, true): return .dragAndDropDICOM
        case (false, false): return .dragAndDropAnything
        }
    }

    /// Whether the import needs anything of the browser.
    public var usesBrowser: Bool {
        addToAlbum || selectStudy
    }
}
