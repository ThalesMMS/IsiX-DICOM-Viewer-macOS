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

// What the Swift extensions of ViewerController (the blocks of the class moved
// by #832) read and write of the class that stays Objective-C. A Swift extension
// cannot see instance variables, so the ones those blocks used are reached
// through these accessors, implemented in ViewerController+SwiftIvars.m.
//
// - An outlet is readonly and nullable: nil until the nib is loaded.
// - A scalar is read and written as it is.
// - An object ivar has a retain setter (setHoros_name:, which releases the old
//   value and retains the new one, like [name release]; name = [value retain])
//   and an assign store (horos_assignName:, a plain name = value, without
//   retain or release), for the places where the Objective-C assigned without
//   retaining or retained on its own.
// - The C arrays of the movie dimension (fileList, pixList, roiList,
//   copyRoiList, volumeData) are read and written by index, with the same two
//   kinds of setter.
//
// This header is for the bridging header only: it is not part of the SDK.

#import "ViewerController.h"

@class DCMView, SeriesView, StudyView, ThickSlabController, DICOMExport, ToolbarPanelController, ViewerController, ColorTransferView, OpacityTransferView, ROI, DCMPix;

@interface ViewerController (SwiftIvars)

/// openingScaleToFitRequested.
@property(assign) BOOL horos_openingScaleToFitRequested;
/// openingContentBoundsByPixels.
@property(retain, nullable) NSDictionary* horos_openingContentBoundsByPixels;
/// openingContentBoundsByPixels = value, without retain or release.
- (void)horos_assignOpeningContentBoundsByPixels:(nullable NSDictionary*)value;
/// roiLock.
@property(retain, nullable) NSRecursiveLock* horos_roiLock;
/// roiLock = value, without retain or release.
- (void)horos_assignRoiLock:(nullable NSRecursiveLock*)value;
/// convThread.
@property(retain, nullable) NSConditionLock* horos_convThread;
/// convThread = value, without retain or release.
- (void)horos_assignConvThread:(nullable NSConditionLock*)value;
/// loadingThread.
@property(retain, nullable) NSThread* horos_loadingThread;
/// loadingThread = value, without retain or release.
- (void)horos_assignLoadingThread:(nullable NSThread*)value;
/// seriesView.
@property(retain, nullable) SeriesView* horos_seriesView;
/// seriesView = value, without retain or release.
- (void)horos_assignSeriesView:(nullable SeriesView*)value;
/// quicktimeWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_quicktimeWindow;
/// quicktimeMode, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_quicktimeMode;
/// quicktimeInterval, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_quicktimeInterval;
/// quicktimeFrom, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_quicktimeFrom;
/// quicktimeTo, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_quicktimeTo;
/// quicktimeIntervalText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_quicktimeIntervalText;
/// quicktimeFromText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_quicktimeFromText;
/// quicktimeToText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_quicktimeToText;
/// quicktimeNumber, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_quicktimeNumber;
/// quicktimeAllViewers, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_quicktimeAllViewers;
/// imageView.
@property(retain, nullable) DCMView* horos_imageView;
/// imageView = value, without retain or release.
- (void)horos_assignImageView:(nullable DCMView*)value;
/// windowsTiling, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_windowsTiling;
/// annotations, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_annotations;
/// seriesPopupView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_seriesPopupView;
/// orientationView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_orientationView;
/// orientationMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_orientationMatrix;
/// currentOrientationTool.
@property(assign) short horos_currentOrientationTool;
/// originalOrientation.
@property(assign) short horos_originalOrientation;
/// slider, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_slider;
/// speedSlider, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_speedSlider;
/// speedView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_speedView;
/// toolsView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_toolsView;
/// WLWWView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_WLWWView;
/// ReconstructionView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_ReconstructionView;
/// ConvView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_ConvView;
/// FusionView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_FusionView;
/// BlendingView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_BlendingView;
/// movieView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_movieView;
/// serieView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_serieView;
/// patientView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_patientView;
/// keyImages, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_keyImages;
/// RGBFactorsView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_RGBFactorsView;
/// speedText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_speedText;
/// wlwwPopup, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_wlwwPopup;
/// convPopup, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_convPopup;
/// clutPopup, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_clutPopup;
/// clutPopupSet.
@property(assign) BOOL horos_clutPopupSet;
/// propagateSettingsView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_propagateSettingsView;
/// subCtrlView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_subCtrlView;
/// enableSubtraction.
@property(assign) BOOL horos_enableSubtraction;
/// subCtrlOnOff, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_subCtrlOnOff;
/// subCtrlMaskID.
@property(assign) long horos_subCtrlMaskID;
/// subCtrlMinMax.
@property(assign) NSPoint horos_subCtrlMinMax;
/// subCtrlMinMaxComputed.
@property(assign) BOOL horos_subCtrlMinMaxComputed;
/// subCtrlMaskText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_subCtrlMaskText;
/// subCtrlSum, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_subCtrlSum;
/// subCtrlPercent, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_subCtrlPercent;
/// shutterOnOff, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_shutterOnOff;
/// shutterView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_shutterView;
/// statusValueToApply.
@property(assign) int horos_statusValueToApply;
/// StatusView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_StatusView;
/// CommentsField, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_CommentsField;
/// StatusPopup, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_StatusPopup;
/// toolsMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_toolsMatrix;
/// roiSetPixWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_roiSetPixWindow;
/// maxValueText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_maxValueText;
/// minValueText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_minValueText;
/// newValueText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_newValueText;
/// InOutROI, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_InOutROI;
/// AllROIsRadio, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_AllROIsRadio;
/// newValueMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_newValueMatrix;
/// checkMaxValue, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_checkMaxValue;
/// checkMinValue, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_checkMinValue;
/// setROI4DSeries, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_setROI4DSeries;
/// blendingTypeWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_blendingTypeWindow;
/// roiPropaWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_roiPropaWindow;
/// roiPropaMode, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_roiPropaMode;
/// roiPropaDim, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_roiPropaDim;
/// roiPropaCopy, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_roiPropaCopy;
/// roiPropaDest, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_roiPropaDest;
/// roiApplyWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_roiApplyWindow;
/// roiApplyMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_roiApplyMatrix;
/// addConvWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_addConvWindow;
/// convMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_convMatrix;
/// sizeMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_sizeMatrix;
/// matrixName, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_matrixName;
/// matrixNorm, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_matrixNorm;
/// addCLUTWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_addCLUTWindow;
/// clutName, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_clutName;
/// dcmExportWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_dcmExportWindow;
/// dcmSelection, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_dcmSelection;
/// dcmFormat, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_dcmFormat;
/// dcmInterval, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_dcmInterval;
/// dcmFrom, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_dcmFrom;
/// dcmTo, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_dcmTo;
/// dcmIntervalText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_dcmIntervalText;
/// dcmFromText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_dcmFromText;
/// dcmToText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_dcmToText;
/// dcmNumber, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_dcmNumber;
/// dcmAllViewers, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_dcmAllViewers;
/// dcmSeriesName, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_dcmSeriesName;
/// imageExportWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_imageExportWindow;
/// imageSelection, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_imageSelection;
/// imageFormat, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_imageFormat;
/// imageAllViewers, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_imageAllViewers;
/// addOpacityWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_addOpacityWindow;
/// OpacityName, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_OpacityName;
/// OpacityView, outlet: nil until the nib is loaded.
@property(readonly, nullable) OpacityTransferView* horos_OpacityView;
/// movieTextSlide, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_movieTextSlide;
/// moviePlayStop, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_moviePlayStop;
/// movieRateSlider, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_movieRateSlider;
/// moviePosSlider, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_moviePosSlider;
/// blendingPopupMenu, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_blendingPopupMenu;
/// blendingPercentage, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_blendingPercentage;
/// blendingSlider, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_blendingSlider;
/// blendingController.
@property(retain, nullable) ViewerController* horos_blendingController;
/// blendingController = value, without retain or release.
- (void)horos_assignBlendingController:(nullable ViewerController*)value;
/// roiRenameName, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_roiRenameName;
/// roiRenameMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_roiRenameMatrix;
/// roiRenameWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_roiRenameWindow;
/// curConvMenu.
@property(retain, nullable) NSString* horos_curConvMenu;
/// curConvMenu = value, without retain or release.
- (void)horos_assignCurConvMenu:(nullable NSString*)value;
/// curWLWWMenu.
@property(retain, nullable) NSString* horos_curWLWWMenu;
/// curWLWWMenu = value, without retain or release.
- (void)horos_assignCurWLWWMenu:(nullable NSString*)value;
/// curCLUTMenu.
@property(retain, nullable) NSString* horos_curCLUTMenu;
/// curCLUTMenu = value, without retain or release.
- (void)horos_assignCurCLUTMenu:(nullable NSString*)value;
/// backCurCLUTMenu.
@property(retain, nullable) NSString* horos_backCurCLUTMenu;
/// backCurCLUTMenu = value, without retain or release.
- (void)horos_assignBackCurCLUTMenu:(nullable NSString*)value;
/// stacksFusion, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_stacksFusion;
/// sliderFusion, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_sliderFusion;
/// activatedFusion, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_activatedFusion;
/// popFusion, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_popFusion;
/// popupRoi, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_popupRoi;
/// buttonToolMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_buttonToolMatrix;
/// fileList[index], index < MAX4D.
- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index;
/// [fileList[index] release]; fileList[index] = [value retain];
- (void)horos_setFileList:(nullable NSMutableArray*)value at:(NSInteger)index;
/// fileList[index] = value, without retain or release.
- (void)horos_assignFileList:(nullable NSMutableArray*)value at:(NSInteger)index;
/// pixList[index], index < MAX4D.
- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index;
/// [pixList[index] release]; pixList[index] = [value retain];
- (void)horos_setPixList:(nullable NSMutableArray<DCMPix *>*)value at:(NSInteger)index;
/// pixList[index] = value, without retain or release.
- (void)horos_assignPixList:(nullable NSMutableArray<DCMPix *>*)value at:(NSInteger)index;
/// roiList[index], index < MAX4D.
- (nullable NSMutableArray<NSMutableArray<ROI *> *>*)horos_roiListAt:(NSInteger)index;
/// [roiList[index] release]; roiList[index] = [value retain];
- (void)horos_setRoiList:(nullable NSMutableArray<NSMutableArray<ROI *> *>*)value at:(NSInteger)index;
/// roiList[index] = value, without retain or release.
- (void)horos_assignRoiList:(nullable NSMutableArray<NSMutableArray<ROI *> *>*)value at:(NSInteger)index;
/// copyRoiList[index], index < MAX4D.
- (nullable NSMutableArray<NSData *>*)horos_copyRoiListAt:(NSInteger)index;
/// [copyRoiList[index] release]; copyRoiList[index] = [value retain];
- (void)horos_setCopyRoiList:(nullable NSMutableArray<NSData *>*)value at:(NSInteger)index;
/// copyRoiList[index] = value, without retain or release.
- (void)horos_assignCopyRoiList:(nullable NSMutableArray<NSData *>*)value at:(NSInteger)index;
/// volumeData[index], index < MAX4D: the NSData object itself, typed NSObject
/// so that Swift does not bridge it to a Data value (cast it with as? NSData).
- (nullable NSObject*)horos_volumeDataAt:(NSInteger)index;
/// [volumeData[index] release]; volumeData[index] = [value retain];
- (void)horos_setVolumeData:(nullable NSObject*)value at:(NSInteger)index;
/// volumeData[index] = value, without retain or release.
- (void)horos_assignVolumeData:(nullable NSObject*)value at:(NSInteger)index;
/// curMovieIndex.
@property(assign) short horos_curMovieIndex;
/// maxMovieIndex.
@property(assign) short horos_maxMovieIndex;
/// toolbar.
@property(retain, nullable) NSToolbar* horos_toolbar;
/// toolbar = value, without retain or release.
- (void)horos_assignToolbar:(nullable NSToolbar*)value;
/// direction.
@property(assign) float horos_direction;
/// ROINamesArray.
@property(retain, nullable) NSMutableArray* horos_ROINamesArray;
/// ROINamesArray = value, without retain or release.
- (void)horos_assignROINamesArray:(nullable NSMutableArray*)value;
/// thickSlab.
@property(retain, nullable) ThickSlabController* horos_thickSlab;
/// thickSlab = value, without retain or release.
- (void)horos_assignThickSlab:(nullable ThickSlabController*)value;
/// exportDCM.
@property(retain, nullable) DICOMExport* horos_exportDCM;
/// exportDCM = value, without retain or release.
- (void)horos_assignExportDCM:(nullable DICOMExport*)value;
/// windowWillClose.
@property(assign) BOOL horos_windowWillClose;
/// requestLoadingCancel.
@property(assign) BOOL horos_requestLoadingCancel;
/// postprocessed.
@property(assign) BOOL horos_postprocessed;
/// keyImagePopUpButton, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_keyImagePopUpButton;
/// displayOnlyKeyImages.
@property(assign) BOOL horos_displayOnlyKeyImages;
/// qt_to.
@property(assign) int horos_qt_to;
/// qt_from.
@property(assign) int horos_qt_from;
/// qt_interval.
@property(assign) int horos_qt_interval;
/// qt_dimension.
@property(assign) int horos_qt_dimension;
/// current_qt_interval.
@property(assign) int horos_current_qt_interval;
/// qt_allViewers.
@property(assign) int horos_qt_allViewers;
/// printWindow, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSWindow* horos_printWindow;
/// printSelection, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_printSelection;
/// printFormat, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_printFormat;
/// printInterval, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_printInterval;
/// printFrom, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_printFrom;
/// printTo, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_printTo;
/// printIntervalText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_printIntervalText;
/// printFromText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_printFromText;
/// printToText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_printToText;
/// printSettings, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_printSettings;
/// printLayout, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_printLayout;
/// printText, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_printText;
/// printPagesToPrint, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_printPagesToPrint;
/// undoQueue.
@property(retain, nullable) NSMutableArray* horos_undoQueue;
/// undoQueue = value, without retain or release.
- (void)horos_assignUndoQueue:(nullable NSMutableArray*)value;
/// redoQueue.
@property(retain, nullable) NSMutableArray* horos_redoQueue;
/// redoQueue = value, without retain or release.
- (void)horos_assignRedoQueue:(nullable NSMutableArray*)value;
/// updateTilingViews.
@property(assign) BOOL horos_updateTilingViews;
/// resampleRatio.
@property(assign) float horos_resampleRatio;
/// registeredViewer.
@property(retain, nullable) ViewerController* horos_registeredViewer;
/// registeredViewer = value, without retain or release.
- (void)horos_assignRegisteredViewer:(nullable ViewerController*)value;
/// blendedWindow.
@property(retain, nullable) ViewerController* horos_blendedWindow;
/// blendedWindow = value, without retain or release.
- (void)horos_assignBlendedWindow:(nullable ViewerController*)value;
/// retainedToolbarItems.
@property(retain, nullable) NSMutableArray* horos_retainedToolbarItems;
/// retainedToolbarItems = value, without retain or release.
- (void)horos_assignRetainedToolbarItems:(nullable NSMutableArray*)value;
/// nonVolumicDataWarningDisplayed.
@property(assign) BOOL horos_nonVolumicDataWarningDisplayed;
/// display12bitToolbarItemView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_display12bitToolbarItemView;
/// display12bitToolbarItemMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_display12bitToolbarItemMatrix;
/// windowFrameToRestore.
@property(assign) NSRect horos_windowFrameToRestore;
/// scaleFitToRestore.
@property(assign) BOOL horos_scaleFitToRestore;
/// printSpoolDirectory.
@property(retain, nullable) NSString* horos_printSpoolDirectory;
/// printSpoolDirectory = value, without retain or release.
- (void)horos_assignPrintSpoolDirectory:(nullable NSString*)value;

