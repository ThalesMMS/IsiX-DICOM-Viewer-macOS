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

/// The preferences that decide what the automatic query retrieves of what it
/// found, read once per retrieve.
public struct AutoRetrieveRules: Hashable, Sendable {
    /// A study is skipped when one already chosen has its accession number.
    public var skipsDuplicateAccessionNumbers: Bool
    /// A study retrieved in the last hour, with the same accession number and
    /// number of images, is not retrieved again.
    public var skipsRecentRetrieves: Bool
    /// With `skipsRecentRetrieves`, and while a study was retrieved in the last
    /// hour, mammography and breast ultrasound studies are skipped.
    public var skipsMammographyDescriptions: Bool
    /// The most studies chosen from one query, before the earlier studies.
    public var maximumStudies: Int
    /// A study whose node reports 0 images counts as one image, as a study
    /// whose node reports no number does.
    public var countsZeroImagesAsUnknown: Bool

    public init(skipsDuplicateAccessionNumbers: Bool = false, skipsRecentRetrieves: Bool = false,
                skipsMammographyDescriptions: Bool = false, maximumStudies: Int = 0, countsZeroImagesAsUnknown: Bool = false) {
        self.skipsDuplicateAccessionNumbers = skipsDuplicateAccessionNumbers
        self.skipsRecentRetrieves = skipsRecentRetrieves
        self.skipsMammographyDescriptions = skipsMammographyDescriptions
        self.maximumStudies = maximumStudies
        self.countsZeroImagesAsUnknown = countsZeroImagesAsUnknown
    }

    /// The rules as the preferences set them, under the keys the preference
    /// panes write.
    public init(preferences: any PreferenceStore) {
        self.init(skipsDuplicateAccessionNumbers: preferences[NetworkPreferences.autoRetrieveSkipsDuplicateAccessionNumbers],
                  skipsRecentRetrieves: preferences[NetworkPreferences.autoRetrieveSkipsRecentRetrieves],
                  skipsMammographyDescriptions: preferences[NetworkPreferences.autoRetrieveSkipsMammographyDescriptions],
                  maximumStudies: preferences[NetworkPreferences.maxNumberOfRetrieveForAutoQR]?.intValue ?? 0,
                  countsZeroImagesAsUnknown: preferences[NetworkPreferences.countsZeroImagesAsUnknown])
    }
}

/// The studies the automatic query retrieved in the last hour, by accession
/// number and number of images.
struct RecentAutoRetrieves: Sendable {
    struct Entry: Sendable, Equatable {
        let date: Date
        let accessionNumber: String?
        let numberOfImages: Int?
    }

    private(set) var entries: [Entry] = []

    /// Whether `study` is to be skipped. An entry older than an hour is
    /// forgotten on the way; any entry of the last hour skips a mammography or
    /// breast ultrasound study when `skipsMammography`, and one with the
    /// study's accession number and number of images skips it in any case.
    mutating func skips(_ study: AutoQueryStudy, skipsMammography: Bool, now: Date) -> Bool {
        var skip = false
        for entry in entries {
            guard entry.date.timeIntervalSince(now) > -60 * 60 else {
                entries.removeAll { $0 == entry }
                continue
            }
            if skipsMammography {
                let description = (study.studyDescription ?? "").lowercased()
                if description.hasPrefix("mg ") || description.hasPrefix("us seins") {
                    skip = true
                }
            }
            if let accessionNumber = entry.accessionNumber, accessionNumber == study.accessionNumber,
               (entry.numberOfImages ?? 0) == (study.numberOfImages ?? 0) {
                skip = true
            }
        }
        return skip
    }

    /// Remembers `study`; its number of images only with its accession number.
    mutating func remember(_ study: AutoQueryStudy, now: Date) {
        entries.append(Entry(date: now, accessionNumber: study.accessionNumber,
                             numberOfImages: study.accessionNumber == nil ? nil : study.numberOfImages))
    }
}

/// Chooses, among the studies a query found, those to retrieve: the first ones
/// that are not here yet, then the earlier studies of their patients that the
/// instance asks for.
struct AutoRetrieveChoice {
    let instance: AutoQueryInstance
    let rules: AutoRetrieveRules
    let querying: any AutoQueryRunning
    let retrieving: any AutoRetrieveStarting
    let localStudies: any LocalStudyReading
    let now: Date

    /// The modalities that never make an earlier study count.
    static let ignoredModalities: Set<String> = ["SR", "SC", "PR", "KO"]

