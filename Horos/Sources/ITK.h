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






#import <Cocoa/Cocoa.h>

/** \brief Creates an itkImageImportFilter

The class of the Horos and OsiriX plugin SDK that handed a series' volume to
ITK: a plugin built for either looks it up by name. It keeps the volume the
application's own import makes (the slices over the viewer's voxels, or over
a copy halved along every axis when resampleData asks for the whole volume
at half its size), which the application's region growing and resampling run
on.

The SDK declared two more messages with types of ITK's C++ headers, which
this header leaves out so that it carries no C++: -itkImporter, answering an
ImportFilterType::Pointer, and
-setupImportFilterWithSize:origin:spacing:data:filterWillOwnBuffer:, taking
an ImportFilterType::SizeType. A plugin built with those headers still sends
them; the class answers both in the ITK adapter with the same calling
convention. The filter is of the plugin's own copy of ITK, which the
application cannot make: -itkImporter answers a null pointer, and the setup
does nothing and leaves the buffer to its caller.

ITK.swift implements the class (@objc @implementation), with the instance
variable the SDK declared, importFilter, which stays a null pointer.
*/
@interface ITK : NSObject

/// slice is -1 for the whole volume, -2 for the whole volume with its slices
/// 1000 mm apart, else the index of the one slice imported.
- (id) initWith :(NSArray*) pix :(float*) srcPtr :(long) slice;
- (id) initWithPix :(NSArray*) pix volume:(float*) volumeData sliceCount:(long) slice resampleData:(BOOL)resampleData;

@end
