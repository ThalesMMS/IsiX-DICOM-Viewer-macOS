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

// CPRController is implemented in Swift since #825 (Horos/Sources/CPRController.swift).
// This header keeps <Horos/CPRController.h>: it brings in the generated interface,
// which declares the same class name and selectors, and keeps the view position,
// CPR type and export constants. Its superclass, Window3DController, stays in
// Objective-C.

#import <Cocoa/Cocoa.h>

// The types come before the imports below: one of them may import
// Horos-Swift.h, whose interface of this class uses them before this header
// has finished.
typedef NSInteger ViewsPosition;
typedef NSInteger CPRType;
typedef NSInteger CPRExportImageFormat;
typedef NSInteger CPRExportSequenceType;
typedef NSInteger CPRExportSeriesType;
typedef NSInteger CPRExportRotationSpan;

#import "OSIWindowController.h"
#import "CPRVolumeData.h"
#import "CPRMPRDCMView.h"
#import "VRController.h"
// VRView.h includes VTK's C++ headers, which Swift cannot read: the files that
// send VRView messages import it themselves.
@class VRView;
#import "FlyAssistant.h"
// FlyAssistant.h reaches this header again through Horos-Swift.h, which
// imports the bridging header: the class may not be declared yet.
@class FlyAssistant;

enum _ViewsPosition {
    NormalPosition = 0,
    HorizontalPosition = 1,
    VerticalPosition = 2
};

enum _CPRType {
    CPRStraightenedType = 0,
    CPRStretchedType = 1
};

enum _CPRExportImageFormat {
    CPR8BitRGBExportImageFormat = 0,
    CPR16BitExportImageFormat = 1,
};

enum _CPRExportSequenceType {
    CPRCurrentOnlyExportSequenceType = 0,
    CPRSeriesExportSequenceType = 1,
};

enum _CPRExportSeriesType {
    CPRRotationExportSeriesType = 0,
    CPRSlabExportSeriesType = 1,
	CPRTransverseViewsExportSeriesType = 2
};

enum _CPRExportRotationSpan {
    CPR180ExportRotationSpan = 0,
    CPR360ExportRotationSpan = 1,
};

@class CPRMPRDCMView;
@class CPRView;
@class CPRCurvedPath;
@class CPRDisplayInfo;
@class CPRTransverseView;
@class CPRVolumeData;
@class HorosCPRRenderLifecycle;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class CPRController;
#else
#import "Horos-Swift.h"
#endif
