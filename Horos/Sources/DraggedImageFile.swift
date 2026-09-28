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

/// Names and reserves the file an image dragged out of a viewer is written into.
///
/// The destination directory belongs to whichever application accepts the drop,
/// so the name has to survive being turned into a path component there. A study
/// or series description is free text out of the DICOM data: it can hold a path
/// separator, a colon, or a leading dot, none of which can go into a file name
/// unexamined. Spaces are kept — this name is read by a person, unlike the
/// export folder names, which follow their own policy.
@objc(HorosDraggedImageFile)
public final class DraggedImageFile: NSObject {
    /// One safe path component describing what is being dragged.
    @objc(nameForStudy:series:)
    public static func name(study: String?, series: String?) -> String {
        let parts = [clean(study), clean(series)].filter { !$0.isEmpty }
        return parts.isEmpty ? "Horos" : parts.joined(separator: " - ")
    }

    /// The first unused URL for that name in `directory`, or nil when the
    /// directory already holds a thousand of them.
    @objc(urlInDirectory:name:pathExtension:)
    public static func url(in directory: URL, name: String, pathExtension: String) -> URL? {
        for index in 0...999 {
            let component = index == 0 ? name : "\(name) (\(index))"
            let candidate = directory.appendingPathComponent(component)
                                     .appendingPathExtension(pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Readable, one component, and short enough for any destination.
    static func clean(_ value: String?) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/\\:<>|?*\""))
        let mapped = (value ?? "").precomposedStringWithCanonicalMapping.unicodeScalars.map {
            forbidden.contains($0) ? " "
                : (CharacterSet.whitespacesAndNewlines.contains($0) ? " " : String($0))
        }.joined()
        let collapsed = mapped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        var result = ""
        for character in trimmed {
            guard result.utf8.count + String(character).utf8.count <= 96 else { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}
