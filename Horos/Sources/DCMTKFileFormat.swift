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

/// A DICOM file parsed by DCMTK, which DCMPix keeps (dcmtkDcmFileFormat) and
/// plugins receive as the untyped pointer to its DcmFileFormat. The file is
/// held by the DCMTK adapter (IsiXDCMTKFile), which deletes it with this
/// object; a pointer set from outside is taken over the same way.
@objc @implementation extension DCMTKFileFormat {

    final var horos_file: IsiXDCMTKFile?

    var dcmtkDcmFileFormat: UnsafeMutableRawPointer? {
        get { horos_file?.handle }
        set {
            // As the instance variable it was: the object deletes the file it
            // holds when it goes, and a file it is no longer given is left to
            // whoever replaced it.
            guard newValue != horos_file?.handle else { return }
            horos_file?.relinquishOwnership()
            horos_file = newValue.map { IsiXDCMTKFile(takingOwnershipOfHandle: $0) }
        }
    }

    init!(file: String!) {
        // The file read whole, as DcmFileFormat::loadFile reads it; one DCMTK
        // cannot read leaves the object empty, as it always did.
        horos_file = (try? IsiXDCMTKFile.file(atPath: file)) ?? IsiXDCMTKFile()
        super.init()
    }
}
