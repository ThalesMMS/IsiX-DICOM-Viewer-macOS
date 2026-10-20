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

#import "ViewerController+SwiftIvars.h"
#import "HorosAlertPanel.h"
#import "Horos-Swift.h"

@implementation ViewerController (SwiftIvars)

- (BOOL)horos_openingScaleToFitRequested
{
    return openingScaleToFitRequested;
}

- (void)setHoros_openingScaleToFitRequested:(BOOL)value
{
    openingScaleToFitRequested = value;
}

- (NSDictionary*)horos_openingContentBoundsByPixels
{
    return openingContentBoundsByPixels;
}

- (void)setHoros_openingContentBoundsByPixels:(NSDictionary*)value
{
    [value retain];
    [openingContentBoundsByPixels release];
    openingContentBoundsByPixels = value;
}

- (void)horos_assignOpeningContentBoundsByPixels:(NSDictionary*)value
{
    openingContentBoundsByPixels = value;
}

- (NSRecursiveLock*)horos_roiLock
{
    return roiLock;
}

- (void)setHoros_roiLock:(NSRecursiveLock*)value
{
    [value retain];
    [roiLock release];
    roiLock = value;
}

- (void)horos_assignRoiLock:(NSRecursiveLock*)value
{
    roiLock = value;
}

- (NSConditionLock*)horos_convThread
{
    return convThread;
}

- (void)setHoros_convThread:(NSConditionLock*)value
{
    [value retain];
    [convThread release];
    convThread = value;
}

- (void)horos_assignConvThread:(NSConditionLock*)value
{
    convThread = value;
}

- (NSThread*)horos_loadingThread
{
    return loadingThread;
}

- (void)setHoros_loadingThread:(NSThread*)value
{
    [value retain];
    [loadingThread release];
    loadingThread = value;
}

- (void)horos_assignLoadingThread:(NSThread*)value
{
    loadingThread = value;
}

- (SeriesView*)horos_seriesView
{
    return seriesView;
}

- (void)setHoros_seriesView:(SeriesView*)value
{
    [value retain];
    [seriesView release];
    seriesView = value;
}

- (void)horos_assignSeriesView:(SeriesView*)value
{
    seriesView = value;
}

- (NSWindow*)horos_quicktimeWindow
{
    [self horosLoadViewerPanels];
    return quicktimeWindow;
}

- (NSMatrix*)horos_quicktimeMode
{
    [self horosLoadViewerPanels];
    return quicktimeMode;
}

- (NSSlider*)horos_quicktimeInterval
{
    [self horosLoadViewerPanels];
    return quicktimeInterval;
}

- (NSSlider*)horos_quicktimeFrom
{
    [self horosLoadViewerPanels];
    return quicktimeFrom;
}

- (NSSlider*)horos_quicktimeTo
{
    [self horosLoadViewerPanels];
    return quicktimeTo;
}

- (NSTextField*)horos_quicktimeIntervalText
{
    [self horosLoadViewerPanels];
    return quicktimeIntervalText;
}

- (NSTextField*)horos_quicktimeFromText
{
    [self horosLoadViewerPanels];
    return quicktimeFromText;
}

- (NSTextField*)horos_quicktimeToText
{
    [self horosLoadViewerPanels];
    return quicktimeToText;
}

- (NSTextField*)horos_quicktimeNumber
{
    [self horosLoadViewerPanels];
    return quicktimeNumber;
}

- (NSButton*)horos_quicktimeAllViewers
{
    [self horosLoadViewerPanels];
    return quicktimeAllViewers;
}

- (DCMView*)horos_imageView
{
    return imageView;
}

- (void)setHoros_imageView:(DCMView*)value
{
    [value retain];
    [imageView release];
    imageView = value;
}

- (void)horos_assignImageView:(DCMView*)value
{
    imageView = value;
}

- (NSView*)horos_windowsTiling
{
    return windowsTiling;
}

- (NSView*)horos_annotations
{
    return annotations;
}

- (NSView*)horos_seriesPopupView
{
    return seriesPopupView;
}

- (NSView*)horos_orientationView
{
    return orientationView;
}

- (NSMatrix*)horos_orientationMatrix
{
    return orientationMatrix;
}

