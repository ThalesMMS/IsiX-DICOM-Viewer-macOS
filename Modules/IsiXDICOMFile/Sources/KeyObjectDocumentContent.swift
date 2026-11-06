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

/// What a Key Object Selection Document the app writes for a study holds: the
/// key images it lists, its content tree (TID 2010, "Of Interest") and its
/// Current Requested Procedure Evidence, grouped by study and series. The
/// images and their flags are the database's; DCMTK, in the app's adapter,
/// writes the document these rules describe.
public enum KeyObjectDocumentContent {

    /// A coded concept: code value, coding scheme designator, code meaning.
    public struct Code: Sendable, Equatable {
        public let value: String
        public let scheme: String
        public let meaning: String

        public init(value: String, scheme: String, meaning: String) {
            self.value = value
            self.scheme = scheme
            self.meaning = meaning
        }
    }

    /// The SOP class of the document.
    public static let sopClassUID = "1.2.840.10008.5.1.4.1.1.88.59"
    /// The document title, from CID 7010: the images are of interest, with no
    /// further reason given.
    public static let documentTitle = Code(value: "113000", scheme: "DCM", meaning: "Of Interest")
    /// The template of the root container, TID 2010 of the DICOM mapping resource.
    public static let templateIdentifier = "2010"
    public static let mappingResource = "DCMR"
    /// The description of the new series that holds the document.
    public static let seriesDescription = "Key Object Selection"
    /// The document is the only instance of its series.
    public static let instanceNumber = 1
    /// The series numbers of the app's own SR series of a study (ROIs 5002,
    /// report 5003, annotations 5004, windows state 5006), which a new series
    /// is not numbered after.
    public static let ownSeriesNumbers: ClosedRange<Int> = 5002...5006

    /// An image of the database, one frame of it for a multi-frame object.
    public struct Image: Sendable, Equatable {
        public var studyInstanceUID: String?
        public var seriesInstanceUID: String?
        public var sopClassUID: String?
        public var sopInstanceUID: String?
        /// The frame of the object this image is, from 0, as the database numbers them.
        public var frameIndex: Int
        public var numberOfFrames: Int
        public var seriesNumber: Int
        public var instanceNumber: Int
        public var isKeyImage: Bool
        /// Whether its series holds pictures, not a report, a presentation
        /// state or another document.
        public var isPicture: Bool

        public init(studyInstanceUID: String?, seriesInstanceUID: String?, sopClassUID: String?, sopInstanceUID: String?,
                    frameIndex: Int = 0, numberOfFrames: Int = 1, seriesNumber: Int = 0, instanceNumber: Int = 0,
                    isKeyImage: Bool, isPicture: Bool = true) {
            self.studyInstanceUID = studyInstanceUID
            self.seriesInstanceUID = seriesInstanceUID
            self.sopClassUID = sopClassUID
            self.sopInstanceUID = sopInstanceUID
            self.frameIndex = frameIndex
            self.numberOfFrames = numberOfFrames
            self.seriesNumber = seriesNumber
            self.instanceNumber = instanceNumber
            self.isKeyImage = isKeyImage
            self.isPicture = isPicture
        }
    }

    /// An IMAGE item of the document: one object, and the frames of it that
    /// are key images, from 1 as DICOM numbers them; none when it has one
    /// frame or all of its frames are, which is what an absent Referenced
    /// Frame Number says.
    public struct Reference: Sendable, Equatable {
        public let studyInstanceUID: String
        public let seriesInstanceUID: String
        public let sopClassUID: String
        public let sopInstanceUID: String
        public let frames: [Int]

        public init(studyInstanceUID: String, seriesInstanceUID: String, sopClassUID: String, sopInstanceUID: String,
                    frames: [Int] = []) {
            self.studyInstanceUID = studyInstanceUID
            self.seriesInstanceUID = seriesInstanceUID
            self.sopClassUID = sopClassUID
            self.sopInstanceUID = sopInstanceUID
            self.frames = frames
        }

        /// The frames as DCMTK takes them: numbers separated by commas; nil
        /// for the whole object.
        public var framesText: String? {
            frames.isEmpty ? nil : frames.map(String.init).joined(separator: ",")
        }
    }

    /// The content tree: a root CONTAINER named by the document title, of
    /// template 2010, that CONTAINS one IMAGE item, with no concept name, per
    /// referenced object.
    public struct Tree: Sendable, Equatable {
        public let title: Code
        public let templateIdentifier: String
        public let mappingResource: String
        public let images: [Reference]
    }

    /// An instance of the evidence.
    public struct Instance: Sendable, Equatable {
        public let sopClassUID: String
        public let sopInstanceUID: String
    }

