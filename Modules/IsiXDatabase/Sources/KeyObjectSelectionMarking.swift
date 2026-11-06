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

/// Which images of a study the index makes key images because a Key Object
/// Selection Document "Of Interest" lists them.
///
/// A key object selection whose title is (113000, DCM, "Of Interest") says
/// that the images it references are the key images of the study, which is
/// what the database's key image flag means. The document and its images
/// arrive in any order, in one import or in several:
/// - a document just indexed marks the images it references that the study
///   already has, whenever they came;
/// - an image just indexed is marked when a document of the study, indexed
///   before, references it.
///
/// A document already indexed is not applied again to the images it met
/// before: an image the user took out of the key images stays out when some
/// other image of the study arrives. The title is told by its code value and
/// coding scheme designator; the meaning is text another system may word
/// differently. A document of any other title marks nothing.
public enum KeyObjectSelectionMarking {

    /// The SOP class of a Key Object Selection Document.
    public static let sopClassUID = "1.2.840.10008.5.1.4.1.1.88.59"
    /// The code value and coding scheme of the title "Of Interest" (CID 7010).
    public static let ofInterestCodeValue = "113000"
    public static let ofInterestCodingScheme = "DCM"

    /// A document title as the report reader gives it.
    public struct Title: Sendable, Equatable {
        public var value: String
        public var scheme: String
        public var meaning: String

        public init(value: String, scheme: String, meaning: String) {
            self.value = value
            self.scheme = scheme
            self.meaning = meaning
        }

        /// The title of `code`, the reader's (value, scheme, meaning); nil for
        /// anything else.
        public init?(code: [String]) {
            guard code.count == 3 else { return nil }
            self.init(value: code[0], scheme: code[1], meaning: code[2])
        }
    }

    /// A key object selection of the study, as read from its file.
    public struct Document: Sendable, Equatable {
        /// Its title; nil when the file did not read as a report.
        public var title: Title?
        /// The SOP Instance UIDs of the images it references.
        public var referencedInstances: [String]
        /// Whether this import indexed it.
        public var isNew: Bool

        public init(title: Title?, referencedInstances: [String], isNew: Bool) {
            self.title = title
            self.referencedInstances = referencedInstances
            self.isNew = isNew
        }
    }

    /// Whether a document of `title` selects key images.
    public static func isOfInterest(_ title: Title?) -> Bool {
        guard let title else { return false }
        return title.value.trimmingCharacters(in: .whitespaces) == ofInterestCodeValue
            && title.scheme.trimmingCharacters(in: .whitespaces) == ofInterestCodingScheme
    }

    /// The SOP Instance UIDs that become key images: those of
    /// `studyInstances`, every image of the study, that a new document "Of
    /// Interest" references, and those of `newInstances`, the images this
    /// import indexed, that one indexed before references.
    public static func instancesToMark(documents: [Document], newInstances: Set<String>,
                                       studyInstances: Set<String>) -> Set<String> {
        var marked = Set<String>()
        for document in documents where isOfInterest(document.title) {
            let present = document.isNew ? studyInstances : newInstances
            marked.formUnion(document.referencedInstances.filter { present.contains($0) })
        }
        return marked
    }
}