- (short)horos_currentOrientationTool
{
    return currentOrientationTool;
}

- (void)setHoros_currentOrientationTool:(short)value
{
    currentOrientationTool = value;
}

- (short)horos_originalOrientation
{
    return originalOrientation;
}

- (void)setHoros_originalOrientation:(short)value
{
    originalOrientation = value;
}

- (NSSlider*)horos_slider
{
    return slider;
}

- (NSSlider*)horos_speedSlider
{
    return speedSlider;
}

- (NSView*)horos_speedView
{
    return speedView;
}

- (NSView*)horos_toolsView
{
    return toolsView;
}

- (NSView*)horos_WLWWView
{
    return WLWWView;
}

- (NSView*)horos_ReconstructionView
{
    return ReconstructionView;
}

- (NSView*)horos_ConvView
{
    return ConvView;
}

- (NSView*)horos_FusionView
{
    return FusionView;
}

- (NSView*)horos_BlendingView
{
    return BlendingView;
}

- (NSView*)horos_movieView
{
    return movieView;
}

- (NSView*)horos_serieView
{
    return serieView;
}

- (NSView*)horos_patientView
{
    return patientView;
}

- (NSView*)horos_keyImages
{
    return keyImages;
}

- (NSView*)horos_RGBFactorsView
{
    return RGBFactorsView;
}

- (NSTextField*)horos_speedText
{
    return speedText;
}

- (NSPopUpButton*)horos_wlwwPopup
{
    return wlwwPopup;
}

- (NSPopUpButton*)horos_convPopup
{
    return convPopup;
}

- (NSPopUpButton*)horos_clutPopup
{
    return clutPopup;
}

- (BOOL)horos_clutPopupSet
{
    return clutPopupSet;
}

- (void)setHoros_clutPopupSet:(BOOL)value
{
    clutPopupSet = value;
}

- (NSView*)horos_propagateSettingsView
{
    return propagateSettingsView;
}

- (NSView*)horos_subCtrlView
{
    return subCtrlView;
}

- (BOOL)horos_enableSubtraction
{
    return enableSubtraction;
}

- (void)setHoros_enableSubtraction:(BOOL)value
{
    enableSubtraction = value;
}

- (NSButton*)horos_subCtrlOnOff
{
    return subCtrlOnOff;
}

- (long)horos_subCtrlMaskID
{
    return subCtrlMaskID;
}

- (void)setHoros_subCtrlMaskID:(long)value
{
    subCtrlMaskID = value;
}

- (NSPoint)horos_subCtrlMinMax
{
    return subCtrlMinMax;
}

- (void)setHoros_subCtrlMinMax:(NSPoint)value
{
    subCtrlMinMax = value;
}

- (BOOL)horos_subCtrlMinMaxComputed
{
    return subCtrlMinMaxComputed;
}

- (void)setHoros_subCtrlMinMaxComputed:(BOOL)value
{
    subCtrlMinMaxComputed = value;
}

- (NSTextField*)horos_subCtrlMaskText
{
    return subCtrlMaskText;
}

- (NSSlider*)horos_subCtrlSum
{
    return subCtrlSum;
}

- (NSSlider*)horos_subCtrlPercent
{
    return subCtrlPercent;
}

- (NSButton*)horos_shutterOnOff
{
    return shutterOnOff;
}

- (NSView*)horos_shutterView
{
    return shutterView;
}

- (int)horos_statusValueToApply
{
    return statusValueToApply;
}

- (void)setHoros_statusValueToApply:(int)value
{
    statusValueToApply = value;
}

- (NSView*)horos_StatusView
{
    return StatusView;
}

- (NSButton*)horos_CommentsField
{
    return CommentsField;
}

- (NSPopUpButton*)horos_StatusPopup
{
    return StatusPopup;
}

- (NSMatrix*)horos_toolsMatrix
{
    return toolsMatrix;
}

- (NSWindow*)horos_roiSetPixWindow
{
    [self horosLoadViewerPanels];
    return roiSetPixWindow;
}

- (NSTextField*)horos_maxValueText
{
    [self horosLoadViewerPanels];
    return maxValueText;
}

