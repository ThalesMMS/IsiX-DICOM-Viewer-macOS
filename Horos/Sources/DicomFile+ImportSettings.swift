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
import IsiXDICOMFile
import IsiXPreferences

extension DicomFile {
    /// The settings shared by the threads that import.
    static let importSettings = ImportSettingsStore()
}

/// The preferences the import reads, read once for every file until the
/// preferences change (+resetDefaults). The DICOM reading asks for them at
/// every file.
@objc(ImportSettings) @implementation extension DicomFile {

    class func setDefaults() {
        importSettings.load {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: ImportSettings.registeredKey) != nil {
                return ImportSettings(defaults: defaults)
            }
            // For the SAFEDBREBUILD shell tool: the factory settings, with the
            // user's own over them.
            let dictionary = DefaultPreferences.applicationDefaults()
            if let user = defaults.persistentDomain(forName: BUNDLE_IDENTIFIER) {
                dictionary.addEntries(from: user)
            }
            return ImportSettings(dictionary: dictionary)
        }
    }

    class func resetDefaults() {
        importSettings.reset()
    }

    func commentsFromDICOMFiles() -> Bool { DicomFile.importSettings.settings.commentsFromDICOMFiles }
    func autoFillComments() -> Bool { DicomFile.importSettings.settings.commentsAutoFill }
    func useSeriesDescription() -> Bool { DicomFile.importSettings.settings.useSeriesDescription }
    func splitMultiEchoMR() -> Bool { DicomFile.importSettings.settings.splitMultiEchoMR }
    func noLocalizer() -> Bool { DicomFile.importSettings.settings.noLocalizer }
    func oneFileOnSeriesForUS() -> Bool { DicomFile.importSettings.settings.oneFileOnSeriesForUS }
    func combineProjectionSeries() -> Bool { DicomFile.importSettings.settings.combineProjectionSeries }
    func combineProjectionSeriesMode() -> Bool { DicomFile.importSettings.settings.combineProjectionSeriesMode != 0 }
    func separateCardiac4D() -> Bool { DicomFile.importSettings.settings.separateCardiac4D }
    func commentsGroup() -> Int32 { DicomFile.importSettings.settings.commentsGroup }
    func commentsElement() -> Int32 { DicomFile.importSettings.settings.commentsElement }
    func commentsGroup2() -> Int32 { DicomFile.importSettings.settings.commentsGroup2 }
    func commentsElement2() -> Int32 { DicomFile.importSettings.settings.commentsElement2 }
    func commentsGroup3() -> Int32 { DicomFile.importSettings.settings.commentsGroup3 }
    func commentsElement3() -> Int32 { DicomFile.importSettings.settings.commentsElement3 }
    func commentsGroup4() -> Int32 { DicomFile.importSettings.settings.commentsGroup4 }
    func commentsElement4() -> Int32 { DicomFile.importSettings.settings.commentsElement4 }
}
