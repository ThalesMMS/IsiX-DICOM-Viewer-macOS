/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The class DicomFile.h declares: its state, its initializers and its
/// accessors. The readers, the classification of a file, the text of its
/// values and the preferences of the import are the categories, in
/// DicomFile+<category>.swift; the rules they apply are in the IsiXDICOMFile
/// module.
///
/// The state is what each reader fills in for the next steps of the import:
/// the identifiers and the descriptions it read, kept as the objects that go
/// into `dicomElements`, the size and the counts.
@objc @implementation extension DicomFile {

    // MARK: - State

    /// The file -init: was given.
    final var horos_filePath: String?
    final var horos_name: NSString?
    final var horos_study: NSString?
    final var horos_serie: NSString?
    final var horos_fileType: NSString?
    final var horos_modality: NSString?
    final var horos_sopUID: NSString?
    final var horos_imageType: NSString?
    final var horos_studyID: String?
    final var horos_imageID: String?
    final var horos_patientID: NSString?
    final var horos_studyIDs: NSString?
    final var horos_seriesNo: NSString?
    final var horos_date: NSDate?
    /// Width, height, frames and series, which -init: puts in the elements
    /// once a reader has read the file.
    final var horos_width: Int = 0
    final var horos_height: Int = 0
    final var horos_numberOfFrames: Int = 0
    final var horos_numberOfSeries: Int = 0
    final var horos_dicomElements = NSMutableDictionary()

    var serieID: String!

    // MARK: - Initializers

    convenience init!(_ f: String!) {
        self.init(f, dicomOnly: false)
    }

    @objc(init:DICOMOnly:) init!(_ f: String!, dicomOnly DICOMOnly: Bool) {
        // Width and height need to be greater than 0, or the database refuses the row.
        horos_width = 1
        horos_height = 1
        horos_filePath = f
        horos_numberOfSeries = 1
        super.init()
        if !readFile(dicomOnly: DICOMOnly) { return nil }
    }

    @objc(initRandom) init!(random: ()) {
        DicomFile.setDefaults()
        horos_width = 1
        horos_height = 1
        // random(), which the Objective-C used, is unavailable in Swift; the
        // numbers only have to differ from one made-up file to the next.
        horos_filePath = String(format: "protp/aksidkoa/saodkireks/ksidjaiskd/orkerofk%d", Int32.random(in: 0...Int32.max))
        horos_numberOfSeries = 1
        super.init()
        readRandomFile(numbered: Int.random(in: 0...Int(Int32.max)))
    }

    // MARK: - Accessors

    @objc(NoOfSeries) func noOfSeries() -> Int { horos_numberOfSeries }
    func getWidth() -> Int { horos_width }
    func getHeight() -> Int { horos_height }
    @objc(NoOfFrames) func noOfFrames() -> Int { horos_numberOfFrames }

    func dicomElements() -> NSMutableDictionary! { horos_dicomElements }

    func element(forKey key: Any!) -> Any! {
        guard let key = key as? NSCopying else { return nil }
        return horos_dicomElements.object(forKey: key)
    }
}