- (NSTextField*)horos_minValueText
{
    [self horosLoadViewerPanels];
    return minValueText;
}

- (NSTextField*)horos_newValueText
{
    [self horosLoadViewerPanels];
    return newValueText;
}

- (NSMatrix*)horos_InOutROI
{
    [self horosLoadViewerPanels];
    return InOutROI;
}

- (NSMatrix*)horos_AllROIsRadio
{
    [self horosLoadViewerPanels];
    return AllROIsRadio;
}

- (NSMatrix*)horos_newValueMatrix
{
    [self horosLoadViewerPanels];
    return newValueMatrix;
}

- (NSButton*)horos_checkMaxValue
{
    [self horosLoadViewerPanels];
    return checkMaxValue;
}

- (NSButton*)horos_checkMinValue
{
    [self horosLoadViewerPanels];
    return checkMinValue;
}

- (NSButton*)horos_setROI4DSeries
{
    [self horosLoadViewerPanels];
    return setROI4DSeries;
}

- (NSWindow*)horos_blendingTypeWindow
{
    [self horosLoadViewerPanels];
    return blendingTypeWindow;
}

- (NSWindow*)horos_roiPropaWindow
{
    [self horosLoadViewerPanels];
    return roiPropaWindow;
}

- (NSMatrix*)horos_roiPropaMode
{
    [self horosLoadViewerPanels];
    return roiPropaMode;
}

- (NSMatrix*)horos_roiPropaDim
{
    [self horosLoadViewerPanels];
    return roiPropaDim;
}

- (NSMatrix*)horos_roiPropaCopy
{
    [self horosLoadViewerPanels];
    return roiPropaCopy;
}

- (NSTextField*)horos_roiPropaDest
{
    [self horosLoadViewerPanels];
    return roiPropaDest;
}

- (NSWindow*)horos_roiApplyWindow
{
    [self horosLoadViewerPanels];
    return roiApplyWindow;
}

- (NSMatrix*)horos_roiApplyMatrix
{
    [self horosLoadViewerPanels];
    return roiApplyMatrix;
}

- (NSWindow*)horos_addConvWindow
{
    [self horosLoadViewerPanels];
    return addConvWindow;
}

- (NSMatrix*)horos_convMatrix
{
    [self horosLoadViewerPanels];
    return convMatrix;
}

- (NSMatrix*)horos_sizeMatrix
{
    [self horosLoadViewerPanels];
    return sizeMatrix;
}

- (NSTextField*)horos_matrixName
{
    [self horosLoadViewerPanels];
    return matrixName;
}

- (NSTextField*)horos_matrixNorm
{
    [self horosLoadViewerPanels];
    return matrixNorm;
}

- (NSWindow*)horos_addCLUTWindow
{
    [self horosLoadViewerPanels];
    return addCLUTWindow;
}

- (NSTextField*)horos_clutName
{
    [self horosLoadViewerPanels];
    return clutName;
}

- (NSWindow*)horos_dcmExportWindow
{
    [self horosLoadViewerPanels];
    return dcmExportWindow;
}

- (NSMatrix*)horos_dcmSelection
{
    [self horosLoadViewerPanels];
    return dcmSelection;
}

- (NSMatrix*)horos_dcmFormat
{
    [self horosLoadViewerPanels];
    return dcmFormat;
}

- (NSSlider*)horos_dcmInterval
{
    [self horosLoadViewerPanels];
    return dcmInterval;
}

- (NSSlider*)horos_dcmFrom
{
    [self horosLoadViewerPanels];
    return dcmFrom;
}

- (NSSlider*)horos_dcmTo
{
    [self horosLoadViewerPanels];
    return dcmTo;
}

- (NSTextField*)horos_dcmIntervalText
{
    [self horosLoadViewerPanels];
    return dcmIntervalText;
}

- (NSTextField*)horos_dcmFromText
{
    [self horosLoadViewerPanels];
    return dcmFromText;
}

- (NSTextField*)horos_dcmToText
{
    [self horosLoadViewerPanels];
    return dcmToText;
}

- (NSTextField*)horos_dcmNumber
{
    [self horosLoadViewerPanels];
    return dcmNumber;
}

