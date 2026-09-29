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

#import "DCMView+SwiftIvars.h"

@implementation DCMView (SwiftIvars)

-(float)horos_rotation
{
    return rotation;
}

-(void)setHoros_rotation:(float)value
{
    rotation = value;
}

-(float)horos_scaleValue
{
    return scaleValue;
}

-(void)setHoros_scaleValue:(float)value
{
    scaleValue = value;
}

-(ToolMode)horos_currentTool
{
    return currentTool;
}

-(void)setHoros_currentTool:(ToolMode)value
{
    currentTool = value;
}

-(BOOL)horos_drawingROI
{
    return drawingROI;
}

-(void)setHoros_drawingROI:(BOOL)value
{
    drawingROI = value;
}

-(long)horos_scrollMode
{
    return scrollMode;
}

-(void)setHoros_scrollMode:(long)value
{
    scrollMode = value;
}

-(NSPoint)horos_start
{
    return start;
}

-(void)setHoros_start:(NSPoint)value
{
    start = value;
}

-(NSPoint)horos_previous
{
    return previous;
}

-(void)setHoros_previous:(NSPoint)value
{
    previous = value;
}

-(float)horos_blendingFactor
{
    return blendingFactor;
}

-(void)setHoros_blendingFactor:(float)value
{
    blendingFactor = value;
}

-(float)horos_blendingFactorStart
{
    return blendingFactorStart;
}

-(void)setHoros_blendingFactorStart:(float)value
{
    blendingFactorStart = value;
}

-(int)horos_annotationType
{
    return annotationType;
}

-(void)setHoros_annotationType:(int)value
{
    annotationType = value;
}

-(NSCursor*)horos_cursor
{
    return cursor;
}

-(void)setHoros_cursor:(NSCursor*)value
{
    [value retain];
    [cursor release];
    cursor = value;
}


-(BOOL)horos_flippedData
{
    return flippedData;
}

-(void)setHoros_flippedData:(BOOL)value
{
    flippedData = value;
}

-(int)horos_volumicData
{
    return volumicData;
}

-(void)setHoros_volumicData:(int)value
{
    volumicData = value;
}

-(BOOL)horos_volumicSeries
{
    return volumicSeries;
}

-(void)setHoros_volumicSeries:(BOOL)value
{
    volumicSeries = value;
}

-(BOOL)horos_mouseDraggedForROIUndo
{
    return mouseDraggedForROIUndo;
}

-(void)setHoros_mouseDraggedForROIUndo:(BOOL)value
{
    mouseDraggedForROIUndo = value;
}

-(BOOL)horos_colorTransfer
{
    return colorTransfer;
}

-(void)setHoros_colorTransfer:(BOOL)value
{
    colorTransfer = value;
}

-(unsigned char *)horos_colorBuf
{
    return colorBuf;
}

-(void)setHoros_colorBuf:(unsigned char *)value
{
    colorBuf = value;
}

-(unsigned char *)horos_redTable
{
    return (unsigned char *)redTable;
}

-(unsigned char *)horos_greenTable
{
    return (unsigned char *)greenTable;
}

-(unsigned char *)horos_blueTable
{
    return (unsigned char *)blueTable;
}

-(float *)horos_sliceFromTo
{
    return (float *)sliceFromTo;
}

-(float *)horos_sliceFromToS
{
    return (float *)sliceFromToS;
}

-(float *)horos_sliceFromToE
{
    return (float *)sliceFromToE;
}

-(float *)horos_sliceFromTo2
{
    return (float *)sliceFromTo2;
}

-(float)horos_sliceFromToThickness
{
    return sliceFromToThickness;
}

-(void)setHoros_sliceFromToThickness:(float)value
{
    sliceFromToThickness = value;
}

-(float *)horos_sliceVector
{
    return (float *)sliceVector;
}

-(float *)horos_slicePoint3D
{
    return (float *)slicePoint3D;
}

-(float)horos_syncRelativeDiff
{
    return syncRelativeDiff;
}

-(void)setHoros_syncRelativeDiff:(float)value
{
    syncRelativeDiff = value;
}

-(long)horos_syncSeriesIndex
{
    return syncSeriesIndex;
}

-(void)setHoros_syncSeriesIndex:(long)value
{
    syncSeriesIndex = value;
}

-(short)horos_thickSlabMode
{
    return thickSlabMode;
}

