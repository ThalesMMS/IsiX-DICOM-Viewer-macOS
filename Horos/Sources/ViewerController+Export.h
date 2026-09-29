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

// The "4.5.1.1 Exportation of image produced" methods of ViewerController
// (sorting, printing, movie, DICOM and image export) are implemented in Swift
// since #832 (ViewerController+Export.swift and
// ViewerController+Export+PrintMovie.swift): Swift extensions of the class,
// which stays Objective-C, with the same selectors. ViewerController.h imports
// this header, so that whoever imports it, plugins included, still sees them:
// the generated interface declares them.

#import "ViewerController.h"

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extension itself.
#elif defined(HOROS_DEFER_SWIFT_INTERFACE)
// VRController.h imports ViewerController.h before its own interface and
// Horos-Swift.h after it: the generated interface declares a Swift subclass of
// VRController (#827), which needs that interface complete.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift: the former declarations, without their
// implementation.
@interface ViewerController (Export)

/** Action to sset up non DICOM printing */
- (IBAction) setPagesToPrint:(id) sender;
/** Action to start printing.  Called when print window is ordered out */
- (IBAction) endPrint:(id) sender;
- (IBAction) export2PACS:(id) sender;
- (void) print:(id) sender;
- (id) findPlayStopButton;
- (IBAction) endQuicktime:(id) sender;
/** ReSort the images displayed according to IMAGE Table field */
- (BOOL) sortSeriesByValue: (NSString*) key ascending: (BOOL) ascending;
/** ReSort the images displayed according to this group/element */
- (BOOL) sortSeriesByDICOMGroup: (int) gr element: (int) el;
/** Action to export as JPEG */
- (void) exportJPEG:(id) sender;
-(IBAction) export2iPhoto:(id) sender;
-(IBAction) PagePadCreate:(id) sender;
- (void) exportQuicktime:(id) sender;
- (IBAction) exportQuicktimeSlider:(id) sender;
- (IBAction) exportDICOMSlider:(id) sender;
- (IBAction) exportDICOMAllViewers:(id) sender;
- (IBAction) endExportDICOMFileSettings:(id) sender;
- (IBAction) exportAllImages:(NSString*) seriesName;
- (void) exportQuicktimeIn:(long) dimension :(long) from :(long) to :(long) interval;
- (void) exportQuicktimeIn:(long) dimension :(long) from :(long) to :(long) interval :(BOOL) allViewers;
- (void) exportQuicktimeIn:(long) dimension :(long) from :(long) to :(long) interval :(BOOL) allViewers mode:(NSString*) mode;
- (IBAction) endExportImage: (id) sender;
- (IBAction) setCurrentdcmExport:(id) sender;
- (void)exportTextFieldDidChange:(NSNotification *)note;
- (IBAction) printSlider:(id) sender;
- (NSDictionary*) exportDICOMFileInt:(int)screenCapture withName:(NSString*)name;
- (NSDictionary*) exportDICOMFileInt:(int)screenCapture withName:(NSString*)name allViewers: (BOOL) allViewers;

@end
#endif