- (NSButton*)horos_dcmAllViewers
{
    [self horosLoadViewerPanels];
    return dcmAllViewers;
}

- (NSTextField*)horos_dcmSeriesName
{
    [self horosLoadViewerPanels];
    return dcmSeriesName;
}

- (NSWindow*)horos_imageExportWindow
{
    [self horosLoadViewerPanels];
    return imageExportWindow;
}

- (NSMatrix*)horos_imageSelection
{
    [self horosLoadViewerPanels];
    return imageSelection;
}

- (NSMatrix*)horos_imageFormat
{
    [self horosLoadViewerPanels];
    return imageFormat;
}

- (NSButton*)horos_imageAllViewers
{
    [self horosLoadViewerPanels];
    return imageAllViewers;
}

- (NSWindow*)horos_addOpacityWindow
{
    [self horosLoadViewerPanels];
    return addOpacityWindow;
}

- (NSTextField*)horos_OpacityName
{
    [self horosLoadViewerPanels];
    return OpacityName;
}

- (OpacityTransferView*)horos_OpacityView
{
    [self horosLoadViewerPanels];
    return OpacityView;
}

- (NSTextField*)horos_movieTextSlide
{
    return movieTextSlide;
}

- (NSButton*)horos_moviePlayStop
{
    return moviePlayStop;
}

- (NSSlider*)horos_movieRateSlider
{
    return movieRateSlider;
}

- (NSSlider*)horos_moviePosSlider
{
    return moviePosSlider;
}

- (NSPopUpButton*)horos_blendingPopupMenu
{
    return blendingPopupMenu;
}

- (NSTextField*)horos_blendingPercentage
{
    return blendingPercentage;
}

- (NSSlider*)horos_blendingSlider
{
    return blendingSlider;
}

- (ViewerController*)horos_blendingController
{
    return blendingController;
}

- (void)setHoros_blendingController:(ViewerController*)value
{
    [value retain];
    [blendingController release];
    blendingController = value;
}

- (void)horos_assignBlendingController:(ViewerController*)value
{
    blendingController = value;
}

- (NSTextField*)horos_roiRenameName
{
    [self horosLoadViewerPanels];
    return roiRenameName;
}

- (NSMatrix*)horos_roiRenameMatrix
{
    [self horosLoadViewerPanels];
    return roiRenameMatrix;
}

- (NSWindow*)horos_roiRenameWindow
{
    [self horosLoadViewerPanels];
    return roiRenameWindow;
}

- (NSString*)horos_curConvMenu
{
    return curConvMenu;
}

- (void)setHoros_curConvMenu:(NSString*)value
{
    [value retain];
    [curConvMenu release];
    curConvMenu = value;
}

- (void)horos_assignCurConvMenu:(NSString*)value
{
    curConvMenu = value;
}

- (NSString*)horos_curWLWWMenu
{
    return curWLWWMenu;
}

- (void)setHoros_curWLWWMenu:(NSString*)value
{
    [value retain];
    [curWLWWMenu release];
    curWLWWMenu = value;
}

- (void)horos_assignCurWLWWMenu:(NSString*)value
{
    curWLWWMenu = value;
}

- (NSString*)horos_curCLUTMenu
{
    return curCLUTMenu;
}

- (void)setHoros_curCLUTMenu:(NSString*)value
{
    [value retain];
    [curCLUTMenu release];
    curCLUTMenu = value;
}

- (void)horos_assignCurCLUTMenu:(NSString*)value
{
    curCLUTMenu = value;
}

- (NSString*)horos_backCurCLUTMenu
{
    return backCurCLUTMenu;
}

- (void)setHoros_backCurCLUTMenu:(NSString*)value
{
    [value retain];
    [backCurCLUTMenu release];
    backCurCLUTMenu = value;
}

- (void)horos_assignBackCurCLUTMenu:(NSString*)value
{
    backCurCLUTMenu = value;
}

- (NSTextField*)horos_stacksFusion
{
    return stacksFusion;
}

- (NSSlider*)horos_sliderFusion
{
    return sliderFusion;
}

- (NSButton*)horos_activatedFusion
{
    return activatedFusion;
}

