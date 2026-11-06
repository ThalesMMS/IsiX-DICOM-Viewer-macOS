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

/// What the selection asks of the database the images are in, and of the
/// destination. Declared here so that the decision does not reach the app;
/// the app implements it over its Core Data objects, on the thread of their
/// context, and the selection calls it there, synchronously. Anything the app
/// cannot answer is thrown: the rule then sends nothing.
public protocol RoutingCatalog {
    /// The files among `files` that the smart-album filter `filter` matches,
    /// in their order.
    func files(_ files: [RoutedFile], matchingFilter filter: String) throws -> [RoutedFile]

    /// The studies of the database whose patient UID is exactly `patientUID`.
    func studies(ofPatientUID patientUID: String) throws -> [RoutedStudy]

    /// Every file of every series of `study`.
    func files(of study: RoutedStudy) throws -> [RoutedFile]

    /// The number of files of the study of `file`, as the database counts them.
    func fileCount(ofStudyOf file: RoutedFile) throws -> Int32

    /// The number of images `node` reports for each study it answers with
    /// when asked for `studyInstanceUID`; empty when it answers none.
    func remoteImageCounts(ofStudyInstanceUID studyInstanceUID: String, on node: DICOMNode) throws -> [Int32]
}

/// What a rule cannot work out about its images.
public struct RoutingSelectionError: Error, Sendable, Hashable {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// Which imported files each autorouting rule sends.
public enum RoutingSelection {
    /// The files of one rule, for the queue.
    public struct Pick: Sendable, Hashable {
        public var rule: RoutingRule
        public var files: [RoutedFile]

        public init(rule: RoutingRule, files: [RoutedFile]) {
            self.rule = rule
            self.files = files
        }
    }

    /// Applies each activated rule of `rules`, in their order, to `files`,
    /// and logs which rule matched how many: the rules that matched files,
    /// with their files.
    public static func apply(_ rules: [RoutingRule], to files: [RoutedFile], nodes: [DICOMNode],
                             databasePath: String, catalog: some RoutingCatalog, now: Date = Date()) -> [Pick] {
        var picks: [Pick] = []
        for rule in rules where rule.isActivated {
            let chosen = (try? self.files(for: rule, of: files, nodes: nodes, databasePath: databasePath,
                                          catalog: catalog, now: now)) ?? []

            // Which rule queued which images, so a send that surprises someone
            // can be traced to the rule that asked for it.
            let filter = rule.entry[RoutingRule.Key.filter]
            let filterText: String
            if case .string(let text)? = filter, !text.isEmpty {
                filterText = ", filter: " + text
            } else {
                filterText = ""
            }
            NSLog(" Autorouting rule \"%@\" -> %@: %d of %d image(s) matched%@",
                  rule.loggedName, rule.entry[RoutingRule.Key.destination]?.text ?? "(null)",
                  Int32(truncatingIfNeeded: chosen.count), Int32(truncatingIfNeeded: files.count), filterText)

            if !chosen.isEmpty {
                picks.append(Pick(rule: rule, files: chosen))
            }
        }
        return picks
    }

    /// The files `rule` sends of `files`:
    /// - those its filter matches, of the files the app generated (filter
    ///   type 1) or imported (2) when it asks for them;
    /// - only image storage when it asks for images only;
    /// - when any are left, the files of up to `previousStudies` earlier
    ///   studies of each study's patient that the rule's destination has not
    ///   been given within three hours (`PreviousRoutingStudies`);
    /// - with a C-FIND test, without the studies the destination already has
    ///   with at least as many images.
    public static func files(for rule: RoutingRule, of imported: [RoutedFile], nodes: [DICOMNode],
                             databasePath: String, catalog: some RoutingCatalog, now: Date = Date()) throws -> [RoutedFile] {
        var files = imported
        switch rule.filterType {
        case 1: files = files.filter(\.isGeneratedByApp)
        case 2: files = files.filter(\.isImported)
        default: break
        }
        files = try catalog.files(files, matchingFilter: rule.effectiveFilter ?? "")

        if rule.imagesOnly {
            files = files.filter(\.isImageStorage)
        }
        guard !files.isEmpty else { return files }

        if rule.previousStudies > 0 {
            files += try previousStudyFiles(for: rule, of: files, nodes: nodes, databasePath: databasePath,
                                            catalog: catalog, now: now)
        }

        if rule.cfindTest {
            files = try withoutStudiesAlreadyThere(files, rule: rule, nodes: nodes, catalog: catalog)
        }
        return files
    }