@end

// The declarations below restate the class's own, which carry no
// nullability: Swift imports them as before.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

@class HorosVolumeLengthROI, DicomImage;

// Instance variables of the superclass and outlets the blocks read, besides
// the ones above.
@interface ViewerController (SwiftIvarsMore)

/// _blendingType, the @protected ivar of OSIWindowController that
/// -blendWithViewer:blendingType: stores.
@property(assign) int horos_blendingType;
/// dcmBox, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSBox* horos_dcmBox;
/// quicktimeBox, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSBox* horos_quicktimeBox;
/// printBox, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSBox* horos_printBox;

@end

// What the Swift extensions of #832 call in the Objective-C of the class:
// methods ViewerController.m implements without declaring them in
// ViewerController.h.
@interface ViewerController (SwiftPrivateMethods)

- (BOOL) isGantryTitled;
- (void) refreshMenus;
- (ViewerController*) resampleSeries:(ViewerController*) movingViewer rescale: (BOOL) rescale;
- (NSString *)fourDFusionRefusalReasonForOverlay: (ViewerController *) overlay;
- (void) applyStatusValue;
- (double) computeOriginalOrientation;
- (void)setImageRows:(int)rows columns:(int)columns rescale: (BOOL) rescale;
- (NSMutableDictionary *)volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create;
- (void)registerVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex anchor:(DicomImage *)anchor;
- (void)attachVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex;
- (void)saveVolumeLengthROIs:(long)movieIndex writtenPaths:(NSMutableArray *)paths anchorPaths:(NSDictionary *)anchorPaths;