    func choose(from found: [AutoQueryStudy], recent: inout RecentAutoRetrieves) async -> [AutoQueryStudy] {
        let local = await fileCounts(of: found)
        var chosen: [AutoQueryStudy] = []

        for study in found {
            var add = true

            if rules.skipsDuplicateAccessionNumbers {
                if chosen.contains(where: { $0.accessionNumber != nil && $0.accessionNumber == study.accessionNumber }) {
                    add = false
                }
            }

            if rules.skipsRecentRetrieves && recent.skips(study, skipsMammography: rules.skipsMammographyDescriptions, now: now) {
                add = false
            }

            if add {
                await addIfNotHere(study, localFiles: local[study.studyInstanceUID] ?? 0, to: &chosen)
                if rules.skipsRecentRetrieves {
                    recent.remember(study, now: now)
                }
            }

            if chosen.count >= rules.maximumStudies { break }
        }

        guard !chosen.isEmpty else { return [] }

        let wanted = instance.numberOfPreviousStudiesToRetrieve
        guard wanted != 0 else { return chosen }

        var earlier: [AutoQueryStudy] = []
        for study in chosen {
            let related = Self.newestFirst(await querying.studies(ofPatientID: study.patientID ?? ""))
            let relatedLocal = await fileCounts(of: related)
            var left = wanted
            for other in related {
                guard other.studyInstanceUID != study.studyInstanceUID, left > 0 else { continue }
                if counts(other, asEarlierStudyOf: study) {
                    await addIfNotHere(other, localFiles: relatedLocal[other.studyInstanceUID] ?? 0, to: &earlier)
                    left -= 1
                }
            }
        }
        return chosen + earlier
    }

    /// Whether `other` is an earlier study of `study` worth retrieving with it:
    /// it shares a modality (other than SR, SC, PR and KO) or its description
    /// holds this one's, as the instance asks.
    func counts(_ other: AutoQueryStudy, asEarlierStudyOf study: AutoQueryStudy) -> Bool {
        var found = false
        if instance.retrieveSameModality {
            let modalities = (study.modality ?? "").components(separatedBy: "\\")
            let others = (other.modality ?? "").components(separatedBy: "\\")
            for modality in modalities where !Self.ignoredModalities.contains(modality) && others.contains(modality) {
                found = true
            }
        }
        if instance.retrieveSameDescription, let description = study.studyDescription,
           let otherDescription = other.studyDescription, otherDescription.range(of: description) != nil {
            found = true
        }
        return found
    }

    /// Adds `study` when some of it is not here yet and it is not being
    /// retrieved for the same number of images. A node that reports no number
    /// of images (or 0, when the rules say so) counts as one when nothing of
    /// the study is here; an earlier retrieve that still matches what the node
    /// reports decides instead, and absences the node announced count as here.
    func addIfNotHere(_ study: AutoQueryStudy, localFiles: Int, to chosen: inout [AutoQueryStudy]) async {
        var here = localFiles
        var total = study.numberOfImages ?? 0
        if study.numberOfImages == nil || (rules.countsZeroImagesAsUnknown && total == 0) {
            if here == 0 { total = 1 }
        }
        if let inventory = await retrieving.retrieveInventory(of: study) {
            here = inventory.imported
            total = inventory.expected
            if inventory.isSatisfied { here = total }
        }
        if here < total, await retrieving.claimTransfer(of: study, expectedFiles: total) {
            chosen.append(study)
        }
    }

    /// The files here of each study, by UID; nothing when the database cannot
    /// be read, so that the retrieve asks for everything, as it would for a
    /// study not yet here.
    private func fileCounts(of studies: [AutoQueryStudy]) async -> [String: Int] {
        (try? await localStudies.fileCounts(ofStudyInstanceUIDs: Set(studies.map(\.studyInstanceUID)))) ?? [:]
    }

    /// `studies` by date and then time, the newest first and those without
    /// either last, the order of equal ones kept.
    static func newestFirst(_ studies: [AutoQueryStudy]) -> [AutoQueryStudy] {
        func newer(_ a: Date?, _ b: Date?) -> Bool? {
            switch (a, b) {
            case let (a?, b?): return a == b ? nil : a > b
            case (nil, nil): return nil
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
        return studies.enumerated().sorted { first, second in
            if let order = newer(first.element.date, second.element.date) { return order }
            if let order = newer(first.element.time, second.element.time) { return order }
            return first.offset < second.offset
        }.map(\.element)
    }
}
