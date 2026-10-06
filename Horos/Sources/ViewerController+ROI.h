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

// The "ROI" methods of ViewerController (ROIs: loading, saving, creation,
// deletion, propagation and selection) are implemented in Swift
// (ViewerController+ROI.swift and ViewerController+ROI+Editing.swift): Swift
// extensions of the class, which stays Objective-C, with the same selectors.
// ViewerController.h imports this header, so that whoever imports it, plugins
// included, still sees them: the generated interface declares them.

#import "ViewerController.h"

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extension itself.
#elif defined(HOROS_DEFER_SWIFT_INTERFACE)
// VRController.h imports ViewerController.h before its own interface and
// Horos-Swift.h after it: the generated interface declares a Swift subclass of
// VRController, which needs that interface complete.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift: the former declarations, without their
// implementation.
@interface ViewerController (ROI)

/** Return the array of ROI objects */
- (NSMutableArray*) roiList;
- (NSMutableArray*) roiList: (long) i;
- (void) setRoiList: (long) i array:(NSMutableArray*) a;
/** Check if the ROI belongs to this viewer */
- (BOOL) containsROI:(ROI*)roi;
/** Delete ALL ROI objects for  current series */
- (IBAction) roiDeleteAll:(id) sender;
/** Stops or aborts any open modal window */
- (IBAction) closeModal:(id) sender;
- (void)bringToFrontROI:(ROI*)roi;
- (void)sendToBackROI:(ROI*) roi;
//arg: this function will automatically scan the buffer to create a textured ROI (tPlain) for all slices
// param forValue: this param defines the region to extract in the stack buffer
- (void)addRoiFromFullStackBuffer:(unsigned char*)buff forSpecificValue:(unsigned char)value withColor:(RGBColor)aColor;
- (void)addRoiFromFullStackBuffer:(unsigned char*)buff forSpecificValue:(unsigned char)value withColor:(RGBColor)aColor withName:(NSString*)name;
//arg: Use this to extract all the rois from the
- (void)addRoiFromFullStackBuffer:(unsigned char*)buff;
- (void)addPlainRoiToCurrentSliceFromBuffer:(unsigned char*)buff;
- (void)addRoiFromFullStackBuffer:(unsigned char*)buff withName:(NSString*)name;
- (void)addPlainRoiToCurrentSliceFromBuffer:(unsigned char*)buff withName:(NSString*)name;
- (void)addPlainRoiToCurrentSliceFromBuffer:(unsigned char*)buff forSpecificValue:(unsigned char)value withColor:(RGBColor)aColor withName:(NSString*)name;
- (ROI*)addLayerRoiToCurrentSliceWithImage:(NSImage*)image referenceFilePath:(NSString*)path layerPixelSpacingX:(float)layerPixelSpacingX layerPixelSpacingY:(float)layerPixelSpacingY;
- (ROI*)createLayerROIFromROI:(ROI*)roi;
- (void)createLayerROIFromSelectedROI;
- (IBAction)createLayerROIFromSelectedROI:(id)sender;
- (IBAction) roiDeleteWithName:(NSString*) name;
- (IBAction) roiIntDeleteAllROIsWithSameName :(NSString*) name;
- (IBAction) roiDeleteAllROIsWithSameName:(id) sender;
- (void) roiLoadFromSeries: (NSString*) filename;
- (void) loadROI:(long) mIndex;
- (void) saveROI:(long) mIndex;
- (IBAction) roiSelectDeselectAll:(id) sender;
- (IBAction) setROITool:(id) sender;
- (void) setROIToolTag:(ToolMode) roitype;
- (IBAction) roiSetPixelsCheckButton:(id) sender;
- (IBAction) roiSetPixelsSetup:(id) sender;
- (IBAction) roiSetPixels:(ROI*)aROI :(short)allRois :(BOOL)propagateIn4D :(BOOL)outside :(float)minValue :(float)maxValue :(float)newValue;
- (IBAction) roiSetPixels:(ROI*)aROI :(short)allRois :(BOOL) propagateIn4D :(BOOL)outside :(float)minValue :(float)maxValue :(float)newValue :(BOOL) revert;
- (IBAction) roiSetPixels:(id) sender;
- (IBAction) roiPropagateSetup: (id) sender;
- (IBAction) roiPropagate:(id) sender;
/** Notification to close all windows */
- (NSMutableArray*) generateROINamesArray;
+ (NSArray*) defaultROINames;
+ (void) setDefaultROINames: (NSArray*) names;
- (IBAction) endRoiRename:(id) sender;
- (IBAction) roiRename:(id) sender;
- (NSArray*)roisWithName:(NSString*)name;
- (NSArray*)roisWithName:(NSString*)name in4D:(BOOL)in4D;
- (NSArray*)roisWithName:(NSString*)name forMovieIndex:(int)m;
- (NSArray*) roisWithComment: (NSString*) comment;
- (NSArray*) roiNames;
- (void) deleteROI: (ROI*) roi;
- (void) deleteSeriesROIwithName: (NSString*) name;
- (void) renameSeriesROIwithName: (NSString*) name newName:(NSString*) newName;
- (NSImage*) imageForROI: (ToolMode) i;
- (void) roiSetStartScheduler:(NSMutableArray*) roiToProceed;
- (IBAction) roiDeleteGeneratedROIsForName:(NSString*) name;
- (IBAction) roiDeleteGeneratedROIs:(id) sender;
- (ROI*)selectedROI;
- (NSMutableArray*) selectedROIs;
- (void)setMode:(long)mode toROIGroupWithID:(NSTimeInterval)groupID;
- (void)selectROI:(ROI*)roi deselectingOther:(BOOL)deselectOther;
- (void)deselectAllROIs;
- (ROI*) roiMorphingBetween:(ROI*) a and:(ROI*) b ratio:(float) ratio;
/**  Group selected ROI together */
- (IBAction)groupSelectedROIs:(id)sender;
/** Ungroup ROI */
- (IBAction)ungroupSelectedROIs:(id)sender;
/**  Lock selected ROI together */
- (IBAction) lockSelectedROIs:(id)sender;
/** Unlock ROI */
- (IBAction) unlockSelectedROIs:(id)sender;
- (IBAction) makeSelectedROIsUnselectable:(id)sender;
- (IBAction) makeAllROIsSelectable:(id)sender;

@end
#endif
