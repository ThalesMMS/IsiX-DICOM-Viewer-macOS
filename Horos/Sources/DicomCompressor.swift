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
import IsiXDatabase

/** \brief Compresses and decompresses lists of DICOM files

 The implementation of DicomCompressor, declared in DicomCompressor.h: the
 class a plugin built for the Horos or OsiriX SDK sends its lists of files to.
 The SDK's class started the Decompress helper once for every 200 files and
 waited for it; the conversion is the Decompress service's now, which the
 database's own conversions go through, and this class only says where the
 results go and with which settings (DicomCompressorRequest, in IsiXDatabase).
 */
@objc @implementation extension DicomCompressor {
    class func decompressFiles(_ filePaths: [Any]!, toDirectory dirPath: String!) {
        convert(filePaths, into: dirPath, options: nil, mode: .decompressList)
    }

    class func decompressFiles(_ filePaths: [Any]!, toDirectory dirPath: String!, withOptions options: [AnyHashable: Any]!) {
        convert(filePaths, into: dirPath, options: options, mode: .decompressList)
    }

    class func decompressFiles(_ filePaths: [Any]!, toDirectory dirPath: String!, withOptionsPath optionsPlistPath: String!) {
        convert(filePaths, into: dirPath, options: DicomCompressorRequest.options(atPath: optionsPlistPath), mode: .decompressList)
    }

    class func compressFiles(_ filePaths: [Any]!, toDirectory dirPath: String!) {
        convert(filePaths, into: dirPath, options: nil, mode: .compress)
    }

    class func compressFiles(_ filePaths: [Any]!, toDirectory dirPath: String!, withOptions options: [AnyHashable: Any]!) {
        convert(filePaths, into: dirPath, options: options, mode: .compress)
    }

    class func compressFiles(_ filePaths: [Any]!, toDirectory dirPath: String!, withOptionsPath optionsPlistPath: String!) {
        convert(filePaths, into: dirPath, options: DicomCompressorRequest.options(atPath: optionsPlistPath), mode: .compress)
    }

    /// Converts the files 200 at a time on the calling thread, which it keeps
    /// until the last batch has ended, or the one during which the thread was
    /// cancelled. Nothing here is the main thread's: a plugin calls from a
    /// thread of its own. What is not the path of a file is left out.
    private static func convert(_ filePaths: [Any]?, into directory: String?, options: [AnyHashable: Any]?,
                                mode: DecompressConversion.Mode) {
        let files = (filePaths ?? []).compactMap { $0 as? String }
        guard !files.isEmpty else { return }
        let request = DicomCompressorRequest(directory: directory, options: options, preferences: PreferencesSource.process.preferences)
        let thread = Thread.current
        let message = mode == .compress ? "+[DicomCompressor compressFiles:toDirectory:]" : "+[DicomCompressor decompressFiles:toDirectory:]"
        // The SDK's class reported no progress, and left the files of a helper
        // that crashed where they were.
        var environment = CompressionHelperRun.Environment(
            progress: { _ in },
            now: { Date.timeIntervalSinceReferenceDate },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            logStackTrace: { N2LogStackTraceMessage($0) },
            logLaunchFailure: { NSLog("%@: %@", message, $0.localizedDescription) },
            crashed: { _ in })
        environment.cancelled = { thread.isCancelled }
        _ = CompressionHelperRun.run(files, mode: mode.rawValue, destination: request.destination, environment: environment) {
            request.batch(arguments: $0, service: DecompressService.shared)
        }
    }
}