@end

// The file-scope statics of ViewerController.m that the Swift extensions of
// #832 read. They stay in ViewerController.m, whose ViewerController
// (SwiftStatics) implements these accessors.
@interface ViewerController (SwiftStatics)

/// SYNCSERIES.
+ (BOOL)horos_SYNCSERIES;
/// numberOf2DViewer.
+ (int)horos_numberOf2DViewer;
/// PlayToolbarItemIdentifier, which -PlayStop: still uses.
+ (NSString*)horos_PlayToolbarItemIdentifier;
/// HorosVolumeLengthReadArchive(path): the ROIs of an archive, or an
/// exception when an existing archive cannot be read.
+ (NSArray *)horos_volumeLengthReadArchive:(NSString *)path;

@end

// What a Swift extension of #832 cannot write itself, kept in Objective-C in
// ViewerController.m, because it needs what only that file declares.
@interface ViewerController (SwiftBridges)

/// [[[ViewerControllerOperation alloc] initWithController: self dict: dict] autorelease]:
/// ViewerControllerOperation is a class of ViewerController.m that no header
/// declares. `dict` is `id` so that Swift passes the NSDictionary without
/// bridging it.
- (NSOperation*) horos_viewerControllerOperationWithDict:(id) dict;
/// [self sendWillFreeVolumeDataNotificationWithVolumeData: volumeData[movieIndex] movieIndex: movieIndex]
- (void)horos_sendWillFreeVolumeDataNotificationForMovieIndex:(NSInteger)movieIndex;
/// [self sendDidAllocateVolumeDataNotificationWithVolumeData: volumeData[movieIndex] movieIndex: movieIndex]
- (void)horos_sendDidAllocateVolumeDataNotificationForMovieIndex:(NSInteger)movieIndex;
/// Clears the volume length state associated with the viewer (its key is a
/// static of ViewerController.m).
- (void)horos_clearVolumeLengthState;

@end

// What a Swift extension of #832 cannot write itself, kept in Objective-C in
// ViewerController+SwiftIvars.m.
@interface ViewerController (SwiftBridgesPublic)

/// [self newROI: type], the autoreleased ROI -newROI: returns. -newROI: is in
/// the "new" family, so Swift would take its result as +1 and over-release
/// it; this name is not.
- (ROI*) horos_unretainedNewROI:(ToolMode) type;
/// The NSBeginAlertSheet of the Shift branch of -ApplyConv:, which Swift
/// cannot call: [sender title] is both the message argument and the
/// contextInfo that -deleteConv:returnCode:contextInfo: reads.
- (void)horos_beginDeleteConvolutionSheetForSender:(nullable id)sender;

@end

#pragma clang diagnostic pop