-(void)setHoros_thickSlabMode:(short)value
{
    thickSlabMode = value;
}

-(short)horos_thickSlabStacks
{
    return thickSlabStacks;
}

-(void)setHoros_thickSlabStacks:(short)value
{
    thickSlabStacks = value;
}

-(NSMutableArray *)horos_dcmPixList
{
    return dcmPixList;
}

-(void)setHoros_dcmPixList:(NSMutableArray *)value
{
    dcmPixList = value;
}

-(NSArray *)horos_dcmFilesList
{
    return dcmFilesList;
}

-(void)setHoros_dcmFilesList:(NSArray *)value
{
    dcmFilesList = value;
}

-(NSMutableArray *)horos_dcmRoiList
{
    return dcmRoiList;
}

-(void)setHoros_dcmRoiList:(NSMutableArray *)value
{
    dcmRoiList = value;
}

-(NSMutableArray *)horos_curRoiList
{
    return curRoiList;
}

-(void)setHoros_curRoiList:(NSMutableArray *)value
{
    curRoiList = value;
}

-(char)horos_listType
{
    return listType;
}

-(void)setHoros_listType:(char)value
{
    listType = value;
}

-(short)horos_curImage
{
    return curImage;
}

-(void)setHoros_curImage:(short)value
{
    curImage = value;
}

-(short)horos_startImage
{
    return startImage;
}

-(void)setHoros_startImage:(short)value
{
    startImage = value;
}

-(ToolMode)horos_currentMouseEventTool
{
    return currentMouseEventTool;
}

-(void)setHoros_currentMouseEventTool:(ToolMode)value
{
    currentMouseEventTool = value;
}

-(BOOL)horos_mouseDragging
{
    return mouseDragging;
}

-(void)setHoros_mouseDragging:(BOOL)value
{
    mouseDragging = value;
}

-(NSPoint)horos_originStart
{
    return originStart;
}

-(void)setHoros_originStart:(NSPoint)value
{
    originStart = value;
}

-(float)horos_startWW
{
    return startWW;
}

-(void)setHoros_startWW:(float)value
{
    startWW = value;
}

-(float)horos_curWW
{
    return curWW;
}

-(void)setHoros_curWW:(float)value
{
    curWW = value;
}

-(float)horos_startMin
{
    return startMin;
}

-(void)setHoros_startMin:(float)value
{
    startMin = value;
}

-(float)horos_startMax
{
    return startMax;
}

-(void)setHoros_startMax:(float)value
{
    startMax = value;
}

-(float)horos_startWL
{
    return startWL;
}

-(void)setHoros_startWL:(float)value
{
    startWL = value;
}

-(float)horos_curWL
{
    return curWL;
}

-(void)setHoros_curWL:(float)value
{
    curWL = value;
}

-(float)horos_bdstartWW
{
    return bdstartWW;
}

-(void)setHoros_bdstartWW:(float)value
{
    bdstartWW = value;
}

-(float)horos_bdstartMin
{
    return bdstartMin;
}

-(void)setHoros_bdstartMin:(float)value
{
    bdstartMin = value;
}

-(float)horos_bdstartMax
{
    return bdstartMax;
}

-(void)setHoros_bdstartMax:(float)value
{
    bdstartMax = value;
}

-(float)horos_bdstartWL
{
    return bdstartWL;
}

-(void)setHoros_bdstartWL:(float)value
{
    bdstartWL = value;
}

-(BOOL)horos_curWLWWSUVConverted
{
    return curWLWWSUVConverted;
}

-(void)setHoros_curWLWWSUVConverted:(BOOL)value
{
    curWLWWSUVConverted = value;
}

-(float)horos_curWLWWSUVFactor
{
    return curWLWWSUVFactor;
}

-(void)setHoros_curWLWWSUVFactor:(float)value
{
    curWLWWSUVFactor = value;
}

-(double)horos_resizeTotal
{
    return resizeTotal;
}

-(void)setHoros_resizeTotal:(double)value
{
    resizeTotal = value;
}

-(float)horos_startScaleValue
{
    return startScaleValue;
}

-(void)setHoros_startScaleValue:(float)value
{
    startScaleValue = value;
}

-(float)horos_rotationStart
{
    return rotationStart;
}

-(void)setHoros_rotationStart:(float)value
{
    rotationStart = value;
}

