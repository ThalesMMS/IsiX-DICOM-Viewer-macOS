//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXImaging

/// The marks the open viewers show for the studies of one patient: «Previous»
/// on the older studies, and a colour and a date rank for each study when
/// several are open.
@MainActor
enum ViewerStudyColouring {
    /// Marks `viewers`, sorted from the most recent study, among the studies
    /// of the patient of `study`.
    static func mark(_ viewers: [ViewerController], patientOf study: DicomStudy?) {

        // "Previous" on the viewers whose study is older than another open
        // study of the same patient.
        var patients: [String] = [], dates: [Any] = []
        for v in viewers {
            let study = v.currentStudy()
            patients.append(study?.patientUID ?? "")
            dates.append(study?.date ?? NSNull())
        }
        let previous = PreviousStudyMark.previousIndices(patients: patients, dates: dates)
        for (i, v) in viewers.enumerated() {
            PreviousStudyMark.setPrevious(previous.contains(i), for: v)
        }

        var colouredStudies: [String?] = []
        for v in viewers {
            if let study = v.currentStudy(), v.currentSeries() != nil {
                colouredStudies.append(study.studyInstanceUID)
            }
            for case let view as DCMView in v.imageViews() ?? [] {
                view.studyColorR = 0
                view.studyColorG = 0
                view.studyColorB = 0
                view.studyDateIndex = UInt(NSNotFound)
                view.needsDisplay = true
            }
        }

        guard !colouredStudies.isEmpty else { return }
        var allStudies: [Any]?

        // The browser's history, with the distant studies, when it is this patient's.
        let browser = PreferencesSource.process.processGraph.currentBrowser
        let comparativeUID = browser?.comparativePatientUID as NSString?
        if let comparativeUID, let patientUID = study?.patientUID,
           comparativeUID.compare(patientUID, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame,
           browser?.comparativeStudies != nil {
            allStudies = browser?.comparativeStudies
        } else if let db = browser?.database {
            // Every study of this patient.
            var search = study?.patientUID
            let predicate: NSPredicate
            if (search?.count ?? 0) == 0 || search == "0" {
                search = study?.name
                predicate = NSPredicate(format: "(name == %@)", argumentArray: [search as Any])
            } else {
                predicate = NSPredicate(format: "(patientUID BEGINSWITH[cd] %@)", argumentArray: [search as Any])
            }
            let found = db.objects(forEntity: db.studyEntity(), predicate: predicate) as [Any]?
            allStudies = (found as? [DicomStudy])?.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }

        // The distant studies of the history are not database objects: their UIDs are read by key.
        let patientStudies = (allStudies ?? []).map { ($0 as AnyObject).value(forKey: "studyInstanceUID") as? String }
        let colors: [Any] = ViewerController.studyColors()?.map { $0 } ?? []
        guard let marks = StudyColour.marks(viewerStudies: viewers.map { $0.studyInstanceUID() }, colouredStudies: colouredStudies,
                                            patientStudies: patientStudies, colourCount: colors.count) else { return }
        for (v, mark) in zip(viewers, marks) {
            let boxColor = mark.colourIndex.map { colors[$0] as? NSColor } ?? nil
            for case let view as DCMView in v.imageViews() ?? [] {
                view.studyColorR = Float(boxColor?.redComponent ?? 0)
                view.studyColorG = Float(boxColor?.greenComponent ?? 0)
                view.studyColorB = Float(boxColor?.blueComponent ?? 0)
                view.studyDateIndex = UInt(bitPattern: mark.dateIndex ?? NSNotFound)
                view.needsDisplay = true
            }
        }
    }
}
