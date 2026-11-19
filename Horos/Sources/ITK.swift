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

/** \brief Creates an itkImageImportFilter

 The implementation of ITK, declared in ITK.h: the class of the Horos and
 OsiriX plugin SDK that handed a series' volume to ITK. The volume is the one
 ITKVolumeImport makes for the application's own region growing and
 resampling; the two messages of the SDK that carry ITK's C++ types are
 answered in the ITK adapter.
 */
@objc @implementation extension ITK {
    /// The volume as ITK sees it; nil when there were no slices or no
    /// voxels, or ITK refused them.
    private final var volume: IsiXITKVolume?

    /// The instance variable of the SDK, which a plugin built for it binds by
    /// name when it loads: the import filter, an ImportFilterType::Pointer of
    /// ITK, which is one pointer. The filter would be of the plugin's own
    /// copy of ITK, which the application cannot make: it stays null.
    final var importFilter: UnsafeMutableRawPointer?

    override init() {
        super.init()
    }

    @objc(initWith:::) init!(_ pix: [Any]!, _ srcPtr: UnsafeMutablePointer<Float>!, _ slice: Int) {
        volume = Self.imported(pix, srcPtr, slice: slice, resampleData: false)
        super.init()
    }

    init!(pix: [Any]!, volume volumeData: UnsafeMutablePointer<Float>!, sliceCount slice: Int, resampleData: Bool) {
        volume = Self.imported(pix, volumeData, slice: slice, resampleData: resampleData)
        super.init()
    }

    private static func imported(_ pix: [Any]?, _ voxels: UnsafeMutablePointer<Float>?, slice: Int, resampleData: Bool) -> IsiXITKVolume? {
        ITKVolumeImport.volume(pix: pix.map { $0 as NSArray }, voxels: voxels, slice: slice, resampleData: resampleData)
    }
}
