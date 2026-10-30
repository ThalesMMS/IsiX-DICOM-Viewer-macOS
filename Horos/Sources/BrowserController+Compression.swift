/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase

// Compressing and decompressing the files of the database, the compression
// the preferences give a modality (IsiXDatabase's CompressionChoice), and the
// former entry points of the incoming folder.

/// The JPEG threads running, against the number of processors.
private nonisolated(unsafe) var numberOfThreadsForJPEG: Int32 = 0

extension BrowserController {

    /// Takes a processor for a JPEG thread when one is free; true when none
    /// was.
    @objc(waitForAProcessor)
    func waitForAProcessor() -> Bool {
        let processors = max(Int32(ProcessInfo.processInfo.processorCount), 1)
        horos_processorsLock?.lock(whenCondition: 1)
        let result = numberOfThreadsForJPEG >= processors
        if !result {
            numberOfThreadsForJPEG += 1
            horos_processorsLock?.unlock(withCondition: numberOfThreadsForJPEG >= processors ? 0 : 1)
        } else {
            NSLog("waitForAProcessor ?? We should not be here...")
            horos_processorsLock?.unlock(withCondition: 0)
        }
        return result
    }

    /// The compression of the Compression preferences for the modality, and
    /// its quality. The Decompress service chooses through the same
    /// CompressionChoice, with the settings the application sends it.
    @objc(compressionForModality:quality:resolution:)
    nonisolated class func compression(forModality mod: String!, quality: UnsafeMutablePointer<Int32>!, resolution: Int32) -> Int32 {
        let defaults = UserDefaults.standard
        let choice = CompressionChoice.choice(forModality: mod, resolution: Int(resolution),
                                              resolutionLimit: defaults.integer(forKey: "CompressionResolutionLimit"),
                                              settings: defaults.array(forKey: "CompressionSettings"),
                                              lowResolutionSettings: defaults.array(forKey: "CompressionSettingsLowRes"))
        if let quality, let chosen = choice.quality {
            quality.pointee = chosen
        }
        return Int32(truncatingIfNeeded: choice.compression)
    }

    #if !OSIRIX_LIGHT

    @available(*, deprecated)
    @objc(decompressDICOMJPEGinINCOMING:)
    func decompressDICOMJPEGinINCOMING(_ array: [Any]!) {
        _ = database?.decompressFiles(atPaths: array, intoDirAtPath: database?.incomingDirPath())
    }

    @available(*, deprecated)
    @objc(decompressDICOMJPEG:)
    func decompressDICOMJPEG(_ array: [Any]!) {
        _ = database?.decompressFiles(atPaths: array, intoDirAtPath: nil)
    }

    @available(*, deprecated)
    @objc(compressDICOMJPEGinINCOMING:)
    func compressDICOMJPEGinINCOMING(_ array: [Any]!) {
        _ = database?.compressFiles(atPaths: array, intoDirAtPath: database?.incomingDirPath())
    }

    @available(*, deprecated)
    @objc(compressDICOMJPEG:)
    func compressDICOMJPEG(_ array: [Any]!) {
        _ = database?.compressFiles(atPaths: array)
    }

    /// 'C' compresses in place, 'X' into the import folder, 'D' and 'I' the
    /// same for decompressing.
    @available(*, deprecated)
    @objc(decompressArrayOfFiles:work:)
    func decompressArrayOfFiles(_ array: [Any]!, work: NSNumber!) {
        guard let database else { return }
        switch UInt8(bitPattern: work?.int8Value ?? 0) {
        case UInt8(ascii: "C"): database.processFiles(atPaths: array, intoDirAtPath: nil, mode: Int32(Compress))
        case UInt8(ascii: "X"): database.processFiles(atPaths: array, intoDirAtPath: database.incomingDirPath(), mode: Int32(Compress))
        case UInt8(ascii: "D"): database.processFiles(atPaths: array, intoDirAtPath: nil, mode: Int32(Decompress))
        case UInt8(ascii: "I"): database.processFiles(atPaths: array, intoDirAtPath: database.incomingDirPath(), mode: Int32(Decompress))
        default: break
        }
    }

    /// The DICOM files of the selection, each once: thumbnails when the menu
    /// or the focus is theirs, else the list.
    private func selectedDICOMFiles(_ sender: Any!) -> [Any] {
        let objects = NSMutableArray()
        let files: NSMutableArray?
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            files = self.files(forDatabaseMatrixSelection: objects)
        } else {
            files = self.files(forDatabaseOutlineSelection: objects)
        }
        guard let files else { return [] }
        files.removeDuplicatedStrings(inSyncWithThisArray: objects)
        var result: [Any] = []
        for index in 0 ..< files.count where index < objects.count {
            if ((objects[index] as AnyObject).value(forKey: "fileType") as? NSString)?.hasPrefix("DICOM") == true {
                result.append(files[index])
            }
        }
        return result
    }

    @objc(compressSelectedFiles:)
    func compressSelectedFiles(_ sender: Any!) {
        guard let database, database.isLocal() else {
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Non-Local Database", comment: ""),
                                                 message: NSLocalizedString("Cannot compress images in a distant database.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let files = selectedDICOMFiles(sender)
        DCMPix.purgeCachedDictionaries()
        database.initiateCompressFiles(atPaths: files)
    }

    @objc(decompressSelectedFiles:)
    func decompressSelectedFiles(_ sender: Any!) {
        guard let database, database.isLocal() else {
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Non-Local Database", comment: ""),
                                                 message: NSLocalizedString("Cannot decompress images in a distant database.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let files = selectedDICOMFiles(sender)
        DCMPix.purgeCachedDictionaries()
        database.initiateDecompressFiles(atPaths: files)
    }

    #endif

    // MARK: Incoming folder (former entry points)

    @available(*, deprecated)
    @objc(checkIncomingThread:)
    func checkIncomingThread(_ sender: Any!) {
        DicomDatabase.activeLocal()?.importFilesFromIncomingDir()
    }

    @available(*, deprecated)
    @objc(checkIncomingNow:)
    func checkIncomingNow(_ sender: Any!) {
        DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
    }

    @available(*, deprecated)
    @objc(checkIncoming:)
    func checkIncoming(_ sender: Any!) {
        DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
    }
}
