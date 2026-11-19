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

/** \brief DCMTK based PrintSCU Not in use

 The implementation of DCMTKPrintSCU, declared in DCMTKPrintSCU.h: the print
 SCU of the Horos and OsiriX plugin SDK, which that SDK marked as not in use.
 It keeps what it is made with and prints nothing.
 */
@objc @implementation extension DCMTKPrintSCU {
    // The instance variables of the SDK, with its names and types: a plugin
    // built for it binds each name when it loads. Those that were of DCMTK's
    // C++ types have the same sizes: an int for the three enumerations of its
    // print management (_filmorientation, _trim, _decimate) and a byte for
    // its OFBool. Nothing is printed, so that all are zero and nil but the
    // files.
    final var _printerID: UnsafePointer<CChar>?, _cfgName: UnsafePointer<CChar>?
    final var _filmorientation: Int32 = 0, _trim: Int32 = 0, _decimate: Int32 = 0
    final var _columns: UInt32 = 0, _rows: UInt32 = 0, _copies: UInt32 = 0, _ovl_graylevel: UInt32 = 0
    final var _filmsize: UnsafePointer<CChar>?, _magnification: UnsafePointer<CChar>?, _smoothing: UnsafePointer<CChar>?
    final var _configuration: UnsafePointer<CChar>?, _img_polarity: UnsafePointer<CChar>?, _img_request_size: UnsafePointer<CChar>?
    final var _img_magnification: UnsafePointer<CChar>?, _img_smoothing: UnsafePointer<CChar>?, _img_configuration: UnsafePointer<CChar>?
    final var _resolution: UnsafePointer<CChar>?, _border: UnsafePointer<CChar>?, _emptyimage: UnsafePointer<CChar>?
    final var _maxdensity: UnsafePointer<CChar>?, _mindensity: UnsafePointer<CChar>?, _plutname: UnsafePointer<CChar>?
    /// The files the SCU was to print, as its initializer was given them.
    final var _filenames: NSArray?
    final var _LUTshape: Int32 = 0
    final var _inverse_plut: Bool = false, _spool: Bool = false
    final var _mediumtype: UnsafePointer<CChar>?, _destination: UnsafePointer<CChar>?, _sessionlabel: UnsafePointer<CChar>?
    final var _priority: UnsafePointer<CChar>?, _ownerID: UnsafePointer<CChar>?
    final var _annotation: Bool = false, _annotationDatetime: Bool = false, _annotationPrinter: Bool = false, _annotationIllumination: Bool = false
    final var _annotationString: UnsafePointer<CChar>?
    final var _illumination: UInt32 = 0, _reflection: UInt32 = 0

    // The initializers of the superclass make a print SCU with no files, as
    // they did in the SDK, where the class inherited them.
    override init() {
        super.init()
    }

    override init!(callingAET myAET: String!, calledAET theirAET: String!, hostname: String!, port: Int32, transferSyntax: Int32,
                   compression: Float, extraParameters: [AnyHashable: Any]!) {
        super.init(callingAET: myAET, calledAET: theirAET, hostname: hostname, port: port, transferSyntax: transferSyntax,
                   compression: compression, extraParameters: extraParameters)
    }

    init!(callingAET myAET: String!, calledAET theirAET: String!, hostname: String!, port: Int32, filesToSend: [Any]!,
          extraParameters: [AnyHashable: Any]!) {
        _filenames = filesToSend as NSArray?
        super.init(callingAET: myAET, calledAET: theirAET, hostname: hostname, port: port, transferSyntax: 0, compression: 0,
                   extraParameters: extraParameters)
    }
}