    /// The files of the earlier studies that go with `files`.
    static func previousStudyFiles(for rule: RoutingRule, of files: [RoutedFile], nodes: [DICOMNode],
                                   databasePath: String, catalog: some RoutingCatalog, now: Date) throws -> [RoutedFile] {
        let node = RoutingDestination.resolve(named: rule.destinationName, in: nodes, ruleName: rule.name).node
        var currentStudies: [RoutedStudy] = []
        var currentIDs = Set<String>()
        for file in files where currentIDs.insert(file.study.id).inserted {
            currentStudies.append(file.study)
        }

        var added: [RoutedFile] = []
        var selected = Set<String>()
        for study in currentStudies {
            guard let node, let patientUID = study.patientUID, !patientUID.isEmpty else { continue }
            let candidates = try catalog.studies(ofPatientUID: patientUID).sorted(by: isListedBefore)
            var remaining = rule.previousStudies
            for prior in candidates {
                if currentIDs.contains(prior.id) { continue }
                if !PreviousRoutingStudies.matches(prior, currentStudy: study, modality: rule.previousModality,
                                                   description: rule.previousDescription) { continue }
                let exhausted = remaining <= 0
                remaining -= 1
                if exhausted { break }
                if !selected.insert(prior.id).inserted { continue }
                var priorFiles = try catalog.files(of: prior)
                if rule.imagesOnly {
                    priorFiles = priorFiles.filter(\.isImageStorage)
                }
                if !priorFiles.isEmpty && PreviousRoutingStudies.reserve(study: prior.studyInstanceUID ?? "", node: node,
                                                                        databasePath: databasePath, now: now) {
                    added += priorFiles
                }
            }
        }
        return added
    }

    /// The order the earlier studies are tried in: the most recent first,
    /// then by Study Instance UID; a study without a date last, and one
    /// without a UID before the others of its date.
    static func isListedBefore(_ left: RoutedStudy, _ right: RoutedStudy) -> Bool {
        switch (left.date, right.date) {
        case let (l?, r?) where l != r: return l > r
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        switch (left.studyInstanceUID, right.studyInstanceUID) {
        case let (l?, r?): return (l as NSString).compare(r) == .orderedAscending
        case (nil, _?): return true
        default: return false
        }
    }

    /// `files` without the studies the rule's destination already has with
    /// at least as many images as here.
    static func withoutStudiesAlreadyThere(_ files: [RoutedFile], rule: RoutingRule, nodes: [DICOMNode],
                                           catalog: some RoutingCatalog) throws -> [RoutedFile] {
        // The first file of each study stands for it.
        var studies: [(uid: String, file: RoutedFile)] = []
        var seen = Set<[UInt16]>()
        for file in files {
            guard let uid = file.study.studyInstanceUID else {
                throw RoutingSelectionError("an image has no Study Instance UID to ask the destination for")
            }
            if seen.insert(Array(uid.utf16)).inserted {
                studies.append((uid, file))
            }
        }

        var kept = files
        for (uid, file) in studies {
            guard let node = RoutingDestination.firstActivatedNode(named: rule.destinationName, in: nodes) else { continue }
            let counts = try catalog.remoteImageCounts(ofStudyInstanceUID: uid, on: node)
            guard let reported = counts.last else { continue }
            if counts.count > 1 {
                NSLog("Uh? multiple studies with same StudyInstanceUID on the distal node....")
            }
            if reported >= (try catalog.fileCount(ofStudyOf: file)) {
                NSLog("Already available on the distant node : we will not send it.")
                kept.removeAll { $0.study.studyInstanceUID.map { ($0 as NSString).isEqual(to: uid) } == true }
            }
        }
        return kept
    }
}
