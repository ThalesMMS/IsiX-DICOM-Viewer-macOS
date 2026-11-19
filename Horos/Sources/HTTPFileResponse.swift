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

/// The implementation of HTTPFileResponse, declared in HTTPResponse.h: the
/// response of the Horos and OsiriX SDK's HTTP server whose body is a file,
/// read as it is sent. The class is Objective-C for the runtime, so that a
/// plugin built for either SDK finds it by name and its Objective-C subclass
/// keeps every method.
///
/// The length is that of the file opened. The SDK took it from the attributes
/// of the path, which for a symbolic link are the link's: a body was then
/// announced with the length of the link's text and the rest of it ran into
/// the next response of the connection.
@objc @implementation extension HTTPFileResponse {
    // The three instance variables of the SDK, with its types: a plugin built
    // for it binds their names when it loads, and its subclass reads and
    // writes them directly. The path's name here is another because the class
    // answers -filePath.
    final var horos_filePath: NSString?
    final var fileHandle: FileHandle?
    final var fileLength: UInt64 = 0

    public override init() {
        super.init()
    }

    /// Nil when the file cannot be opened for reading.
    public init!(filePath: String!) {
        super.init()
        guard let filePath, let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0, status.st_size >= 0 else {
            try? handle.close()
            return nil
        }
        horos_filePath = filePath as NSString
        fileHandle = handle
        fileLength = UInt64(status.st_size)
    }

    deinit {
        try? fileHandle?.close()
    }

    func filePath() -> String! {
        horos_filePath as String?
    }

    var contentLength: UInt64 {
        fileLength
    }

    var offset: UInt64 {
        get { (try? fileHandle?.offset()) ?? 0 }
        set { try? fileHandle?.seek(toOffset: newValue) }
    }

    /// Up to `length` bytes from the offset, which moves past them; nothing
    /// at the end of the file.
    func readData(ofLength length: UInt32) -> Data! {
        ((try? fileHandle?.read(upToCount: Int(length))) ?? nil) ?? Data()
    }

    var isDone: Bool {
        offset == fileLength
    }
}

// What the connection's exchange reads a response through; see the same
// extension of HTTPDataResponse.
extension HTTPFileResponse: HTTPServerResponse, HTTPServerDeferredResponse {
    func readData(ofLength length: Int) -> Data? {
        readData(ofLength: UInt32(clamping: length))
    }

    var isChunked: Bool { FormerHTTPResponseOptions.isChunked(self) }

    var responseHeaderFields: [(String, String)] { FormerHTTPResponseOptions.headerFields(of: self) }

    func connectionDidClose() { FormerHTTPResponseOptions.connectionDidClose(self) }

    var waitsForData: Bool { FormerHTTPResponseOptions.isAsynchronous(self) }
}