-(NSPoint)horos_origin
{
    return origin;
}

-(void)setHoros_origin:(NSPoint)value
{
    origin = value;
}

-(short)horos_crossMove
{
    return crossMove;
}

-(void)setHoros_crossMove:(short)value
{
    crossMove = value;
}

-(NSMatrix *)horos_matrix
{
    return matrix;
}

-(void)setHoros_matrix:(NSMatrix *)value
{
    matrix = value;
}

-(BOOL)horos_xFlipped
{
    return xFlipped;
}

-(void)setHoros_xFlipped:(BOOL)value
{
    xFlipped = value;
}

-(BOOL)horos_yFlipped
{
    return yFlipped;
}

-(void)setHoros_yFlipped:(BOOL)value
{
    yFlipped = value;
}

-(NSSize)horos_stringSize
{
    return stringSize;
}

-(void)setHoros_stringSize:(NSSize)value
{
    stringSize = value;
}

-(NSString *)horos_stringID
{
    return stringID;
}

-(void)setHoros_stringID:(NSString *)value
{
    stringID = value;
}

-(float)horos_mouseXPos
{
    return mouseXPos;
}

-(void)setHoros_mouseXPos:(float)value
{
    mouseXPos = value;
}

-(float)horos_mouseYPos
{
    return mouseYPos;
}

-(void)setHoros_mouseYPos:(float)value
{
    mouseYPos = value;
}

-(float)horos_pixelMouseValue
{
    return pixelMouseValue;
}

-(void)setHoros_pixelMouseValue:(float)value
{
    pixelMouseValue = value;
}

-(long)horos_pixelMouseValueR
{
    return pixelMouseValueR;
}

-(void)setHoros_pixelMouseValueR:(long)value
{
    pixelMouseValueR = value;
}

-(long)horos_pixelMouseValueG
{
    return pixelMouseValueG;
}

-(void)setHoros_pixelMouseValueG:(long)value
{
    pixelMouseValueG = value;
}

-(long)horos_pixelMouseValueB
{
    return pixelMouseValueB;
}

-(void)setHoros_pixelMouseValueB:(long)value
{
    pixelMouseValueB = value;
}

-(float)horos_blendingMouseXPos
{
    return blendingMouseXPos;
}

-(void)setHoros_blendingMouseXPos:(float)value
{
    blendingMouseXPos = value;
}

-(float)horos_blendingMouseYPos
{
    return blendingMouseYPos;
}

-(void)setHoros_blendingMouseYPos:(float)value
{
    blendingMouseYPos = value;
}

-(float)horos_blendingPixelMouseValue
{
    return blendingPixelMouseValue;
}

-(void)setHoros_blendingPixelMouseValue:(float)value
{
    blendingPixelMouseValue = value;
}

-(long)horos_blendingPixelMouseValueR
{
    return blendingPixelMouseValueR;
}

-(void)setHoros_blendingPixelMouseValueR:(long)value
{
    blendingPixelMouseValueR = value;
}

-(long)horos_blendingPixelMouseValueG
{
    return blendingPixelMouseValueG;
}

-(void)setHoros_blendingPixelMouseValueG:(long)value
{
    blendingPixelMouseValueG = value;
}

-(long)horos_blendingPixelMouseValueB
{
    return blendingPixelMouseValueB;
}

-(void)setHoros_blendingPixelMouseValueB:(long)value
{
    blendingPixelMouseValueB = value;
}

-(BOOL)horos_isKeyView
{
    return isKeyView;
}

-(void)setHoros_isKeyView:(BOOL)value
{
    isKeyView = value;
}

-(BOOL)horos__dragInProgress
{
    return _dragInProgress;
}

-(void)setHoros__dragInProgress:(BOOL)value
{
    _dragInProgress = value;
}

-(NSTimer *)horos__mouseDownTimer
{
    return _mouseDownTimer;
}

-(void)setHoros__mouseDownTimer:(NSTimer *)value
{
    _mouseDownTimer = value;
}

-(BOOL)horos__hasChanged
{
    return _hasChanged;
}

-(void)setHoros__hasChanged:(BOOL)value
{
    _hasChanged = value;
}

-(int)horos_repulsorRadius
{
    return repulsorRadius;
}

-(void)setHoros_repulsorRadius:(int)value
{
    repulsorRadius = value;
}