    /// The instances of a series in the evidence.
    public struct EvidenceSeries: Sendable, Equatable {
        public let seriesInstanceUID: String
        public let instances: [Instance]
    }

    /// The series of a study in the evidence.
    public struct EvidenceStudy: Sendable, Equatable {
        public let studyInstanceUID: String
        public let series: [EvidenceSeries]
    }

    // MARK: - Rules

    /// The key images of the study `studyInstanceUID`, from every series of
    /// it that holds pictures, one reference per object: the frames of a
    /// multi-frame object that are key images are gathered in it. An image
    /// without its UIDs, of another study or that is not a key image is left
    /// out. In the order of the series numbers, then of the instance numbers,
    /// the UIDs breaking ties.
    public static func keyImages(_ images: [Image], inStudy studyInstanceUID: String) -> [Reference] {
        struct Gathered {
            var image: Image
            var frames: Set<Int>
        }
        var gathered: [String: Gathered] = [:]
        for image in images where image.isKeyImage && image.isPicture && image.studyInstanceUID == studyInstanceUID {
            guard let instance = nonEmpty(image.sopInstanceUID), nonEmpty(image.seriesInstanceUID) != nil,
                  nonEmpty(image.sopClassUID) != nil else { continue }
            gathered[instance, default: Gathered(image: image, frames: [])].frames.insert(max(0, image.frameIndex) + 1)
        }

        let ordered = gathered.values.sorted { lhs, rhs in
            let a = lhs.image, b = rhs.image
            if a.seriesNumber != b.seriesNumber { return a.seriesNumber < b.seriesNumber }
            if a.seriesInstanceUID != b.seriesInstanceUID { return (a.seriesInstanceUID ?? "") < (b.seriesInstanceUID ?? "") }
            if a.instanceNumber != b.instanceNumber { return a.instanceNumber < b.instanceNumber }
            return (a.sopInstanceUID ?? "") < (b.sopInstanceUID ?? "")
        }
        return ordered.map { entry in
            let image = entry.image
            let frames = image.numberOfFrames > 1 && entry.frames.count < image.numberOfFrames ? entry.frames.sorted() : []
            return Reference(studyInstanceUID: studyInstanceUID, seriesInstanceUID: image.seriesInstanceUID ?? "",
                             sopClassUID: image.sopClassUID ?? "", sopInstanceUID: image.sopInstanceUID ?? "", frames: frames)
        }
    }

    /// The content tree of the document that lists `references`.
    public static func tree(of references: [Reference]) -> Tree {
        Tree(title: documentTitle, templateIdentifier: templateIdentifier, mappingResource: mappingResource,
             images: references)
    }

    /// The Current Requested Procedure Evidence of `references`: every
    /// referenced instance once, under its series and its study, each in the
    /// order it first appears.
    public static func evidence(of references: [Reference]) -> [EvidenceStudy] {
        var studies: [String] = []
        var seriesOfStudy: [String: [String]] = [:]
        var instancesOfSeries: [String: [Instance]] = [:]
        var seen: Set<String> = []
        for reference in references where seen.insert(reference.sopInstanceUID).inserted {
            if seriesOfStudy[reference.studyInstanceUID] == nil {
                studies.append(reference.studyInstanceUID)
            }
            let key = reference.studyInstanceUID + "\u{0}" + reference.seriesInstanceUID
            if instancesOfSeries[key] == nil {
                seriesOfStudy[reference.studyInstanceUID, default: []].append(reference.seriesInstanceUID)
            }
            instancesOfSeries[key, default: []].append(Instance(sopClassUID: reference.sopClassUID,
                                                                sopInstanceUID: reference.sopInstanceUID))
        }
        return studies.map { study in
            EvidenceStudy(studyInstanceUID: study, series: (seriesOfStudy[study] ?? []).map { series in
                EvidenceSeries(seriesInstanceUID: series, instances: instancesOfSeries[study + "\u{0}" + series] ?? [])
            })
        }
    }

    /// The number of the new series: one more than the highest of the study's
    /// series, the app's own SR series aside; 1 for a study without others.
    public static func seriesNumber(after existing: [Int]) -> Int {
        (existing.filter { !ownSeriesNumbers.contains($0) }.max() ?? 0) + 1
    }

    /// Whether a document read back - its title's meaning and the instances
    /// of its IMAGE items, in the order of its tree - is the one written for
    /// `references`.
    public static func readsBack(title: String?, instances: [String], as references: [Reference]) -> Bool {
        title == documentTitle.meaning && instances == references.map(\.sopInstanceUID)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
