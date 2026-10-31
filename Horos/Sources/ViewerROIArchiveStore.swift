/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXContracts

/// The ROI archives of the images of a series, the app's `ROIStoring`: the
/// ROI reports of their study (the "OsiriX ROI SR" series, one report per
/// image and frame) and the former ROIs folder of their database.
///
/// The process graph makes one over the images a viewer loads or saves, on
/// the main thread, where their database objects are read. It keeps the
/// images and their database, never the viewer. The reports of a study are
/// listed once, the first time one of its images is asked for.
@MainActor final class ViewerROIArchiveStore: ROIStoring {
    /// The database of the images, where new reports are made and indexed.
    let database: DicomDatabase
    private let ingest: DatabaseIngest
    private var images: [ROIImageReference: DicomImage] = [:]
    /// The reports of each study, as the study's ROI series held them when first asked, in the
    /// form DicomStudy.roiPath(forImage:inArray:) takes them.
    private var reports: [ObjectIdentifier: NSArray] = [:]

    init(images: [DicomImage], database: DicomDatabase, ingest: DatabaseIngest) {
        self.database = database
        self.ingest = ingest
        for image in images {
            let reference = Self.reference(of: image)
            if self.images[reference] == nil { self.images[reference] = image }
        }
    }

    /// The SOP Instance UID and the frame of `image`, as its report is filed.
    static func reference(of image: DicomImage) -> ROIImageReference {
        ROIImageReference(sopInstanceUID: image.sopInstanceUID() ?? "", frame: image.frameID?.intValue ?? 0)
    }

    /// The image of `reference`, when the store holds it.
    func image(of reference: ROIImageReference) -> DicomImage? {
        images[reference]
    }

    // MARK: - ROIStoring

    func storedArchive(of reference: ROIImageReference) -> StoredROIArchive? {
        guard let path = images[reference].flatMap(path(of:)) else { return nil }
        if let report = SRAnnotation.roi(fromDICOM: path) {
            return StoredROIArchive(archive: report, isReport: true)
        }
        // A file of the former ROIs folder is the archive itself.
        return FileManager.default.contents(atPath: path).map { StoredROIArchive(archive: $0, isReport: false) }
    }

    func destination(of reference: ROIImageReference) -> ROIArchiveDestination? {
        guard let image = images[reference] else { return nil }
        if let path = path(of: image) {
            let exists = FileManager.default.fileExists(atPath: path)
            // The former ROIs folder: the file goes, its ROIs go to a new report.
            guard exists, path == image.srPath() else {
                return ROIArchiveDestination(path: path, exists: exists, replacesFormerFile: false)
            }
            try? FileManager.default.removeItem(atPath: path)
            return newDestination(replacesFormerFile: true)
        }
        return newDestination(replacesFormerFile: false)
    }

    func write(_ archive: Data, to destination: ROIArchiveDestination, of reference: ROIImageReference) -> Bool {
        guard let image = images[reference],
              let report = SRAnnotation(rois: [], path: destination.path, forImage: image) else { return false }
        if let seriesInstanceUID = image.series?.study?.roiSRSeries()?.seriesDICOMUID {
            report.setSeriesInstanceUID(seriesInstanceUID)
        }
        report.horos_dataEncapsulated = archive as NSData
        return report.writeToFile(atPath: destination.path)
    }

    func index(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        ingest.index(paths, preset: .generated, in: database)
    }

    // MARK: - Files

    /// The file of the ROIs of `image`: its report, or a file of the former
    /// ROIs folder; nil when it has neither.
    private func path(of image: DicomImage) -> String? {
        guard let study = image.series?.study else { return nil }
        let key = ObjectIdentifier(study)
        if reports[key] == nil {
            reports[key] = NSArray(array: Array(study.roiSRSeries()?.images ?? []))
        }
        return study.roiPath(forImage: image, inArray: reports[key])
    }

    private func newDestination(replacesFormerFile: Bool) -> ROIArchiveDestination? {
        guard let path = database.uniquePathForNewDataFile(withExtension: "dcm") else { return nil }
        return ROIArchiveDestination(path: path, exists: FileManager.default.fileExists(atPath: path), replacesFormerFile: replacesFormerFile)
    }
}