- (NSPopUpButton*)horos_popFusion
{
    return popFusion;
}

- (NSPopUpButton*)horos_popupRoi
{
    return popupRoi;
}

- (NSMatrix*)horos_buttonToolMatrix
{
    return buttonToolMatrix;
}

- (NSMutableArray*)horos_fileListAt:(NSInteger)index
{
    return fileList[index];
}

- (void)horos_setFileList:(NSMutableArray*)value at:(NSInteger)index
{
    [value retain];
    [fileList[index] release];
    fileList[index] = value;
}

- (void)horos_assignFileList:(NSMutableArray*)value at:(NSInteger)index
{
    fileList[index] = value;
}

- (NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index
{
    return pixList[index];
}

- (void)horos_setPixList:(NSMutableArray<DCMPix *>*)value at:(NSInteger)index
{
    [value retain];
    [pixList[index] release];
    pixList[index] = value;
}

- (void)horos_assignPixList:(NSMutableArray<DCMPix *>*)value at:(NSInteger)index
{
    pixList[index] = value;
}

- (NSMutableArray<NSMutableArray<ROI *> *>*)horos_roiListAt:(NSInteger)index
{
    return roiList[index];
}

- (void)horos_setRoiList:(NSMutableArray<NSMutableArray<ROI *> *>*)value at:(NSInteger)index
{
    [value retain];
    [roiList[index] release];
    roiList[index] = value;
}

- (void)horos_assignRoiList:(NSMutableArray<NSMutableArray<ROI *> *>*)value at:(NSInteger)index
{
    roiList[index] = value;
}

- (NSMutableArray<NSData *>*)horos_copyRoiListAt:(NSInteger)index
{
    return copyRoiList[index];
}

- (void)horos_setCopyRoiList:(NSMutableArray<NSData *>*)value at:(NSInteger)index
{
    [value retain];
    [copyRoiList[index] release];
    copyRoiList[index] = value;
}

- (void)horos_assignCopyRoiList:(NSMutableArray<NSData *>*)value at:(NSInteger)index
{
    copyRoiList[index] = value;
}

- (NSObject*)horos_volumeDataAt:(NSInteger)index
{
    return volumeData[index];
}

- (void)horos_setVolumeData:(NSObject*)value at:(NSInteger)index
{
    [value retain];
    [volumeData[index] release];
    volumeData[index] = (NSData*) value;
}

- (void)horos_assignVolumeData:(NSObject*)value at:(NSInteger)index
{
    volumeData[index] = (NSData*) value;
}

- (short)horos_curMovieIndex
{
    return curMovieIndex;
}

- (void)setHoros_curMovieIndex:(short)value
{
    curMovieIndex = value;
}

- (short)horos_maxMovieIndex
{
    return maxMovieIndex;
}

- (void)setHoros_maxMovieIndex:(short)value
{
    maxMovieIndex = value;
}

- (NSToolbar*)horos_toolbar
{
    return toolbar;
}

- (void)setHoros_toolbar:(NSToolbar*)value
{
    [value retain];
    [toolbar release];
    toolbar = value;
}

- (void)horos_assignToolbar:(NSToolbar*)value
{
    toolbar = value;
}

- (float)horos_direction
{
    return direction;
}

- (void)setHoros_direction:(float)value
{
    direction = value;
}

- (NSMutableArray*)horos_ROINamesArray
{
    return ROINamesArray;
}

- (void)setHoros_ROINamesArray:(NSMutableArray*)value
{
    [value retain];
    [ROINamesArray release];
    ROINamesArray = value;
}

- (void)horos_assignROINamesArray:(NSMutableArray*)value
{
    ROINamesArray = value;
}

- (ThickSlabController*)horos_thickSlab
{
    return thickSlab;
}

- (void)setHoros_thickSlab:(ThickSlabController*)value
{
    [value retain];
    [thickSlab release];
    thickSlab = value;
}

- (void)horos_assignThickSlab:(ThickSlabController*)value
{
    thickSlab = value;
}

- (DICOMExport*)horos_exportDCM
{
    return exportDCM;
}

- (void)setHoros_exportDCM:(DICOMExport*)value
{
    [value retain];
    [exportDCM release];
    exportDCM = value;
}

- (void)horos_assignExportDCM:(DICOMExport*)value
{
    exportDCM = value;
}

- (BOOL)horos_windowWillClose
{
    return windowWillClose;
}

- (void)setHoros_windowWillClose:(BOOL)value
{
    windowWillClose = value;
}

- (BOOL)horos_requestLoadingCancel
{
    return requestLoadingCancel;
}

- (void)setHoros_requestLoadingCancel:(BOOL)value
{
    requestLoadingCancel = value;
}

- (BOOL)horos_postprocessed
{
    return postprocessed;
}

- (void)setHoros_postprocessed:(BOOL)value
{
    postprocessed = value;
}

- (NSPopUpButton*)horos_keyImagePopUpButton
{
    return keyImagePopUpButton;
}

- (BOOL)horos_displayOnlyKeyImages
{
    return displayOnlyKeyImages;
}

- (void)setHoros_displayOnlyKeyImages:(BOOL)value
{
    displayOnlyKeyImages = value;
}

- (int)horos_qt_to
{
    return qt_to;
}

- (void)setHoros_qt_to:(int)value
{
    qt_to = value;
}

- (int)horos_qt_from
{
    return qt_from;
}

- (void)setHoros_qt_from:(int)value
{
    qt_from = value;
}

- (int)horos_qt_interval
{
    return qt_interval;
}

- (void)setHoros_qt_interval:(int)value
{
    qt_interval = value;
}

- (int)horos_qt_dimension
{
    return qt_dimension;
}

- (void)setHoros_qt_dimension:(int)value
{
    qt_dimension = value;
}

- (int)horos_current_qt_interval
{
    return current_qt_interval;
}

- (void)setHoros_current_qt_interval:(int)value
{
    current_qt_interval = value;
}

- (int)horos_qt_allViewers
{
    return qt_allViewers;
}

- (void)setHoros_qt_allViewers:(int)value
{
    qt_allViewers = value;
}

- (NSWindow*)horos_printWindow
{
    [self horosLoadViewerPanels];
    return printWindow;
}

- (NSMatrix*)horos_printSelection
{
    [self horosLoadViewerPanels];
    return printSelection;
}

- (NSMatrix*)horos_printFormat
{
    [self horosLoadViewerPanels];
    return printFormat;
}

- (NSSlider*)horos_printInterval
{
    [self horosLoadViewerPanels];
    return printInterval;
}

- (NSSlider*)horos_printFrom
{
    [self horosLoadViewerPanels];
    return printFrom;
}

- (NSSlider*)horos_printTo
{
    [self horosLoadViewerPanels];
    return printTo;
}

- (NSTextField*)horos_printIntervalText
{
    [self horosLoadViewerPanels];
    return printIntervalText;
}

- (NSTextField*)horos_printFromText
{
    [self horosLoadViewerPanels];
    return printFromText;
}

- (NSTextField*)horos_printToText
{
    [self horosLoadViewerPanels];
    return printToText;
}

- (NSMatrix*)horos_printSettings
{
    [self horosLoadViewerPanels];
    return printSettings;
}

- (NSPopUpButton*)horos_printLayout
{
    [self horosLoadViewerPanels];
    return printLayout;
}

- (NSTextField*)horos_printText
{
    [self horosLoadViewerPanels];
    return printText;
}

- (NSTextField*)horos_printPagesToPrint
{
    [self horosLoadViewerPanels];
    return printPagesToPrint;
}

- (NSMutableArray*)horos_undoQueue
{
    return undoQueue;
}

- (void)setHoros_undoQueue:(NSMutableArray*)value
{
    [value retain];
    [undoQueue release];
    undoQueue = value;
}

- (void)horos_assignUndoQueue:(NSMutableArray*)value
{
    undoQueue = value;
}

- (NSMutableArray*)horos_redoQueue
{
    return redoQueue;
}

- (void)setHoros_redoQueue:(NSMutableArray*)value
{
    [value retain];
    [redoQueue release];
    redoQueue = value;
}

- (void)horos_assignRedoQueue:(NSMutableArray*)value
{
    redoQueue = value;
}

- (BOOL)horos_updateTilingViews
{
    return updateTilingViews;
}

- (void)setHoros_updateTilingViews:(BOOL)value
{
    updateTilingViews = value;
}

- (float)horos_resampleRatio
{
    return resampleRatio;
}

- (void)setHoros_resampleRatio:(float)value
{
    resampleRatio = value;
}

- (ViewerController*)horos_registeredViewer
{
    return registeredViewer;
}

- (void)setHoros_registeredViewer:(ViewerController*)value
{
    [value retain];
    [registeredViewer release];
    registeredViewer = value;
}

- (void)horos_assignRegisteredViewer:(ViewerController*)value
{
    registeredViewer = value;
}

- (ViewerController*)horos_blendedWindow
{
    return blendedWindow;
}

- (void)setHoros_blendedWindow:(ViewerController*)value
{
    [value retain];
    [blendedWindow release];
    blendedWindow = value;
}

- (void)horos_assignBlendedWindow:(ViewerController*)value
{
    blendedWindow = value;
}

- (NSMutableArray*)horos_retainedToolbarItems
{
    return retainedToolbarItems;
}

- (void)setHoros_retainedToolbarItems:(NSMutableArray*)value
{
    [value retain];
    [retainedToolbarItems release];
    retainedToolbarItems = value;
}

- (void)horos_assignRetainedToolbarItems:(NSMutableArray*)value
{
    retainedToolbarItems = value;
}

- (BOOL)horos_nonVolumicDataWarningDisplayed
{
    return nonVolumicDataWarningDisplayed;
}

- (void)setHoros_nonVolumicDataWarningDisplayed:(BOOL)value
{
    nonVolumicDataWarningDisplayed = value;
}

- (NSView*)horos_display12bitToolbarItemView
{
    return display12bitToolbarItemView;
}

- (NSMatrix*)horos_display12bitToolbarItemMatrix
{
    return display12bitToolbarItemMatrix;
}

- (NSRect)horos_windowFrameToRestore
{
    return windowFrameToRestore;
}

- (void)setHoros_windowFrameToRestore:(NSRect)value
{
    windowFrameToRestore = value;
}

- (BOOL)horos_scaleFitToRestore
{
    return scaleFitToRestore;
}

- (void)setHoros_scaleFitToRestore:(BOOL)value
{
    scaleFitToRestore = value;
}

- (NSString*)horos_printSpoolDirectory
{
    return printSpoolDirectory;
}

- (void)setHoros_printSpoolDirectory:(NSString*)value
{
    [value retain];
    [printSpoolDirectory release];
    printSpoolDirectory = value;
}

- (void)horos_assignPrintSpoolDirectory:(NSString*)value
{
    printSpoolDirectory = value;
}

@end

@implementation ViewerController (SwiftIvarsMore)

- (int)horos_blendingType
{
    return _blendingType;
}

- (void)setHoros_blendingType:(int)value
{
    _blendingType = value;
}

- (NSBox*)horos_dcmBox
{
    [self horosLoadViewerPanels];
    return dcmBox;
}

- (NSBox*)horos_quicktimeBox
{
    [self horosLoadViewerPanels];
    return quicktimeBox;
}

- (NSBox*)horos_printBox
{
    [self horosLoadViewerPanels];
    return printBox;
}

@end

// The bridges that need nothing private to ViewerController.m. The others,
// and the accessors of its statics, are in ViewerController.m.
@implementation ViewerController (SwiftBridgesPublic)

- (ROI*) horos_unretainedNewROI:(ToolMode) type
{
    return [self newROI: type];
}

// The Shift branch of -ApplyConv:, as the former code wrote it.
- (void)horos_beginDeleteConvolutionSheetForSender:(id)sender
{
    NSString *title = [sender title];
    [HorosAlertPanel beginWithTitle:NSLocalizedString(@"Remove a Convolution Filter", nil)
                           message:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete this convolution filter : '%@'", nil), title]
                     defaultButton:NSLocalizedString(@"Delete", nil) alternateButton:NSLocalizedString(@"Cancel", nil) otherButton:nil
                    modalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
        [self deleteConv:nil returnCode:(int)returnCode contextInfo:title];
    }];
}

@end
