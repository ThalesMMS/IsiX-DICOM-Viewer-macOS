/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ¬†version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ¬†See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ¬†If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ¬† OsiriX
 ¬†Copyright (c) OsiriX Team
 ¬†All rights reserved.
 ¬†Distributed under GNU - LGPL
 ¬†
 ¬†See http://www.osirix-viewer.com/copyright.html for details.
 ¬† ¬† This software is distributed WITHOUT ANY WARRANTY; without even
 ¬† ¬† the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ¬† ¬† PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import ImageIO

/// Adds EXIF to a JPEG or TIFF file.
///
/// Implemented in Swift since #717: the Objective-C name, the selector and
/// <Horos/JPEGExif.h> are those of the former class.
@objc(JPEGExif)
public final class JPEGExif: NSObject {

    @objc(addExif:properties:format:)
    public class func addExif(_ url: URL!, properties exifDict: [AnyHashable: Any]!, format: String!) {
        // CGImageSourceCreateWithURL returned NULL for a nil URL.
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }

        var type: String? = nil

        if format == "tiff" { type = "public.tiff" }
        if format == "jpeg" { type = "public.jpeg" }

        // Finalize in memory before replacing the source file. An unfinished
        // ImageIO file destination leaves temporary files and drops the EXIF.
        let encoded = NSMutableData()
        let dest = type.flatMap { CGImageDestinationCreateWithData(encoded as CFMutableData, $0 as CFString, 1, nil) }
        if let dest {
            let newProps: NSDictionary = [kCGImagePropertyExifDictionary as String: (exifDict as NSDictionary?) ?? NSDictionary()]
            CGImageDestinationAddImageFromSource(dest, source, 0, newProps as CFDictionary)
            if CGImageDestinationFinalize(dest) {
                do {
                    try encoded.write(to: url, options: .atomic)
                } catch {
                    NSLog("Could not save image metadata: %@", error as NSError)
                }
            } else {
                NSLog("Could not finalize image metadata for %@", url as NSURL)
            }
        }
    }
}