-(NSPoint)horos_repulsorPosition
{
    return repulsorPosition;
}

-(void)setHoros_repulsorPosition:(NSPoint)value
{
    repulsorPosition = value;
}

-(NSEvent *)horos_lengthClickEvent
{
    return lengthClickEvent;
}

-(void)setHoros_lengthClickEvent:(NSEvent *)value
{
    lengthClickEvent = value;
}

-(BOOL)horos_replayingLengthDrag
{
    return replayingLengthDrag;
}

-(void)setHoros_replayingLengthDrag:(BOOL)value
{
    replayingLengthDrag = value;
}

-(NSPoint)horos_ROISelectorStartPoint
{
    return ROISelectorStartPoint;
}

-(void)setHoros_ROISelectorStartPoint:(NSPoint)value
{
    ROISelectorStartPoint = value;
}

-(NSPoint)horos_ROISelectorEndPoint
{
    return ROISelectorEndPoint;
}

-(void)setHoros_ROISelectorEndPoint:(NSPoint)value
{
    ROISelectorEndPoint = value;
}

-(NSMutableArray *)horos_ROISelectorSelectedROIList
{
    return ROISelectorSelectedROIList;
}

-(void)setHoros_ROISelectorSelectedROIList:(NSMutableArray *)value
{
    ROISelectorSelectedROIList = value;
}

-(BOOL)horos_syncOnLocationImpossible
{
    return syncOnLocationImpossible;
}

-(void)setHoros_syncOnLocationImpossible:(BOOL)value
{
    syncOnLocationImpossible = value;
}

-(int)horos_resampledBaseAddrSize
{
    return resampledBaseAddrSize;
}

-(void)setHoros_resampledBaseAddrSize:(int)value
{
    resampledBaseAddrSize = value;
}

-(NSRect)horos_drawingFrameRect
{
    return drawingFrameRect;
}

-(void)setHoros_drawingFrameRect:(NSRect)value
{
    drawingFrameRect = value;
}

-(NSRect)horos_screenCaptureRect
{
    return screenCaptureRect;
}

-(void)setHoros_screenCaptureRect:(NSRect)value
{
    screenCaptureRect = value;
}

-(BOOL)horos_exceptionDisplayed
{
    return exceptionDisplayed;
}

-(void)setHoros_exceptionDisplayed:(BOOL)value
{
    exceptionDisplayed = value;
}

-(BOOL)horos_COPYSETTINGSINSERIES
{
    return COPYSETTINGSINSERIES;
}

-(void)setHoros_COPYSETTINGSINSERIES:(BOOL)value
{
    COPYSETTINGSINSERIES = value;
}

-(int)horos_avoidRecursiveSync
{
    return avoidRecursiveSync;
}

-(void)setHoros_avoidRecursiveSync:(int)value
{
    avoidRecursiveSync = value;
}

-(BOOL)horos_avoidChangeWLWWRecursive
{
    return avoidChangeWLWWRecursive;
}

-(void)setHoros_avoidChangeWLWWRecursive:(BOOL)value
{
    avoidChangeWLWWRecursive = value;
}

-(float)horos_studyColorR
{
    return studyColorR;
}

-(void)setHoros_studyColorR:(float)value
{
    studyColorR = value;
}

-(float)horos_studyColorG
{
    return studyColorG;
}

-(void)setHoros_studyColorG:(float)value
{
    studyColorG = value;
}

-(float)horos_studyColorB
{
    return studyColorB;
}

-(void)setHoros_studyColorB:(float)value
{
    studyColorB = value;
}

-(NSUInteger)horos_studyDateIndex
{
    return studyDateIndex;
}

-(void)setHoros_studyDateIndex:(NSUInteger)value
{
    studyDateIndex = value;
}

-(HorosAnnotationBox *)horos_studyDateBox
{
    return studyDateBox;
}

-(void)setHoros_studyDateBox:(HorosAnnotationBox *)value
{
    studyDateBox = value;
}

-(NSArray *)horos_cleanedOutDcmPixArray
{
    return cleanedOutDcmPixArray;
}

-(void)setHoros_cleanedOutDcmPixArray:(NSArray *)value
{
    cleanedOutDcmPixArray = value;
}

-(DCMView *)horos_blendingView
{
    return blendingView;
}

-(void)setHoros_blendingView:(DCMView *)value
{
    blendingView = value;
}

@end
