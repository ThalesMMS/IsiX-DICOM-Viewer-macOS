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

#include "options.h"
#import "HorosAlertPanel.h"
#import "AppController.h"
#import "Horos-Swift.h"
#import "HorosDCMTKObject.h"
#import <objc/runtime.h>
#import "PlanarHostBridge.h"
#import "ViewerAutounbinderDetach.h"
#import "DicomFileDCMTKCategory.h"

#import "NSImage+N2.h"
#import "DefaultsOsiriX.h"
#import "NSAppleScript+HandlerCalls.h"
#import "AYDicomPrintWindowController.h"
#import "MyOutlineView.h"
#import "PluginFilter.h"
#import "DCMPix.h"
#import "DicomImage.h"
#import "VRController.h"
#import "NSSplitViewSave.h"
#import "SRController.h"
#import "OsiriXToolbar.h"
#import "NSFullScreenWindow.h"
#import "ViewerController.h"
#import "ViewerController+ROIInterchange.h"
#import "HorosCalibration.h"
#import "HorosContentBounds.h"
#import "BrowserController.h"
#import "Wait.h"
#import "XMLController.h"
#include <Accelerate/Accelerate.h>
#import "WaitRendering.h"
#import "HistogramWindow.h"
#import "ROIWindow.h"
#import "ROIDefaultsWindow.h"
#import <ScreenSaver/ScreenSaverView.h>
#import "ToolbarPanel.h"
#import "ThumbnailsListPanel.h"
#import "DCMView.h"
#import "StudyView.h"
#import "ColorTransferView.h"
#import "ThickSlabController.h"
#import "Mailer.h"
#import "ITKSegmentation3DController.h"
#import "ITKSegmentation3D.h"
#import "OSIWindow.h"
#import "Photos.h"
#import "SeriesView.h"
#import "DICOMExport.h"
#import "ROIVolumeController.h"
#import "OrthogonalMPRViewer.h"
#import "OrthogonalMPRPETCTViewer.h"
#import "OrthogonalMPRPETCTController.h"
#import "EndoscopyViewer.h"
#import "PaletteController.h"
#import "ROIManagerController.h"
#import "NSUserDefaultsController+OsiriX.h"
#import "ThreadsManager.h"
#import "NSThread+N2.h"
#import "ITKBrushROIFilter.h"
#import "DCMAbstractSyntaxUID.h"
#import "printView.h"
#import "ITKTransform.h"
#import "NSManagedObject+N2.h"
#import "DicomStudy.h"
#import "JPEGExif.h"
#import "Reports.h"
#import "SRAnnotation.h"
#import "CalciumScoringWindowController.h"
#import "HornRegistration.h"
#import "N2Stuff.h"
#import "BonjourBrowser.h"
#import "PluginManager.h"
#import "DCMObject.h"
#import "DCMAttributeTag.h"
#import "NavigatorWindowController.h"
#import "ThreeDPositionController.h"
#import "ThumbnailCell.h"
#import "DicomSeries.h"
#import "DicomFile.h"
#import "MPRController.h"
#import "CPRController.h"
#import "Notifications.h"
#import "DicomDatabase.h"
#import "N2Debug.h"
#import "OSIEnvironment+Private.h"
#import "NSString+N2.h"
#import "WindowLayoutManager.h"
#import "DCMTKQueryNode.h"
#import "DCMTKStudyQueryNode.h"
#import "O2ViewerThumbnailsMatrix.h"
#import "ToolBarNSWindow.h"
#import "RemoteDicomDatabase.h"

#if defined(USEHOMEPHONE)
#import "homephone/HorosHomePhone.h"
#endif

int delayedTileWindows = NO;

#define MAXSCREENS 10

extern ThumbnailsListPanel *thumbnailsListPanel[ MAXSCREENS];


static	BOOL SYNCSERIES = NO, ViewBoundsDidChangeProtect = NO, recursiveCloseWindowsProtected = NO;

// The other toolbar identifiers are constants of ViewerController+Toolbar.swift
// since #832; the ones below are still read here.
static NSString*	PlayToolbarItemIdentifier			= @"Play.pdf";
static NSString*	PauseToolbarItemIdentifier			= @"Pause.pdf";
//static NSString*	iChatBroadCastToolbarItemIdentifier = @"iChat.icns";
static NSString*	SyncSeriesToolbarItemIdentifier		= @"Sync.pdf";
static NSString*	ReportToolbarItemIdentifier			= @"Report.icns";


static	float deg2rad									= M_PI/180.0;

static NSMenu *wlwwPresetsMenu = nil;
static NSMenu *contextualMenu = nil;
static NSMenu *convolutionPresetsMenu = nil;
static NSMenu *opacityPresetsMenu = nil;
static NSImage* retrieveImage = nil;

static int numberOf2DViewer = 0;
static NSMutableArray *arrayOf2DViewers = nil;
static BOOL DisplayUseInvertedPolarity = NO;

BOOL SyncButtonBehaviorIsBetweenStudies = NO;

// compares the names of 2 ROIs.
// using the option NSNumericSearch => "Point 1" < "Point 5" < "Point 21".
// use it with sortUsingFunction:context: to order an array of ROIs
NSInteger sortROIByName(id roi1, id roi2, void *context)
{
    NSString *n1 = [roi1 name];
    NSString *n2 = [roi2 name];
    return [n1 compare:n2 options:NSNumericSearch];
}

@interface ViewerControllerOperation: NSOperation
{
    ViewerController *ctrl;
    NSDictionary *dict;
}

- (id) initWithController:(ViewerController*) c dict: (NSDictionary*) d;

@end

@implementation ViewerControllerOperation

- (id) initWithController:(ViewerController*) c dict: (NSDictionary*) d;
{
    self = [super init];
    
    ctrl = [c retain];
    dict = [d retain];
    
    return self;
}

- (void) main
{
    @autoreleasepool
    {
#ifndef OSIRIX_LIGHT
        // ** Set Pixels
        
        if( [[dict valueForKey:@"action"] isEqualToString:@"setPixel"])
        {
            [[dict objectForKey:@"curPix"]	fillROI:		nil
                                            newVal:			[[dict objectForKey:@"newValue"] floatValue]
                                          minValue:		[[dict objectForKey:@"minValue"] floatValue]
                                          maxValue:		[[dict objectForKey:@"maxValue"] floatValue]
                                           outside:		[[dict objectForKey:@"outside"] boolValue]
                                  orientationStack:2
                                           stackNo:		[[dict objectForKey:@"stackNo"] intValue]
                                           restore:		[[dict objectForKey:@"revert"] boolValue]
                                          addition:		[[dict objectForKey:@"addition"] boolValue]];
        }
        
        if( [[dict valueForKey:@"action"] isEqualToString:@"setPixelRoi"])
        {
            [[dict objectForKey:@"curPix"]	fillROI:			[dict objectForKey:@"roi"]
                                            newVal:				[[dict objectForKey:@"newValue"] floatValue]
                                          minValue:			[[dict objectForKey:@"minValue"] floatValue]
                                          maxValue:			[[dict objectForKey:@"maxValue"] floatValue]
                                           outside:			[[dict objectForKey:@"outside"] boolValue]
                                  orientationStack:	2
                                           stackNo:			[[dict objectForKey:@"stackNo"] intValue]
                                           restore:			[[dict objectForKey:@"revert"] boolValue]
                                          addition:			[[dict objectForKey:@"addition"] boolValue]];
        }
        // ** Math Morphology
        
        if( [[dict valueForKey:@"action"] isEqualToString:@"close"])
            [[dict objectForKey:@"filter"] close: [dict objectForKey:@"roi"] withStructuringElementRadius: [[dict objectForKey:@"radius"] intValue]];
        
        if( [[dict valueForKey:@"action"] isEqualToString:@"open"])
            [[dict objectForKey:@"filter"] open: [dict objectForKey:@"roi"] withStructuringElementRadius: [[dict objectForKey:@"radius"] intValue]];
        
        if( [[dict valueForKey:@"action"] isEqualToString:@"dilate"])
            [[dict objectForKey:@"filter"] dilate: [dict objectForKey:@"roi"] withStructuringElementRadius: [[dict objectForKey:@"radius"] intValue]];
        
        if( [[dict valueForKey:@"action"] isEqualToString:@"erode"])
            [[dict objectForKey:@"filter"] erode: [dict objectForKey:@"roi"] withStructuringElementRadius: [[dict objectForKey:@"radius"] intValue]];
#endif
        
    }
}

- (void) dealloc
{
    [ctrl release];
    [dict release];
    [super dealloc];
}

@end


@interface ViewerController (Private)

-(NSMenu*)contextualMenu;
-(NSMenu*)contextualMenuForROI:(ROI*)roi;

- (void)sendWillFreeVolumeDataNotificationWithVolumeData:(NSData *)volumeData movieIndex:(NSInteger)movieIndex;
- (void)sendDidAllocateVolumeDataNotificationWithVolumeData:(NSData *)volumeData movieIndex:(NSInteger)movieIndex;

@end

@interface ViewerController (Dummy)

- (void)resizeWindow:(id)dummy;

@end

enum
{
    NSTruncateStart,
    NSTruncateMiddle,
    NSTruncateEnd
};

@interface NSString (Truncate)

- (NSString *)stringWithTruncatingToLength:(unsigned)length;
- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom;
- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom withEllipsisString:(NSString *)ellipsis;

@end


@implementation NSString (Truncate)

- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom withEllipsisString:(NSString *)ellipsis{
    NSMutableString *result = [[[NSMutableString alloc] initWithString:self] autorelease];
    NSString *immutableResult;
    
    if([result length] <= length) {
        return self; // no truncation, foolios
    }
    
    unsigned int charactersEachSide = length / 2;
    
    NSString *first;
    NSString *last;
    
    switch(truncateFrom) {
        case NSTruncateStart:
            [result insertString:ellipsis atIndex:length - [ellipsis length]];
            immutableResult  = [[result substringToIndex:length] copy];
            return [immutableResult autorelease];
            break;
        case NSTruncateMiddle:
            first = [result substringToIndex:charactersEachSide - [ellipsis length]+1];
            last = [result substringFromIndex:[result length] - charactersEachSide];
            immutableResult = [[[NSArray arrayWithObjects:first, last, NULL] componentsJoinedByString:ellipsis] copy];
            return [immutableResult autorelease];
            break;
        case NSTruncateEnd:
            [result insertString:ellipsis atIndex:[result length] - length + [ellipsis length] ];
            immutableResult  = [[result substringFromIndex:[result length] - length] copy];
            return [immutableResult autorelease];
    }
    
    return @"";
}


- (NSString *)stringWithTruncatingToLength:(unsigned)length {
    return [self stringTruncatedToLength:length direction:NSTruncateMiddle];
}

- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom {
    return [self stringTruncatedToLength:length direction:truncateFrom withEllipsisString:@"…"];
}

@end

#pragma mark-

@interface ViewerController ()

-(void)observeScrollerStyleDidChangeNotification:(NSNotification*)n;
+ (NSColor*)_selectedItemColor;
+ (NSColor*)_fusionedItemColor;
+ (NSColor*)_openItemColor;
- (BOOL)horosPickInterslicePreferred:(ROI *)preferred first:(NSDictionary **)first second:(NSDictionary **)second;
- (NSMutableDictionary *)volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create;
- (void)registerVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex anchor:(DicomImage *)anchor;
- (void)attachVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex;
- (void)restoreVolumeLengthSnapshot:(NSDictionary *)snapshot movieIndex:(long)movieIndex;
- (void)saveVolumeLengthROIs:(long)movieIndex writtenPaths:(NSMutableArray *)paths anchorPaths:(NSDictionary *)anchorPaths;
@end

static char HorosVolumeLengthStateKey;

// Unlike an absent archive, an unreadable archive must never be replaced by an
// empty list when a generated view saves its volume measurements.
static NSArray *HorosVolumeLengthReadArchive(NSString *path)
{
    if( path.length == 0 || [[NSFileManager defaultManager] fileExistsAtPath:path] == NO)
        return @[];
    NSData *data = [SRAnnotation roiFromDICOM:path];
    id rois = data ? [HorosRestrictedUnarchiver unarchiveROIsWithData:data] : [HorosRestrictedUnarchiver unarchiveROIsWithFile:path];
    if( [rois isKindOfClass:[NSArray class]] == NO)
        [NSException raise:NSInvalidUnarchiveOperationException format:@"The existing ROI archive could not be read."];
    return rois;
}

@interface ViewerController (SEGSurface)
- (IBAction)showSEGSurfaces:(id)sender;
@end

BOOL HorosCalibrationFloat(NSString *text, NSLocale *locale, float *value)
{
    NSString *entry = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!entry.length) return NO;
    for (NSLocale *candidate in @[locale, [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]])
    {
        NSScanner *scanner = [NSScanner scannerWithString:entry];
        scanner.locale = candidate;
        double number = 0;
        if ([scanner scanDouble:&number] && scanner.isAtEnd && isfinite(number) && fabs(number) <= FLT_MAX)
        {
            float result = (float)number;
            if (number != 0 && result == 0) return NO;
            *value = result;
            return YES;
        }
    }
    return NO;
}

@implementation ViewerController

@synthesize currentOrientationTool, speedSlider, speedText, toolbarPanel;
@synthesize timer, keyImageCheck, injectionDateTime, blendedWindow;
@synthesize blendingTypeWindow, blendingTypeMultiply, blendingTypeSubtract, blendingTypeRGB, blendingPlugins, blendingResample;
@synthesize flagListPODComparatives, windowsStateName, titledGantry;
@synthesize movieRateSlider = movieRateSlider, movieTextSlide = movieTextSlide;

// WARNING: If you add or modify this list, check ViewerController.m, DCMView.h and HotKey Pref Pane
static int hotKeyToolCrossTable[] =
{
    WWWLToolHotKeyAction,		//tWL				0
    MoveHotKeyAction,			//tTranslate		1
    ZoomHotKeyAction,			//tZoom				2
    RotateHotKeyAction,			//tRotate			3
    ScrollHotKeyAction,			//tNext				4
    LengthHotKeyAction,			//tMesure			5
    RectangleHotKeyAction,		//tROI				6
    Rotate3DHotKeyAction,		//t3DRotate			7
    OrthoMPRCrossHotKeyAction,	//tCross			8
    OvalHotKeyAction,			//tOval				9
    OpenPolygonHotKeyAction,	//tOPolygon			10
    ClosedPolygonHotKeyAction, //tCPolygon			11
    AngleHotKeyAction,			//tAngle			12
    TextHotKeyAction,			//tText				13
    ArrowHotKeyAction,			//tArrow			14
    PencilHotKeyAction,			//tPencil			15
    -1,                         //t3Dpoint			16
    scissors3DHotKeyAction,		//t3DCut			17
    Camera3DotKeyAction,		//tCamera3D			18
    ThreeDPointHotKeyAction,    //t2DPoint			19
    PlainToolHotKeyAction,		//tPlain			20
    BoneRemovalHotKeyAction,	//tBonesRemoval		21
    -1,							//tWLBlended		22
    RepulsorHotKeyAction,		//tRepulsor			23
    -1,							//tLayerROI			24
    SelectorHotKeyAction,		//tROISelector		25
    -1,							//tAxis				26
    -1,							//tDynAngle			27
    -1,                         //tCurvedROI        28
    -1,                         //tTAGT             29
};

+ (ToolMode) getToolEquivalentToHotKey :(int) h
{
    int m = sizeof( hotKeyToolCrossTable) / sizeof( hotKeyToolCrossTable[ 0]);
    
    for( int i = 0; i < m; i++)
        if( hotKeyToolCrossTable[ i] == h) return i;
    
    return -1;
}

+ (int) getHotKeyEquivalentToTool:(ToolMode) h
{
    if( h <= sizeof( hotKeyToolCrossTable) / sizeof( hotKeyToolCrossTable[ 0]))
    {
        return hotKeyToolCrossTable[ h];
    }
    
    return -1;
}

+ (NSArray*) displayed2DViewerForScreen: (NSScreen*) screen
{
    NSMutableArray *array = [NSMutableArray array];
    
    for( NSWindow *w in [NSApp orderedWindows])
    {
        if( [[w windowController] isKindOfClass:[ViewerController class]] && w.isVisible)
        {
            if( screen == nil || [w.screen isEqual: screen])
            {
                ViewerController *v = w.windowController;
                
                if( v.windowWillClose == NO)
                    [array addObject: v];
            }
        }
    }
    
    return array;
}

// Retained as a compatibility entry point for existing callers and plugins.
// Selection now reads AppKit's current order instead of retaining viewer snapshots.
+ (void) clearFrontMost2DViewerCache
{
}

+ (ViewerController*) frontMostDisplayed2DViewerForScreen: (NSScreen*) screen
{
    // AppKit's orderedWindows can lag the key/main viewer during activation.
    // Prefer the actual command recipient before considering other visible windows.
    NSArray *windows = [@[NSApp.keyWindow ?: (id)NSNull.null,
                          NSApp.mainWindow ?: (id)NSNull.null]
                        arrayByAddingObjectsFromArray:[NSApp orderedWindows]];
    for (id candidate in windows)
    {
        if (![candidate isKindOfClass:[NSWindow class]])
            continue;
        NSWindow *window = candidate;
        if (!window.isVisible || ![window.windowController isKindOfClass:[ViewerController class]])
            continue;
        if (screen && ![window.screen isEqual:screen])
            continue;
        ViewerController *viewer = window.windowController;
        if (!viewer.windowWillClose)
            return viewer;
    }
    return nil;
}

+ (ViewerController*) frontMostDisplayed2DViewer
{
    return [self frontMostDisplayed2DViewerForScreen:nil];
}

+ (BOOL) isFrontMost2DViewer: (NSWindow*) window
{
    return window != nil && [self frontMostDisplayed2DViewer].window == window;
}

+ (NSMutableArray*) get2DViewers // on screen and off screen
{
    @synchronized( arrayOf2DViewers)
    {
        return [[arrayOf2DViewers copy] autorelease];
    }
    
    return nil;
}

+ (NSMutableArray*) getDisplayed2DViewers
{
    NSMutableArray *viewersList = [NSMutableArray array];
    
    for( ViewerController *w in [ViewerController get2DViewers])
    {
        if( [[w window] isKindOfClass: [NSFullScreenWindow class]])
        {
        }
        else if( [w isKindOfClass:[ViewerController class]])
        {
            if( [w windowWillClose] == NO)
                [viewersList addObject: w];
        }
    }
    
    return viewersList;
}

+ (NSArray*) getDisplayedStudies
{
    NSArray				*displayedViewers = [ViewerController getDisplayed2DViewers];
    NSMutableArray		*studiesArray = [NSMutableArray array];
    
    for( ViewerController *win in displayedViewers)
    {
        if( [[[win imageView] seriesObj] valueForKey:@"study"])
        {
            if( [studiesArray containsObject: [[[win imageView] seriesObj] valueForKey:@"study"]] == NO)
                [studiesArray addObject: [[[win imageView] seriesObj] valueForKey:@"study"]];
        }
    }
    
    return studiesArray;
}

+ (NSArray*) getDisplayedSeries
{
    NSArray				*displayedViewers = [ViewerController getDisplayed2DViewers];
    NSMutableArray		*seriesArray = [NSMutableArray array];
    
    for( ViewerController *win in displayedViewers)
    {
        if( [[win imageView] seriesObj])
        {
            if( [seriesArray containsObject: [[win imageView] seriesObj]] == NO)
                [seriesArray addObject: [[win imageView] seriesObj]];
        }
    }
    
    return seriesArray;
}

+ (NSArray*) studyColors
{
    static NSArray *gStudyColors = nil;
    
    if( gStudyColors == nil)
        gStudyColors = [[NSArray alloc] initWithObjects:
                        [NSColor colorWithDeviceRed:0.4f green:0.4f blue:0.0f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.4f green:0.0f blue:0.4f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.0f green:0.4f blue:0.4f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.4f green:0.0f blue:0.0f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.0f green:0.4f blue:0.0f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.0f green:0.0f blue:0.4f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.3f green:0.5f blue:0.0f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.3f green:0.0f blue:0.6f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.0f green:0.5f blue:0.6f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.3f green:0.0f blue:0.0f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.0f green:0.5f blue:0.0f alpha:1.0f],
                        [NSColor colorWithDeviceRed:0.0f green:0.0f blue:0.6 alpha:1.0f],
                        nil];
    
    return gStudyColors;
}

- (NSString*) description
{
    return [NSString stringWithFormat: @"ViewerController: %@, %@", self.studyInstanceUID, imageView.studyObj.date];
}

- (long) indexForPix: (long) pixIndex	// for backward compatibility
{
    return pixIndex;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
#ifdef EXPORTTOOLBARITEM
    return YES;
#endif
    BOOL valid = NO;
    
    if( windowWillClose)
        return NO;
    
    if( [[fileList[ 0] lastObject] isKindOfClass:[NSManagedObject class]] == NO)
        return NO;
    
    if (item.action == @selector(togglePatientCrosshair:)) {
        item.state = [HorosPatientCrosshairController shared].isVisible ? NSControlStateValueOn : NSControlStateValueOff;
        return self.imageView.curDCM != nil;
    }

    if( [item action] == @selector( seriesPopupSelect:))
    {
        [self buildSeriesPopup];
        valid = YES;
    }
    else if( [item action] == @selector( displaySUV:))
    {
        if( [[imageView curDCM] hasSUV])
            valid = YES;
    }
    else if( [item action] == @selector( flipDataSeries:))
    {
        if( pixList[ curMovieIndex].count > 1)
            valid = YES;
    }
    else if( [item action] == @selector( navigator:))
    {
        if( [[[self imageView] curDCM] isRGB] && [self isDataVolumicIn4D: YES])
            valid = YES;
    }
    else if( [item action] == @selector( threeDPanel:))
    {
        if( [self isDataVolumicIn4D: YES])
            valid = YES;
    }
    else if( [item action] == @selector( useVOILUT:))
    {
        if( imageView.curDCM.VOILUTApplied)
            [item setState: NSControlStateValueOn];
        else
            [item setState: [[NSUserDefaults standardUserDefaults] boolForKey: @"UseVOILUT"]];
        
        if( imageView.curDCM.VOILUT_table)
            valid = YES;
    }
    else if( [item action] == @selector(resetWindowsState:))
    {
        NSArray				*studiesArray = [ViewerController getDisplayedStudies];
        for( id loopItem in studiesArray)
        {
            if( [loopItem valueForKey:@"windowsState"]) valid = YES;
        }
    }
    else if( [item action] == @selector(setAllKeyImages:))
    {
        if( postprocessed == NO)
        {
            for( int x = 0 ; x < maxMovieIndex ; x++)
            {
                for( NSManagedObject *o in fileList[ x])
                {
                    if( [[o valueForKey: @"isKeyImage"] boolValue] == NO)
                    {
                        valid = YES;
                        break;
                    }
                }
            }
        }
    }
    else if( [item action] == @selector(setAllNonKeyImages:))
    {
        if( postprocessed == NO)
        {
            for( int x = 0 ; x < maxMovieIndex ; x++)
            {
                for( NSManagedObject *o in fileList[ x])
                {
                    if( [[o valueForKey: @"isKeyImage"] boolValue] == YES)
                    {
                        valid = YES;
                        break;
                    }
                }
            }
        }
    }
    else if( [item action] == @selector(findNextPreviousKeyImage:))
    {
        if( postprocessed == NO)
        {
            DicomStudy *s = [[imageView seriesObj] valueForKey:@"study"];
            
            if( [[s keyImages] count])
                valid = YES;
        }
    }
    else if( [item action] == @selector(loadWindowsState:))
    {
        if( [imageView.studyObj valueForKey:@"windowsState"]) valid = YES;
    }
    else if( [item action] == @selector(roiDeleteAllROIsWithSameName:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(blendWindows:))
    {
        if( numberOf2DViewer > 1) valid = YES;
    }
    else if( [item action] == @selector(roiGetInfo:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(roiHistogram:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(roiVolume:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(roiVolumeEraseRestore:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(createLayerROIFromSelectedROI:))
    {
        if( [self selectedROI])
        {
            valid = YES;
            
            ROI *r = [self selectedROI];
            
            if( r.type == tText) valid = NO;
            if( r.type == tMesure) valid = NO;
            if( r.type == t2DPoint) valid = NO;
            if( r.type == tArrow) valid = NO;
        }
    }
    else if( [item action] == @selector(generateGeometryFromSelectedLine:))
    {
        ROI *line = nil;
        if( [item representedObject] && [[item representedObject] isKindOfClass: [ROI class]])
            line = [item representedObject];
        else
        {
            for( ROI *roi in [self selectedROIs])
            {
                if( roi.type == tMesure && roi.points.count >= 2)
                {
                    line = roi;
                    break;
                }
            }
        }
        valid = line != nil && line.locked == NO;
    }
    else if( [item action] == @selector(measureBetweenSelectedSlices:))
    {
        NSDictionary *first = nil, *second = nil;
        valid = [self horosPickInterslicePreferred: nil first: &first second: &second];
    }
    else if( [item action] == @selector(groupSelectedROIs:))
    {
        if( [[self selectedROIs] count] > 1) valid = YES;
    }
    else if( [item action] == @selector(ungroupSelectedROIs:))
    {
        for( ROI *r in [roiList[curMovieIndex] objectAtIndex: [imageView curImage]])
        {
            if( r.groupID)
            {
                valid = YES;
                break;
            }
        }
    }
    else if( [item action] == @selector(lockSelectedROIs:))
    {
        for( ROI *r in [roiList[ curMovieIndex] objectAtIndex: [imageView curImage]])
        {
            if( r.locked == NO)
            {
                valid = YES;
                break;
            }
        }
    }
    else if( [item action] == @selector(unlockSelectedROIs:))
    {
        for( ROI *r in [roiList[ curMovieIndex] objectAtIndex: [imageView curImage]])
        {
            if( r.locked == YES)
            {
                valid = YES;
                break;
            }
        }
    }
    else if( [item action] == @selector(makeSelectedROIsUnselectable:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(makeAllROIsSelectable:))
    {
        for( ROI *r in [roiList[ curMovieIndex] objectAtIndex: [imageView curImage]])
        {
            if( r.selectable == NO)
            {
                valid = YES;
                break;
            }
        }
    }
    else if( [item action] == @selector(morphoSelectedBrushROI:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(convertBrushPolygon:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(mergeBrushROI:))
    {
        // This used to assign the answer on every element, so only the last one
        // decided: a brush followed by a polygon disabled the command, the same
        // two the other way round enabled it, and the merge then ran over a ROI
        // that is not a brush. HorosROIMenuEnablement gives the order-independent
        // rule the command can honour.
        NSMutableArray *types = [NSMutableArray array];
        for( ROI *i in [self selectedROIs])
            [types addObject: @(i.type)];
        valid = [HorosROIMenuEnablement mayMergeBrushROIsWithTypes: types];
    }
    else if( [item action] == @selector(roiPropagateSetup:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(roiDeleteGeneratedROIs:))
    {
        for( int y = 0; y < maxMovieIndex; y++)
        {
            for( int x = 0; x < [pixList[ y] count]; x++)
            {
                for( int i = 0; i < [[roiList[ y] objectAtIndex: x] count]; i++)
                {
                    ROI *r = [[roiList[ y] objectAtIndex: x] objectAtIndex: i];
                    
                    if( [[r comments] isEqualToString: @"morphing generated"])
                    {
                        valid = YES;
                        break;
                    }
                }
            }
        }
    }
    else if( [item action] == @selector(roiSaveSeries:) || [item action] == @selector(roiSelectDeselectAll:) || [item action] == @selector(roiDeleteAll:) || [item action] == @selector(roiRename:) || [item action] == @selector(setROIsImagesKeyImages:))
    {
        for( int y = 0; y < maxMovieIndex; y++)
        {
            for( int x = 0; x < [pixList[ y] count]; x++)
            {
                if ([[roiList[y] objectAtIndex:x] count] > 0)
                    valid = YES;
            }
        }
    }
    else if( [item action] == @selector(roiPropagateSlab:))
    {
        if( [self selectedROI]) valid = YES;
    }
    else if( [item action] == @selector(applyConvolutionOnSource:))
    {
        if( [curConvMenu isEqualToString:NSLocalizedString(@"No Filter", nil)] == NO) valid = YES;
    }
    else if( [item action] == @selector(ConvertToBWMenu:))
    {
        if( [[pixList[ curMovieIndex] objectAtIndex: 0] isRGB] == YES) valid = YES;
    }
    else if( [item action] == @selector(ConvertToRGBMenu:))
    {
        if( [[pixList[ curMovieIndex] objectAtIndex: 0] isRGB] == NO) valid = YES;
    }
    else if( [item action] == @selector(setImageTiling:))
    {
        valid = YES;
        
        int rows = [imageView rows];
        int columns = [imageView columns];
        int tag =  ((rows - 1) * 4) + (columns - 1);
        
        if( [item tag] == tag) [item setState:NSControlStateValueOn];
        else [item setState:NSControlStateValueOff];
    }
    else if( [item action] == @selector(SyncSeries:))
    {
        valid = YES;
        [item setState: SYNCSERIES];
    }
    else if( [item action] == @selector(setKeyImage:))
    {
        valid = YES;
        [item setState: [keyImageCheck state]];
    }
    else if( [item action] == @selector(setROITool:) || [item action] == @selector(setDefaultTool:) || [item action] == @selector(setDefaultToolMenu:))
    {
        valid = YES;
        
        NSArray *allKeys = [[DCMView hotKeyDictionary] allKeys];
        
        [item setKeyEquivalentModifierMask: 0];
        [item setKeyEquivalent: @""];
        
        for( NSString *k in allKeys)
        {
            if( [ViewerController getHotKeyEquivalentToTool: [item tag]] >= 0)
            {
                if( [[[DCMView hotKeyDictionary] objectForKey: k] intValue] == [ViewerController getHotKeyEquivalentToTool: [item tag]])
                {
                    [item setKeyEquivalentModifierMask: 0];
                    [item setKeyEquivalent: k];
                }
            }
        }
        
        if( [item tag] == [imageView currentTool]) [item setState:NSControlStateValueOn];
        else [item setState:NSControlStateValueOff];
        
        if( [item image] == nil)
        {
            [item setImage: [self imageForROI: [item tag]]];
            [[item image] setSize:ToolsMenuIconSize];
        }
    }
    else if( [item action] == @selector(ApplyCLUT:))
    {
        valid = YES;
        
        if( [[item title] isEqualToString: curCLUTMenu]) [item setState:NSControlStateValueOn];
        else [item setState:NSControlStateValueOff];
    }
    else if( [item action] == @selector(ApplyConv:))
    {
        valid = YES;
        
        if( [[item title] isEqualToString: curConvMenu]) [item setState:NSControlStateValueOn];
        else [item setState:NSControlStateValueOff];
    }
    else if( [item action] == @selector(ApplyOpacity:))
    {
        valid = YES;
        
        if( [[item title] isEqualToString: curOpacityMenu]) [item setState:NSControlStateValueOn];
        else [item setState:NSControlStateValueOff];
    }
    else if( [item action] == @selector(ApplyWLWW:))
    {
        valid = YES;
        
        NSString	*str = nil;
        
        @try
        {
            str = [[item title] substringFromIndex: 4];
        }
        
        @catch (NSException * e) {}
        
        if( [str isEqualToString: curWLWWMenu] || [[item title] isEqualToString: curWLWWMenu]) [item setState:NSControlStateValueOn];
        else [item setState:NSControlStateValueOff];
    }
    else if( [item action] == @selector(increaseFontSize:) || [item action] == @selector(decreaseFontSize:))
    {
        valid = [DCMView labelFontSizeMenuItemIsEnabled: item];
    }
    else valid = YES;
    
    return valid;
}

- (IBAction) resetWindowsState:(id)sender
{
    NSArray *studiesArray = [ViewerController getDisplayedStudies];
    
    for( id loopItem in studiesArray)
    {
        [loopItem setValue: nil forKey:@"windowsState"];
    }
}

- (IBAction) loadWindowsState:(id) sender
{
    BOOL c = [[NSUserDefaults standardUserDefaults] boolForKey:@"automaticWorkspaceLoad"];
    
    if( c == NO) [[NSUserDefaults standardUserDefaults] setBool: YES forKey:@"automaticWorkspaceLoad"];
    
    [[BrowserController currentBrowser] databaseOpenStudy: [[imageView seriesObj] valueForKey:@"study"]];
    
    if( c == NO) [[NSUserDefaults standardUserDefaults] setBool: c forKey:@"automaticWorkspaceLoad"];
}

- (IBAction) saveWindowsState:(id) sender
{
    [ViewerController saveWindowsState];
}

- (IBAction) saveWindowsStateAsDICOMSR:(id) sender
{
    self.windowsStateName = [NSUserDefaults formatDateTime: [NSDate date]];
    
    if( saveWindowsStateWindow)
        [self.window beginSheet:saveWindowsStateWindow completionHandler:nil];
    else
        [ViewerController saveWindowsStateWithDICOMSR: YES name: nil];
}

- (IBAction) endSaveWindowsStateAsDICOMSR:(id) sender
{
    [saveWindowsStateWindow orderOut:sender];
    
    [saveWindowsStateWindow.sheetParent endSheet:saveWindowsStateWindow returnCode: [sender tag]];
    
    if( [sender tag])
        [ViewerController saveWindowsStateWithDICOMSR: YES name: self.windowsStateName];
}

+ (void) saveWindowsState
{
    [ViewerController saveWindowsStateWithDICOMSR: [[NSUserDefaults standardUserDefaults] boolForKey: @"alwaysArchiveWindowsStateAsDICOMSR"] name: nil];
}

+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name
{
    NSArray				*displayedViewers = [ViewerController getDisplayed2DViewers];
    NSMutableArray		*state = [NSMutableArray array];
    
    int indexImage;
    
    if( name.length == 0)
        name = [NSUserDefaults formatDateTime: [NSDate date]];
    
    @try
    {
        for( ViewerController *win in displayedViewers)
        {
            DCMView *view = [win imageView];
            //            if ([[view curDCM] generated])
            //                continue;
            
            NSMutableDictionary	*dict = [NSMutableDictionary dictionary];
            
            if( [win studyInstanceUID] && [[view seriesObj] valueForKey:@"seriesInstanceUID"])
            {
                NSRect	r = [[win window] frame];
                [dict setObject: name forKey: @"name"];
                [dict setObject: [NSString stringWithFormat: @"%f %f %f %f", r.origin.x, r.origin.y, r.size.width, r.size.height]  forKey:@"window position"];
                [dict setObject: NSStringFromRect( [AppController usefullRectForScreen: win.window.screen]) forKey: @"screen"];
                [dict setObject: @([[NSScreen screens] indexOfObject: win.window.screen]) forKey:@"screenIndex"];
                [dict setObject: @([view rows]) forKey:@"rows"];
                [dict setObject: @([view columns]) forKey:@"columns"];
                
                if( [view flippedData]) indexImage = [win getNumberOfImages] -1 -[[[win seriesView] firstView] curImage];
                else indexImage = [[[win seriesView] firstView] curImage];
                
                [dict setObject: @(indexImage) forKey:@"index"];
                
                if( [[view curDCM] SUVConverted] == NO)
                {
                    [dict setObject: @([view.curDCM storedWindowLevelForCalibratedLevel:view.curWL]) forKey:@"wl"];
                    [dict setObject: @([view curWW]) forKey:@"ww"];
                }
                else
                {
                    [dict setObject: @([view.curDCM storedWindowLevelForCalibratedLevel:view.curWL / [win factorPET2SUV]]) forKey:@"wl"];
                    [dict setObject: @([view curWW] / [win factorPET2SUV]) forKey:@"ww"];
                }
                [dict setObject: @([view scaleValue]) forKey:@"scale"];
                [dict setObject: @([view origin].x) forKey:@"x"];
                [dict setObject: @([view origin].y) forKey:@"y"];
                [dict setObject: @([view rotation]) forKey:@"rotation"];
                [dict setObject: @([view xFlipped]) forKey:@"xFlipped"];
                [dict setObject: @([view yFlipped]) forKey:@"yFlipped"];
                
                [dict setObject: [win studyInstanceUID] forKey:@"studyInstanceUID"];
                
                NSMutableArray *seriesUIDs = [NSMutableArray array];
                for( int x = 0 ; x <  [win maxMovieIndex] ; x++)
                {
                    DCMPix *dcmPix = [[win pixList: x] objectAtIndex: 0];
                    
                    if( dcmPix.seriesObj)
                        [seriesUIDs addObject: [dcmPix.seriesObj valueForKey:@"seriesInstanceUID"]];
                }
                
                BOOL allSeriesUIDidentical = YES;
                
                for( NSString *uid in seriesUIDs)
                {
                    if( [uid isEqualToString: [seriesUIDs lastObject]] == NO) allSeriesUIDidentical = NO;
                }
                
                if( allSeriesUIDidentical == NO)
                    [dict setObject: [seriesUIDs componentsJoinedByString:@"\\**\\"] forKey:@"seriesInstanceUID"];
                else if( seriesUIDs.count)
                    [dict setObject: [seriesUIDs lastObject] forKey:@"seriesInstanceUID"];
                
                // A series imported from a raster file (TIFF, JPEG...) has no
                // DICOM Series Instance UID: seriesInstanceUID above finds it
                // again, and the restore skips an absent seriesDICOMUID (#1020).
                NSString *seriesDICOMUID = [win.currentSeries valueForKey:@"seriesDICOMUID"];
                if( seriesDICOMUID)
                    [dict setObject: seriesDICOMUID forKey:@"seriesDICOMUID"];
                
                if( [win maxMovieIndex] > 1)
                    [dict setObject: @YES forKey:@"4DData"];
                else
                    [dict setObject: @NO forKey:@"4DData"];
                
                if( [[NSUserDefaults standardUserDefaults] objectForKey:@"LastWindowsTilingRowsColumns"])
                    [dict setObject: [[NSUserDefaults standardUserDefaults] objectForKey:@"LastWindowsTilingRowsColumns"] forKey:@"LastWindowsTilingRowsColumns"];
                
                [dict setObject: [[NSUserDefaults standardUserDefaults] objectForKey:@"COPYSETTINGS"] forKey:@"propagateSettings"];
                
                if( [DCMView syncro] == syncroLOC)
                    [dict setObject: @YES forKey:@"syncSettings"];
                else if( [DCMView syncro] == syncroOFF)
                    [dict setObject: @NO forKey:@"syncSettings"];
                
                if( SyncButtonBehaviorIsBetweenStudies)
                {
                    [dict setObject: @YES forKey:@"SyncButtonBehaviorIsBetweenStudies"];
                    [dict setObject: @(SYNCSERIES) forKey: @"SYNCSERIES"];
                    [dict setObject: @(view.syncRelativeDiff) forKey:@"syncRelativeDiff"];
                }
                else
                {
                    [dict setObject: @NO forKey:@"SyncButtonBehaviorIsBetweenStudies"];
                    [dict setObject: @(SYNCSERIES) forKey: @"SYNCSERIES"];
                }
                
                [dict setObject: [NSDate date] forKey:@"date"];
                
                [state addObject: dict];
            }
        }
        
        if( [displayedViewers count] != [state count]) return;	//We will save the states ONLY if we can save the state of ALL DISPLAYED windows !:!:!:
        
        //	NSString	*tmp = [NSString stringWithFormat:@"/tmp/windowsState"];
        //	[[NSFileManager defaultManager] removeItemAtPath: tmp error:NULL];
        //	[state writeToFile: tmp atomically: YES];
        
        NSData *windowsState = [NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        
        NSMutableArray	*studiesArray = [NSMutableArray array];
        
        for( ViewerController *win in displayedViewers)
        {
            DCMView *view = [win imageView];
            if ([[view curDCM] generated])
                continue;
            
            if( [[view seriesObj] valueForKey:@"seriesInstanceUID"])
            {
                if( [studiesArray containsObject: [[view seriesObj] valueForKey:@"study"]] == NO)
                    [studiesArray addObject: [[view seriesObj] valueForKey:@"study"]];
            }
        }
        
        for( DicomStudy *study in studiesArray)
        {
            [study setValue: windowsState forKey:@"windowsState"];
            
            if( DICOMSR)
                [study archiveWindowsStateAsDICOMSR];
        }
    }
    @catch (NSException *e) {
        N2LogExceptionWithStackTrace( e);
    }
}

// Volume lengths have one object per UUID. Slice lists contain aliases only;
// the retained source image remains the persistence anchor after a reslice.
- (NSMutableDictionary *)volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create
{
    if( movieIndex < 0 || movieIndex >= MAX4D) return nil;
    NSMutableDictionary *states = objc_getAssociatedObject(self, &HorosVolumeLengthStateKey);
    if( states == nil && create)
    {
        states = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &HorosVolumeLengthStateKey, states, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSMutableDictionary *state = states[@(movieIndex)];
    if( state == nil && create)
    {
        state = [NSMutableDictionary dictionaryWithObject:[NSMutableDictionary dictionary] forKey:@"anchors"];
        id anchor = [fileList[movieIndex] firstObject];
        if( [anchor isKindOfClass:[DicomImage class]]) state[@"anchor"] = anchor;
        states[@(movieIndex)] = state;
    }
    return state;
}

- (NSArray<HorosVolumeLengthROI *> *)volumeLengthROIsForMovieIndex:(long)movieIndex
{
    if( movieIndex < 0 || movieIndex >= MAX4D) return @[];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for( NSArray *slice in roiList[movieIndex])
        for( ROI *roi in slice)
            if( [roi isKindOfClass:[HorosVolumeLengthROI class]])
            {
                HorosVolumeLengthROI *length = (HorosVolumeLengthROI *)roi;
                if( length.volumeIdentifier.length && [seen containsObject:length.volumeIdentifier] == NO)
                {
                    [seen addObject:length.volumeIdentifier];
                    [result addObject:length];
                }
            }
    return result;
}

- (void)registerVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex anchor:(DicomImage *)anchor
{
    if( roi.volumeIdentifier.length == 0) return;
    NSMutableDictionary *state = [self volumeLengthStateForMovieIndex:movieIndex create:YES];
    NSMutableDictionary *anchors = state[@"anchors"];
    if( anchor == nil) anchor = anchors[roi.volumeIdentifier] ?: state[@"anchor"];
    if( anchor)
    {
        anchors[roi.volumeIdentifier] = anchor;
        NSMutableDictionary *payload = [[roi.volumeLength mutableCopy] autorelease];
        if( anchor.sopInstanceUID.length) payload[@"storageSOPInstanceUID"] = anchor.sopInstanceUID;
        payload[@"storageFrame"] = anchor.frameID ?: @0;
        roi.volumeLength = payload;
    }
}

- (void)attachVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex
{
    if( movieIndex < 0 || movieIndex >= MAX4D || roi.volumeIdentifier.length == 0) return;
    roi.isAliased = YES;
    for( NSMutableArray *slice in roiList[movieIndex])
    {
        for( NSInteger i = (NSInteger)slice.count - 1; i >= 0; i--)
        {
            ROI *existing = slice[i];
            if( [existing isKindOfClass:[HorosVolumeLengthROI class]] &&
               [[(HorosVolumeLengthROI *)existing volumeIdentifier] isEqualToString:roi.volumeIdentifier])
                [slice removeObjectAtIndex:i];
        }
        [slice addObject:roi];
    }
}

- (void)addVolumeLengthROI:(HorosVolumeLengthROI *)roi
{
    [self addVolumeLengthROI:roi movieIndex:curMovieIndex];
}

- (void)addVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex
{
    if( movieIndex < 0 || movieIndex >= maxMovieIndex || roi.volumeIdentifier.length == 0) return;
    [self registerVolumeLengthROI:roi movieIndex:movieIndex anchor:nil];
    [self attachVolumeLengthROI:roi movieIndex:movieIndex];
    if( movieIndex == curMovieIndex) roi.curView = imageView;
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixAddROINotification object:self
                                                      userInfo:@{@"ROI":roi, @"sliceNumber":@(movieIndex == curMovieIndex ? [imageView curImage] : 0)}];
    [imageView setNeedsDisplay:YES];
}

- (void)restoreVolumeLengthSnapshot:(NSDictionary *)snapshot movieIndex:(long)movieIndex
{
    if( movieIndex < 0 || movieIndex >= MAX4D) return;
    NSMutableDictionary *state = [self volumeLengthStateForMovieIndex:movieIndex create:YES];
    [state removeAllObjects];
    [state addEntriesFromDictionary:snapshot[@"state"]];
    state[@"anchors"] = [[state[@"anchors"] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    for( NSMutableArray *slice in roiList[movieIndex])
        for( NSInteger i = (NSInteger)slice.count - 1; i >= 0; i--)
            if( [slice[i] isKindOfClass:[HorosVolumeLengthROI class]]) [slice removeObjectAtIndex:i];
    for( HorosVolumeLengthROI *roi in snapshot[@"rois"])
    {
        [self registerVolumeLengthROI:roi movieIndex:movieIndex anchor:nil];
        [self attachVolumeLengthROI:roi movieIndex:movieIndex];
    }
}

- (void)saveVolumeLengthROIs:(long)movieIndex writtenPaths:(NSMutableArray *)paths anchorPaths:(NSDictionary *)anchorPaths
{
    NSDictionary *anchors = [self volumeLengthStateForMovieIndex:movieIndex create:NO][@"anchors"];
    if( anchors.count == 0) return;
    NSArray *current = [self volumeLengthROIsForMovieIndex:movieIndex];
    NSMutableSet *saved = [NSMutableSet set];
    for( DicomImage *anchor in anchors.allValues)
    {
        if( [saved containsObject:anchor.objectID]) continue;
        [saved addObject:anchor.objectID];
        DicomDatabase *database = [DicomDatabase databaseForContext:anchor.managedObjectContext];
        DicomStudy *study = anchor.series.study;
        NSString *path = anchorPaths[anchor.objectID] ?: [study roiPathForImage:anchor];
        NSArray *previous = HorosVolumeLengthReadArchive(path);
        NSMutableArray *combined = [NSMutableArray array];
        for( ROI *roi in previous)
        {
            DicomImage *owner = [roi isKindOfClass:[HorosVolumeLengthROI class]] ? anchors[[(HorosVolumeLengthROI *)roi volumeIdentifier]] : nil;
            if( owner == nil || [owner.objectID isEqual:anchor.objectID] == NO) [combined addObject:roi];
        }
        for( HorosVolumeLengthROI *roi in current)
            if( [((DicomImage *)anchors[roi.volumeIdentifier]).objectID isEqual:anchor.objectID]) [combined addObject:roi];
        if( [ViewerController areROIsArraysIdentical:previous with:combined]) continue;
        if( path.length == 0 || [[NSFileManager defaultManager] fileExistsAtPath:path] == NO)
            path = [database uniquePathForNewDataFileWithExtension:@"dcm"];
        SRAnnotation *annotation = [[[SRAnnotation alloc] initWithROIs:combined path:path forImage:anchor] autorelease];
        NSString *seriesUID = [[study roiSRSeries] valueForKey:@"seriesDICOMUID"];
        if( seriesUID.length) [annotation setSeriesInstanceUID:seriesUID];
        if( [annotation writeToFileAtPath:path])
        {
            if( [paths containsObject:path] == NO) [paths addObject:path];
        }
        else
            NSLog(@"Volume Length: could not save the ROI archive.");
    }
}

- (void) executeUndo:(NSMutableArray*) u
{
    if( [u count])
    {
        [imageView cancelLengthPlacement];
        [imageView stopROIEditing];
        
        if( [[[u lastObject] objectForKey: @"type"] isEqualToString:@"roi"])
        {
            NSMutableArray	*rois = [[u lastObject] objectForKey: @"rois"];
            
            int i, x, z;
            
            for( i = 0; i < maxMovieIndex; i++)
            {
                for( x = 0; x < [roiList[ i] count] ; x++)
                {
                    for( z = 0; z < [[roiList[ i] objectAtIndex: x] count]; z++)
                        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object:[[roiList[ i] objectAtIndex: x] objectAtIndex: z] userInfo: nil];
                    
                    [[roiList[ i] objectAtIndex: x] removeAllObjects];
                }
            }
            
            for( i = 0; i < maxMovieIndex; i++)
            {
                NSArray *r = [rois objectAtIndex: i];
                
                for( x = 0; x < [roiList[ i] count] ; x++)
                {
                    [[roiList[ i] objectAtIndex: x] addObjectsFromArray: [r objectAtIndex: x]];
                    
                    for( ROI *r in [roiList[ i] objectAtIndex: x])
                    {
                        [imageView roiSet: r];
                        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIChangeNotification object: r userInfo: nil];
                    }
                }
            }
            
            for( int movie = 0; movie < maxMovieIndex; movie++)
                for( HorosVolumeLengthROI *roi in [self volumeLengthROIsForMovieIndex:movie])
                {
                    [self registerVolumeLengthROI:roi movieIndex:movie anchor:nil];
                    [self attachVolumeLengthROI:roi movieIndex:movie];
                }
            [imageView setIndex: [imageView curImage]];
            
            NSLog( @"roi undo");
            
            [u removeLastObject];
        }
    }
}

- (IBAction) redo:(id) sender
{
    if( [redoQueue count])
    {
        [undoQueue addObject: [self prepareObjectForUndo: [[redoQueue lastObject] objectForKey:@"type"]]];
        
        [self executeUndo: redoQueue];
    }
    else NSBeep();
}

- (IBAction) undo:(id) sender
{
    if( [undoQueue count])
    {
        [redoQueue addObject: [self prepareObjectForUndo: [[undoQueue lastObject] objectForKey:@"type"]]];
        
        [self executeUndo: undoQueue];
    }
    else NSBeep();
}

- (id) prepareObjectForUndo:(NSString*) string
{
    @try {
        if( [string isEqualToString: @"roi"])
        {
            NSMutableArray	*rois = [NSMutableArray array];
            
            for( int i = 0; i < maxMovieIndex; i++)
            {
                NSMutableArray *array = [NSMutableArray array];
                NSMutableDictionary *volumeCopies = [NSMutableDictionary dictionary];
                for( NSArray *ar in roiList[ i])
                {
                    NSMutableArray *a = [NSMutableArray array];
                    for( ROI *r in ar)
                    {
                        NSString *identifier = [r isKindOfClass:[HorosVolumeLengthROI class]] ? [(HorosVolumeLengthROI *)r volumeIdentifier] : nil;
                        ROI *copy = identifier.length ? volumeCopies[identifier] : nil;
                        if( copy == nil)
                        {
                            copy = [[r copy] autorelease];
                            if( identifier.length) volumeCopies[identifier] = copy;
                        }
                        [a addObject:copy];
                    }
                    [array addObject:a];
                }
                [rois addObject: array];
            }
            
            return [NSDictionary dictionaryWithObjectsAndKeys: string, @"type", rois, @"rois", nil];
        }
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    return nil;
}

- (void) removeLastItemFromUndoQueue
{
    if( [undoQueue count])
        [undoQueue removeLastObject];
}

- (void) addToUndoQueue:(NSString*) string
{
    if( [[NSUserDefaults standardUserDefaults] integerForKey: @"UndoQueueSize"] <= 0)
        return;
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"DontUseUndoQueueForROIs"] == NO)
        [undoQueue addObject: [self prepareObjectForUndo: string]];
    
    if( [undoQueue count] > [[NSUserDefaults standardUserDefaults] integerForKey: @"UndoQueueSize"])
    {
        [undoQueue removeObjectAtIndex: 0];
    }
}

#pragma mark-
#pragma mark 1. window and workplace

+ (void) correctGangtryTilt: (ViewerController*) viewerController
{
#ifdef OSIRIX_LIGHT
    N2LogStackTrace( @"Function NOT available in light version");
#else
    DCMPix *curPix;
    BOOL OK = YES;
    
    NSArray *pixList = [viewerController pixList];
    
    curPix = [pixList objectAtIndex: pixList.count/2];   //pixList.count/2];
    
    long imageSize, size;
    
    
    id w = [viewerController startWaitProgressWindow: NSLocalizedString( @"Gantry Tilt Correction", nil) :pixList.count];
    
    @try
    {
        imageSize = [curPix pwidth] * [curPix pheight];
        size = sizeof(float) * [pixList count]/2 * imageSize;
        
        double orientation[ 9];
        double origin[ 3];
        double matrix[ 12];
        
        [curPix orientationDouble: orientation];
        origin[ 0] = [curPix originX]; origin[ 1] = [curPix originY]; origin[ 2] = [curPix originZ];
        
        for( DCMPix *p in pixList)
        {
            double o[ 9];
            double xyz[ 3];
            
            [p orientationDouble: o];
            xyz[ 0] = [p originX]; xyz[ 1] = [p originY]; xyz[ 2] = [p originZ];
            
            BOOL equal = YES;
            for( int i = 0 ; i < 6 ; i++)
            {
                if( o[ i] != orientation[ i])
                    equal = NO;
            }
            
            if( equal == NO)
            {
                HorosRunInformationalAlertPanel( NSLocalizedString(@"Error!", nil), NSLocalizedString(@"These slices have not the same orientation. Gantry Tilt Correction cannot be applied to this dataset.", nil), NSLocalizedString(@"OK", nil), 0L, 0L);
                OK = NO;
                break;
            }
        }
        
        if( OK)
        {
            for( DCMPix *p in pixList)
            {
                if( p != curPix)
                {
                    double o[ 9];
                    double xyz[ 3];
                    
                    [p orientationDouble: o];
                    xyz[ 0] = [p originX]; xyz[ 1] = [p originY]; xyz[ 2] = [p originZ];
                    
                    double vectorModel[ 9], vectorSensor[ 9];
                    
                    [p orientationDouble: vectorSensor];
                    [curPix orientationDouble: vectorModel];
                    
                    double length;
                    
                    // --
                    matrix[ 9] = xyz[ 0] - origin[ 0];
                    matrix[ 10] = xyz[ 1] - origin[ 1];
                    matrix[ 11] = xyz[ 2] - origin[ 2];
                    // --
                    
                    matrix[ 0] = vectorSensor[ 0] * vectorModel[ 0] + vectorSensor[ 1] * vectorModel[ 1] + vectorSensor[ 2] * vectorModel[ 2];
                    matrix[ 1] = vectorSensor[ 0] * vectorModel[ 3] + vectorSensor[ 1] * vectorModel[ 4] + vectorSensor[ 2] * vectorModel[ 5];
                    matrix[ 2] = vectorSensor[ 0] * vectorModel[ 6] + vectorSensor[ 1] * vectorModel[ 7] + vectorSensor[ 2] * vectorModel[ 8];
                    
                    length = sqrt(matrix[0]*matrix[0] + matrix[1]*matrix[1] + matrix[2]*matrix[2]);
                    
                    matrix[0] = matrix[ 0] / length;
                    matrix[1] = matrix[ 1] / length;
                    matrix[2] = matrix[ 2] / length;
                    
                    // --
                    
                    matrix[ 3] = vectorSensor[ 3] * vectorModel[ 0] + vectorSensor[ 4] * vectorModel[ 1] + vectorSensor[ 5] * vectorModel[ 2];
                    matrix[ 4] = vectorSensor[ 3] * vectorModel[ 3] + vectorSensor[ 4] * vectorModel[ 4] + vectorSensor[ 5] * vectorModel[ 5];
                    matrix[ 5] = vectorSensor[ 3] * vectorModel[ 6] + vectorSensor[ 4] * vectorModel[ 7] + vectorSensor[ 5] * vectorModel[ 8];
                    
                    length = sqrt(matrix[3]*matrix[3] + matrix[4]*matrix[4] + matrix[5]*matrix[5]);
                    
                    matrix[3] = matrix[ 3] / length;
                    matrix[4] = matrix[ 4] / length;
                    matrix[5] = matrix[ 5] / length;
                    
                    // --
                    
                    matrix[6] = matrix[1]*matrix[5] - matrix[2]*matrix[4];
                    matrix[7] = matrix[2]*matrix[3] - matrix[0]*matrix[5];
                    matrix[8] = matrix[0]*matrix[4] - matrix[1]*matrix[3];
                    
                    length = sqrt(matrix[6]*matrix[6] + matrix[7]*matrix[7] + matrix[8]*matrix[8]);
                    
                    matrix[6] = matrix[ 6] / length;
                    matrix[7] = matrix[ 7] / length;
                    matrix[8] = matrix[ 8] / length;
                    
                    long size;
                    
                    float *resultBuff = [ITKTransform reorient2Dimage: matrix firstObject: curPix firstObjectOriginal: p length: &size];
                    if( resultBuff)
                    {
                        memcpy( [p fImage] , resultBuff, size);
                        free( resultBuff);
                    }
                    else
                    {
                        HorosRunInformationalAlertPanel( NSLocalizedString( @"Error!", nil), NSLocalizedString( @"Not Enough Memory", nil), NSLocalizedString(@"OK", nil), 0L, 0L);
                        break;
                    }
                    
                    // Project the 3D point on the plane : dot product of normal plane vector (vectorModel) and distance between point and plane origin (matrix9,10,11)
                    double distance = matrix[ 9] * vectorModel[ 6] + matrix[ 10] * vectorModel[ 7] + matrix[ 11] * vectorModel[ 8];
                    double outputOrigin[ 3];
                    
                    outputOrigin[0] = origin[ 0] + distance*vectorModel[ 6];
                    outputOrigin[1] = origin[ 1] + distance*vectorModel[ 7];
                    outputOrigin[2] = origin[ 2] + distance*vectorModel[ 8];
                    
                    [p setOriginDouble: outputOrigin];
                }
                
                [viewerController waitIncrementBy:w :1];
            }
            
            for( DCMPix *p in pixList)
                [p setSliceInterval: 0];
        }
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    
    [viewerController endWaitWindow: w];
    
    // We modified the view: OsiriX please update the display!
    [viewerController needsDisplayUpdate];
#endif
}

- (void) refreshMenus
{
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixUpdateWLWWMenuNotification object: curWLWWMenu userInfo: nil];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateCLUTMenuNotification object: curCLUTMenu userInfo: nil];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateConvolutionMenuNotification object: curConvMenu userInfo: nil];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateOpacityMenuNotification object: curOpacityMenu userInfo: nil];
    
    [clutPopup setTitle:curCLUTMenu];
    [convPopup setTitle:curConvMenu];
    [wlwwPopup setTitle:curWLWWMenu];
    [OpacityPopup setTitle:curOpacityMenu];
}

- (void) refresh
{
    float   iwl, iww;
    [imageView getWLWW:&iwl :&iww];
    [imageView setWLWW:iwl :iww];
}

- (BOOL) isPostprocessed
{
    return postprocessed;
}

- (void) setPostprocessed:(BOOL) v
{
    postprocessed = v;
    [[NavigatorWindowController navigatorWindowController] initView];
    [self updateNavigator];
}

- (BOOL) postprocessed
{
    return postprocessed;
}

- (void) replaceSeriesWith:(NSMutableArray*)newPixList :(NSMutableArray*)newDcmList :(NSData*) newData
{
    [self changeImageData:newPixList :newDcmList :newData :NO];
    [self setPostprocessed: YES];
    
    [self computeInterval];
    [self setWindowTitle:self];
    [imageView setIndex: [newPixList count]/2];
    [imageView sendSyncMessage:0];
    [self adjustSlider];
}

static volatile int numberOfThreadsForRelisce = 0;

- (BOOL) waitForAProcessor
{
    int processors =  [[NSProcessInfo processInfo] processorCount];
    
    [processorsLock lockWhenCondition: 1];
    BOOL result = numberOfThreadsForRelisce >= processors;
    if( result == NO)
    {
        numberOfThreadsForRelisce++;
        if( numberOfThreadsForRelisce >= processors)
        {
            [processorsLock unlockWithCondition: 0];
        }
        else
        {
            [processorsLock unlockWithCondition: 1];
        }
    }
    else
    {
        NSLog( @"waitForAProcessor ?? We should not be here...");
        [processorsLock unlockWithCondition: 0];
    }
    
    return result;
}

- (void) resliceThread:(NSDictionary*) dict
{
    NSAutoreleasePool	*pool = [[NSAutoreleasePool alloc] init];
    
    int i = [[dict valueForKey:@"i"] intValue];
    int sign = [[dict valueForKey:@"sign"] intValue];
    int newX = [[dict valueForKey:@"newX"] intValue];
    int newY = [[dict valueForKey:@"newY"] intValue];
    BOOL square = [[dict valueForKey:@"square"] boolValue];
    DCMPix *curPix = [dict valueForKey:@"curPix"];
    register float *restrict curPixFImage = [[dict valueForKey:@"curPix"] fImage];
    int rowBytes = [[dict valueForKey:@"rowBytes"] intValue] / 4;
    int j = [[dict valueForKey:@"curMovieIndex"] intValue];
    
    register float *restrict srcPtr, *restrict dstPtr, *restrict mainSrcPtr;
    int count = [pixList[ j] count];
    
    count /= 2;
    count *= 2;
    
    if( sign > 0)
        mainSrcPtr = [[pixList[ j] objectAtIndex: count-1] fImage];
    else
        mainSrcPtr = [[pixList[ j] objectAtIndex: 0] fImage];
    
    int sliceSize = [[pixList[ j] objectAtIndex: 0] pwidth] * [[pixList[ j] objectAtIndex: 0] pheight];
    
    mainSrcPtr += i;
    
    if( sign > 0)
    {
        int x = count;
        while (x-->0)
        {
            srcPtr = mainSrcPtr - x*sliceSize;
            dstPtr = curPixFImage + x * newX;
            
            int y = newX;
            while (y-->0)
            {
                *dstPtr++ = *srcPtr;
                srcPtr += rowBytes;
            }
        }
    }
    else
    {
        int x = count;
        while (x-->0)
        {
            srcPtr = mainSrcPtr + x*sliceSize;
            dstPtr = curPixFImage + x * newX;
            
            int y = newX;
            while (y-->0)
            {
                *dstPtr++ = *srcPtr;
                srcPtr += rowBytes;
            }
        }
    }
    
    if( square)
    {
        vImage_Buffer	srcVimage, dstVimage;
        
        srcVimage.data = [curPix fImage];
        srcVimage.height =  [pixList[ j] count];
        srcVimage.width = newX;
        srcVimage.rowBytes = newX*4;
        
        dstVimage.data = [curPix fImage];
        dstVimage.height =  newY;
        dstVimage.width = newX;
        dstVimage.rowBytes = newX*4;
        
        vImageScale_PlanarF( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
    }
    
    [processorsLock lock];
    if( numberOfThreadsForRelisce >= 0) numberOfThreadsForRelisce--;
    [processorsLock unlockWithCondition: 1];
    
    [pool release];
}

-(BOOL) processReslice:(long) directionm :(BOOL) newViewer
{
    DCMPix				*firstPix = [pixList[ curMovieIndex] objectAtIndex: 0];
    DCMPix				*lastPix = nil;
    long				i, newTotal;
    unsigned char		*emptyData;
    long				imageSize, size, y, newX, newY;
    double				orientation[ 9], newXSpace, newYSpace, origin[ 3], sign;
    BOOL				square = NO;
    BOOL				succeed = YES;
    
    NSString			*previousCLUT = [curCLUTMenu retain];
    NSString			*previousOpacity = [curOpacityMenu retain];
    
    if( [pixList[ curMovieIndex] count] < 100 && firstPix.pheight <= 256 && firstPix.pwidth <= 256)
        square = YES;
    
    // Get Values
    if( directionm == 0)		// X - RESLICE
    {
        newTotal = [firstPix pheight];
        
        newX = [firstPix pwidth];
        
        if( square)
        {
            newXSpace = [firstPix pixelSpacingX];
            newYSpace = [firstPix pixelSpacingX];
            
            newY = ([pixList[ curMovieIndex] count] * fabs( [firstPix sliceInterval])) / [firstPix pixelSpacingX];
            
            int even = newY / 2;
            even *= 2;
            
            if( even <= [pixList[ curMovieIndex] count])
            {
                NSLog( @"---- newY < [pixList[ curMovieIndex] count]");
                square = NO;
            }
        }
        
        if( square == NO)
        {
            newXSpace = [firstPix pixelSpacingX];
            newYSpace = fabs( [firstPix sliceInterval]);
            newY = [pixList[ curMovieIndex] count];
        }
    }
    else
    {
        newTotal = [firstPix pwidth];				// Y - RESLICE
        
        newX = [firstPix pheight];
        
        if( square)
        {
            newXSpace = [firstPix pixelSpacingY];
            newYSpace = [firstPix pixelSpacingY];
            
            newY = ([pixList[ curMovieIndex] count]  * fabs( [firstPix sliceInterval])) / [firstPix pixelSpacingY];
            
            int even = newY / 2;
            even *= 2;
            
            if( even <= [pixList[ curMovieIndex] count])
            {
                NSLog( @"---- newY < [pixList[ curMovieIndex] count]");
                square = NO;
            }
        }
        
        
        if( square == NO)
        {
            newY = [pixList[ curMovieIndex] count];
            
            newXSpace = [firstPix pixelSpacingY];
            newYSpace = fabs( [firstPix sliceInterval]);
        }
    }
    
    newX /= 2;
    newX *= 2;
    
    newY /= 2;
    newY *= 2;
    
    i =  [pixList[ curMovieIndex] count];
    i /= 2;
    i *= 2;
    i--;
    lastPix = [pixList[ curMovieIndex] objectAtIndex: i];
    
    sign = 1.0;
    
    imageSize = sizeof(float) * newX * newY;
    size = newTotal * imageSize;
    
    NSMutableArray *xPix = [NSMutableArray array];
    NSMutableArray *xFiles = [NSMutableArray array];
    NSMutableArray *xData = [NSMutableArray array];
    
    succeed = YES;
    
    for( int j = 0 ; j < maxMovieIndex && succeed == YES; j++)
    {
        firstPix = [pixList[ j] objectAtIndex: 0];
        
        // CREATE A NEW SERIES WITH ALL IMAGES !
        emptyData = malloc( size);
        if( emptyData)
        {
            NSMutableArray	*newPixList = [NSMutableArray array];
            NSMutableArray	*newDcmList = [NSMutableArray array];
            
            NSData	*newData = [NSData dataWithBytesNoCopy:emptyData length: size freeWhenDone:YES];
            
            NSLog( @"reslice start");
            
#ifdef VIMAGEYRESLICE
            if( directionm)
            {
                vImage_Buffer src;
                vImage_Buffer dst;
                
                src.height = firstPix.pheight * newY;
                src.width = firstPix.pwidth;
                src.rowBytes = src.width*4;
                src.data = firstPix.fImage;
                
                dst.width = firstPix.pheight * newY;
                dst.height = firstPix.pwidth;
                dst.rowBytes = dst.width*4;
                dst.data = emptyData;
                
                vImageRotate90_PlanarF( &src, &dst, kRotate270DegreesClockwise, 0, 0);
            }
#endif
            
            // Display a waiting window
            id waitWindow = [self startWaitProgressWindow: NSLocalizedString( @"Reslicing...", nil) :newTotal];
            
            for( i = 0 ; i < newTotal; i ++)
            {
                [newPixList addObject: [[[pixList[ j] objectAtIndex: 0] copy] autorelease]];
                
                // SUV
                [[newPixList lastObject] setDisplaySUVValue: [firstPix displaySUVValue]];
                [[newPixList lastObject] setSUVConverted: [firstPix SUVConverted]];
                [[newPixList lastObject] setFactorPET2SUV: [firstPix factorPET2SUV]];
                [[newPixList lastObject] setRadiopharmaceuticalStartTime: [firstPix radiopharmaceuticalStartTime]];
                [[newPixList lastObject] setPatientsWeight: [firstPix patientsWeight]];
                [[newPixList lastObject] setRadionuclideTotalDose: [firstPix radionuclideTotalDose]];
                [[newPixList lastObject] setRadionuclideTotalDoseCorrected: [firstPix radionuclideTotalDoseCorrected]];
                [[newPixList lastObject] setAcquisitionTime: [firstPix acquisitionTime]];
                [[newPixList lastObject] setDecayCorrection: [firstPix decayCorrection]];
                [[newPixList lastObject] setDecayFactor: [firstPix decayFactor]];
                [[newPixList lastObject] setUnits: [firstPix units]];
                
                [[newPixList lastObject] setPwidth: newX];
                //				[[newPixList lastObject] setRowBytes: newX*sizeof(float)];
                [[newPixList lastObject] setPheight: newY];
                
                [[newPixList lastObject] setfImage: (float*) (emptyData + imageSize * ([newPixList count] - 1))];
                [[newPixList lastObject] setTot: newTotal];
                [[newPixList lastObject] setFrameNo: (long)[newPixList count]-1];
                [[newPixList lastObject] setID: (long)[newPixList count]-1];
                
                if( [fileList[ j] count])
                {
                    [newDcmList addObject: [fileList[ j] objectAtIndex: 0]];
                }
                
                if( directionm == 0)		// X - RESLICE
                {
                    DCMPix	*curPix = [newPixList lastObject];
                    
                    int count = [pixList[ j] count];
                    int pwidth = [[pixList[ j] objectAtIndex: 0] pwidth];
                    
                    count /= 2;
                    count *= 2;
                    
                    if( sign > 0)
                    {
                        for( y = 0; y < count; y++)
                        {
                            memcpy(	[curPix fImage] + (count-y-1) * newX,
                                   [[pixList[ j] objectAtIndex: y] fImage] + i * pwidth,
                                   newX * sizeof( float));
                        }
                    }
                    else
                    {
                        for( y = 0; y < count; y++)
                        {
                            memcpy(	[curPix fImage] + y * newX,
                                   [[pixList[ j] objectAtIndex: y] fImage] + i * pwidth,
                                   newX * sizeof( float));
                        }
                    }
                    
                    if( square)
                    {
                        vImage_Buffer	srcVimage, dstVimage;
                        
                        srcVimage.data = [curPix fImage];
                        srcVimage.height =  count;
                        srcVimage.width = newX;
                        srcVimage.rowBytes = newX*4;
                        
                        dstVimage.data = [curPix fImage];
                        dstVimage.height =  newY;
                        dstVimage.width = newX;
                        dstVimage.rowBytes = newX*4;
                        
                        vImageScale_PlanarF( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
                    }
                    
                    [lastPix orientationDouble: orientation];
                    
                    orientation[ 3] = orientation[ 6] * -sign;
                    orientation[ 4] = orientation[ 7] * -sign;
                    orientation[ 5] = orientation[ 8] * -sign;
                    
                    [curPix setOrientationDouble: orientation];	// Normal vector is recomputed in this procedure
                    
                    [curPix setPixelSpacingX: newXSpace];
                    [curPix setPixelSpacingY: newYSpace];
                    
                    [curPix setPixelRatio:  newYSpace / newXSpace];
                    
                    [curPix orientationDouble: orientation];
                    
                    [lastPix convertPixDoubleX:0 pixY: i toDICOMCoords: origin pixelCenter: NO];
                    
                    [curPix setOriginDouble: origin];
                    
                    [curPix computeSliceLocation];
                    
                    [curPix setSliceThickness: [firstPix pixelSpacingY]];
                    [curPix setSliceInterval: 0];
                    
                }
                else											// Y - RESLICE
                {
                    DCMPix	*curPix = [newPixList lastObject];
                    long	rowBytes = [firstPix pwidth]*4;
                    
#ifndef VIMAGEYRESLICE
                    [self waitForAProcessor];
                    
                    NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys: @(i), @"i", @(sign), @"sign", @(newX), @"newX", @(newY), @"newY", @(square), @"square", [NSNumber numberWithInt: rowBytes], @"rowBytes", curPix, @"curPix", @(j), @"curMovieIndex", nil];
                    
                    [NSThread detachNewThreadSelector: @selector(resliceThread:) toTarget:self withObject: d];
#endif
                    [lastPix orientationDouble: orientation];
                    
                    // Y Vector = Normal Vector
                    orientation[ 0] = orientation[ 3];
                    orientation[ 1] = orientation[ 4];
                    orientation[ 2] = orientation[ 5];
                    
                    orientation[ 3] = orientation[ 6] * -sign;
                    orientation[ 4] = orientation[ 7] * -sign;
                    orientation[ 5] = orientation[ 8] * -sign;
                    
                    [curPix setOrientationDouble: orientation];	// Normal vector is recomputed in this procedure
                    
                    [curPix setPixelSpacingX: newXSpace];
                    [curPix setPixelSpacingY: newYSpace];
                    
                    [curPix setPixelRatio:  newYSpace / newXSpace];
                    
                    [curPix orientationDouble: orientation];
                    
                    [lastPix convertPixDoubleX:i pixY:0 toDICOMCoords: origin pixelCenter: NO];
                    
                    [curPix setOriginDouble: origin];
                    
                    [curPix computeSliceLocation];
                    
                    [curPix setSliceThickness: [firstPix pixelSpacingX]];
                    [curPix setSliceInterval: 0];
                }
                
                [self waitIncrementBy:waitWindow :1];
            }
            
            BOOL finished = NO;
            do
            {
                [processorsLock lockWhenCondition: 1];
                if( numberOfThreadsForRelisce <= 0)
                {
                    finished = YES;
                    [processorsLock unlockWithCondition: 1];
                }
                else [processorsLock unlockWithCondition: 0];
            }
            while( finished == NO);
            
            NSLog( @"reslice end");
            
            [xData addObject: newData];
            [xFiles addObject: newDcmList];
            [xPix addObject: newPixList];
            
            postprocessed = YES;
            
            // Close the waiting window
            [self endWaitWindow: waitWindow];
        }
        else succeed = NO;
    }
    
    if( succeed)
    {
        int mx = maxMovieIndex;
        NSMutableArray *volumeSnapshots = [NSMutableArray arrayWithCapacity:mx];
        for( int movie = 0; movie < mx; movie++)
        {
            NSArray *lengths = [self volumeLengthROIsForMovieIndex:movie];
            if( newViewer) lengths = [[[NSArray alloc] initWithArray:lengths copyItems:YES] autorelease];
            NSDictionary *state = [[[self volumeLengthStateForMovieIndex:movie create:YES] copy] autorelease];
            [volumeSnapshots addObject:@{@"rois":lengths, @"state":state}];
        }
        ViewerController *reslicedViewer = self;
        for( int j = 0 ; j < mx; j++)
        {
            if( j == 0)
            {
                if( newViewer)
                {
                    ViewerController	*new2DViewer;
                    
                    // CREATE A SERIES
                    new2DViewer = [self newWindow: [xPix objectAtIndex: j] :[xFiles objectAtIndex: j] :[xData objectAtIndex: j]];
                    reslicedViewer = new2DViewer;
                    [new2DViewer setImageIndex: [[xPix objectAtIndex: j] count] /2];
                    [[new2DViewer window] makeKeyAndOrderFront: self];
                }
                else
                {
                    [self changeImageData: [xPix objectAtIndex: j] :[xFiles objectAtIndex: j] :[xData objectAtIndex: j] :NO];
                }
            }
            else
            {
                [reslicedViewer addMovieSerie: [xPix objectAtIndex: j] :[xFiles objectAtIndex: j] :[xData objectAtIndex: j]];
            }
            [reslicedViewer restoreVolumeLengthSnapshot:volumeSnapshots[j] movieIndex:j];
        }
        
        [reslicedViewer setPostprocessed: YES];
        
        [reslicedViewer computeInterval];
        [reslicedViewer setWindowTitle:self];
        [[reslicedViewer imageView] setIndex: [[xPix objectAtIndex: 0] count]/2];
        [[reslicedViewer imageView] sendSyncMessage:0];
        [reslicedViewer adjustSlider];
        
        [reslicedViewer ApplyCLUTString: previousCLUT];
        [reslicedViewer ApplyOpacityString: previousOpacity];
    }
    
    [previousCLUT release];
    [previousOpacity release];
    
    return succeed;
}

+ (int) orientation:(double*) vectors
{
    int o = 0;
    
    if( fabs( vectors[6]) > fabs(vectors[7]) && fabs( vectors[6]) > fabs(vectors[8]))	o = 0;
    if( fabs( vectors[7]) > fabs(vectors[6]) && fabs( vectors[7]) > fabs(vectors[8]))	o = 1;
    if( fabs( vectors[8]) > fabs(vectors[6]) && fabs( vectors[8]) > fabs(vectors[7]))	o = 2;
    
    return o;
}

- (IBAction) vertFlipDataSet:(id) sender
{
    int y, x;
    
    for( y = 0 ; y < maxMovieIndex; y++)
    {
        DCMPix			*firstObject = [pixList[ y] objectAtIndex: 0];
        float			*volumeDataPtr = [firstObject fImage];
        vImage_Buffer	src, dest;
        
        dest.data = malloc( [firstObject pheight] * [firstObject pwidth] * 4);
        
        if( dest.data)
        {
            for( x = 0; x < [pixList[ y] count]; x++)
            {
                src.height = dest.height = [firstObject pheight];
                src.width = dest.width = [firstObject pwidth];
                src.rowBytes = src.width*4;
                dest.rowBytes = dest.width*4;
                src.data = volumeDataPtr;
                
                vImageVerticalReflect_PlanarF ( &src, &dest, 0);
                
                memcpy( src.data, dest.data, [firstObject pheight] * [firstObject pwidth] * 4);
                volumeDataPtr += [firstObject pheight]*[firstObject pwidth];
            }
            
            free( dest.data);
        }
        else NSLog( @"***** not enough memory : vertFlipDataSet");
    }
    
    for( y = 0 ; y < maxMovieIndex; y++)
    {
        for( x = 0; x < [pixList[ y] count]; x++)
        {
            double	o[ 9], origin[ 3];
            DCMPix	*dcm = [pixList[ y] objectAtIndex: x];
            
            [dcm orientationDouble: o];
            
            o[ 3] *= -1;
            o[ 4] *= -1;
            o[ 5] *= -1;
            
            [dcm setOrientationDouble: o];
            [dcm setSliceInterval: 0];
            
            [dcm convertPixDoubleX: 0 pixY: -[dcm pheight]+1 toDICOMCoords: origin pixelCenter: NO];
            
            [dcm setOriginDouble: origin];
            
            [dcm computeSliceLocation];
        }
    }
    
    [self setPostprocessed: YES];
    
    [self computeInterval];
    [self updateImage: self];
}

- (IBAction) horzFlipDataSet:(id) sender
{
    int y, x;
    
    for( y = 0 ; y < maxMovieIndex; y++)
    {
        DCMPix	*firstObject = [pixList[ y] objectAtIndex: 0];
        float	*volumeDataPtr = [firstObject fImage];
        
        vImage_Buffer src, dest;
        
        src.height = dest.height = [firstObject pheight]*[pixList[ y] count];
        src.width = dest.width = [firstObject pwidth];
        src.rowBytes = dest.rowBytes = src.width*4;
        src.data = dest.data = volumeDataPtr;
        
        vImageHorizontalReflect_PlanarF ( &src, &dest, 0);
    }
    
    for( y = 0 ; y < maxMovieIndex; y++)
    {
        for( x = 0; x < [pixList[ y] count]; x++)
        {
            double	o[ 9];
            DCMPix	*dcm = [pixList[ y] objectAtIndex: x];
            
            [dcm orientationDouble: o];
            
            o[ 0] *= -1;
            o[ 1] *= -1;
            o[ 2] *= -1;
            
            [dcm setOrientationDouble: o];
            [dcm setSliceInterval: 0];
            
            double	origin[3];
            
            [dcm convertPixDoubleX: -[dcm pwidth]+1 pixY: 0 toDICOMCoords: origin pixelCenter: NO];
            [dcm setOriginDouble: origin];
            
            [dcm computeSliceLocation];
        }
    }
    
    [self setPostprocessed: YES];
    
    [self computeInterval];
    [self updateImage: self];
}

- (void) rotateDataSet:(int) constant
{
    int y, x;
    double rot = 0;
    
    switch( constant)
    {
        case kRotate90DegreesClockwise:		rot = 90;		break;
        case kRotate180DegreesClockwise:	rot = 180;		break;
        case kRotate270DegreesClockwise:	rot = 270;		break;
    }
    
    for( y = 0 ; y < maxMovieIndex; y++)
    {
        DCMPix			*firstObject = [pixList[ y] objectAtIndex: 0];
        float			*volumeDataPtr = [firstObject fImage];
        vImage_Buffer	src, dest;
        
        dest.data = malloc( [firstObject pheight] * [firstObject pwidth] * 4);
        
        for( x = 0; x < [pixList[ y] count]; x++)
        {
            src.height = dest.height = [firstObject pheight];
            src.width = dest.width = [firstObject pwidth];
            
            if( constant == kRotate90DegreesClockwise || constant == kRotate270DegreesClockwise)
            {
                dest.height = [firstObject pwidth];
                dest.width = [firstObject pheight];
            }
            
            src.rowBytes = src.width*4;
            dest.rowBytes = dest.width*4;
            src.data = volumeDataPtr;
            
            vImageRotate90_PlanarF ( &src, &dest, constant, 0, 0);
            
            memcpy( src.data, dest.data, [firstObject pheight] * [firstObject pwidth] * 4);
            
            volumeDataPtr += [firstObject pheight]*[firstObject pwidth];
        }
        
        free( dest.data);
    }
    
    for( y = 0 ; y < maxMovieIndex; y++)
    {
        for( x = 0; x < [pixList[ y] count]; x++)
        {
            double	o[ 9];
            DCMPix	*dcm = [pixList[ y] objectAtIndex: x];
            
            if( constant == kRotate90DegreesClockwise || constant == kRotate270DegreesClockwise)
            {
                float x = [dcm pixelSpacingX];
                float y = [dcm pixelSpacingY];
                
                [dcm setPixelSpacingX:  y];
                [dcm setPixelSpacingY:  x];
                
                [dcm setPixelRatio: x/y];
                
                // ***************************
                
                x = [dcm pwidth];
                y = [dcm pheight];
                
                [dcm setPheight: x];
                [dcm setPwidth: y];
                //				[dcm setRowBytes: y*sizeof(float)];
            }
            
            [dcm orientationDouble: o];
            
            // Compute normal vector
            o[6] = o[1]*o[5] - o[2]*o[4];
            o[7] = o[2]*o[3] - o[0]*o[5];
            o[8] = o[0]*o[4] - o[1]*o[3];
            
            XYZ vector, rotationVector;
            
            rotationVector.x = o[ 6];	rotationVector.y = o[ 7];	rotationVector.z = o[ 8];
            
            vector.x = o[ 0];	vector.y = o[ 1];	vector.z = o[ 2];
            vector =  ArbitraryRotate(vector, -rot*deg2rad, rotationVector);
            o[ 0] = vector.x;	o[ 1] = vector.y;	o[ 2] = vector.z;
            
            vector.x = o[ 3];	vector.y = o[ 4];	vector.z = o[ 5];
            vector =  ArbitraryRotate(vector, -rot*deg2rad, rotationVector);
            o[ 3] = vector.x;	o[ 4] = vector.y;	o[ 5] = vector.z;
            
            [dcm setOrientationDouble: o];
            [dcm setSliceInterval: 0];
            
            // Origin
            double		d[ 3];
            double		yy, xx;
            
            switch( constant)
            {
                case kRotate90DegreesClockwise:		yy = 0;						xx = -[dcm pwidth]+1;		break;
                case kRotate180DegreesClockwise:	yy = [dcm pheight]-1;		xx = -[dcm pwidth]+1;		break;
                case kRotate270DegreesClockwise:	yy = 0;						xx = [dcm pwidth]-1;		break;
            }
            
            double	originX, originY, originZ;
            
            originX = [dcm originX];
            originY = [dcm originY];
            originZ = [dcm originZ];
            
            [dcm orientationDouble: o];
            
            d[0] = originX + yy*o[3]*[dcm pixelSpacingY] + xx*o[0]*[dcm pixelSpacingX];
            d[1] = originY + yy*o[4]*[dcm pixelSpacingY] + xx*o[1]*[dcm pixelSpacingX];
            d[2] = originZ + yy*o[5]*[dcm pixelSpacingY] + xx*o[2]*[dcm pixelSpacingX];
            
            [dcm setOriginDouble: d];
            [dcm computeSliceLocation];
        }
    }
    
    [self setPostprocessed: YES];
    
    [self computeInterval];
    [self updateImage: self];
}

- (IBAction) squareDataSet:(id) sender
{
    int y;
    
    for( y = 0 ; y < maxMovieIndex; y++)
    {
        DCMPix	*curPix = [pixList[ y] objectAtIndex: 0];
        
        if( [curPix pixelSpacingX] != [curPix pixelSpacingY])
        {
            if( [curPix pixelSpacingX] < [curPix pixelSpacingY])
            {
                [self resampleDataWithXFactor:1.0 yFactor:[curPix pixelSpacingX] / [curPix pixelSpacingY] zFactor:1.0];
            }
            else
            {
                [self resampleDataWithXFactor:[curPix pixelSpacingY] / [curPix pixelSpacingX] yFactor:1.0 zFactor:1.0];
            }
            
            [self setPostprocessed: YES];
        }
    }
}

- (IBAction) setOrientationTool:(id) sender
{
    short newOrientationTool = [[sender selectedCell] tag];
    
    BOOL volumicData = [self isDataVolumicIn4D: NO];
    
    if( volumicData == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Data Error", nil), NSLocalizedString(@"This tool works only with 3D data series.", nil), nil, nil, nil);
        return;
    }
    
    BOOL executed = [self setOrientation:newOrientationTool];
    if( executed == NO)
        {
            // TODO check/create localizedStrings for first two strings
            // The alert has one button, so the alternate branch never ran; it
            // only pointed at a page about a 64-bit build this already is.
            HorosRunCriticalAlertPanel(@"Error", @"Cannot execute this reslicing.\r\rPlease report this issue in the issue tracker.", NSLocalizedString(@"OK", nil), nil, nil);
        }
}

- (BOOL) setOrientation: (int) newOrientationTool
{
    BOOL succeed = YES;
    
    if( newOrientationTool != currentOrientationTool)
    {
        float previousZooming = [imageView scaleValue] / [[pixList[ curMovieIndex] objectAtIndex: 0] pixelSpacingX];
        
        if( displayOnlyKeyImages)
        {
            [keyImagePopUpButton selectItemAtIndex: 0];
            [self keyImageDisplayButton: self];
        }
        
        [self checkEverythingLoaded];
        [self displayWarningIfGantryTitled];
        [self displayAWarningIfNonTrueVolumicData];
        
        int previousFusion = [popFusion selectedTag];
        int previousFusionActivated = [activatedFusion state];
        NSInteger previousSlabCount = sliderFusion.integerValue;
        
        BOOL volumicData = [self isDataVolumicIn4D: NO];
        
        if( volumicData == NO)
        {
            HorosRunAlertPanel(NSLocalizedString(@"Data Error", nil), NSLocalizedString(@"This tool works only with 3D data series.", nil), nil, nil, nil);
            
            succeed = NO;
            
            return succeed;
        }
        
        //		if( [[pixList[ curMovieIndex] objectAtIndex: 0] isRGB])
        //		{
        //			HorosRunAlertPanel(NSLocalizedString(@"Data Error", nil), NSLocalizedString(@"This tool works only with B/W data series.", nil), nil, nil, nil);
        //			return;
        //		}
        
        // To stop any attempt to reload the data...
        postprocessed = YES;
        
        BOOL newViewer = NO;
        
        [imageView setDrawing: NO];
        
        [imageView stopROIEditingForce: YES];
        [self checkEverythingLoaded];
        
        if( blendingController)
            [self ActivateBlending: nil];
        
        
        NSLog( @"Orientation : current: %d new: %d", currentOrientationTool, newOrientationTool);
        
        switch( currentOrientationTool)
        {
            case 0:
            {
                switch( newOrientationTool)
                {
                    case 0:
                        [imageView setIndex: [pixList[curMovieIndex] count]/2];
                        [imageView sendSyncMessage:0];
                        [self adjustSlider];
                        break;
                        
                    case 1:
                        [self checkEverythingLoaded];
                        succeed = [self processReslice: 0 :newViewer];
                        break;
                        
                    case 2:
                        [self checkEverythingLoaded];
                        succeed = [self processReslice: 1 :newViewer];
                        break;
                }
            }
                break;
                
            case 1:	// coronal
            {
                switch( newOrientationTool)
                {
                    case 0:
                        [self checkEverythingLoaded];
                        succeed = [self processReslice: 0 :newViewer];
                        
                        if( succeed)
                            [self vertFlipDataSet: self];
                        break;
                        
                    case 1:
                        [imageView setIndex: [pixList[curMovieIndex] count]/2];
                        [imageView sendSyncMessage:0];
                        [self adjustSlider];
                        break;
                        
                    case 2:
                        [self checkEverythingLoaded];
                        succeed = [self processReslice: 1 :newViewer];
                        
                        if( succeed)
                            [self rotateDataSet: kRotate90DegreesClockwise];
                        break;
                }
            }
                break;
                
            case 2:	// sagi
            {
                switch( newOrientationTool)
                {
                    case 0:
                        [self checkEverythingLoaded];
                        succeed = [self processReslice: 0 :newViewer];
                        
                        if( succeed)
                        {
                            [self rotateDataSet: kRotate90DegreesClockwise];
                            [self horzFlipDataSet: self];
                        }
                        break;
                        
                    case 1:
                        [self checkEverythingLoaded];
                        succeed = [self processReslice: 1 :newViewer];
                        
                        if( succeed)
                        {
                            [self rotateDataSet: kRotate90DegreesClockwise];
                            [self horzFlipDataSet: self];
                        }
                        break;
                        
                    case 2:
                        [imageView setIndex: [pixList[curMovieIndex] count]/2];
                        [imageView sendSyncMessage:0];
                        [self adjustSlider];
                        break;
                }
            }
                break;
        }
        
        if( succeed == NO)
        {
            // Was titled "32-bit" and advised upgrading to OsiriX 64-bit: false
            // on this 64-bit arm64 product, and it named another application.
            HorosRunCriticalAlertPanel(NSLocalizedString(@"Not enough memory", nil), NSLocalizedString(@"Cannot execute this reslicing.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        }
        else
        {
            currentOrientationTool = newOrientationTool;
        }
        
        [self setPostprocessed: YES];
        
        if( newViewer == NO)
            [orientationMatrix selectCellWithTag: currentOrientationTool];
        
        float   iwl, iww;
        [imageView getWLWW:&iwl :&iww];
        [imageView setWLWW:iwl :iww];
        
        if( previousFusion != 0)
        {
            [self checkEverythingLoaded];
            [self computeInterval];
            if( previousFusionActivated == NSControlStateValueOn)
            {
                NSInteger maximum = MIN((NSInteger)sliderFusion.maxValue, (NSInteger)[pixList[curMovieIndex] count]);
                [sliderFusion setIntegerValue:MAX(2, MIN(previousSlabCount, maximum))];
                [stacksFusion setIntegerValue:sliderFusion.integerValue];
                [self setFusionMode: maximum >= 2 ? previousFusion : 0];
            }
            [popFusion selectItemWithTag:previousFusion];
        }
        
        [imageView setScaleValue: previousZooming * [[pixList[ curMovieIndex] objectAtIndex: 0] pixelSpacingX]];
        [imageView scaleToFit];
        [imageView setDrawing: YES];
        
        [self propagateSettings];
        
        [self updateImage: self];
        
        [imageView sendSyncMessage:0];
        [self adjustSlider];
    }
    return succeed;
}

//- (void)setOrientationToolFrom2DMPR:(id)sender
//{
//	WaitRendering *wait = [[WaitRendering alloc] init: NSLocalizedString(@"Processing...", nil)];
//	[wait showWindow:self];
//	[orientationMatrix selectCellWithTag:[[sender selectedCell] tag]];
//	[self setOrientationTool:orientationMatrix];
//	[self checkEverythingLoaded];
//	[self performSelector:@selector(MPR2DViewer:) withObject:self afterDelay:0.05];
//	[wait close];
//	[wait autorelease];
//}

- (void)contextualDictionaryPath:(NSString *)newContextualDictionaryPath /* deprecated */ {
}

- (NSString *)contextualDictionaryPath /* deprecated */ {
    return @"default";
}

- (void) computeContextualMenu
{
    NSLog(@"2D Viewer Contextual Menu - Generate");
    NSMenu* menu = [[self contextualMenu] copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixPopulatedContextualMenuNotification object:menu
                                                      userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                self, [ViewerController className], NULL]];
    [imageView setMenu:[menu autorelease]];
}

- (void)computeContextualMenuForROI:(ROI*)roi
{
    NSLog(@"2D Viewer Contextual Menu - Generate for ROI: %@", roi);
    NSMenu* menu = [[self contextualMenuForROI:roi] copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixPopulatedContextualMenuNotification object:menu
                                                      userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                self, [ViewerController className],
                                                                roi, [ROI className], NULL]];
    [imageView setMenu:[menu autorelease]];
}

-(NSMenu*)contextualMenuForROI:(ROI*)roi
{
    NSMenu* menu = [[[NSMenu alloc] init] autorelease];
    NSMenuItem* temp;
    
    temp = [[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"ROI: %@", [roi name]] action:NULL keyEquivalent:@""] autorelease];
    [menu addItem:temp];
    
    if( roi.locked == NO)
    {
        [menu addItem:[NSMenuItem separatorItem]];
        
        temp = [[[NSMenuItem alloc] initWithTitle:@"Remove" action:@selector(roiContextualMenuActionRemove:) keyEquivalent:@""] autorelease];
        [temp setRepresentedObject:roi];
        [temp setTarget:self];
        [menu addItem:temp];
        
        if( roi.type == tMesure && roi.points.count >= 2)
        {
            temp = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Generate Perpendicular, Parallel and Midpoint", nil)
                                               action:@selector(generateGeometryFromSelectedLine:)
                                        keyEquivalent:@""] autorelease];
            [temp setRepresentedObject:roi];
            [temp setTarget:self];
            [menu addItem:temp];
        }
        if( roi.type == t2DPoint)
        {
            temp = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Measure Between Slices (Projection vs 3D)", nil)
                                               action:@selector(measureBetweenSelectedSlices:)
                                        keyEquivalent:@""] autorelease];
            [temp setRepresentedObject:roi];
            [temp setTarget:self];
            [menu addItem:temp];
        }
    }
    
    return menu;
}

- (IBAction) generateGeometryFromSelectedLine:(id) sender
{
    ROI *source = nil;
    if( [sender isKindOfClass: [NSMenuItem class]] && [[sender representedObject] isKindOfClass: [ROI class]])
        source = [sender representedObject];
    if( source == nil)
    {
        for( ROI *roi in [self selectedROIs])
        {
            if( roi.type == tMesure && roi.points.count >= 2)
            {
                source = roi;
                break;
            }
        }
    }
    if( source == nil || source.type != tMesure || source.points.count < 2 || source.locked)
        return;
    
    HorosROILineConstruction *geometry = [HorosROILineGeometry constructionFromLineA: [source pointAtIndex: 0]
                                                                                  b: [source pointAtIndex: 1]
                                                                           spacingX: source.pixelSpacingX
                                                                           spacingY: source.pixelSpacingY];
    if( geometry == nil)
        return;
    
    [self addToUndoQueue: @"roi"];
    
    NSTimeInterval groupID = source.groupID > 0 ? source.groupID : [NSDate timeIntervalSinceReferenceDate];
    source.groupID = groupID;
    
    ROI *parallel = [self newROI: tMesure];
    [parallel addPoint: geometry.parallelA];
    [parallel addPoint: geometry.parallelB];
    [parallel setName: NSLocalizedString(@"Parallel", nil)];
    [parallel setThickness: source.thickness];
    [parallel setOpacity: source.opacity];
    [parallel setColor: source.rgbcolor];
    [parallel setGroupID: groupID];
    
    ROI *perpendicular = [self newROI: tMesure];
    [perpendicular addPoint: geometry.perpendicularA];
    [perpendicular addPoint: geometry.perpendicularB];
    [perpendicular setName: NSLocalizedString(@"Perpendicular", nil)];
    [perpendicular setThickness: source.thickness];
    [perpendicular setOpacity: source.opacity];
    [perpendicular setColor: source.rgbcolor];
    [perpendicular setGroupID: groupID];
    
    ROI *midpoint = [self newROI: t2DPoint];
    [midpoint setROIRect: NSMakeRect(geometry.midpoint.x, geometry.midpoint.y, 0, 0)];
    [midpoint setName: NSLocalizedString(@"Midpoint", nil)];
    [midpoint setThickness: source.thickness];
    [midpoint setOpacity: source.opacity];
    [midpoint setColor: source.rgbcolor];
    [midpoint setGroupID: groupID];
    
    NSMutableArray *list = [roiList[curMovieIndex] objectAtIndex: [imageView curImage]];
    [list addObject: parallel];
    [list addObject: perpendicular];
    [list addObject: midpoint];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIChangeNotification object: parallel userInfo: nil];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIChangeNotification object: perpendicular userInfo: nil];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIChangeNotification object: midpoint userInfo: nil];
    [imageView setNeedsDisplay: YES];
}

- (NSArray *)horosInterslicePointRecords
{
    NSMutableArray *records = [NSMutableArray array];
    NSMutableArray *viewers = [NSMutableArray arrayWithObject: self];
    if( self.blendingController && self.blendingController != self)
        [viewers addObject: self.blendingController];
    else if( self.blendedWindow && self.blendedWindow != self)
        [viewers addObject: self.blendedWindow];
    if( self.registeredViewer && self.registeredViewer != self && [viewers indexOfObjectIdenticalTo: self.registeredViewer] == NSNotFound)
        [viewers addObject: self.registeredViewer];

    for( ViewerController *viewer in viewers)
    {
        NSArray *rois = [viewer roiList];
        NSArray *pixs = [viewer pixList];
        NSUInteger count = MIN([rois count], [pixs count]);
        for( NSUInteger i = 0; i < count; i++)
        {
            DCMPix *pix = [pixs objectAtIndex: i];
            for( ROI *roi in [rois objectAtIndex: i])
            {
                if( roi.type != t2DPoint || roi.locked)
                    continue;
                [records addObject: [NSDictionary dictionaryWithObjectsAndKeys:
                                     roi, @"roi", pix, @"pix",
                                     [NSNumber numberWithUnsignedInteger: i], @"slice",
                                     viewer, @"viewer", nil]];
            }
        }
    }
    return records;
}

- (BOOL)horosRecordsOnDistinctSlices:(NSDictionary *)first other:(NSDictionary *)second
{
    if( first == nil || second == nil)
        return NO;
    if( [first objectForKey: @"roi"] == [second objectForKey: @"roi"])
        return NO;
    if( [first objectForKey: @"viewer"] != [second objectForKey: @"viewer"])
        return YES;
    return [[first objectForKey: @"slice"] isEqualToNumber: [second objectForKey: @"slice"]] == NO;
}

- (BOOL)horosPickInterslicePreferred:(ROI *)preferred first:(NSDictionary **)first second:(NSDictionary **)second
{
    NSArray *records = [self horosInterslicePointRecords];
    NSMutableArray *selected = [NSMutableArray array];
    NSDictionary *preferredRecord = nil;
    for( NSDictionary *record in records)
    {
        ROI *roi = [record objectForKey: @"roi"];
        if( preferred && roi == preferred)
            preferredRecord = record;
        long mode = [roi ROImode];
        if( mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing)
            [selected addObject: record];
    }

    NSArray *pool = [selected count] >= 2 ? selected : records;
    if( preferredRecord)
    {
        for( NSDictionary *other in pool)
        {
            if( [self horosRecordsOnDistinctSlices: preferredRecord other: other])
            {
                if( first) *first = preferredRecord;
                if( second) *second = other;
                return YES;
            }
        }
    }

    for( NSUInteger i = 0; i < [pool count]; i++)
    {
        for( NSUInteger j = i + 1; j < [pool count]; j++)
        {
            NSDictionary *a = [pool objectAtIndex: i];
            NSDictionary *b = [pool objectAtIndex: j];
            if( [self horosRecordsOnDistinctSlices: a other: b])
            {
                if( first) *first = a;
                if( second) *second = b;
                return YES;
            }
        }
    }

    if( [selected count] == 1)
    {
        NSDictionary *chosen = [selected objectAtIndex: 0];
        for( NSDictionary *other in records)
        {
            if( [self horosRecordsOnDistinctSlices: chosen other: other])
            {
                if( first) *first = chosen;
                if( second) *second = other;
                return YES;
            }
        }
    }
    return NO;
}

- (HorosROISlicePoint *)horosSlicePointFromRecord:(NSDictionary *)record
{
    ROI *roi = [record objectForKey: @"roi"];
    DCMPix *pix = [record objectForKey: @"pix"];
    float orientation[ 9];
    [pix orientation: orientation];
    NSPoint pixel = roi.rect.origin;
    return [[[HorosROISlicePoint alloc] initWithPixelX: pixel.x
                                                pixelY: pixel.y
                                               originX: pix.originX
                                               originY: pix.originY
                                               originZ: pix.originZ
                                                  rowX: orientation[ 0]
                                                  rowY: orientation[ 1]
                                                  rowZ: orientation[ 2]
                                                  colX: orientation[ 3]
                                                  colY: orientation[ 4]
                                                  colZ: orientation[ 5]
                                               normalX: orientation[ 6]
                                               normalY: orientation[ 7]
                                               normalZ: orientation[ 8]
                                              spacingX: pix.pixelSpacingX
                                              spacingY: pix.pixelSpacingY
                                           pixelCenter: YES] autorelease];
}

- (IBAction) measureBetweenSelectedSlices:(id) sender
{
    ROI *preferred = nil;
    if( [sender isKindOfClass: [NSMenuItem class]] && [[sender representedObject] isKindOfClass: [ROI class]])
        preferred = [sender representedObject];

    NSDictionary *first = nil, *second = nil;
    if( [self horosPickInterslicePreferred: preferred first: &first second: &second] == NO)
        return;

    HorosROISlicePoint *firstPoint = [self horosSlicePointFromRecord: first];
    HorosROISlicePoint *secondPoint = [self horosSlicePointFromRecord: second];
    HorosROIIntersliceMeasure *measure = [HorosROIIntersliceGeometry measureFrom: firstPoint to: secondPoint];
    if( measure == nil)
        return;

    [self addToUndoQueue: @"roi"];

    NSPoint labelAt = [[first objectForKey: @"roi"] rect].origin;
    if( [second objectForKey: @"viewer"] == self &&
       [[second objectForKey: @"slice"] integerValue] == [imageView curImage])
        labelAt = [[second objectForKey: @"roi"] rect].origin;

    ROI *note = [self newROI: tText];
    [note setROIRect: NSMakeRect(labelAt.x + 6, labelAt.y + 6, 0, 0)];
    [note setName: [NSString stringWithFormat: NSLocalizedString(@"%.2f mm projection / %.2f mm 3D (%@)", nil),
                    measure.projectedDistance, measure.distance3D, measure.orientation]];
    [note setComments: measure.summary];

    NSTimeInterval groupID = [NSDate timeIntervalSinceReferenceDate];
    ROI *firstROI = [first objectForKey: @"roi"];
    ROI *secondROI = [second objectForKey: @"roi"];
    if( firstROI.groupID == 0)
        firstROI.groupID = groupID;
    if( secondROI.groupID == 0)
        secondROI.groupID = firstROI.groupID;
    note.groupID = firstROI.groupID;

    NSMutableArray *list = [roiList[curMovieIndex] objectAtIndex: [imageView curImage]];
    [list addObject: note];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIChangeNotification object: note userInfo: nil];
    [imageView setNeedsDisplay: YES];
}

- (void)sendWillFreeVolumeDataNotificationWithVolumeData:(NSData *)freeingVolumeData movieIndex:(NSInteger)movieIndex
{
    if (freeingVolumeData) {
        NSAutoreleasePool *pool;
        pool = [[NSAutoreleasePool alloc] init];
        // this Autorelease pool is here to deal with some sort of race condition when freeing the ViewerController, if the viewercontroler
        // get's retain/autoreleased we get a crash in the main run loop. This is a hack...
        
        [[NSNotificationCenter defaultCenter] postNotification:
         [NSNotification notificationWithName:OsirixViewerControllerWillFreeVolumeDataNotification object:self
                                     userInfo:[NSDictionary dictionaryWithObjectsAndKeys:freeingVolumeData, @"volumeData", [NSNumber numberWithInteger:movieIndex], @"movieIndex", nil]]];
        
        [pool release];
    }
}

- (void)sendDidAllocateVolumeDataNotificationWithVolumeData:(NSData *)allocatingVolumeData movieIndex:(NSInteger)movieIndex
{
    if(allocatingVolumeData) {
        NSAutoreleasePool *pool;
        pool = [[NSAutoreleasePool alloc] init];
        // this Autorelease pool is here to deal with some sort of race condition when freeing the ViewerController, if the viewercontroler
        // get's retain/autoreleased we get a crash in the main run loop. This is a hack...
        
        [[NSNotificationCenter defaultCenter] postNotification:
         [NSNotification notificationWithName:OsirixViewerControllerDidAllocateVolumeDataNotification object:self
                                     userInfo:[NSDictionary dictionaryWithObjectsAndKeys:allocatingVolumeData, @"volumeData", [NSNumber numberWithInteger:movieIndex], @"movieIndex", nil]]];
        
        [pool release];
    }
}

-(void)roiContextualMenuActionRemove:(NSMenuItem*)source
{
    ROI* roi = [source representedObject];
    [roi retain];
    [[[roi curView] curRoiList] removeObject:roi];
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixRemoveROINotification object:roi];
    [roi release];
}

- (void) applyWindowProtocol:(id) sender
{
    [[AppController sharedAppController] closeAllViewers: self];
    
    DicomStudy *s = self.currentStudy;
    NSArray *imageSeries = s.imageSeries;
    
    [imageSeries setValue:nil forKey:@"rotationAngle"];
    [imageSeries setValue:nil forKey:@"scale"];
    [imageSeries setValue:nil forKey:@"windowLevel"];
    [imageSeries setValue:nil forKey:@"windowWidth"];
    [imageSeries setValue:nil forKey:@"xFlipped"];
    [imageSeries setValue:nil forKey:@"yFlipped"];
    [imageSeries setValue:nil forKey:@"xOffset"];
    [imageSeries setValue:nil forKey:@"yOffset"];
    [imageSeries setValue:nil forKey:@"displayStyle"];
    [s setValue:nil forKey:@"windowsState"];
    
    [[BrowserController currentBrowser] databaseOpenStudy: self.currentStudy withProtocol: [sender representedObject]];
}

- (NSMenu*) contextualMenu
{
    // if contextualMenuPath says @"default", recreate the default menu once and again
    // if contextualMenuPath contains a path, create the new contextual menu
    // if contextualMenuPath says @"custom", don't do anything
    
    [contextualMenu release];
    contextualMenu = nil;
    

    /******************* Tools menu ***************************/
    contextualMenu =  [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Tools", nil)];
    
    // ******************* series popup menu *********************
    
    [self buildSeriesPopup];
    [contextualMenu addItem: seriesPopupContextualMenu];
    [contextualMenu addItem: [NSMenuItem separatorItem]];
    
    
    //  *****
    
    NSMenu *submenu =  [[[NSMenu alloc] initWithTitle:NSLocalizedString(@"ROI", nil)] autorelease];
    NSMenuItem *item;
    NSArray *titles = [NSArray arrayWithObjects:NSLocalizedString(@"Contrast", nil), NSLocalizedString(@"Move", nil), NSLocalizedString(@"Magnify", nil), NSLocalizedString(@"Rotate", nil), NSLocalizedString(@"Scroll", nil), nil];
    NSArray *images = [NSArray arrayWithObjects: @"WLWW", @"Move", @"Zoom",  @"Rotate",  @"Stack", @"Length", nil];	// DO NOT LOCALIZE THIS LINE ! -> filenames !
    NSEnumerator *enumerator2 = [images objectEnumerator];
    NSEnumerator *enumerator3 = [[popupRoi itemArray] objectEnumerator];
    NSString *title;
    NSString *image;
    
    NSMenuItem *subItem;
    int i = 0;
    
    [enumerator3 nextObject];	// First item is pop main menu
    while (subItem = [enumerator3 nextObject])
    {
        int tag = [subItem tag];
        if( tag)
        {
            item = [[[NSMenuItem alloc] initWithTitle: [subItem title] action: @selector(setROITool:) keyEquivalent:@""] autorelease];
            [item setTag:tag];
            
            [item setTarget:self];
            [[item image] setSize:ToolsMenuIconSize];
            [submenu addItem:item];
        }
        else [submenu addItem: [NSMenuItem separatorItem]];
    }
    
    for (title in titles)
    {
        image = [enumerator2 nextObject];
        item = [[[NSMenuItem alloc] initWithTitle: title action: @selector(setDefaultTool:) keyEquivalent:@""] autorelease];
        [item setTag:i++];
        [item setTarget:self];
        [item setImage:[NSImage imageNamed:image]];
        [[item image] setSize:ToolsMenuIconSize];
        [contextualMenu addItem:item];
    }
    
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Patient Crosshair", nil) action:@selector(setDefaultTool:) keyEquivalent:@""] autorelease];
    item.tag = tCross; item.target = self;
    [contextualMenu addItem:item];
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Show Patient Crosshair", nil) action:@selector(togglePatientCrosshair:) keyEquivalent:@""] autorelease];
    item.target = self;
    [contextualMenu addItem:item];

    image = [enumerator2 nextObject];
    item = [[[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"ROI", nil) action: nil keyEquivalent:@""] autorelease];
    [item setTag: -1];
    [item setTarget: self];
    
    
    if( [imageView currentTool] >= tMesure)
        [item setImage: [self imageForROI: [imageView currentTool]]];
    else
        [item setImage: [self imageForROI: tMesure]];
    
    [[item image] setSize:ToolsMenuIconSize];
    
    [contextualMenu addItem:item];
    [[contextualMenu itemAtIndex: contextualMenu.itemArray.count-1] setSubmenu:submenu];
    [contextualMenu addItemWithTitle:NSLocalizedString(@"Generate Perpendicular, Parallel and Midpoint", nil)
                              action:@selector(generateGeometryFromSelectedLine:)
                       keyEquivalent:@""];
    [contextualMenu addItemWithTitle:NSLocalizedString(@"Measure Between Slices (Projection vs 3D)", nil)
                              action:@selector(measureBetweenSelectedSlices:)
                       keyEquivalent:@""];
    [contextualMenu addItem:[NSMenuItem separatorItem]];

    /******************* WW/WL menu items **********************/
    
    NSMenu *menu = [[[[AppController sharedAppController] wlwwMenu] copy] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Window Width & Level", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:menu];
    [contextualMenu addItem:item];
    
    [contextualMenu addItem:[NSMenuItem separatorItem]];
    
    /************* window resize Menu ****************/
    
    submenu =  [[[NSMenu alloc] initWithTitle:@"Resize window"] autorelease];
    
    NSArray *resizeWindowArray = [NSArray arrayWithObjects:@"25%", @"50%", @"100%", @"200%", @"300%", @"iPod Video", nil];
    i = 0;
    for (NSString *titleMenu in resizeWindowArray) {
        int tag = i++;
        item = [[[NSMenuItem alloc] initWithTitle:titleMenu action: @selector(resizeWindow:) keyEquivalent:@""] autorelease];
        [item setTag:tag];
        [item setTarget:imageView];
        [submenu addItem:item];
    }
    
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Resize window", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:submenu];
    [contextualMenu addItem:item];
    
    [contextualMenu addItem:[NSMenuItem separatorItem]];
    [contextualMenu addItemWithTitle:NSLocalizedString(@"No Rescale Size (100%)", nil) action: @selector(actualSize:) keyEquivalent:@""];
    [contextualMenu addItemWithTitle:NSLocalizedString(@"Actual size", nil) action: @selector(realSize:) keyEquivalent:@""];
    [contextualMenu addItemWithTitle:NSLocalizedString(@"Scale To Fit", nil) action: @selector(scaleToFit:) keyEquivalent:@""];
    [contextualMenu addItemWithTitle:NSLocalizedString(@"Mark as Key image", nil) action: @selector(setKeyImage:) keyEquivalent:@""];
    
    // Tiling
    menu = [[[[AppController sharedAppController] imageTilingMenu] copy] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Image Tiling", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:menu];
    [contextualMenu addItem:item];
    
    menu = [[[AppController sharedAppController].windowsTilingMenuRows copy] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Windows Tiling - Rows", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:menu];
    [contextualMenu addItem:item];
    
    menu = [[[AppController sharedAppController].windowsTilingMenuColumns copy] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Windows Tiling - Columns", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:menu];
    [contextualMenu addItem:item];
    
    /********** Protocol submenu ************/
    submenu =  [[[NSMenu alloc] initWithTitle: NSLocalizedString(@"Apply Window Protocol", nil)] autorelease];
    NSString *m = self.modality;
    for (NSDictionary *protocol in [WindowLayoutManager hangingProtocolsForModality:m]) {
        NSString *t = [NSString stringWithFormat: @"%@ - %@", m, [protocol objectForKey: @"Study Description"]];
        
        item = [[[NSMenuItem alloc] initWithTitle: t action: @selector( applyWindowProtocol:) keyEquivalent:@""] autorelease];
        [item setTarget: self];
        [item setRepresentedObject: protocol];
        [submenu addItem:item];
    }
    
    item = [[[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Apply Window Protocol", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:submenu];
    [contextualMenu addItem:item];
    
    /********** Orientation submenu ************/
    
    menu = [[[[AppController sharedAppController] orientationMenu] copy] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Orientation", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:menu];
    [contextualMenu addItem:item];
    
    /*************Export submenu**************/
    menu = [[[[AppController sharedAppController] exportMenu] copy] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Export", nil) action: nil keyEquivalent:@""] autorelease];
    [item setSubmenu:menu];
    [contextualMenu addItem:item];
    
    /*************Workspace submenu**************/
    if ([[AppController sharedAppController] workspaceMenu]) {
        [contextualMenu addItem: [NSMenuItem separatorItem]];
        [contextualMenu addItemWithTitle: NSLocalizedString(@"Save Workspace State", nil) action: @selector(saveWindowsState:) keyEquivalent:@""];
        [contextualMenu addItemWithTitle: NSLocalizedString(@"Save Workspace State as DICOM SR", nil) action: @selector(saveWindowsStateAsDICOMSR:) keyEquivalent:@""];
        NSMenuItem *mi = [[[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Load Workspace State DICOM SR", nil) action: nil keyEquivalent:@""] autorelease];
        [mi setSubmenu: [[[[AppController sharedAppController] workspaceMenu] copy] autorelease]];
        [contextualMenu addItem: mi];
    }
    
    // The SEG command is supplied by the separately integrated #377 category.
    if ([self respondsToSelector:@selector(showSEGSurfaces:)])
    {
        NSMenuItem *segSurfaces = [contextualMenu addItemWithTitle:NSLocalizedString(@"SEG Surfaces...", nil)
            action:@selector(showSEGSurfaces:) keyEquivalent:@""];
        [segSurfaces setTarget:self];
    }

    return contextualMenu;
}

- (void) setWindowTitle:(id) sender
{
    if( windowWillClose) return;
    
    NSString *loading = @"         ";
    
    @synchronized( loadingThread)
    {
        if( loadingThread.isExecuting)
        {
            if( [[loadingThread.threadDictionary objectForKey: @"loadingPercentage"] floatValue] != 1)
            {
                loading = [NSString stringWithFormat:NSLocalizedString(@" - %2.f%%", nil), [[loadingThread.threadDictionary objectForKey: @"loadingPercentage"] floatValue] * 100.];
                [NSTimer cancelPreviousPerformRequestsWithTarget:self selector:@selector(setWindowTitle:) object:nil];
                [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(setWindowTitle:) userInfo:nil repeats:NO];
            }
        }
    }
    
    if( [fileList[ curMovieIndex] count])
    {
        NSManagedObject	*curImage = [fileList[ curMovieIndex] objectAtIndex:0];
        
        if( [[[curImage valueForKey:@"completePath"] lastPathComponent] isEqualToString:@"Empty.tif"])
            [[self window] setTitle: NSLocalizedString( @"No images", nil)];
        else
        {
            NSDate	*bod = [curImage valueForKeyPath:@"series.study.dateOfBirth"];
            NSString *windowTitle;
            NSString *seriesName = [curImage valueForKeyPath:@"series.name"];
            
            if( seriesName == nil)
                seriesName = @"";
            
            if ([[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"] == annotFull)
            {
                if( [curImage valueForKeyPath:@"series.study.dateOfBirth"])
                    windowTitle = [NSString stringWithFormat: @"%@ - %@ (%@) - %@", [curImage valueForKeyPath:@"series.study.name"], [[NSUserDefaults dateFormatter] stringFromDate:bod], [curImage valueForKeyPath:@"series.study.yearOld"], seriesName];
                else
                    windowTitle = [NSString stringWithFormat: @"%@ - %@", [curImage valueForKeyPath:@"series.study.name"], seriesName];
            }
            else windowTitle = [NSString stringWithFormat: @"%@", seriesName];
            
            if( [[[curImage valueForKeyPath:@"series.id"] stringValue] length])
                windowTitle = [windowTitle stringByAppendingFormat: @" (%@)", [[curImage valueForKeyPath:@"series.id"] stringValue]];
            
            DCMPix *p = [pixList[ curMovieIndex] objectAtIndex:0];
            
            if( p.generated && p.generatedName.length)
                windowTitle = [windowTitle stringByAppendingString: [NSString stringWithFormat: @" - %@", p.generatedName]];
            
            if( [[imageView curDCM] SUVConverted])
                windowTitle = [windowTitle stringByAppendingString: NSLocalizedString( @" (SUV Converted)", nil)];
            
            windowTitle = [windowTitle stringByAppendingString: loading];
            
            [[self window] setTitle: windowTitle];
            
            @synchronized( loadingThread)
            {
                if( loadingThread.isExecuting == NO || [[loadingThread.threadDictionary objectForKey: @"loadingPercentage"] floatValue] >= 1)
                    if( [[imageView curDCM] srcFile] && [[NSFileManager defaultManager] fileExistsAtPath: [[imageView curDCM] srcFile]])
                        [[self window] setRepresentedFilename: [[imageView curDCM] srcFile]];
            }
        }
    }
    else [[self window] setTitle: @"Viewer"];
    
    [imageView checkCursor];	// <- To avoid a stupid bug between setTitle and NSTrackingArea.....
}

- (id) startWaitProgressWindow :(NSString*) message :(long) max
{
    Wait *splash = [[Wait alloc] initWithString:message];
    [splash showWindow:self];
    [[splash progress] setMaxValue:max];
    
    return splash;
}

- (void) waitIncrementBy:(id) waitWindow :(long) val
{
    [waitWindow incrementBy:val];
}

- (id) startWaitWindow :(NSString*) message
{
    WaitRendering *splash = [[WaitRendering alloc] init:message];
    [splash showWindow:self];
    
    return splash;
}

- (void) endWaitWindow:(id) waitWindow
{
    [waitWindow close];
    [waitWindow autorelease];
}

-(IBAction) updateImage:(id) sender
{
    for( DCMView *v in [seriesView imageViews])
    {
        [v updateImage];
    }
}

-(void) needsDisplayUpdate
{
    [self updateImage:self];
    
    float   iwl, iww;
    [imageView getWLWW:&iwl :&iww];
    [imageView setWLWW:iwl :iww];
    
    for( int y = 0; y < maxMovieIndex; y++)
    {
        for( int x = 0; x < [pixList[y] count]; x++)
            [[pixList[y] objectAtIndex: x] changeWLWW:iwl :iww];
    }
}

- (void)windowDidLoad
{
    [super windowDidLoad];

    // Keep independently tiled viewers in the database full-screen Space, and out
    // of one of their own: this window's full screen is fullScreenMenu:.
    [HorosFullScreenWindowSupport declineNativeFullScreen: self.window];
    
    [self checkView: subCtrlView :NO];
    
    [[self window] setInitialFirstResponder: imageView];
    
    
//	keyObjectPopupController = [[KeyObjectPopupController alloc]initWithViewerController:self popup:keyImagePopUpButton];
    [keyImagePopUpButton selectItemAtIndex: displayOnlyKeyImages];
    
    seriesView = [[[studyView seriesViews] objectAtIndex:0] retain];
    imageView = [[[seriesView imageViews] objectAtIndex:0] retain];
}

+ (ViewerController *) newWindow:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v frame: (NSRect) frame
{
    ViewerController *win = [[ViewerController alloc] initWithPix:f withFiles:d withVolume:v];
    
    [win showWindowTransition];
    [win startLoadImageThread]; // Start async reading of all images
    
    if( NSIsEmptyRect( frame) == NO)
        [[win window] setFrame: frame display: NO];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOTILING"])
        [[AppController sharedAppController] tileWindows: nil];
    else
        [[AppController sharedAppController] checkAllWindowsAreVisible: nil makeKey: YES];
    
    return win;
}

+ (ViewerController *) newWindow:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v
{
    return [ViewerController newWindow:f :d : v frame: NSMakeRect(0, 0, 0, 0)];
}

- (ViewerController *) newWindow:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v
{
    return [ViewerController newWindow:f :d :v];
}

- (void) tileWindows
{
    [[AppController sharedAppController] tileWindows: nil];
}

- (IBAction) SetWindowsTiling:(NSPopUpButton*) menu
{
    int tag = [menu selectedTag];
    int rows = tag / 10;
    int columns = tag % 10;
    
    columns *= [[[AppController sharedAppController] viewerScreens] count];
    
    int displayedViewersCount = [ViewerController getDisplayed2DViewers].count;
    
    BOOL copyAutoTilingPreference = [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOTILING"];
    
    [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"AUTOTILING"];
    
    if( displayedViewersCount > rows*columns)
    {
        while( [ViewerController getDisplayed2DViewers].count > rows*columns)
        {
            if( [[ViewerController getDisplayed2DViewers] lastObject] != self)
                [[[[ViewerController getDisplayed2DViewers] lastObject] window] close];
            
            else if( [[ViewerController getDisplayed2DViewers] objectAtIndex: 0] != self)
                [[[[ViewerController getDisplayed2DViewers] objectAtIndex: 0] window] close];
        }
    }
    
    if( displayedViewersCount < rows*columns)
    {
        [[BrowserController currentBrowser] displayWaitWindowIfNecessary];
        
        NSMutableArray *seriesArray = [[[self.currentStudy imageSeriesContainingPixels: YES] mutableCopy] autorelease];
        NSUInteger index = [seriesArray indexOfObject: [imageView seriesObj]];
        
        if( index == NSNotFound)
            index = 0;
        
        // Remove series already displayed
        for( ViewerController *v in [ViewerController get2DViewers])
        {
            NSUInteger seriesIndex = [[seriesArray valueForKey: @"objectID"] indexOfObject: v.currentSeries.objectID];
            if( seriesIndex != NSNotFound)
                [seriesArray removeObjectAtIndex: seriesIndex];
        }
        for( int i = displayedViewersCount ; i < rows*columns; i++)
        {
            ViewerController *newViewer = nil;
            if( seriesArray.count > 0)
            {
                index++;
                if( index >= seriesArray.count)
                    index = 0;
                
                newViewer = [[BrowserController currentBrowser] loadSeries: [seriesArray objectAtIndex: index] :nil :YES keyImagesOnly: NO];
                
                [seriesArray removeObjectAtIndex: index];
            }
            else
                newViewer = [[BrowserController currentBrowser] loadSeries: [imageView seriesObj] :nil :YES keyImagesOnly: NO]; //Duplicate existing
            
            [newViewer showCurrentThumbnail: self];
        }
        
        [[BrowserController currentBrowser] closeWaitWindowIfNecessary];
        
        for( int i = 0; i < [[NSScreen screens] count]; i++) [thumbnailsListPanel[ i] setThumbnailsView: nil viewer:nil];
        [[self window] makeKeyAndOrderFront: self];
        [self refreshToolbar];
        [self updateNavigator];
    }
    
    if( delayedTileWindows)
        [NSObject cancelPreviousPerformRequestsWithTarget:[AppController sharedAppController] selector:@selector(tileWindows:) object:nil];
    delayedTileWindows = YES;
    
    [[AppController sharedAppController] performSelector: @selector(tileWindows:) withObject: [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: rows], @"rows", [NSNumber numberWithInt: columns], @"columns", nil] afterDelay: 0.1];
    
    [[NSUserDefaults standardUserDefaults] setBool: copyAutoTilingPreference forKey: @"AUTOTILING"];
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)sender defaultFrame:(NSRect)defaultFrame
{
    NSRect currentFrame = [sender frame];
    NSRect screenRect = [AppController usefullRectForScreen: [sender screen]];
    
    if( NSIsEmptyRect( standardRect)) standardRect = currentFrame;
    
    if (currentFrame.size.height >= screenRect.size.height - 20 && currentFrame.size.width >= screenRect.size.width - 20)
        return standardRect;
    else
        return screenRect;
}

- (void)setWindowFrame:(NSRect)rect showWindow:(BOOL) showWindow animate: (BOOL) animate
{
    NSRect	curRect = [[self window] frame];
    BOOL wasAlreadyVisible = [[self window] isVisible];
    
    //To avoid the use of WindowDidMove function - Magnetic windows
    [OSIWindowController setDontEnterMagneticFunctions: YES];
    
    rect.origin.x =  roundf( rect.origin.x);
    rect.origin.y =  roundf(rect.origin.y);
    rect.size.width =  roundf(rect.size.width);
    rect.size.height =  roundf(rect.size.height);
    
    [self setStandardRect:rect];
    
    BOOL rectIdentical = YES;
    
    float maxdiff = 0, d;
    
    d = fabs( curRect.origin.y - rect.origin.y);	if( d > maxdiff) maxdiff = d;
    d = fabs( curRect.origin.x - rect.origin.x);	if( d > maxdiff) maxdiff = d;
    d = fabs( curRect.size.height - rect.size.height);	if( d > maxdiff) maxdiff = d;
    d = fabs( curRect.size.width - rect.size.width);	if( d > maxdiff) maxdiff = d;
    
    if( fabs( curRect.origin.y - rect.origin.y) >= 1.0) rectIdentical = NO;
    if( fabs( curRect.origin.x - rect.origin.x) >= 1.0) rectIdentical = NO;
    if( fabs( curRect.size.height - rect.size.height) >= 1.0) rectIdentical = NO;
    if( fabs( curRect.size.width - rect.size.width) >= 1.0) rectIdentical = NO;
    
    if( maxdiff < 5) animate = NO;
    
    if( rectIdentical == NO)
    {
        
        if( showWindow == YES && wasAlreadyVisible == YES)
            [[self window] orderFront:self];
        
        if( animate == YES && wasAlreadyVisible == YES)
        {
            [AppController resizeWindowWithAnimation: [self window] newSize: rect];
        }
        else [[self window] setFrame: rect display:NO];
        
        if( showWindow == YES && wasAlreadyVisible == NO)
            [[self window] orderFront:self];
        
        //		if( showWindow && [[NSUserDefaults standardUserDefaults] boolForKey: @"AlwaysScaleToFit"] == NO)
        //		{
        //			if( wasAlreadyVisible)
        //				[imageView setScaleValue: scaleValue * [imageView frame].size.width / previousHeight];
        //		}
    }
    else
    {
        if( NSEqualRects( curRect, rect) == NO)
            [[self window] setFrame: rect display:NO];
        
        if( showWindow) [[self window] orderFront:self];
    }
    
    [OSIWindowController setDontEnterMagneticFunctions: NO];
}

- (void)setWindowFrame:(NSRect)rect showWindow:(BOOL) showWindow
{
    [self setWindowFrame: rect showWindow: showWindow animate: NO];
}

- (void)setWindowFrame:(NSRect)rect
{
    [self setWindowFrame: rect showWindow: YES];
}


-(BOOL) windowWillClose
{
    return windowWillClose;
}

- (BOOL)windowShouldClose:(id)sender
{
    if( [toolbar customizationPaletteIsRunning])
        return NO;
    
    if( [[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagOption)
        return NO;
    
    if( [[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagShift)
    {
        [NSObject cancelPreviousPerformRequestsWithTarget: [AppController sharedAppController] selector:@selector(closeAllViewers:) object:nil];
        [[AppController sharedAppController] performSelector: @selector(closeAllViewers:) withObject:nil afterDelay: 0.1];
        
        return NO;
    }
    
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification
{
    [self cancelOpeningScaleToFit];
    [ViewerController clearFrontMost2DViewerCache];
    
#ifndef OSIRIX_LIGHT
    [[OSIEnvironment sharedEnvironment] removeViewerController:self];
#endif
    
    [self.window makeFirstResponder: nil];
    
    [previewMatrixScrollView setPostsBoundsChangedNotifications: NO];
    [[[splitView subviews] objectAtIndex: 0] setPostsFrameChangedNotifications: NO];
    
    // The series load (#974): this viewer's and the fused one's are asked to
    // stop, then this one waits for its worker, which holds the buffers the
    // viewer releases, and refuses any later start or delivery.
    [self.horosSeriesLoad requestCancel];
    if (blendingController)
        [blendingController.horosSeriesLoad requestCancel];
    [self.horosSeriesLoad close];
    
    [[self window] setAcceptsMouseMovedEvents: NO];
    
    [imageView stopROIEditingForce: YES];
    
    // **************************
    
    if( FullScreenOn == YES) [self fullScreenMenu: self];
    
    if( [subCtrlOnOff state]) [imageView setWLWW: 0 :0];
    
    // Every view of the tiling stops drawing here, not only the first: each
    // shows pixels of the volume that -finalizeSeriesViewing releases below,
    // and a view drawn after that copies it. With a 3D MPR open on the
    // viewer, which closes on OsirixCloseViewerNotification, such a frame
    // follows the close (#1016).
    for( DCMView *v in [seriesView imageViews])
        [v setDrawing: NO];
    [imageView setDrawing: NO];
    
    windowWillClose = YES;
    
    // Viewer.xib binds controls to File's Owner. AppKit's Autounbinder does
    // not retain self; after this extra release its dealloc over-releases.
    [HorosViewerBindingTeardown unbindFileOwnerBindingsOn: self];
    HorosDetachAutounbinder(self);
    [self unbind:@"flagListPODComparatives"];
    self.flagListPODComparatives = nil;
    NSLog(@"ViewerBindingTeardown: File's Owner bindings dropped before close");
    
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    
    
    [highLightedTimer invalidate];
    [highLightedTimer release];
    highLightedTimer = nil;
    
    if( movieTimer)
    {
        [movieTimer invalidate];
        [movieTimer release];
        movieTimer = nil;
    }
    
    if( timer)
    {
        [timer invalidate];
        [timer release];
        timer = nil;
    }
    
    //	if( timeriChat)
    //    {
    //        [timeriChat invalidate];
    //        [timeriChat release];
    //        timeriChat = nil;
    //    }
    
    if(t12BitTimer)
    {
        [t12BitTimer invalidate];
        [t12BitTimer release];
        t12BitTimer = nil;
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixCloseViewerNotification object: self userInfo: nil];
    
    if( SYNCSERIES)
    {
        NSArray		*winList = [NSApp windows];
        long		win = 0;
        
        for( id loopItem in winList)
        {
            if( [[loopItem windowController] isKindOfClass:[ViewerController class]])
            {
                if( self != [loopItem windowController]) win++;
            }
        }
        
        if( win <= 1)
        {
            [self SyncSeries: self];
        }
    }
    
    [toolbarPanel close];
    [toolbarPanel release];
    toolbarPanel = nil;
    
    
    [self finalizeSeriesViewing];
    
    
    [self autorelease];
    
    
    numberOf2DViewer--;
    @synchronized( arrayOf2DViewers)
    {
        [arrayOf2DViewers removeObject: self];
    }
    
    if( numberOf2DViewer == 0)
    {
        [AppController setUSETOOLBARPANEL: NO];
        
        for( int i = 0; i < [[NSScreen screens] count]; i++)
            [[thumbnailsListPanel[ i] window] orderOut:self];
        
        [[WindowLayoutManager sharedWindowLayoutManager] setCurrentHangingProtocolForModality: nil description: nil];
    }
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOTILING"])
    {
        if( delayedTileWindows)
            [NSObject cancelPreviousPerformRequestsWithTarget:[AppController sharedAppController] selector:@selector(tileWindows:) object:nil];
        delayedTileWindows = YES;
        [[AppController sharedAppController] performSelector: @selector(tileWindows:) withObject:nil afterDelay: 0.3];
    }
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
    {
        [previewMatrix renewRows:0 columns:0];
        
        for( int i = 0 ; i < [[NSScreen screens] count]; i++)
            [thumbnailsListPanel[ i] thumbnailsListWillClose: previewMatrixScrollView];
    }
    
    [[NSCursor arrowCursor] set];
}

- (void)windowDidMiniaturize:(NSNotification *)notification
{
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOTILING"])
    {
        [NSApp sendAction: @selector(tileWindows:) to:nil from: self];
    }
    
    if( [AppController USETOOLBARPANEL])
        [[toolbarPanel window] orderOut: self];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
    {
        for( int i = 0; i < [[NSScreen screens] count]; i++)
        {
            if( [thumbnailsListPanel[ i] thumbnailsView] == previewMatrixScrollView)
                [[thumbnailsListPanel[ i] window] orderOut:self];
        }
    }
}

- (void)windowDidDeminiaturize:(NSNotification *)notification
{
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOTILING"])
    {
        [NSApp sendAction: @selector(tileWindows:) to:nil from: self];
    }
    
    if( [AppController USETOOLBARPANEL] && [HorosToolbarPolicy shouldKeepDetachedToolbarVisibleWhenFullScreen: FullScreenOn])
        [[toolbarPanel window] orderFront: self];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
    {
        for( int i = 0; i < [[NSScreen screens] count]; i++)
        {
            if( [thumbnailsListPanel[ i] thumbnailsView] == previewMatrixScrollView)
                [[thumbnailsListPanel[ i] window] orderOut:self];
        }
    }
}

- (void) windowDidResignMain:(NSNotification *)aNotification
{
    [ViewerController clearFrontMost2DViewerCache];
    
    [imageView stopROIEditingForce: YES];
    
    [imageView sendSyncMessage: 0];
    
    [self autoHideMatrix];
    
    if( [AppController USETOOLBARPANEL])
        [toolbarPanel.window orderOut: self];
    
    [imageView setNeedsDisplay: YES];
}

//-(void) windowDidResignKey:(NSNotification *)aNotification
//{
//    [ViewerController clearFrontMost2DViewerCache];
//
//	[imageView stopROIEditingForce: YES];
//
//    [self autoHideMatrix];
//
////	if( FullScreenOn == YES)
////        [self fullScreenMenu: self];
//
//    if( [AppController USETOOLBARPANEL])
//        [toolbarPanel.window orderOut: self];
//
//    [imageView setNeedsDisplay: YES];
//}

- (void)windowDidChangeScreen:(NSNotification *)aNotification
{
    [ViewerController clearFrontMost2DViewerCache];
    
    if( windowWillClose)
        return;
    
    if( [OSIWindowController dontWindowDidChangeScreen])
        return;
    
    [ToolbarPanelController checkForValidToolbar];
    
    [self redrawToolbar];
}

- (void) redrawToolbar
{
    @try {
    
    if( [AppController USETOOLBARPANEL])
    {
        if( [ViewerController isFrontMost2DViewer: self.window] && [HorosToolbarPolicy shouldKeepDetachedToolbarVisibleWhenFullScreen: FullScreenOn])
        {
            if( [toolbarPanel.window.toolbar customizationPaletteIsRunning] == NO)
                [toolbarPanel.window orderBack: self];
        }
        else
            [toolbarPanel.window orderOut: self];
    }
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
    {
        for( int i = 0; i < MIN((NSUInteger)MAXSCREENS, [[NSScreen screens] count]); i++)
        {
            if( [thumbnailsListPanel[ i] thumbnailsView] == previewMatrixScrollView && [[self window] screen] != [[NSScreen screens] objectAtIndex: i])
                [thumbnailsListPanel[ i] setThumbnailsView: nil viewer:nil];
        }
        
        BOOL found = NO;
        for( int i = 0; i < MIN((NSUInteger)MAXSCREENS, [[NSScreen screens] count]); i++)
        {
            if( [[self window] screen] == [[NSScreen screens] objectAtIndex: i])
            {
                [thumbnailsListPanel[ i] setThumbnailsView: previewMatrixScrollView viewer: self];
                found = YES;
            }
            // Other screens own independent thumbnail panels. Do not hide them
            // when this viewer redraws or moves between displays.
        }
        if( found == NO)
            N2LogStackTrace( @"Toolbar NOT found");
    }
    
    if( [AppController USETOOLBARPANEL] == NO)
        [[toolbarPanel window] orderOut:self];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"] == NO || [[NSUserDefaults standardUserDefaults] boolForKey: @"SeriesListVisible"] == NO)
    {
        for( int i = 0; i < MIN((NSUInteger)MAXSCREENS, [[NSScreen screens] count]); i++)
            [[thumbnailsListPanel[ i] window] orderOut:self];
    }
    
    } @finally {
    }
}

- (void) refreshToolbar
{
    [self autoHideMatrix];
    
    [self redrawToolbar];
    
    if( [[self window] isVisible])
    {
        @try
        {
            if( fileList[ curMovieIndex] && [[[[fileList[ curMovieIndex] objectAtIndex: 0] valueForKey:@"completePath"] lastPathComponent] isEqualToString:@"Empty.tif"] == NO)
            {
                if( [imageView curImage] >= 0)
                    (void)[[BrowserController currentBrowser] findAndSelectFile: nil image:[fileList[ curMovieIndex] objectAtIndex:[imageView curImage]] shouldExpand:NO];
            }
        }
        @catch (NSException *e)
        {
            NSLog( @"***** exception in %s: %@", __PRETTY_FUNCTION__, e);
        }
    }
    
    [self SetSyncButtonBehavior: self];
    //	[self refreshMenus];
}

- (void) windowDidBecomeMain:(NSNotification *)aNotification
{
    [ViewerController clearFrontMost2DViewerCache];
    
    if( recursiveCloseWindowsProtected) return;
    
    
    [self refreshToolbar];
    [self updateNavigator];
    [imageView setNeedsDisplay: YES];
    
}

//- (void) windowDidBecomeKey:(NSNotification *)aNotification
//{
//    [ViewerController clearFrontMost2DViewerCache];
//
//	if( recursiveCloseWindowsProtected) return;
//
//    NSDisableScreenUpdates();
//
//	[self refreshToolbar];
//	[self updateNavigator];
//    [imageView setNeedsDisplay: YES];
//
//    NSEnableScreenUpdates();
//}

- (BOOL) is2DViewer
{
    return YES;
}

+ (void)closeAllWindows
{
    if( [NSThread isMainThread] == NO)
    {
        N2LogStackTrace( @"ViewerController closeAllWindows NOT on mainThread");
        return;
    }
    
    if( recursiveCloseWindowsProtected) return;
    recursiveCloseWindowsProtected = YES;
    
    if( delayedTileWindows)
    {
        delayedTileWindows = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:[AppController sharedAppController] selector:@selector(tileWindows:) object:nil];
    }
    
    NSArray *v = [ViewerController getDisplayed2DViewers];
    
    if( [v count])
    {
        if( [[NSUserDefaults standardUserDefaults] boolForKey:@"automaticWorkspaceSave"])
        {
            [ViewerController saveWindowsState];
        }
        
        for (ViewerController* viewer in v)
        {
            if( [viewer FullScreenON])
                [viewer fullScreenMenu: self];
            
            [[viewer window] orderOut: self];
        }
        
        for (ViewerController*  viewer in v)
        {
            if( [viewer windowWillClose] == NO)
            {
                [[viewer window] close];	//performClose: self
            }
        }
    }
    
    if( delayedTileWindows)
    {
        delayedTileWindows = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:[AppController sharedAppController] selector:@selector(tileWindows:) object:nil];
    }
    
    recursiveCloseWindowsProtected = NO;
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"DontResetListPODComparativesIn2DViewer"] == NO)
        [[NSUserDefaults standardUserDefaults] setBool: YES forKey: @"listPODComparativesIn2DViewer"];
    
    [[BrowserController currentBrowser] selectDatabaseOutline];
}

- (void)applicationDidResignActive:(NSNotification *)aNotification
{
    [ViewerController clearFrontMost2DViewerCache];
    
    if( FullScreenOn == YES) [self fullScreenMenu: self];
}

-(IBAction) fullScreenMenu:(id) sender
{
    //	float scaleValue = [imageView scaleValue];
    
    
    [self setUpdateTilingViewsValue: YES];
    [self selectFirstTilingView];
    
    if( FullScreenOn == YES) // we need to go back to non-full screen
    {
        [StartingWindow setContentView: contentView];
        
        [FullScreenWindow setDelegate:nil];
        [FullScreenWindow close];
        [FullScreenWindow release];
        FullScreenWindow = nil;
        
        FullScreenOn = NO;
        
        [HorosToolbarPolicy setStripAboveImage: slider.superview collapsed: NO restoringHeight: previousSliderStripHeight];
        [StartingWindow setFrame: previousFrameRect display: YES];
        
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"NoImageTilingInFullscreen"] && (previousFullscreenColumns != 1 || previousFullscreenRows != 1))
        {
            [imageView setIndex: previousFullscreenCurImage];
            [self setImageRows: previousFullscreenRows columns: previousFullscreenColumns];
            [[self window] makeFirstResponder: [[seriesView imageViews] objectAtIndex: previousFullscreenViewIndex]];
        }
        
        if( previousScaledFit)
            [imageView performSelector: @selector( scaleToFit) withObject: nil afterDelay: 0.01];
        
        [[NSUserDefaults standardUserDefaults] setBool:previousPropagate forKey: @"COPYSETTINGS"];
        
        [previewMatrix sizeToCells];
        
        [self redrawToolbar];
    }
    else // FullScreenOn == false
    {
        unsigned int windowStyle;
        NSRect contentRect;
        
        previousPropagate = [[NSUserDefaults standardUserDefaults] boolForKey: @"COPYSETTINGS"];
        
        if( self.blendingController == nil)
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey: @"COPYSETTINGS"];
        
        previousFullscreenColumns = [imageView columns];
        previousFullscreenRows = [imageView rows];
        int selectedIndex = [imageView curImage];
        previousFullscreenViewIndex = [[seriesView imageViews] indexOfObject: imageView];
        
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"NoImageTilingInFullscreen"] && (previousFullscreenColumns != 1 || previousFullscreenRows != 1))
            [self setImageRows: 1 columns: 1];
        
        previousFullscreenCurImage = [imageView curImage];
        
        [imageView setIndex: selectedIndex];
        
        StartingWindow = [self window];
        windowStyle = NSWindowStyleMaskBorderless;
        // The whole screen: no strip is left for the menu bar or the toolbar panel.
        contentRect = [HorosToolbarPolicy fullscreenContentRectOnScreen: [self.window.screen frame]];
        
        previousScaledFit = imageView.isScaledFit;
        previousFrameRect = StartingWindow.frame;
        [StartingWindow setFrame: contentRect display: NO];
        
        FullScreenWindow = [[NSFullScreenWindow alloc] initWithContentRect:contentRect styleMask: windowStyle backing:NSBackingStoreBuffered defer: NO];
        if(FullScreenWindow != nil)
        {
            [FullScreenWindow setTitle: @"myWindow"];
            [FullScreenWindow setReleasedWhenClosed: NO];
            [FullScreenWindow setLevel: NSScreenSaverWindowLevel - 1];
            [FullScreenWindow setBackgroundColor:[NSColor blackColor]];
            
            contentView = [[self window] contentView];
            [FullScreenWindow setContentView: contentView];
            
            [FullScreenWindow setDelegate:self];
            [FullScreenWindow setWindowController: self];
            
            //          [splitView adjustSubviews];
            //			frame.size.width = previous;
            //			[[[splitView subviews] objectAtIndex: 0] setFrameSize: frame.size];
            
            [FullScreenWindow makeKeyAndOrderFront: self];
            [FullScreenWindow makeFirstResponder: imageView];
            [FullScreenWindow setAcceptsMouseMovedEvents: YES];
            
            if( previousScaledFit)
                [imageView scaleToFit];
            
            FullScreenOn = YES;
            // The detached toolbar is put away while the image has the screen;
            // -redrawToolbar brings it back when fullscreen ends.
            if( [AppController USETOOLBARPANEL])
                [toolbarPanel.window orderOut: self];
            // So is the strip of the image slider: the wheel and the keys still browse.
            previousSliderStripHeight = [HorosToolbarPolicy setStripAboveImage: slider.superview collapsed: YES restoringHeight: previousSliderStripHeight];
        }
        
        [previewMatrix sizeToCells];
    }
    
    [self setUpdateTilingViewsValue : NO];
    
    //	[self selectFirstTilingView];
    //	[imageView setScaleValue: scaleValue];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"AlwaysScaleToFit"])
        [imageView scaleToFit];
    
    [imageView display];
    
}

- (BOOL) FullScreenON { return FullScreenOn;}

-(void) offFullScreen
{
    if( FullScreenOn == YES) [self fullScreenMenu:self];
}


-(void) UpdateConvolutionMenu: (NSNotification*) note
{
    if( windowWillClose)
        return;
    
    if( convolutionPresetsMenu == nil || [note userInfo] != nil)
    {
        //*** Build the menu
        short       i;
        NSArray     *keys;
        NSArray     *sortedKeys;
        
        keys = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"Convolution"] allKeys];
        sortedKeys = [keys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        
        // Popup Menu
        
        [convolutionPresetsMenu release];
        convolutionPresetsMenu = [[NSMenu alloc] init];
        
        [convolutionPresetsMenu addItemWithTitle:NSLocalizedString(@"No Filter", nil) action:nil keyEquivalent:@""];
        [convolutionPresetsMenu addItemWithTitle:NSLocalizedString(@"No Filter", nil) action:@selector (ApplyConv:) keyEquivalent:@""];
        [convolutionPresetsMenu addItem: [NSMenuItem separatorItem]];
        
        for( i = 0; i < [sortedKeys count]; i++)
        {
            [convolutionPresetsMenu addItemWithTitle:[sortedKeys objectAtIndex:i] action:@selector (ApplyConv:) keyEquivalent:@""];
        }
        [convolutionPresetsMenu addItem: [NSMenuItem separatorItem]];
        [convolutionPresetsMenu addItemWithTitle:NSLocalizedString(@"Add a Filter", nil) action:@selector (AddConv:) keyEquivalent:@""];
        [convPopup setMenu: [[convolutionPresetsMenu copy] autorelease]];
        convPopupSet = YES;
    }
    else if( convPopupSet == NO)
    {
        [convPopup setMenu: [[convolutionPresetsMenu copy] autorelease]];
        convPopupSet = YES;
    }
    
    [convPopup setTitle: curConvMenu];
}

-(void) UpdateWLWWMenu: (NSNotification*) note
{
    if( windowWillClose)
        return;
    
    if( wlwwPresetsMenu == nil || [note userInfo] != nil)
    {
        //*** Build the menu
        NSArray     *keys;
        NSArray     *sortedKeys;
        
        // Presets VIEWER Menu
        
        keys = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"WLWW3"] allKeys];
        sortedKeys = [keys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        
        [wlwwPresetsMenu release];
        wlwwPresetsMenu = [[NSMenu alloc] init];
        
        [wlwwPresetsMenu addItemWithTitle: NSLocalizedString(@"Default WL & WW", nil) action:nil keyEquivalent:@""];
        [wlwwPresetsMenu addItemWithTitle: NSLocalizedString(@"Other", nil) action:@selector (ApplyWLWW:) keyEquivalent:@""];
        [wlwwPresetsMenu addItemWithTitle: NSLocalizedString(@"Default WL & WW", nil) action:@selector (ApplyWLWW:) keyEquivalent:@""];
        [wlwwPresetsMenu addItemWithTitle: NSLocalizedString(@"Full dynamic", nil) action:@selector (ApplyWLWW:) keyEquivalent:@""];
        [wlwwPresetsMenu addItem: [NSMenuItem separatorItem]];
        
        for( int i = 0; i < [sortedKeys count]; i++)
        {
            [wlwwPresetsMenu addItemWithTitle:[NSString stringWithFormat:@"%d - %@", i+1, [sortedKeys objectAtIndex:i]] action:@selector (ApplyWLWW:) keyEquivalent:@""];
        }
        [wlwwPresetsMenu addItem: [NSMenuItem separatorItem]];
        [wlwwPresetsMenu addItemWithTitle: NSLocalizedString(@"Add Current WL/WW", nil) action:@selector (AddCurrentWLWW:) keyEquivalent:@""];
        [wlwwPresetsMenu addItemWithTitle: NSLocalizedString(@"Set WL/WW Manually", nil) action:@selector (SetWLWW:) keyEquivalent:@""];
        
        [wlwwPopup setMenu: [[wlwwPresetsMenu copy] autorelease]];
        
        [contextualMenu release];
        contextualMenu = nil;
        [imageView setMenu: nil];	// Will force recomputing, when needed
        wlwwPopupSet = YES;
    }
    else if( wlwwPopupSet == NO)
    {
        [wlwwPopup setMenu: [[wlwwPresetsMenu copy] autorelease]];
        wlwwPopupSet = YES;
    }
    [wlwwPopup setTitle: curWLWWMenu];
}

- (void) AddCurrentWLWW:(id) sender
{
    float cwl, cww;
    
    [imageView getWLWW:&cwl :&cww];
    
    [wl setStringValue: [HorosWindowLevelText stringForValue: cwl]];
    [ww setStringValue: [HorosWindowLevelText stringForValue: cww]];
    
    [newName setStringValue: NSLocalizedString(@"Unnamed", nil)];
    
    [[self window] beginSheet:addWLWWWindow completionHandler:nil];
}

-(IBAction) endNameWLWW:(id) sender
{
    float iwl, iww;
    NSLog(@"endNameWLWW");
    
    // A window may be narrower than one unit. Reading these back as integers
    // rounded the fraction away and then the zero guard turned it into 1, so
    // saving a preset changed the window it was supposed to record.
    iwl = [HorosWindowLevelText valueFromString: [wl stringValue] fallback: 0];
    iww = [HorosWindowLevelText widthFromString: [ww stringValue] fallback: 1];
    
    [addWLWWWindow orderOut:sender];
    
    [addWLWWWindow.sheetParent endSheet:addWLWWWindow returnCode:[sender tag]];
    
    if( [sender tag])   //User clicks OK Button
    {
        NSMutableDictionary *presetsDict = [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"WLWW3"] mutableCopy] autorelease];
        [presetsDict setObject:[NSArray arrayWithObjects:[NSNumber numberWithFloat:iwl], [NSNumber numberWithFloat:iww], nil] forKey:[newName stringValue]];
        [[NSUserDefaults standardUserDefaults] setObject: presetsDict forKey:@"WLWW3"];
        
        if( curWLWWMenu != [newName stringValue])
        {
            [curWLWWMenu release];
            curWLWWMenu = [[newName stringValue] retain];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateWLWWMenuNotification object: curWLWWMenu userInfo: [NSDictionary dictionary]];
        
        [imageView setWLWW: iwl: iww];
    }
}

- (void) renderButton:(id) sender
{
    NSLog( @"render Button");
}

-(void) UpdateOpacityMenu: (NSNotification*) note
{
    if( windowWillClose)
        return;
    
    if( opacityPresetsMenu == nil || [note userInfo] != nil)
    {
        //*** Build the menu
        short       i;
        NSArray     *keys;
        NSArray     *sortedKeys;
        
        // Presets VIEWER Menu
        
        keys = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"OPACITY"] allKeys];
        sortedKeys = [keys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        
        [opacityPresetsMenu release];
        opacityPresetsMenu = [[NSMenu alloc] init];
        
        [opacityPresetsMenu addItemWithTitle:NSLocalizedString(@"Linear Table", nil) action:@selector (ApplyOpacity:) keyEquivalent:@""];
        [opacityPresetsMenu addItemWithTitle:NSLocalizedString(@"Linear Table", nil) action:@selector (ApplyOpacity:) keyEquivalent:@""];
        for( i = 0; i < [sortedKeys count]; i++)
        {
            [opacityPresetsMenu addItemWithTitle:[sortedKeys objectAtIndex:i] action:@selector (ApplyOpacity:) keyEquivalent:@""];
        }
        [opacityPresetsMenu addItem: [NSMenuItem separatorItem]];
        [opacityPresetsMenu addItemWithTitle:NSLocalizedString(@"Add an Opacity Table", nil) action:@selector (AddOpacity:) keyEquivalent:@""];
        
        [OpacityPopup setMenu: [[opacityPresetsMenu copy] autorelease]];
        OpacityPopupSet = YES;
    }
    else if( OpacityPopupSet == NO)
    {
        [OpacityPopup setMenu: [[opacityPresetsMenu copy] autorelease]];
        OpacityPopupSet = YES;
    }
    
    [OpacityPopup setTitle: curOpacityMenu];
}

- (DCMView*) imageView
{
    return imageView;
}

- (NSArray*) imageViews
{
    return [seriesView imageViews];
}

-(NSString*) modality
{
    if( [imageView curImage] < fileList[ curMovieIndex].count)
        return [[fileList[ curMovieIndex] objectAtIndex:[imageView curImage]] valueForKeyPath:@"series.modality"];
    else
        return nil;
}

+ (int) numberOf2DViewer
{
    return numberOf2DViewer;
}

#ifndef OSIRIX_LIGHT
- (IBAction)querySelectedStudy: (id)sender
{
    [[BrowserController currentBrowser] querySelectedStudy: self];
}
#endif

#pragma mark-
#pragma mark 2. window subdivision

#define SERIESPOPUPSIZE 35

- (void) buildSeriesPopup
{
    if( needsToBuildSeriesPopupMenu == NO)
        return;
    
    needsToBuildSeriesPopupMenu = NO;
    
    [seriesPopupMenu.menu removeAllItems];
    
    if( seriesPopupContextualMenu == nil)
        seriesPopupContextualMenu = [[NSMenuItem alloc] initWithTitle: @"Displayed Series" action: nil keyEquivalent: @""];
    
    [seriesPopupContextualMenu setSubmenu: nil];
    
    BOOL hasComparatives = NO, hasComparativesNewerThanMostRecentLoaded = NO;
    
    @try
    {
        DicomDatabase *db = [[BrowserController currentBrowser] database];
        NSPredicate				*predicate;
        long					i, index = 0;
        NSManagedObject			*curImage = [fileList[0] objectAtIndex:0];
        
        DicomStudy *study = [curImage valueForKeyPath:@"series.study"];
        if( study == nil)
            return;
        
        NSMutableArray *viewerSeries = [NSMutableArray array];
        
        for( int i = 0 ; i < maxMovieIndex; i++)
            [viewerSeries addObject: [[fileList[ i] objectAtIndex:0] valueForKey:@"series"]];
        
        // FIND ALL STUDIES of this patient
        NSString *searchString = [study valueForKey:@"patientUID"];
        
        if( [searchString length] == 0 || [searchString isEqualToString:@"0"])
        {
            searchString = [study valueForKey:@"name"];
            predicate = [NSPredicate predicateWithFormat: @"(name == %@)", searchString];
        }
        else predicate = [NSPredicate predicateWithFormat: @"(patientUID BEGINSWITH[cd] %@)", searchString];
        
        NSArray *studiesArray = nil;
        // Use the 'history' array of the browser controller, if available (with the distant studies)
        if( [[[BrowserController currentBrowser] comparativePatientUID] compare: [study patientUID] options: NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch] == NSOrderedSame && [[BrowserController currentBrowser] comparativeStudies] != nil)
            studiesArray = [BrowserController currentBrowser].comparativeStudies;
        else
        {
            if( [[BrowserController currentBrowser] selectThisStudy: study] == NO)
                NSLog( @"---- buildSeriesPopup - history not found");
            
            studiesArray = [db objectsForEntity:db.studyEntity predicate:predicate];
            studiesArray = [studiesArray sortedArrayUsingDescriptors: [NSArray arrayWithObject: [NSSortDescriptor sortDescriptorWithKey: @"date" ascending: NO]]];
        }
        
#ifndef OSIRIX_LIGHT
        if (!retrieveImage) {
            retrieveImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"DownArrowGreyRev" ofType:@"pdf"]];
            retrieveImage.size = NSMakeSize(50,50);
        }
#endif
        
        if ([studiesArray count])
        {
            studiesArray = [NSArray arrayWithArray: studiesArray];
            
            NSArray *displayedSeries = [ViewerController getDisplayedSeries];
            NSMutableArray *seriesArray = [NSMutableArray array];
            
            i = 0;
            for( id s in studiesArray)
            {
#ifndef OSIRIX_LIGHT
                if( [s isKindOfClass: [DCMTKStudyQueryNode class]] && [[s valueForKey: @"studyInstanceUID"] isEqualToString: study.studyInstanceUID]) // For the current study, always take the local images
                    s = study;
                else if ([s isKindOfClass: [DCMTKStudyQueryNode class]]) { // and still, if there are local series, display them!
                    NSArray* local = [db objectsForEntity:db.studyEntity predicate:[NSPredicate predicateWithFormat:@"studyInstanceUID = %@ AND patientID = %@", [s studyInstanceUID], [s patientID]]];
                    if (local.count)
                        s = [local objectAtIndex:0];
                }
#endif
                
                if( [s isKindOfClass: [DicomStudy class]]) //Local Study DicomStudy
                {
                    [seriesArray addObject: [[BrowserController currentBrowser] childrenArray: s]];
                    
                    //if( [s isHidden] == NO)
                    i += [[seriesArray lastObject] count];
                }
#ifndef OSIRIX_LIGHT
                else if( [s isKindOfClass: [DCMTKStudyQueryNode class]]) //Distant Study DCMTKQueryStudyNode
                {
                    [seriesArray addObject: [NSArray array]];
                }
#endif
            }
            
            NSArray *allStudiesArray = studiesArray;
            
#ifndef OSIRIX_LIGHT
            NSMutableArray* tstudiesArray = [NSMutableArray array];
            NSMutableArray* tseriesArray = [NSMutableArray array];
            BOOL iteratedFirstLoaded = NO;
            for (int i = 0; i < studiesArray.count; ++i) {
                id s = [studiesArray objectAtIndex:i];
                NSArray* series = [seriesArray objectAtIndex:i];
                
                BOOL isNonLoadedComp = [s isKindOfClass:[DCMTKQueryNode class]];
                if (!isNonLoadedComp || series.count || self.flagListPODComparatives.boolValue) {
                    [tstudiesArray addObject:s];
                    [tseriesArray addObject:series];
                }
                
                if (isNonLoadedComp) {
                    hasComparatives = YES;
                    if (!iteratedFirstLoaded)
                        hasComparativesNewerThanMostRecentLoaded = YES;
                } else
                    iteratedFirstLoaded = YES;
            }
            studiesArray = tstudiesArray;
            seriesArray = tseriesArray;
#endif
            
            for( id curStudy in studiesArray)
            {
                NSMenuItem *cell = [[[NSMenuItem alloc] initWithTitle: @"" action: @selector( seriesPopupSelect:) keyEquivalent: @""] autorelease];
                [cell setTarget: self];
                [seriesPopupMenu.menu addItem: cell];
                
                NSUInteger curStudyIndexAll = [allStudiesArray indexOfObject: curStudy];
                NSUInteger curStudyIndex = [studiesArray indexOfObject: curStudy];
                
                [cell setRepresentedObject:[O2ViewerThumbnailsMatrixRepresentedObject object:curStudy children:[seriesArray objectAtIndex:curStudyIndex]]];
                
#ifndef OSIRIX_LIGHT
                if( [curStudy isKindOfClass: [DCMTKStudyQueryNode class]] && [[curStudy valueForKey: @"studyInstanceUID"] isEqualToString: study.studyInstanceUID]) // For the current study, always take the local images
                    curStudy = study;
#endif
                NSArray *series = [seriesArray objectAtIndex: curStudyIndex];
                NSArray *images = nil;
                
                if( [curStudy isKindOfClass: [DicomStudy class]])
                {
                    @try
                    {
                        images = [[BrowserController currentBrowser] imagesArray: curStudy preferredObject: oAny];
                        
                        if( [series count] != [images count])
                            N2LogStackTrace(@"[series count] != [images count] : You should not be here......");
                        
                        NSString *name = [[curStudy valueForKey:@"studyName"] stringByTruncatingToLength: 50];
                        
                        NSString *stateText;
                        NSUInteger stateIndex = [[curStudy valueForKey:@"stateText"] intValue];
                        if( stateIndex && stateIndex < BrowserController.statesArray.count) stateText = [BrowserController.statesArray objectAtIndex: stateIndex];
                        else stateText = @"";
                        
                        NSString *comment = [curStudy valueForKey:@"comment"];
                        
                        if( comment == nil)
                            comment = @"";
                        comment = [comment stringWithTruncatingToLength: 50];
                        
                        NSString *modality = [curStudy valueForKey:@"modality"];
                        if( modality == nil)
                            modality = @"OT:";
                        
#ifndef OSIRIX_LIGHT
                        if ([[cell.representedObject object] isKindOfClass:[DCMTKStudyQueryNode class]]) { // this is an incomplete study
                            [cell setImage:retrieveImage];
                            
                        }
#endif
                        
                        NSString *patName = @"";
                        
                        if( [curStudy valueForKey:@"name"] && [curStudy valueForKey:@"dateOfBirth"])
                            patName = [NSString stringWithFormat: @"%@ %@", [curStudy valueForKey:@"name"], [NSUserDefaults formatDate:[curStudy valueForKey:@"dateOfBirth"]]];
                        
                        if( [[curStudy valueForKey:@"name"] isEqualToString: study.name])
                            patName = @"";
                        
                        if ([[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"] != annotFull)
                            patName = @"";
                        
                        
                        NSMutableDictionary *d = [NSMutableDictionary dictionary];
                        
                        NSArray *colors = ViewerController.studyColors;
                        NSColor *bkgColor = nil;
                        if( curStudyIndexAll >= colors.count)
                            bkgColor = [colors lastObject];
                        else
                            bkgColor = [colors objectAtIndex: curStudyIndexAll];
                        
                        [d setObject: [NSFont boldSystemFontOfSize: 16] forKey: NSFontAttributeName];
                        
                        NSAttributedString *s = [[[NSAttributedString alloc] initWithString: [NSString stringWithFormat: @"%d", (int) curStudyIndexAll+1] attributes: d] autorelease];
                        
                        
                        if( DisplayUseInvertedPolarity)
                            bkgColor = [NSColor colorWithCalibratedRed: 1.0-bkgColor.redComponent green: 1.0-bkgColor.greenComponent blue:1.0-bkgColor.blueComponent alpha: bkgColor.alphaComponent];
                        
                        NSImage *number = [NSImage imageWithSize:NSMakeSize(SERIESPOPUPSIZE, SERIESPOPUPSIZE) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
                            [bkgColor set];
                            [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:5 yRadius:5] fill];
                            [s drawAtPoint:NSMakePoint((SERIESPOPUPSIZE - s.size.width) / 2, (SERIESPOPUPSIZE - s.size.height) / 2)];
                            return YES;
                        }];
                        
                        [cell setImage: number];
                        
                        NSMutableArray* components = [NSMutableArray array];
                        if( [curStudy date]) [components addObject:[[NSUserDefaults dateTimeFormatter] stringFromDate:[curStudy date]]];
                        if( patName.length) [components addObject:patName];
                        if( name.length) [components addObject:name];
                        if( modality.length) [components addObject:modality];
                        if( comment.length) [components addObject:comment];
                        
                        NSAttributedString *finalString = [[[NSAttributedString alloc] initWithString: [components componentsJoinedByString:@" / "] attributes: [NSDictionary dictionaryWithObject: [NSFont boldSystemFontOfSize: 14] forKey: NSFontAttributeName]] autorelease];
                        [cell setAttributedTitle: finalString];
                    }
                    @catch (NSException *exception) {
                        N2LogException( exception);
                    }
                    index++;
                }
                
#ifndef OSIRIX_LIGHT
                if ([curStudy isKindOfClass: [DCMTKQueryNode class]]) //Distant Study DCMTKQueryStudyNode
                {
                    @try
                    {
                        NSArray* local = [db objectsForEntity:db.studyEntity predicate:[NSPredicate predicateWithFormat:@"studyInstanceUID = %@ AND patientID = %@", [curStudy studyInstanceUID], [curStudy patientID]]];
                        if (local.count)
                            images = [[BrowserController currentBrowser] imagesArray:[local objectAtIndex:0] preferredObject: oAny];
                        
                        NSString *name = [[curStudy valueForKey:@"studyName"] stringByTruncatingToLength: 50];
                        if( name == nil)
                            name = @"";
                        NSString *modality = [curStudy valueForKey:@"modality"];
                        if( modality == nil)
                            modality = @"OT";
                        
                        NSString *patName = @"";
                        
                        if( [curStudy valueForKey:@"name"] && [curStudy valueForKey:@"dateOfBirth"])
                            patName = [NSString stringWithFormat: @"%@\r%@", [curStudy valueForKey:@"name"], [NSUserDefaults formatDate:[curStudy valueForKey:@"dateOfBirth"]]];
                        
                        if( [[curStudy name] isEqualToString:study.name])
                            patName = @"";
                        if ([[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"] != annotFull)
                            patName = @"";
                        
                        NSMutableArray* components = [NSMutableArray array];
                        if ([curStudy date]) [components addObject:[[NSUserDefaults dateTimeFormatter] stringFromDate:[curStudy date]]];
                        if (patName.length) [components addObject:patName];
                        if (name.length) [components addObject:name];
                        if (modality.length) [components addObject:modality];
                        
                        NSAttributedString *title = [[[NSAttributedString alloc] initWithString: [components componentsJoinedByString:@" / "] attributes: [NSDictionary dictionaryWithObject: [NSFont boldSystemFontOfSize: 14] forKey: NSFontAttributeName]] autorelease];
                        [cell setAttributedTitle: title];
                        
                        [cell setImage:retrieveImage];
                    }
                    @catch ( NSException *e) {
                        N2LogException( e);
                    }
                    index++;
                }
#endif
                
                //                if(![curStudy respondsToSelector:@selector(isHidden)] || [curStudy isHidden] == NO)
                {
                    for( i = 0; i < [series count]; i++)
                    {
                        DicomSeries* curSeries = [series objectAtIndex:i];
                        
                        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
                        NSMenuItem *cell = [[[NSMenuItem alloc] initWithTitle: @"" action: @selector( seriesPopupSelect:) keyEquivalent: @""] autorelease];
                        [cell setTarget: self];
                        [seriesPopupMenu.menu addItem: cell];
                        
                        [cell setRepresentedObject: [O2ViewerThumbnailsMatrixRepresentedObject object:curSeries]];
                        
                        NSString *name = [curSeries valueForKey:@"name"];
                        
                        if( [name length] > 50)
                            name = [name stringByTruncatingToLength: 50];
                        
                        if( name == nil)
                            name = @"";
                        
                        if( [viewerSeries containsObject: curSeries]) // Red
                        {
                            [attributes setObject: [[self class] _selectedItemColor] forKey: NSBackgroundColorAttributeName];
                            [seriesPopupMenu selectItem: cell];
                        }
                        else if( [[self blendingController] currentSeries] == curSeries) // Green
                            [attributes setObject:  [[self class] _fusionedItemColor] forKey: NSBackgroundColorAttributeName];
                        
                        else if( [displayedSeries containsObject: curSeries]) // Yellow
                            [attributes setObject:  [[self class] _openItemColor] forKey: NSBackgroundColorAttributeName];
                        
                        [attributes setObject: [NSFont systemFontOfSize: 14] forKey: NSFontAttributeName];
                        
                        name = [name stringByAppendingFormat: @" / %@", N2LocalizedSingularPluralCount( curSeries.images.count, @"image", @"images")];
                        
                        NSAttributedString *title = [[[NSAttributedString alloc] initWithString: name attributes: attributes] autorelease];
                        [cell setAttributedTitle: title];
                        
                        if( 1)
                        {
                            NSImage	*img = [[[NSImage alloc] initWithData: [curSeries primitiveValueForKey:@"thumbnail"]] autorelease];
                            
                            if( img == nil)
                            {
                                @try
                                {
                                    DCMPix* dcmPix = [[DCMPix alloc] initWithPath: [[images objectAtIndex: i] valueForKey:@"completePath"] :0 :0 :nil :0 :[[[images objectAtIndex: i] valueForKeyPath:@"series.id"] intValue] isBonjour:[[BrowserController currentBrowser] isCurrentDatabaseBonjour] imageObj:[images objectAtIndex: i]];
                                    
                                    [dcmPix CheckLoad];
                                    
                                    if (dcmPix && dcmPix.notAbleToLoadImage == NO)
                                    {
                                        img = [dcmPix generateThumbnailImageWithWW:0 WL:0];
                                        
                                        if( img)
                                        {
                                            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"StoreThumbnailsInDB"])
                                                curSeries.thumbnail = [BrowserController produceJPEGThumbnail:img];
                                        }
                                        else
                                            img = [NSImage imageNamed:@"FileNotFound.tif"];
                                        
                                    }
                                    else
                                        img = [NSImage imageNamed:@"FileNotFound.tif"];
                                    
                                    [dcmPix release];
                                }
                                @catch (NSException* e)
                                {
                                    N2LogExceptionWithStackTrace(e);
                                    img = [NSImage imageNamed:@"FileNotFound.tif"];
                                }
                            }
                            
                            if( DisplayUseInvertedPolarity)
                                img = [img imageInverted];
                            
                            [cell setImage: [img imageByScalingProportionallyToSizeUsingNSImage: NSMakeSize( SERIESPOPUPSIZE, SERIESPOPUPSIZE)]];
                        }
                        
                        index++;
                    }
                }
                
                if( curStudy != studiesArray.lastObject)
                    [seriesPopupMenu.menu addItem: [NSMenuItem separatorItem]];
            }
        }
    }
    @catch (NSException *e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [seriesPopupContextualMenu setSubmenu: [[seriesPopupMenu.menu copy] autorelease]];
    [seriesPopupContextualMenu setImage: seriesPopupMenu.selectedItem.image];
    [seriesPopupContextualMenu setTitle: (self.currentSeries.name ? self.currentSeries.name : NSLocalizedString( @"Unnamed", nil))];
    
    for( DCMView *v in self.imageViews)
        [v computeColor];
}

- (void) loadSelectedSeries: (id) series rightClick: (BOOL) rightClick
{
    if( [series isKindOfClass: [DicomStudy class]])
    {
        DicomStudy *s = series;
        
        NSArray *seriesArray = [s imageSeriesContainingPixels: YES];
        if( seriesArray.count)
            series = [seriesArray objectAtIndex: 0];
        else
            return;
    }
    
    NSMutableArray *viewerSeries = [NSMutableArray array];
    
    for( int i = 0 ; i < maxMovieIndex; i++)
    {
        if( [[fileList[ i] objectAtIndex:0] valueForKey:@"series"])
            [viewerSeries addObject: [[fileList[ i] objectAtIndex:0] valueForKey:@"series"]];
    }
    
    if( (rightClick || ([[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagCommand)) && FullScreenOn == NO)
    {
        if( ([[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagShift) || [[BrowserController currentBrowser] isUsingExternalViewer: series] == NO)
        {
            BOOL c = [[NSUserDefaults standardUserDefaults] boolForKey:@"syncPreviewList"];
            
            [[NSUserDefaults standardUserDefaults] setBool: NO forKey:@"syncPreviewList"];
            
            ViewerController *newViewer = [[BrowserController currentBrowser] loadSeries :series :nil :YES keyImagesOnly: displayOnlyKeyImages];
            [newViewer setHighLighted: 1.0];
            
            if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"] == NO)
                [self showCurrentThumbnail: self];
            
            if( [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOTILING"])
                [NSApp sendAction: @selector(tileWindows:) to:nil from: self];
            else
                [[AppController sharedAppController] checkAllWindowsAreVisible: self makeKey: YES];
            
            for( int i = 0; i < [[NSScreen screens] count]; i++) [thumbnailsListPanel[ i] setThumbnailsView: nil viewer: nil];
            
            [[self window] makeKeyAndOrderFront: self];
            [self refreshToolbar];
            [self updateNavigator];
            
            [newViewer showCurrentThumbnail: self];
            
            [[NSUserDefaults standardUserDefaults] setBool: c forKey:@"syncPreviewList"];
            [self syncThumbnails];
        }
    }
    else
    {
        if( [viewerSeries containsObject: series] == NO)
        {
            BOOL found = NO;
            BOOL showWindowIfDisplayed = [[NSUserDefaults standardUserDefaults] boolForKey: @"showWindowInsteadOfSwitching"];
            
            if( ([[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagShift))
                showWindowIfDisplayed = !showWindowIfDisplayed;
            
            if( showWindowIfDisplayed)
            {
                // is this series already displayed? -> select it !
                
                for( ViewerController *v in [ViewerController getDisplayed2DViewers])
                {
                    if( [[v imageView] seriesObj] == series && v != self)
                    {
                        [[v window] makeKeyAndOrderFront: self];
                        [v setHighLighted: 1.0];
                        
                        found = YES;
                    }
                }
            }
            
            if( found == NO)
            {
                BOOL savedAUTOHIDEMATRIX = [[NSUserDefaults standardUserDefaults] boolForKey:@"AUTOHIDEMATRIX"];
                
                [[NSUserDefaults standardUserDefaults] setBool: NO forKey:@"AUTOHIDEMATRIX"];
                
                if( ([[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagShift) || [[BrowserController currentBrowser] isUsingExternalViewer: series] == NO)
                {
                    (void)[[BrowserController currentBrowser] loadSeries :series :self :YES keyImagesOnly: displayOnlyKeyImages];
                    
                    [self showCurrentThumbnail:self];
                    [self updateNavigator];
                }
                
                [[NSUserDefaults standardUserDefaults] setBool: savedAUTOHIDEMATRIX forKey:@"AUTOHIDEMATRIX"];
            }
        }
        else if( series != [[fileList[ curMovieIndex] objectAtIndex:0] valueForKey:@"series"]) // Select it in 4D !
        {
            NSUInteger idx = [viewerSeries indexOfObject: series];
            
            if( idx != NSNotFound)
            {
                [self setMovieIndex: idx];
                [self propagateSettings];
            }
        }
        else
            [self mouseMoved];
    }
}
- (IBAction)seriesPopupSelect:(NSMenuItem *)sender
{
    id series = [sender.representedObject object];
    
    if( [series isKindOfClass: [DicomStudy class]])
    {
        DicomStudy *s = series;
        series = [s.imageSeries objectAtIndex: 0];
        
        for( NSMenuItem *i in seriesPopupMenu.menu.itemArray)
        {
            if( series == [i.representedObject object])
                [seriesPopupMenu selectItem: i];
        }
    }
    
#ifndef OSIRIX_LIGHT
    if( [series isKindOfClass: [DCMTKStudyQueryNode class]]) //Distant Study
    {
        [[BrowserController currentBrowser] retrieveComparativeStudy: series select: YES open: YES showGUI: YES viewer: self];
        return;
    }
#endif
    
    [self loadSelectedSeries: series rightClick: NO];
}

- (void) matrixPreviewLoadAllSeries: (id) sender
{
    
}

- (void) matrixPreviewPressed:(id) sender
{
    ThumbnailCell *cell = [sender selectedCell];
    
    [cell setLineBreakMode: NSLineBreakByWordWrapping];
    [cell setFont:[NSFont boldSystemFontOfSize: [[BrowserController currentBrowser] fontSize: @"dbSmallMatrixFont"]]];
    
    [cell setImagePosition: NSImageBelow];
    [cell setTransparent:NO];
    [cell setEnabled:YES];
    
    [cell setButtonType:NSButtonTypeMomentaryPushIn];
    [cell setBezelStyle:NSBezelStyleShadowlessSquare];
    //[cell setShowsStateBy:NSPushInCellMask];
    [cell setHighlightsBy:NSContentsCellMask];
    [cell setImageScaling:NSImageScaleProportionallyDown];
    [cell setBordered:YES];
    
    id series = [[[sender selectedCell] representedObject] object];
    
    [self loadSelectedSeries: series rightClick: cell.rightClick];
}

-(BOOL) checkFrameSize
{
    BOOL visible = [self matrixIsVisible];
    
    return visible;
}

// How thick the series list strip has to be on the stored edge (#380 D).
- (CGFloat) horosSeriesListThickness
{
    HorosSeriesListPlacement placement = [HorosSeriesListLayout storedPlacementIn: [NSUserDefaults standardUserDefaults]];
    CGFloat height = previewMatrix ? [previewMatrix cellSize].height : 120;
    if( height < 1) height = 120;
    return [HorosSeriesListLayout thicknessForPlacement: placement
                                         thumbnailWidth: [ThumbnailCell thumbnailCellWidth]
                                        thumbnailHeight: height];
}

- (void) updateSeriesListMode
{
    if( windowWillClose || splitView == nil)
        return;

    BOOL floating = [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"];
    BOOL visible = [[NSUserDefaults standardUserDefaults] boolForKey: @"SeriesListVisible"];
    HorosSeriesListPlacement placement = [HorosSeriesListLayout storedPlacementIn: [NSUserDefaults standardUserDefaults]];
    [HorosSeriesListLayout placeScrollView: previewMatrixScrollView inSplitView: splitView
                                 floating: floating visible: visible thumbnailWidth: [self horosSeriesListThickness]
                                placement: placement];
    [splitView resizeSubviewsWithOldSize: splitView.bounds.size];
    if( visible && needsToBuildSeriesMatrix)
        [self buildMatrixPreview: NO];
    else if( visible)
        [HorosSeriesListLayout layOutMatrix: previewMatrix count: (long)[[previewMatrix cells] count] placement: placement];
}

- (void) setMatrixVisible: (BOOL) visible
{
    if( windowWillClose)
        return;
    
    BOOL currentlyVisible = [self matrixIsVisible];
    
    if (currentlyVisible != visible)
    {
        NSView* v = [[splitView subviews] objectAtIndex:0];
        [v setHidden:!visible];
        if (visible) {
            NSRect f = v.frame; f.size.width = [ThumbnailCell thumbnailCellWidth];
            [v setFrame:f];
        }
        [splitView resizeSubviewsWithOldSize:splitView.bounds.size];
        
        if( visible && needsToBuildSeriesMatrix)
            [self buildMatrixPreview: NO];
    }
    
    [[NSUserDefaults standardUserDefaults] setBool: visible forKey: @"SeriesListVisible"];
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
        return;
    
    if( [keyPath isEqualToString:@"SeriesListVisible"])
    {
        static int noReentry = 0;
        
        if( noReentry == 0)
        {
            noReentry = 1;
            for( ViewerController *v in [ViewerController getDisplayed2DViewers])
                [v setMatrixVisible: [[change objectForKey:NSKeyValueChangeNewKey] intValue]];
            noReentry = 0;
        }
    }
}

- (void) autoHideMatrix
{
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
        return;
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"AUTOHIDEMATRIX"] == NO)
        return;
    
    BOOL hide = NO;
    NSWindow *window = nil;
    
    if( windowWillClose)
        return;
    
    if( [self FullScreenON] == NO)
    {
        window = self.window;
        if( [window isKeyWindow] == NO)
            hide = YES;
        //		if( [window isMainWindow] == NO)
        //            hide = YES;
    }
    else
        window = FullScreenWindow;
    
    NSPoint	mouse = [window mouseLocationOutsideOfEventStream];
    
    BOOL isCurrentlyVisible = [self matrixIsVisible];
    
    if( hide == NO)
    {
        if( isCurrentlyVisible == NO)
        {
            if( mouse.x >= 0 && mouse.x <= [previewMatrix cellSize].width+13 && mouse.y >= 0 && mouse.y <= [splitView frame].size.height-20)
            {
                
            }
            else
                hide = YES;
        }
        else
        {
            if( mouse.x >= 0 && mouse.x <= [previewMatrix cellSize].width+13 && mouse.y >= 0 && mouse.y <= [splitView frame].size.height)
            {
                
            }
            else
                hide = YES;
        }
    }
    
    if( isCurrentlyVisible == hide)
    {
        NSMutableArray *scaleValues = [NSMutableArray array];
        NSMutableArray *originValues = [NSMutableArray array];
        
        for( DCMView * v in [seriesView imageViews])
        {
            [scaleValues addObject: [NSNumber numberWithFloat: v.scaleValue]];
            [originValues addObject: NSStringFromPoint( v.origin)];
        }
        
        [self setMatrixVisible: !hide];
        
        
        int i = 0;
        for( DCMView * v in [seriesView imageViews])
        {
            [v displayIfNeeded];
            v.scaleValue = [[scaleValues objectAtIndex: i] floatValue];
            v.origin = NSPointFromString( [originValues objectAtIndex: i]);
            i++;
        }
        
        [self propagateSettings];
        
        for( DCMView * v in [seriesView imageViews])
            [v displayIfNeeded];
        
    }
}

- (NSScrollView*) previewMatrixScrollView
{
    return previewMatrixScrollView;
}

- (NSView*) previewRootView
{
    return previewRootView;
}

- (void) syncThumbnails
{
    ViewBoundsDidChangeProtect = YES;
    
    for( ViewerController *v in [ViewerController getDisplayed2DViewers])
    {
        BOOL same = NO;
        
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"SyncSeriesListForAllComparativeStudies"])
            same = [v.currentStudy.patientUID isEqualToString: self.currentStudy.patientUID];
        else
            same = [[v studyInstanceUID] isEqualToString: [self studyInstanceUID]];
        
        if( v != self && same)
        {
            NSClipView *clipView = [v.previewMatrixScrollView contentView];
            NSRect proposedBounds = clipView.bounds;
            proposedBounds.origin = [[previewMatrix superview] bounds].origin;
            [clipView scrollToPoint: [clipView constrainBoundsRect: proposedBounds].origin];
            [v.previewMatrixScrollView reflectScrolledClipView: [v.previewMatrixScrollView contentView]];
            
            
            //            [NSAnimationContext beginGrouping];
            //            [[NSAnimationContext currentContext] setDuration:0.2];
            //            NSClipView* clipView = [v.previewMatrixScrollView contentView];
            //            [[clipView animator] setBoundsOrigin: [[v.previewMatrixScrollView contentView] constrainScrollPoint: [[previewMatrix superview] bounds].origin]];
            //            [v.previewMatrixScrollView reflectScrolledClipView: [v.previewMatrixScrollView contentView]]; // may not bee necessary
            //            [NSAnimationContext endGrouping];
        }
    }
    
    ViewBoundsDidChangeProtect = NO;
}

- (void) ViewBoundsDidChange: (NSNotification*) note
{
    if( ViewBoundsDidChangeProtect == NO)
    {
        ViewBoundsDidChangeProtect = YES;
        
        if( [note object] == [previewMatrixScrollView contentView])
        {
            BOOL syncThumbnails = [[NSUserDefaults standardUserDefaults] boolForKey: @"syncPreviewList"];
            
            if ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagCommand)
                syncThumbnails = !syncThumbnails;
            
            if( syncThumbnails)
            {
                [NSObject cancelPreviousPerformRequestsWithTarget: self selector:@selector( syncThumbnails) object:nil];
                [self performSelector: @selector( syncThumbnails) withObject:nil afterDelay: 0.1];
            }
        }
        
        ViewBoundsDidChangeProtect = NO;
    }
}

-(void) ViewFrameDidChange:(NSNotification*) note
{
    if( windowWillClose)
        return;
    
    if( [[splitView subviews] count] > 1)
    {
        if ([note object] == [[splitView subviews] objectAtIndex: 1])
        {
            if( [self matrixIsVisible] && matrixPreviewBuilt == NO)
            {
                [self buildMatrixPreview];
            }
        }
    }
}

- (NSRect)splitView:(NSSplitView *)s effectiveRect:(NSRect)proposedEffectiveRect forDrawnRect:(NSRect)drawnRect ofDividerAtIndex:(NSInteger)dividerIndex
{
    if( s == splitView)
    {
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
            return NSZeroRect;
    }
    
    return proposedEffectiveRect;
}

- (void)splitViewDidResizeSubviews:(NSNotification *) notification
{
    if( windowWillClose)
        return;
    
    if (notification.object == splitView)
    {
        [previewMatrix sizeToCells];
        
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"AUTOHIDEMATRIX"] == NO && FullScreenOn == NO)
        {
            
            // Apply show / hide matrix to all viewers
            if( ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagOption) == NO)
            {
                static BOOL noreentry = NO;
                
                if( noreentry == NO)
                {
                    noreentry = YES;
                    
                    BOOL showMatrix = [self matrixIsVisible];
                    
                    for( ViewerController *v in [ViewerController get2DViewers])
                    {
                        if( v != self)
                        {
                            if (showMatrix != [v matrixIsVisible])
                                [v setMatrixVisible: showMatrix];
                        }
                        else
                        {
                            if( [v matrixIsVisible] && needsToBuildSeriesMatrix)
                                [self buildMatrixPreview: NO];
                        }
                    }
                }
                noreentry = NO;
            }
            
        }
    }
}

-(void)splitViewWillResizeSubviews:(NSNotification *)notification
{
    if( windowWillClose)
        return;
    
    if (notification.object == splitView)
    {
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"] == NO)
        {
            OSIWindow* window = (OSIWindow*)self.window;
            if( [window respondsToSelector:@selector(disableUpdatesUntilFlush)])
                [window disableUpdatesUntilFlush];
        }
    }
}

- (BOOL)splitView: (NSSplitView *)sender canCollapseSubview: (NSView *)subview
{
    if( sender == splitView)
    {
        if( subview == [[sender subviews] objectAtIndex:1]) // Main view
            return NO;
    }
    
    //    if (sender == leftSplitView)
    //    {
    //        if (subview == [[sender subviews] objectAtIndex:1])
    //            return NO;
    //    }
    
    return YES;
}

- (CGFloat)splitView:(NSSplitView *)sender constrainSplitPosition:(CGFloat)proposedPosition ofSubviewAt:(NSInteger)offset
{
    if( windowWillClose)
        return proposedPosition;
    
    if (sender == splitView)
    {
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
            return 0;
        
        CGFloat rcs = [self horosSeriesListThickness];
        
        // A strip across the top or bottom snaps to its own thickness; the
        // scrollbar correction below is about a vertical scroller (#380 D).
        if( [HorosSeriesListLayout storedPlacementIn: [NSUserDefaults standardUserDefaults]] == HorosSeriesListPlacementTop ||
            [HorosSeriesListLayout storedPlacementIn: [NSUserDefaults standardUserDefaults]] == HorosSeriesListPlacementBottom)
            return proposedPosition > rcs / 2 ? rcs : 0;
        
        NSScrollView* scrollView = previewMatrixScrollView;
        CGFloat scrollbarWidth = 0;
        if ([scrollView isKindOfClass:[NSScrollView class]])
        {
            NSScroller* scroller = [scrollView verticalScroller];
            if ([BrowserController _scrollerStyle:scroller] != 1)
                if ([scrollView hasVerticalScroller] && ![scroller isHidden])
                    scrollbarWidth = [scroller frame].size.width;
        }
        
        proposedPosition -= scrollbarWidth;
        
        NSUInteger f = roundf(proposedPosition/rcs);
        if (f > 1) f = 1;
        proposedPosition = rcs*f;
        
        if (proposedPosition)
            proposedPosition += (scrollbarWidth?scrollbarWidth+2:1);
        
        return proposedPosition;
    }
    //
    //    if (sender == leftSplitView)
    //    {
    //        if (offset == 0)
    //        {
    //            if ([sender isSubviewCollapsed:[sender.subviews objectAtIndex:0]])//[sender.subviews count] == 2)
    //                return 0;
    //            else
    //                return 15;
    //        }
    //    }
    
    return proposedPosition;
}

-(BOOL) matrixIsVisible
{
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
        return YES;
    
    BOOL r = [HorosSeriesListLayout isListVisibleInSplitView: splitView
                                                   placement: [HorosSeriesListLayout storedPlacementIn: [NSUserDefaults standardUserDefaults]]
                                                   thickness: [self horosSeriesListThickness]];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"SeriesListVisible"] != r)
        [[NSUserDefaults standardUserDefaults] setBool: r forKey: @"SeriesListVisible"];
    
    return r;
}

-(void) splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize
{
    if( windowWillClose)
        return;
    
    if( sender == splitView)
    {
        CGFloat dividerPosition = [self matrixIsVisible]? [self horosSeriesListThickness] : 0;
        dividerPosition = [self splitView:sender constrainSplitPosition:dividerPosition ofSubviewAt:0];
        
        NSRect splitFrame = [sender frame];
        
        if( isnan(splitFrame.size.height) || splitFrame.size.height < 0 || isnan(splitFrame.size.width) || splitFrame.size.width < 0)
        {
            NSLog( @"******* splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize - %f", splitFrame.size.height);
            return;
        }
        
        // Any edge, not only a left dock (#380 D).
        [HorosSeriesListLayout resizeSubviewsOfSplitView: sender
                                               placement: [HorosSeriesListLayout storedPlacementIn: [NSUserDefaults standardUserDefaults]]
                                               thickness: dividerPosition];
    }
    
    //    if (sender == leftSplitView)
    //    {
    //        {
    //            CGFloat ch = [sender isSubviewCollapsed:[sender.subviews objectAtIndex:0]]? 0 : 15;
    //            [[sender.subviews objectAtIndex:0] setFrame:NSMakeRect(0, 0, sender.frame.size.width, ch)];
    //            if (ch > 0) ch += sender.dividerThickness;
    //            [[sender.subviews objectAtIndex:1] setFrame:NSMakeRect(0, ch, sender.frame.size.width, sender.frame.size.height-ch)];
    //        }
    //    }
}

-(void) observeScrollerStyleDidChangeNotification:(NSNotification*)n
{
    [splitView resizeSubviewsWithOldSize:[splitView bounds].size];
}

- (void) matrixPreviewSwitchHidden:(id) sender
{
    id curStudy = [[[sender selectedCell] representedObject] object];
    
    if( [curStudy isKindOfClass: [DicomStudy class]]) //Local study
    {
        if([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagCommand)
        {
            [[BrowserController currentBrowser] databaseOpenStudy: curStudy];
        }
        else
        {
            [curStudy setHidden: ![curStudy isHidden]];
            
            for( ViewerController *v in [ViewerController getDisplayed2DViewers])
            {
                if( [v.studyInstanceUID isEqualToString: self.studyInstanceUID])
                    [v buildMatrixPreview: NO];
                else
                    [v buildMatrixPreview: YES];
            }
        }
    }
#ifndef OSIRIX_LIGHT
    else if( [curStudy isKindOfClass: [DCMTKStudyQueryNode class]]) //Distant Study
    {
        [[BrowserController currentBrowser] retrieveComparativeStudy: curStudy select: NO open: NO];
    }
#endif
}

- (void) checkBuiltMatrixPreview
{
    if( [self checkFrameSize] == YES && matrixPreviewBuilt == NO)
    {
        if( [[self window] isKeyWindow])
            [self buildMatrixPreview: YES];
        else
            [self buildMatrixPreview: NO];
    }
}

+ (NSColor*)_selectedItemColor { // red
    return [NSColor colorWithCalibratedRed:252./255 green:177./255 blue:141./255 alpha:1];
}

+ (NSColor*)_fusionedItemColor { // green
    return [NSColor colorWithCalibratedRed:195./255 green:249./255 blue:145./255 alpha:1];
}

+ (NSColor*)_openItemColor { // yellow
    return [NSColor colorWithCalibratedRed:249./255 green:240./255 blue:140./255 alpha:1];
}

+ (NSColor*)_differentStudyColor { // gray
    return [NSColor colorWithCalibratedRed:0.55 green:0.55 blue:0.55 alpha:1];
}

- (void) buildMatrixPreview: (BOOL) showSelected
{
    if( [[self window] isVisible] == NO) return;	//we will do it in checkBuiltMatrixPreview : faster opening !
    if( windowWillClose) return;
    
    // series popup menu button : will build all the items, when needed, later
    
    needsToBuildSeriesPopupMenu = YES;
    needsToBuildSeriesMatrix = YES;
    
    [seriesPopupMenu.menu removeAllItems];
    NSMenuItem *menuItem = [[[NSMenuItem alloc] initWithTitle: @"" action: @selector( seriesPopupSelect:) keyEquivalent: @""] autorelease];
    NSImage	*img = [[[NSImage alloc] initWithData: [self.currentSeries primitiveValueForKey:@"thumbnail"]] autorelease];
    
    if( DisplayUseInvertedPolarity)
        img = [img imageInverted];
    
    [menuItem setImage: [img imageByScalingProportionallyToSizeUsingNSImage: NSMakeSize( SERIESPOPUPSIZE, SERIESPOPUPSIZE)]];
    [seriesPopupMenu.menu addItem: menuItem];
    [seriesPopupContextualMenu setTitle: (self.currentSeries.name ? self.currentSeries.name : NSLocalizedString( @"Unnamed", nil))];
    
    if( [self matrixIsVisible] == NO)
        return;
    
    // *************
    
    BOOL hasComparatives = NO, hasComparativesNewerThanMostRecentLoaded = NO;
    
    @try
    {
        DicomDatabase *db = [[BrowserController currentBrowser] database];
        NSPredicate				*predicate;
        long					i, index = 0;
        NSManagedObject			*curImage = [fileList[0] objectAtIndex:0];
        NSPoint					origin = [[previewMatrix superview] bounds].origin;
        
        BOOL visible = [self checkFrameSize];
        
        if( visible == NO) matrixPreviewBuilt = NO;
        else matrixPreviewBuilt = YES;
        
        [previewMatrixScrollView setPostsBoundsChangedNotifications:YES];
        
        DicomStudy *study = [curImage valueForKeyPath:@"series.study"];
        if( study == nil)
        {
            [previewMatrix renewRows: 0 columns: 0];
            [previewMatrix sizeToCells];
            matrixPreviewBuilt = NO;
            return;
        }
        
        NSMutableArray *viewerSeries = [NSMutableArray array];
        
        for( int i = 0 ; i < maxMovieIndex; i++)
            [viewerSeries addObject: [[fileList[ i] objectAtIndex:0] valueForKey:@"series"]];
        
        // FIND ALL STUDIES of this patient
        NSString *searchString = [study valueForKey:@"patientUID"];
        
        if( [searchString length] == 0 || [searchString isEqualToString:@"0"])
        {
            searchString = [study valueForKey:@"name"];
            predicate = [NSPredicate predicateWithFormat: @"(name == %@)", searchString];
        }
        else predicate = [NSPredicate predicateWithFormat: @"(patientUID BEGINSWITH[cd] %@)", searchString];
        
        NSArray *studiesArray = nil;
        // Use the 'history' array of the browser controller, if available (with the distant studies)
        
        if( [[[BrowserController currentBrowser] comparativePatientUID] compare: [study patientUID] options: NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch] == NSOrderedSame && [[BrowserController currentBrowser] comparativeStudies] != nil)
            studiesArray = [BrowserController currentBrowser].comparativeStudies;
        else
        {
            //            if( [[BrowserController currentBrowser] selectThisStudy: study] == NO)
            //                NSLog( @"---- buildMatrixPreview - history not found");
            
            studiesArray = [db objectsForEntity:db.studyEntity predicate:predicate];
            studiesArray = [studiesArray sortedArrayUsingDescriptors: [NSArray arrayWithObject: [NSSortDescriptor sortDescriptorWithKey: @"date" ascending: NO]]];
        }
        
#ifndef OSIRIX_LIGHT
        
        if (!retrieveImage) {
            retrieveImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"DownArrowGreyRev" ofType:@"pdf"]];
            retrieveImage.size = NSMakeSize(SERIESPOPUPSIZE,SERIESPOPUPSIZE);
        }
#endif
        
        if ([studiesArray count])
        {
            studiesArray = [NSArray arrayWithArray: studiesArray];
            
            NSArray *displayedSeries = [ViewerController getDisplayedSeries];
            NSMutableArray *seriesArray = [NSMutableArray array];
            
            i = 0;
            for( id s in studiesArray)
            {
#ifndef OSIRIX_LIGHT
                if( [s isKindOfClass: [DCMTKStudyQueryNode class]] && [[s valueForKey: @"studyInstanceUID"] isEqualToString: study.studyInstanceUID]) // For the current study, always take the local images
                    s = study;
                else if ([s isKindOfClass: [DCMTKStudyQueryNode class]]) { // and still, if there are local series, display them!
                    NSArray* local = [db objectsForEntity:db.studyEntity predicate:[NSPredicate predicateWithFormat:@"studyInstanceUID = %@ AND patientID = %@", [s studyInstanceUID], [s patientID]]];
                    if (local.count)
                        s = [local objectAtIndex:0];
                }
#endif
                
                if( [s isKindOfClass: [DicomStudy class]]) //Local Study DicomStudy
                {
                    [seriesArray addObject: [[BrowserController currentBrowser] childrenArray: s]];
                    
                    if( [s isHidden] == NO)
                        i += [[seriesArray lastObject] count];
                    
                    //                    i++; // display all button
                }
#ifndef OSIRIX_LIGHT
                else if( [s isKindOfClass: [DCMTKStudyQueryNode class]]) //Distant Study DCMTKQueryStudyNode
                {
                    [seriesArray addObject: [NSArray array]];
                }
#endif
            }
            
            NSArray *allStudiesArray = studiesArray;
            
#ifndef OSIRIX_LIGHT
            NSMutableArray* tstudiesArray = [NSMutableArray array];
            NSMutableArray* tseriesArray = [NSMutableArray array];
            BOOL iteratedFirstLoaded = NO;
            for (int i = 0; i < studiesArray.count; ++i) {
                id s = [studiesArray objectAtIndex:i];
                NSArray* series = [seriesArray objectAtIndex:i];
                
                BOOL isNonLoadedComp = [s isKindOfClass:[DCMTKQueryNode class]];
                if (!isNonLoadedComp || series.count || self.flagListPODComparatives.boolValue) {
                    [tstudiesArray addObject:s];
                    [tseriesArray addObject:series];
                }
                
                if (isNonLoadedComp) {
                    hasComparatives = YES;
                    if (!iteratedFirstLoaded)
                        hasComparativesNewerThanMostRecentLoaded = YES;
                } else
                    iteratedFirstLoaded = YES;
            }
            
            studiesArray = tstudiesArray;
            seriesArray = tseriesArray;
#endif
            
            [previewMatrix setCellClass: [ThumbnailCell class]];
            
            // One column down a side strip, one row across a top or bottom
            // strip; the cell size never changes, so the thumbnails scroll
            // instead of being squeezed (#380 D).
            [HorosSeriesListLayout layOutMatrix: previewMatrix count: i+[studiesArray count]
                                      placement: [HorosSeriesListLayout storedPlacementIn: [NSUserDefaults standardUserDefaults]]];
            
            for (NSButtonCell* cell in previewMatrix.cells)
            {
                [cell setLineBreakMode: NSLineBreakByWordWrapping];
                [cell setFont:[NSFont boldSystemFontOfSize: [[BrowserController currentBrowser] fontSize: @"dbSmallMatrixFont"]]];
                [cell setBackgroundColor:nil];
                
                [cell setRepresentedObject:nil];
                
                [cell setImagePosition: NSImageBelow];
                [cell setTransparent:NO];
                [cell setEnabled:YES];
                
                [cell setButtonType:NSButtonTypeMomentaryPushIn];
                [cell setBezelStyle:NSBezelStyleShadowlessSquare];
                //[cell setShowsStateBy:NSPushInCellMask];
                [cell setHighlightsBy:NSContentsCellMask];
                [cell setImageScaling:NSImageScaleProportionallyDown];
                [cell setBordered:YES];
                
                [cell setTitle:@""];
                
                [cell setImage: nil];
                
                [cell setTarget: self];
            }
            
            
            for( id curStudy in studiesArray)
            {
                NSButtonCell* cell = [previewMatrix cellAtRow: index column:0];
                
                NSUInteger curStudyIndexAll = [allStudiesArray indexOfObject: curStudy];
                NSUInteger curStudyIndex = [studiesArray indexOfObject: curStudy];
                
                [cell setRepresentedObject:[O2ViewerThumbnailsMatrixRepresentedObject object:curStudy children:[seriesArray objectAtIndex:curStudyIndex]]];
                [cell setAction: @selector(matrixPreviewSwitchHidden:)];
                
#ifndef OSIRIX_LIGHT
                if( [curStudy isKindOfClass: [DCMTKStudyQueryNode class]] && [[curStudy valueForKey: @"studyInstanceUID"] isEqualToString: study.studyInstanceUID]) // For the current study, always take the local images
                    curStudy = study;
#endif
                
                if( [[curStudy valueForKey: @"studyInstanceUID"] isEqualToString: study.studyInstanceUID])
                    [cell setBackgroundColor: nil];
                else
                    [cell setBackgroundColor: [[self class] _differentStudyColor]];
                
                NSArray *series = [seriesArray objectAtIndex: curStudyIndex];
                NSArray *images = nil;
                
                if( [curStudy isKindOfClass: [DicomStudy class]])
                {
                    @try
                    {
                        images = [[BrowserController currentBrowser] imagesArray: curStudy preferredObject: oAny];
                        
                        if( [series count] != [images count])
                            N2LogStackTrace(@"[series count] != [images count] : You should not be here......");
                        
                        NSString *name = [[curStudy valueForKey:@"studyName"] stringByTruncatingToLength: 34];
                        
                        NSString *stateText;
                        NSUInteger stateIndex = [[curStudy valueForKey:@"stateText"] intValue];
                        if( stateIndex && stateIndex < BrowserController.statesArray.count) stateText = [BrowserController.statesArray objectAtIndex: stateIndex];
                        else stateText = @"";
                        NSString *comment = [curStudy valueForKey:@"comment"];
                        
                        if( comment == nil)
                            comment = @"";
                        comment = [comment stringWithTruncatingToLength: 32];
                        
                        NSString *modality = [curStudy valueForKey:@"modality"];
                        if( modality == nil)
                            modality = @"OT:";
                        
                        NSString *action = nil;
#ifndef OSIRIX_LIGHT
                        if ([[cell.representedObject object] isKindOfClass:[DCMTKStudyQueryNode class]]) { // this is an incomplete study
                            
                            switch( [[NSUserDefaults standardUserDefaults] integerForKey: @"dbFontSize"])
                            {
                                case -1:
                                    [cell setImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 0.6]];
                                    [cell setAlternateImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 0.6]];
                                    break;
                                case 0:
                                    [cell setImage: retrieveImage];
                                    [cell setAlternateImage: retrieveImage];
                                    break;
                                case 1:
                                    [cell setImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 1.3]];
                                    [cell setAlternateImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 1.3]];
                                    break;
                            }
                            
                            [cell setImagePosition:NSImageOverlaps];
                            [cell setImageScaling:NSImageScaleProportionallyDown];
                            
                        } else {
#endif
                            if( [curStudy isHidden])
                                action = NSLocalizedString(@"Show Series", nil);
                            else
                                action = NSLocalizedString(@"Hide Series", nil);
#ifndef OSIRIX_LIGHT
                        }
#endif
                        
                        NSString *patName = @"";
                        
                        if( [curStudy valueForKey:@"name"] && [curStudy valueForKey:@"dateOfBirth"])
                            patName = [NSString stringWithFormat: @"%@\r%@", [curStudy valueForKey:@"name"], [NSUserDefaults formatDate:[curStudy valueForKey:@"dateOfBirth"]]];
                        
                        if( [[curStudy valueForKey:@"name"] isEqualToString: study.name])
                            patName = @"";
                        
                        if ([[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"] != annotFull)
                            patName = @"";
                        
                        NSMutableArray* components = [NSMutableArray array];
                        [components addObject: [NSString stringWithFormat: @" %d ", (int) curStudyIndexAll+1]];
                        [components addObject: @""];
                        if (patName.length) [components addObject:patName];
                        if (name.length) [components addObject:name];
                        if ([curStudy date]) [components addObject:[[NSUserDefaults dateTimeFormatter] stringFromDate:[curStudy date]]];
                        [components addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: %@", @"semicolon separator for spacing"), modality, N2SingularPluralCount([series count], NSLocalizedString(@"series", @"one series, singular"), NSLocalizedString(@"series", @"zero or 2 or more series, plural"))]];
                        if (stateText.length) [components addObject:stateText];
                        if (comment.length) [components addObject:comment];
                        if (action.length) [components addObject:[NSString stringWithFormat:@"\r%@", action]];
                        
                        
                        NSMutableAttributedString *finalString = [[[NSMutableAttributedString alloc] initWithString: [components componentsJoinedByString:@"\r"]] autorelease];
                        
                        NSMutableDictionary *attribs = [NSMutableDictionary dictionary];
                        [attribs setObject: [NSFont boldSystemFontOfSize: [[BrowserController currentBrowser] fontSize: @"viewerNumberFont"]] forKey: NSFontAttributeName];
                        
                        NSArray *colors = ViewerController.studyColors;
                        NSColor *bkgColor = nil;
                        if( curStudyIndexAll >= colors.count)
                            bkgColor = [colors lastObject];
                        else
                            bkgColor = [colors objectAtIndex: curStudyIndexAll];
                        
                        if( DisplayUseInvertedPolarity)
                            bkgColor = [NSColor colorWithCalibratedRed: 1.0-bkgColor.redComponent green: 1.0-bkgColor.greenComponent blue:1.0-bkgColor.blueComponent alpha: bkgColor.alphaComponent];
                        
                        [attribs setObject: bkgColor forKey: NSBackgroundColorAttributeName];
                        [finalString setAttributes: attribs range: NSMakeRange( 0, [[components objectAtIndex: 0] length])];
                        
                        [attribs setObject: [NSFont boldSystemFontOfSize: [[BrowserController currentBrowser] fontSize: @"dbSmallMatrixFont"]] forKey: NSFontAttributeName];
                        [attribs removeObjectForKey: NSBackgroundColorAttributeName];
                        [finalString setAttributes: attribs range: NSMakeRange( [[components objectAtIndex: 0] length], finalString.length - [[components objectAtIndex: 0] length])];
                        
                        [finalString setAlignment:NSTextAlignmentCenter range: NSMakeRange( 0, finalString.length)];
                        [cell setAttributedTitle: finalString];
                        
                        //                        index++;
                        //
                        //                        {
                        //                            cell = [previewMatrix cellAtRow: index column:0];
                        //
                        //                            [cell setRepresentedObject:[O2ViewerThumbnailsMatrixRepresentedObject object:curStudy children: nil]];
                        //                            [cell setAction: @selector(matrixPreviewLoadAllSeries:)];
                        //                            xxxxxx
                        //                            NSMutableAttributedString *finalString = [[[NSMutableAttributedString alloc] initWithString: NSLocalizedString(@"All series", nil)] autorelease];
                        //
                        //                            NSMutableDictionary *attribs = [NSMutableDictionary dictionary];
                        //                            [attribs setObject: [NSFont boldSystemFontOfSize: [[BrowserController currentBrowser] fontSize: @"dbSmallMatrixFont"]] forKey: NSFontAttributeName];
                        //                            [finalString setAttributes: attribs range: NSMakeRange( 0, finalString.length)];
                        //
                        //                            [finalString setAlignment:NSTextAlignmentCenter range: NSMakeRange( 0, finalString.length)];
                        //                            [cell setAttributedTitle: finalString];
                        //                        }
                    }
                    @catch (NSException *exception) {
                        N2LogException( exception);
                    }
                    index++;
                }
                
#ifndef OSIRIX_LIGHT
                if ([curStudy isKindOfClass: [DCMTKQueryNode class]]) //Distant Study DCMTKQueryStudyNode
                {
                    @try
                    {
                        NSArray* local = [db objectsForEntity:db.studyEntity predicate:[NSPredicate predicateWithFormat:@"studyInstanceUID = %@ AND patientID = %@", [curStudy studyInstanceUID], [curStudy patientID]]];
                        if (local.count)
                            images = [[BrowserController currentBrowser] imagesArray:[local objectAtIndex:0] preferredObject: oAny];
                        
                        NSString *name = [[curStudy valueForKey:@"studyName"] stringByTruncatingToLength: 34];
                        if( name == nil)
                            name = @"";
                        NSString *stateText = @"";
                        NSString *comment = @"";
                        NSString *modality = [curStudy valueForKey:@"modality"];
                        if( modality == nil)
                            modality = @"OT";
                        
                        NSString *patName = @"";
                        
                        if( [curStudy valueForKey:@"name"] && [curStudy valueForKey:@"dateOfBirth"])
                            patName = [NSString stringWithFormat: @"%@\r%@", [curStudy valueForKey:@"name"], [NSUserDefaults formatDate:[curStudy valueForKey:@"dateOfBirth"]]];
                        
                        if( [[curStudy name] isEqualToString:study.name])
                            patName = @"";
                        if ([[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"] != annotFull)
                            patName = @"";
                        
                        if ([stateText length] == 0 && [comment length] == 0) {
                            NSMutableArray* components = [NSMutableArray array];
                            if (patName.length) [components addObject:patName];
                            if (name.length) [components addObject:name];
                            if ([curStudy date]) [components addObject:[[NSUserDefaults dateTimeFormatter] stringFromDate:[curStudy date]]];
                            if (modality.length) [components addObject:modality];
                            [cell setTitle:[components componentsJoinedByString:@"\r"]];
                        }
                        
                        switch( [[NSUserDefaults standardUserDefaults] integerForKey: @"dbFontSize"])
                        {
                            case -1:
                                [cell setImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 0.6]];
                                [cell setAlternateImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 0.6]];
                                break;
                            case 0:
                                [cell setImage: retrieveImage];
                                [cell setAlternateImage:retrieveImage];
                                break;
                            case 1:
                                [cell setImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 1.3]];
                                [cell setAlternateImage: [retrieveImage imageByScalingProportionallyUsingNSImage: 1.3]];
                                break;
                        }
                        
                        [cell setImagePosition:NSImageOverlaps];
                        [cell setImageScaling:NSImageScaleProportionallyDown];
                    }
                    @catch ( NSException *e) {
                        N2LogException( e);
                    }
                    index++;
                }
#endif
                
                if(![curStudy respondsToSelector:@selector(isHidden)] || [curStudy isHidden] == NO)
                {
                    for( i = 0; i < [series count]; i++)
                    {
                        DicomSeries* curSeries = [series objectAtIndex:i];
                        
                        NSButtonCell *cell = [previewMatrix cellAtRow: index column:0];
                        
                        if( [[curStudy valueForKey: @"studyInstanceUID"] isEqualToString: study.studyInstanceUID])
                            [cell setBackgroundColor: nil];
                        else
                            [cell setBackgroundColor: [[self class] _differentStudyColor]];
                        
                        [cell setRepresentedObject: [O2ViewerThumbnailsMatrixRepresentedObject object:curSeries]];
                        [cell setFont:[NSFont systemFontOfSize: [[BrowserController currentBrowser] fontSize: @"dbSmallMatrixFont"]]];
                        [cell setAction: @selector(matrixPreviewPressed:)];
                        [cell setLineBreakMode: NSLineBreakByCharWrapping];
                        
                        NSString *name = [curSeries valueForKey:@"name"];
                        
                        if( [name length] > 18)
                        {
                            [cell setFont:[NSFont boldSystemFontOfSize: [[BrowserController currentBrowser] fontSize: @"viewerSmallCellFont"]]];
                            name = [name stringByTruncatingToLength: 34];
                        }
                        
                        NSString *singleType = NSLocalizedString( @"Image", nil);
                        NSString *pluralType = NSLocalizedString( @"Images", nil);
                        int count = [[curSeries valueForKey:@"noFiles"] intValue];
                        if( count == 1)
                        {
                            @try
                            {
                                int frames = [[[[curSeries valueForKey:@"images"] anyObject] valueForKey:@"numberOfFrames"] intValue];
                                if( frames > 1)
                                {
                                    count = frames;
                                    pluralType = NSLocalizedString( @"Frames", @"Frames: for example, 50 Frames in a series");
                                }
                            }
                            @catch (NSException * e)
                            {
                                N2LogExceptionWithStackTrace(e);
                            }
                        }
                        else if (count == 0)
                        {
                            count = [[curSeries valueForKey: @"rawNoFiles"] intValue];
                            
                            int frames = [[[[curSeries valueForKey:@"images"] anyObject] valueForKey:@"numberOfFrames"] intValue];
                            
                            if( count == 1 && frames > 1)
                                count = frames;
                            
                            if( count == 1)
                                singleType = NSLocalizedString( @"Object", nil);
                            else
                                pluralType = NSLocalizedString( @"Objects", nil);
                        }
                        
                        if( name == nil)
                            name = @"";
                        
                        NSString *seriesDateText = curSeries.displayDate ? [NSUserDefaults formatDateTime:curSeries.displayDate] : @"";
                        [cell setTitle:[NSString stringWithFormat:@"%@\r%@\r%@", name, seriesDateText, N2LocalizedSingularPluralCount(count, singleType, pluralType)]];
                        
                        if( [viewerSeries containsObject: curSeries]) // Red
                        {
                            [cell setBackgroundColor:[[self class] _selectedItemColor]];
                        }
                        else if( [[self blendingController] currentSeries] == curSeries) // Green
                        {
                            [cell setBackgroundColor: [[self class] _fusionedItemColor]];
                        }
                        else if( [displayedSeries containsObject: curSeries]) // Yellow
                        {
                            [cell setBackgroundColor: [[self class] _openItemColor]];
                        }
                        
                        if( visible)
                        {
                            NSImage	*img = [[[NSImage alloc] initWithData: [curSeries primitiveValueForKey:@"thumbnail"]] autorelease];
                            
                            if( img == nil)
                            {
                                @try
                                {
                                    DCMPix* dcmPix = [[DCMPix alloc] initWithPath: [[images objectAtIndex: i] valueForKey:@"completePath"] :0 :0 :nil :0 :[[[images objectAtIndex: i] valueForKeyPath:@"series.id"] intValue] isBonjour:[[BrowserController currentBrowser] isCurrentDatabaseBonjour] imageObj:[images objectAtIndex: i]];
                                    
                                    [dcmPix CheckLoad];
                                    
                                    if (dcmPix && dcmPix.notAbleToLoadImage == NO)
                                    {
                                        img = [dcmPix generateThumbnailImageWithWW:0 WL:0];
                                        
                                        if (img)
                                        {
                                            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"StoreThumbnailsInDB"])
                                                curSeries.thumbnail = [BrowserController produceJPEGThumbnail:img];
                                        }
                                        else img = [NSImage imageNamed:@"FileNotFound.tif"];
                                        
                                    }
                                    else img = [NSImage imageNamed:@"FileNotFound.tif"];
                                    
                                    [dcmPix release];
                                }
                                @catch (NSException* e)
                                {
                                    N2LogExceptionWithStackTrace(e);
                                    img = [NSImage imageNamed:@"FileNotFound.tif"];
                                }
                            }
                            
                            if( DisplayUseInvertedPolarity)
                                img = [img imageInverted];
                            
                            switch( [[NSUserDefaults standardUserDefaults] integerForKey: @"dbFontSize"])
                            {
                                case -1:
                                    [cell setImage: [img imageByScalingProportionallyUsingNSImage: 0.6]];
                                    [cell setAlternateImage:[img imageByScalingProportionallyUsingNSImage: 0.6]];
                                    break;
                                case 0:
                                    [cell setImage: img];
                                    [cell setAlternateImage:img];
                                    break;
                                case 1:
                                    [cell setImage: [img imageByScalingProportionallyUsingNSImage: 1.3]];
                                    [cell setAlternateImage:[img imageByScalingProportionallyUsingNSImage: 1.3]];
                                    break;
                            }
                        }
                        
                        index++;
                    }
                }
                else // series are hidden : color the study cell if series are selected
                {
                    //   [cell setBordered: YES];
                    for( i = 0; i < [series count]; i++)
                    {
                        DicomSeries* curSeries = [series objectAtIndex:i];
                        
                        if( [viewerSeries containsObject: curSeries]) // Red
                        {
                            [cell setBackgroundColor:[[self class] _selectedItemColor]];
                            //[cell setBordered: NO];
                            break;
                        }
                        else if( [[self blendingController] currentSeries] == curSeries) // Green
                        {
                            [cell setBackgroundColor: [[self class] _fusionedItemColor]];
                            //[cell setBordered: NO];
                            break;
                        }
                        else if( [displayedSeries containsObject: curSeries]) // Yellow
                        {
                            [cell setBackgroundColor: [[self class] _openItemColor]];
                            //[cell setBordered: NO];
                            break;
                        }
                    }
                }
                
                
            }
        }
        
        [previewMatrix sizeToCells];
        
        if( showSelected)
        {
            NSInteger index = [[[previewMatrix cells] valueForKeyPath:@"representedObject.object"] indexOfObject: [[fileList[ curMovieIndex] objectAtIndex:0] valueForKey:@"series"]];
            
            if( index != NSNotFound)
                [previewMatrix scrollCellToVisibleAtRow: index column:0];
        }
        else
        {
            [[previewMatrixScrollView contentView] scrollToPoint: origin];
            [previewMatrixScrollView reflectScrolledClipView: [previewMatrixScrollView contentView]];
        }
        
        [previewMatrix setNeedsDisplay:YES];
    }
    @catch (NSException *e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    @finally {
        [comparativesButton setEnabled:hasComparatives];
        
        NSColor* color = [NSColor whiteColor];
        NSString* tip = @"";
        
        if( self.flagListPODComparatives.boolValue == NO)
        {
            comparativesButton.title = NSLocalizedString( @"Comparatives", nil);
            if (hasComparatives) {
                color = [[self class] _openItemColor]; // yellow
                tip = NSLocalizedString(@"There are PACS On-Demand comparatives", nil);
            }
            
            if (hasComparativesNewerThanMostRecentLoaded) {
                color = [[self class] _selectedItemColor]; // red
                tip = NSLocalizedString(@"There are more recent PACS On-Demand comparatives", nil);
            }
        }
        else
            comparativesButton.title = [NSString stringWithFormat: @"✓ %@", NSLocalizedString( @"Comparatives", nil)];
        
        if (hasComparatives)
        {
            if( tip.length)
                tip = [tip stringByAppendingString:@", "];
            
            if (self.flagListPODComparatives.boolValue)
                tip = [tip stringByAppendingString: NSLocalizedString( @"Click here to hide them", nil)];
            else
                tip = [tip stringByAppendingString: NSLocalizedString( @"Click here to show them", nil)];
        }
        NSMutableDictionary* attributes = [[[comparativesButton.attributedTitle attributesAtIndex:0 effectiveRange:NULL] mutableCopy] autorelease];
        [attributes setObject:color forKey:NSForegroundColorAttributeName];
        [comparativesButton setAttributedTitle:[[[NSAttributedString alloc] initWithString:comparativesButton.title attributes:attributes] autorelease]];
        [comparativesButton setToolTip:tip];
        
        BOOL showComparativesButton = NO;
        
#ifndef OSIRIX_LIGHT
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"searchForComparativeStudiesOnDICOMNodes"] && !self.database.isReadOnly && self.database.isLocal) {
            NSArray* servers = [BrowserController comparativeServers];
            if (servers.count)
                showComparativesButton = YES;
        }
#endif
        
        //        [[leftSplitView.subviews objectAtIndex:0] setHidden:!showComparativesButton];
        //        [self splitView:leftSplitView resizeSubviewsWithOldSize:leftSplitView.bounds.size];
    }
    
    for( DCMView *v in self.imageViews)
        [v computeColor];
    
    [self buildSeriesPopup];
    
    needsToBuildSeriesMatrix = NO;
}

- (void) matrixPreviewSelectCurrentSeries
{
    [self showCurrentThumbnail: self];
}

- (void) showCurrentThumbnail:(id) sender;
{
    NSInteger index = [[[previewMatrix cells] valueForKeyPath:@"representedObject.object"] indexOfObject: [[fileList[ curMovieIndex] objectAtIndex:0] valueForKey:@"series"]];
    
    if( index != NSNotFound)
        [previewMatrix scrollCellToVisibleAtRow: index column:0];
}

- (void) buildMatrixPreview
{
    [self buildMatrixPreview: YES];
}

- (void) updateRepresentedFileName
{
    NSString	*path = [[BrowserController currentBrowser] getLocalDCMPath:[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] : 0];
    [[self window] setRepresentedFilename: path];
}

- (BOOL)window:(NSWindow *)sender shouldPopUpDocumentPathMenu:(NSMenu *)titleMenu
{
    [self updateRepresentedFileName];
    
    return YES;
}

#ifndef OSIRIX_LIGHT
- (void) viewXML:(id) sender
{
    [self checkEverythingLoaded];
    
    NSString	*path = [[BrowserController currentBrowser] getLocalDCMPath:[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] : 0];
    [[self window] setRepresentedFilename: path];
    
    DicomImage *im = [fileList[curMovieIndex] objectAtIndex:[imageView curImage]];
    
    if( [XMLController windowForViewer: self])
        [[[XMLController windowForViewer: self] window] makeKeyAndOrderFront: self];
    else
    {
        XMLController * xmlController = [[XMLController alloc] initWithImage: im windowName:[NSString stringWithFormat: NSLocalizedString( @"Meta-Data: %@", nil), [[self window] title]] viewer: self];
        [[xmlController window] setAlphaValue: 0.01];
        
        [[AppController sharedAppController] tileWindows: nil];
        
        for( int i = 0; i < 15 ; i++)
        {
            [[xmlController window] setAlphaValue: (i+1.0) / 15.];
            [NSThread sleepForTimeInterval: 0.03];
        }
        
        [[self window] makeKeyAndOrderFront: self];
    }
}
#endif

#pragma mark-
#pragma mark 3. mouse management

static ViewerController *draggedController = nil;

- (void) completeDragOperation:(ViewerController*) vc
{
    // First reset all controls
    NSView* blendingTypeContent = [blendingTypeWindow contentView];
    for (NSView* view in [blendingTypeContent subviews])
    {
        if ([view isKindOfClass:[NSControl class]])
        {
            NSControl* control = (NSControl*) view;
            [control setEnabled:YES];
        }
    }
    
    int iz, xz;
    
    if( [[[vc imageView] curDCM] pwidth] != [[imageView curDCM] pwidth] ||
       [[[vc imageView] curDCM] pheight] != [[imageView curDCM] pheight])
    {
        [blendingTypeMultiply setEnabled: NO];
        [blendingTypeSubtract setEnabled: NO];
        [blendingTypeRGB setEnabled: NO];
    }
    
    if( [[[vc pixList] objectAtIndex: 0] isRGB])
        [blendingTypeRGB setEnabled: NO];
    
    if( [[self studyInstanceUID] isEqualToString: [vc studyInstanceUID]] == NO)
        [blendingResample setEnabled: NO];
    
    // Prepare fusion plug-ins menu
    for( iz = 0; iz < [[PluginManager fusionPluginsMenu] numberOfItems]; iz++)
    {
        [[[PluginManager fusionPluginsMenu] itemAtIndex:iz] setTag: -iz];
        
        if( [[[PluginManager fusionPluginsMenu] itemAtIndex:iz] hasSubmenu])
        {
            NSMenu  *subMenu = [[[PluginManager fusionPluginsMenu] itemAtIndex:iz] submenu];
            
            for( xz = 0; xz < [subMenu numberOfItems]; xz++)
            {
                [[subMenu itemAtIndex:xz] setTag: -iz];
                [[subMenu itemAtIndex:xz] setTarget:self];
                [[subMenu itemAtIndex:xz] setAction:@selector(endBlendingType:)];
            }
        }
        else
        {
            [[[PluginManager fusionPluginsMenu] itemAtIndex:iz] setTarget:self];
            [[[PluginManager fusionPluginsMenu] itemAtIndex:iz] setAction:@selector(endBlendingType:)];
        }
    }
    [blendingPlugins setMenu: [PluginManager fusionPluginsMenu]];
    
    [blendedWindow release];
    blendedWindow = [vc retain];
    
    // What type of blending?
    [[self window] beginSheet:blendingTypeWindow completionHandler:^(NSModalResponse returnCode) {
        [self blendingSheetDidEnd:blendingTypeWindow returnCode:(int)returnCode contextInfo:nil];
    }];
    
    draggedController = nil;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    NSPasteboard	*paste = [sender draggingPasteboard];
    long			i;
    
    if ([paste availableTypeFromArray:DCMView.PasteboardTypes])
    {
        DCMView	*vi = [sender draggingSource];
        
        if ([[[vi window] windowController] is2DViewer] == YES)
        {
            if ([[[[vi window] windowController] blendingController] isEqual:self])
                return NO;
            if( [[vi window] windowController] != self) [self completeDragOperation: [[vi window] windowController]];
        }
    }
	else if ([paste availableTypeFromArray:DCMView.PluginPasteboardTypes])
    {
        // in this case, the drag operation was performed from a plugin.
        id source = [sender draggingSource];
        
        NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithCapacity:2];
        [userInfo setValue:self forKey:@"destination"]; // should not be used anymore, as [notification object] is the same (was NULL)
        [userInfo setValue:sender forKey:@"dragOperation"]; // should use key "NSDraggingInfo"
        [userInfo setValue:sender forKey:@"id<NSDraggingInfo>"];
        [[NSNotificationCenter defaultCenter] postNotificationName:OsirixPerformDragOperationNotification object:self userInfo:userInfo];
        
        if ([source respondsToSelector:@selector(performPluginDragOperation:destination:)]) {
            return [source performPluginDragOperation:sender destination:self];
        }
    }
    else if ([paste availableTypeFromArray:BrowserController.DatabaseObjectXIDsPasteboardTypes])
    {
        NSArray* xids = [NSPropertyListSerialization propertyListWithData:[paste propertyListForType:[paste availableTypeFromArray:BrowserController.DatabaseObjectXIDsPasteboardTypes]]
                                                         options:NSPropertyListImmutable
                                                                   format:NULL
                                                                    error:NULL];
        NSMutableArray* items = [NSMutableArray array];
        for (NSString* xid in xids)
            [items addObject:[BrowserController.currentBrowser.database objectWithID:[NSManagedObject UidForXid:xid]]];
        
        if( [[items lastObject] isKindOfClass: [DicomSeries class]])
        {
            [self.window makeKeyAndOrderFront: self];
            [self loadSelectedSeries: [items lastObject] rightClick: NO];
        }
    }
    else
    {
        NSArray			*types = [NSArray arrayWithObjects:@"NSFilenamesPboardType", nil];
        NSString		*desiredType = [paste availableTypeFromArray:types];
        NSData			*carriedData = nil;
        
        if( desiredType) carriedData = [paste dataForType: desiredType];
        
        if (nil == carriedData)
        {
            //			//the operation failed for some reason
            //			HorosRunAlertPanel(NSLocalizedString(@"Paste Error", nil), NSLocalizedString(@"Sorry, but the past operation failed", nil), nil, nil, nil);
            return NO;
        }
        else
        {
            //the pasteboard was able to give us some meaningful data
            if ([desiredType isEqualToString:@"NSFilenamesPboardType"])
            {
                //we have a list of file names in an NSData object
                NSArray				*fileArray = [paste propertyListForType:@"NSFilenamesPboardType"];
                
                // Find a 2D viewer containing this specific file!
                
                NSArray				*winList = [NSApp windows];
                BOOL				found = NO;
                
                for( i = 0; i < [winList count] && found == NO; i++)
                {
                    if( [[[winList objectAtIndex:i] windowController] isKindOfClass:[ViewerController class]])
                    {
                        //						for( z = 0; z < [[[winList objectAtIndex:i] windowController] maxMovieIndex]; z++)
                        //						{
                        //							NSMutableArray  *pList = [[[winList objectAtIndex:i] windowController] pixList: z];
                        //
                        //							for( x = 0; x < [pList count]; x++)
                        //							{
                        //								if([[[pList objectAtIndex: x] sourceFile] isEqualToString: draggedFile])
                        //								{
                        if( found == NO)
                        {
                            if( [[winList objectAtIndex:i] windowController] == draggedController && draggedController != self)
                            {
                                [self completeDragOperation: [[winList objectAtIndex:i] windowController]];
                                found = YES;
                            }
                            else if( draggedController == self)
                            {
                                //											NSLog(@"Myself => Cancel fusion if previous one!");
                                [self ActivateBlending: nil];
                            }
                        }
                        //								}
                        //							}
                        //						}
                    }
                }
                
                if( found == NO)
                {
                    //Is it an image? -> Create a layer ROI
                    
                    NSMutableArray *roiFiles = [NSMutableArray array];
                    for( NSString *file in fileArray)
                    {
                        NSString *extension = file.pathExtension.lowercaseString;
                        if( [extension isEqualToString:@"roi"])
                        {
                            [roiFiles addObject: file];
                        }
                        else if( [extension isEqualToString:@"rois_series"] || [extension isEqualToString:@"json"])
                        {
                            [self roiLoadFromSeries: file];
                        }
                        else
                        {
                            NSImage *im = [[NSImage alloc] initWithContentsOfFile: file];
                            if( im)
                            {
                                ROI* theNewROI = [self addLayerRoiToCurrentSliceWithImage: im referenceFilePath:@"none" layerPixelSpacingX:[[imageView curDCM] pixelSpacingX] layerPixelSpacingY:[[imageView curDCM] pixelSpacingY]];
                                
                                [theNewROI setName: [file lastPathComponent]];
                                [theNewROI setIsLayerOpacityConstant: YES];
                                [theNewROI setCanColorizeLayer: NO];
                                [theNewROI setCanResizeLayer: YES];
                                
                                NSRect r = {[NSEvent mouseLocation], NSZeroSize};
                                NSPoint eventLocation = [self.window convertRectFromScreen:r].origin;
                                eventLocation = [imageView convertPoint:eventLocation fromView:nil];
                                NSPoint imageLocation = [imageView ConvertFromNSView2GL:eventLocation];
                                
                                NSPoint centroid = [theNewROI centroid];
                                NSPoint offset;
                                
                                offset.x = imageLocation.x - centroid.x;
                                offset.y = imageLocation.y - centroid.y;
                                
                                NSArray *newROIPoints = [theNewROI points];
                                for ( MyPoint *p in newROIPoints)
                                    [p move:offset.x :offset.y];
                                
                                [im release];
                                
                                [self selectROI:theNewROI deselectingOther:YES];
                            }
                        }
                    }
                    if( roiFiles.count)
                    {
                        NSError *error = nil;
                        if( [self importROIFiles: roiFiles error: &error] == NO)
                            [self presentROIImportErrorForPath: [roiFiles lastObject] error: error];
                    }
                }
            }
            else
            {
                //this can't happen
                NSAssert(NO, @"This can't happen");
                return NO;
            }
        }
    }
    
    draggedController = nil;
    
    return YES;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    if( draggedController == nil)
    {
        draggedController = self;
        NSLog(@"catched");
    }
    
    if ((NSDragOperationGeneric & [sender draggingSourceOperationMask]) == NSDragOperationGeneric)
    {
        //this means that the sender is offering the type of operation we want
        //return that we want the NSDragOperationGeneric operation that they
        //are offering
        return NSDragOperationGeneric;
    }
    else
    {
        //since they aren't offering the type of operation we want, we have
        //to tell them we aren't interested
        return NSDragOperationNone;
    }
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
    NSLog(@"exited");
    
    //we aren't particularily interested in this so we will do nothing
    //this is one of the methods that we do not have to implement
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    if ((NSDragOperationGeneric & [sender draggingSourceOperationMask]) == NSDragOperationGeneric)
    {
        //this means that the sender is offering the type of operation we want
        //return that we want the NSDragOperationGeneric operation that they
        //are offering
        return NSDragOperationGeneric;
    }
    else
    {
        //since they aren't offering the type of operation we want, we have
        //to tell them we aren't interested
        return NSDragOperationNone;
    }
}

- (void)draggingEnded:(id <NSDraggingInfo>)sender
{
    //we don't do anything in our implementation
    //this could be ommitted since NSDraggingDestination is an infomal
    //protocol and returns nothing
    NSLog(@"draggingEnded");
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
    NSLog(@"prepareForDragOperation");
    return YES;
}

- (void) keyDown:(NSEvent *)event
{
    if( [[event characters] length] == 0) return;
    
    unichar c = [[event characters] characterAtIndex:0];
    
    if( c == 3 || c == 13 || c == ' ')
    {
        [self PlayStop:[self findPlayStopButton]];
    }
    else if((c >='1' && c <= '7') | (c >='a' && c <= 'g'))		// SHUTTLE PRO
    {
        if( !timer)  [self PlayStop:[self findPlayStopButton]];  // PLAY
        
        NSLog( @"%@", [event characters]);
        
        if( (c >='a' && c <= 'g')) {c -= 'a' -1;	direction = -1;}
        if( (c >='1' && c <= '7')) {c -= '1' -1;	direction = 1;}
        
        switch( c)
        {
            case 1:   [speedSlider setFloatValue:2];		break;
            case 2:   [speedSlider setFloatValue:5];		break;
            case 3:   [speedSlider setFloatValue:10];		break;
            case 4:   [speedSlider setFloatValue:15];		break;
            case 5:   [speedSlider setFloatValue:25];		break;
            case 6:   [speedSlider setFloatValue:30];		break;
            case 7:   [speedSlider setFloatValue:60];		break;
        }
        
        [self speedSliderAction:self];
    }
    else if( c == '0')
    {
        if( timer)
            [self PlayStop:[self findPlayStopButton]];  // STOP
    }
    
    else if (c == NSUpArrowFunctionKey)
    {
        if( maxMovieIndex > 1)
        {
            curMovieIndex --;
            if( curMovieIndex < 0) curMovieIndex = maxMovieIndex-1;
            
            [self setMovieIndex: curMovieIndex];
        }
        else [super keyDown:event];
    }
    else if(c ==  NSDownArrowFunctionKey)
    {
        if( maxMovieIndex > 1)
        {
            curMovieIndex ++;
            if( curMovieIndex >= maxMovieIndex) curMovieIndex = 0;
            
            [self setMovieIndex: curMovieIndex];
        }
        else [super keyDown:event];
    }
    else if (c == NSLeftArrowFunctionKey && ([event modifierFlags] & NSEventModifierFlagCommand))
    {
        [[BrowserController currentBrowser] loadNextSeries:[fileList[0] objectAtIndex:0] : -1 :self :YES keyImagesOnly: displayOnlyKeyImages];
    }
    else if (c == NSRightArrowFunctionKey && ([event modifierFlags] & NSEventModifierFlagCommand))
    {
        [[BrowserController currentBrowser] loadNextSeries:[fileList[0] objectAtIndex:0] : 1 :self :YES keyImagesOnly: displayOnlyKeyImages];
    }
    else
    {
        [super keyDown:event];
    }
}

- (float) highLighted
{
    return highLighted;
}

- (void) highLightTimerFunction:(NSTimer*)theTimer
{
    highLighted -= 0.05;
    for( DCMView * v in [seriesView imageViews])
        [v setNeedsDisplay: YES];
    
    if( highLighted <= 0.0)
    {
        [highLightedTimer invalidate];
        [highLightedTimer release];
        highLightedTimer = nil;
    }
}

- (void) setHighLighted: (float) b
{
    if( b != highLighted)
    {
        highLighted = b;
        
        for( DCMView * v in [seriesView imageViews])
            [v setNeedsDisplay: YES];
        
        if( b == 1.0)
        {
            [highLightedTimer invalidate];
            [highLightedTimer release];
            
            highLightedTimer = [[NSTimer scheduledTimerWithTimeInterval:0.02 target:self selector:@selector(highLightTimerFunction:) userInfo:0 repeats: YES] retain];
            [[NSRunLoop currentRunLoop] addTimer: highLightedTimer forMode:NSModalPanelRunLoopMode];
            [[NSRunLoop currentRunLoop] addTimer: highLightedTimer forMode:NSEventTrackingRunLoopMode];
        }
    }
}

- (void)mouseMoved:(NSEvent *)theEvent {
    [self mouseMoved];
}

- (void)mouseMoved
{
    if( ![[self window] isVisible] && ![self FullScreenON])
        return;
    
    if( windowWillClose) return;
    
    [self autoHideMatrix];
}

- (IBAction) setCurrentPosition:(id) sender
{
    if( [sender tag] == 0)
    {
        if( [imageView flippedData])
        {
            [dcmFrom setIntValue: [pixList[ curMovieIndex] count] - [imageView curImage]];
            [quicktimeFrom setIntValue:  [pixList[ curMovieIndex] count] - [imageView curImage]];
        }
        else
        {
            [dcmFrom setIntValue: [imageView curImage]+1];
            [quicktimeFrom setIntValue: [imageView curImage]+1];
        }
    }
    else
    {
        if( [imageView flippedData])
        {
            [dcmTo setIntValue:  [pixList[ curMovieIndex] count] - [imageView curImage]];
            [quicktimeTo setIntValue:  [pixList[ curMovieIndex] count] - [imageView curImage]];
        }
        else
        {
            [dcmTo setIntValue: [imageView curImage]+1];
            [quicktimeTo setIntValue: [imageView curImage]+1];
        }
    }
    
    [dcmFrom performClick: self];	// Will update the text field
    [dcmTo performClick: self];	// Will update the text field
    [dcmInterval performClick: self];	// Will update the text field
    [quicktimeFrom performClick: self];	// Will update the text field
    [quicktimeTo performClick: self];	// Will update the text field
    [quicktimeInterval performClick: self];	// Will update the text field
}

// functions s that plugins can also play with globals
+ (ViewerController *) draggedController
{
    return draggedController;
}

+ (void) setDraggedController:(ViewerController *) controller
{
    draggedController = controller;
}

#pragma mark-
#pragma mark 4. toolbox space

- (IBAction)customizeViewerToolBar:(id)sender
{
    [toolbar runCustomizationPalette:sender];
}

- (IBAction) switchCobbAngle:(id) sender
{
    [[NSUserDefaults standardUserDefaults] setBool: ![[NSUserDefaults standardUserDefaults] boolForKey: @"displayCobbAngle"] forKey: @"displayCobbAngle"];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"ROITEXTIFSELECTED"] == YES && [[NSUserDefaults standardUserDefaults] boolForKey: @"displayCobbAngle"] == YES)
        [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"ROITEXTIFSELECTED"]; // To display the Cobbs value -> show all ROIs information
}

#pragma mark - NSToolbarDelegate
// The methods of this block are implemented in Swift since #832
// (ViewerController+Toolbar.swift), with the same selectors.

#pragma mark-
#pragma mark 4.1. single viewport

- (BOOL) isDataVolumic
{
    return [self isDataVolumicIn4D: NO checkEverythingLoaded: YES tryToCorrect: YES];
}

- (BOOL) isDataVolumicIn4D: (BOOL) check4D checkEverythingLoaded:(BOOL) c;
{
    return [self isDataVolumicIn4D: check4D checkEverythingLoaded: c tryToCorrect: YES];
}

- (BOOL) isDataVolumicIn4D: (BOOL) check4D checkEverythingLoaded:(BOOL) c tryToCorrect: (BOOL) tryToCorrect
{
    BOOL volumicData = YES;
    BOOL firstImage = NO, lastImage = NO;
    
    if( c == NO)
    {
        @synchronized( loadingThread)
        {
            if( loadingThread)
            {
                if( (!loadingThread.isExecuting) == NO)
                    return NO;
            }
        }
    }
    
    [self checkEverythingLoaded];
    
    isDataVolumicIn4DLevel++;
    
    @try
    {
        for( int x = 0 ; x < maxMovieIndex ; x++)
        {
            if( check4D == YES || x == curMovieIndex)
            {
                if( [pixList[ x] count] > 4)
                {
                    float orientation[ 9];
                    
                    [[pixList[ x] objectAtIndex: 1] orientation: orientation];
                    
                    int pw = [[[fileList[ x] objectAtIndex: [pixList[ x] count]/2] valueForKey: @"width"] intValue];
                    int ph = [[[fileList[ x] objectAtIndex: [pixList[ x] count]/2] valueForKey: @"height"] intValue];
                    int firstWrongImage = -1;
                    int numberOfNonVolumicImages = 0;
                    
                    // Check for non continuous matrix
                    for( int j = 0 ; j < [pixList[ x] count]; j++)
                    {
                        if( pw != [[[fileList[ x] objectAtIndex: j] valueForKey: @"width"] intValue] || ph != [[[fileList[ x] objectAtIndex: j] valueForKey: @"height"] intValue])
                        {
                            volumicData = NO;
                            numberOfNonVolumicImages++;
                            
                            if( firstWrongImage == -1)
                                firstWrongImage = j;
                        }
                    }
                    
                    if( tryToCorrect && numberOfNonVolumicImages == 1 && (firstWrongImage == 0 || firstWrongImage == (long)[pixList[ x] count]-1)) // First or last image with different matrix
                    {
                        NSMutableArray *newFileList = [NSMutableArray array];
                        NSMutableArray *newPixList = [NSMutableArray array];
                        
                        long newSize = pw * ph * ((long)[pixList[ x] count]-1) * sizeof( float);
                        
                        float *newPtr = (float*) malloc( newSize);
                        if( newPtr)
                        {
                            NSData *newVolumeData = [NSData dataWithBytesNoCopy: newPtr length: newSize freeWhenDone: YES];
                            
                            for( int n = 0; n < [pixList[ x] count]; n++)
                            {
                                if( firstWrongImage != n)
                                {
                                    DCMPix *newPix = [[[pixList[ x] objectAtIndex: n] copy] autorelease];
                                    
                                    memcpy( newPtr, [newPix fImage], pw * ph * sizeof( float));
                                    
                                    [newPix setfImage: newPtr];
                                    newPtr += pw * ph;
                                    
                                    [newPixList addObject: newPix];
                                    [newFileList addObject: [fileList[ x] objectAtIndex: n]];
                                }
                            }
                            
                            [self changeImageData: newPixList :newFileList :newVolumeData :NO];
                            
                            [self computeInterval];
                            [self setWindowTitle:self];
                            
                            [imageView setIndex: 0];
                            [imageView sendSyncMessage: 0];
                            
                            [self adjustSlider];
                            
                            postprocessed = YES;
                        }
                    }
                    
                    [[pixList[ x] objectAtIndex: 1] orientation: orientation];
                    
                    pw = [[[fileList[ x] objectAtIndex: [pixList[ x] count]/2] valueForKey: @"width"] intValue];
                    ph = [[[fileList[ x] objectAtIndex: [pixList[ x] count]/2] valueForKey: @"height"] intValue];
                    firstWrongImage = -1;
                    numberOfNonVolumicImages = 0;
                    
                    // Check for non same orientation
                    for( int j = 0 ; j < [pixList[ x] count]; j++)
                    {
                        if( pw != [[[fileList[ x] objectAtIndex: j] valueForKey: @"width"] intValue] || ph != [[[fileList[ x] objectAtIndex: j] valueForKey: @"height"] intValue])
                        {
                            volumicData = NO;
                        }
                        
                        if( volumicData)
                        {
                            float o[ 9];
                            [[pixList[ x] objectAtIndex: j] orientation: o];
                            for( int k = 0 ; k < 9; k++)
                            {
                                if( fabs( o[ k] - orientation[ k]) > ORIENTATION_SENSIBILITY)
                                {
                                    volumicData = NO;
                                    
                                    if( j == 0)
                                        firstImage = YES;
                                    
                                    if( j == (long)[pixList[ x] count] -1)
                                        lastImage = YES;
                                }
                            }
                        }
                    }
                }
                else volumicData = NO;
            }
        }
        
        if( volumicData == NO && (firstImage == YES || lastImage == YES))
        {
            if( firstImage)
            {
                for( int x = 0 ; x < maxMovieIndex ; x++)
                {
                    if( check4D == YES || x == curMovieIndex)
                    {
                        // Correct origin
                        float originA[ 3];
                        [[pixList[ x] objectAtIndex: 2] origin: originA];
                        float originB[ 3];
                        [[pixList[ x] objectAtIndex: 1] origin: originB];
                        
                        DCMPix *pix = [pixList[ x] objectAtIndex: 0];
                        
                        float savedOrigin[ 3];
                        [pix origin: savedOrigin];
                        
                        originB[ 0] -= originA[ 0] - originB[ 0];
                        originB[ 1] -= originA[ 1] - originB[ 1];
                        originB[ 2] -= originA[ 2] - originB[ 2];
                        
                        [pix setOrigin: originB];
                        
                        // Correct orientation
                        float orientation[ 9];
                        [[pixList[ x] objectAtIndex: 1] orientation: orientation];
                        
                        float savedOrientation[ 9];
                        [pix orientation: savedOrientation];
                        
                        [pix setOrientation: orientation];
                        
                        BOOL r = NO;
                        
                        if( isDataVolumicIn4DLevel < 4)
                            r = [self isDataVolumicIn4D: check4D checkEverythingLoaded: c tryToCorrect: NO];
                        
                        if( r && tryToCorrect)
                        {
                            if( [pix isRGB] == NO)
                            {
                                // Set this image to maxValueOfSeries, to find the true minValueOfSeries
                                float m = [pix maxValueOfSeries];
                                float *ptr = [pix fImage];
                                int z = [pix pwidth]*[pix pheight];
                                while( z-- > 0)
                                    *ptr++ = m;
                                
                                [pix computePixMinPixMax];
                                
                                // Then recompute minValueOfSeries
                                for( DCMPix *p in pixList[ x])
                                    p.minValueOfSeries = 0;
                                for( DCMPix *p in pixList[ x])
                                    [p minValueOfSeries];
                                
                                m = [pix minValueOfSeries];
                                ptr = [pix fImage];
                                z = [pix pwidth]*[pix pheight];
                                while( z-- > 0)
                                    *ptr++ = m;
                                
                                // Then recompute maxValueOfSeries
                                for( DCMPix *p in pixList[ x])
                                    p.maxValueOfSeries = 0;
                                
                                for( DCMPix *p in pixList[ x])
                                    [p maxValueOfSeries];
                                
                                [pix kill8bitsImage];
                                [self refresh];
                                [imageView setNeedsDisplay: YES];
                            }
                            else
                            {
                                unsigned char *ptr = (unsigned char*) [pix fImage];
                                int z = [pix pwidth]*[pix pheight]*4;
                                while( z-- > 0)
                                    *ptr++ = 0;
                                
                                [pix kill8bitsImage];
                                [self refresh];
                                [imageView setNeedsDisplay: YES];
                            }
                            
                            DCMPix *otherPix = [pixList[ x] objectAtIndex: 2];
                            [pix setPixelSpacingX: [otherPix pixelSpacingX]];
                            [pix setPixelSpacingY: [otherPix pixelSpacingY]];
                        }
                        else
                        {
                            [pix setOrigin: savedOrigin];
                            [pix setOrientation: savedOrientation];
                        }
                        
                        isDataVolumicIn4DLevel--;
                        return r;
                    }
                }
            }
            
            if( lastImage)
            {
                for( int x = 0 ; x < maxMovieIndex ; x++)
                {
                    if( check4D == YES || x == curMovieIndex)
                    {
                        // Correct origin
                        float originA[ 3];
                        [[pixList[ x] objectAtIndex: [pixList[ x] count]-2] origin: originA];
                        float originB[ 3];
                        [[pixList[ x] objectAtIndex: [pixList[ x] count]-3] origin: originB];
                        
                        DCMPix *pix = [pixList[ x] lastObject];
                        
                        float savedOrigin[ 3];
                        [pix origin: savedOrigin];
                        
                        originA[ 0] += originA[ 0] - originB[ 0];
                        originA[ 1] += originA[ 1] - originB[ 1];
                        originA[ 2] += originA[ 2] - originB[ 2];
                        
                        [pix setOrigin: originA];
                        
                        // Correct orientation
                        float orientation[ 9];
                        [[pixList[ x] objectAtIndex: 1] orientation: orientation];
                        
                        float savedOrientation[ 9];
                        [pix orientation: savedOrientation];
                        
                        [pix setOrientation: orientation];
                        
                        BOOL r = NO;
                        if( isDataVolumicIn4DLevel < 4)
                            r = [self isDataVolumicIn4D: check4D checkEverythingLoaded: c tryToCorrect: NO];
                        
                        if( r && tryToCorrect)
                        {
                            if( [pix isRGB] == NO)
                            {
                                // Set this image to maxValueOfSeries, to find the true minValueOfSeries
                                float m = [pix maxValueOfSeries];
                                float *ptr = [pix fImage];
                                int z = [pix pwidth]*[pix pheight];
                                while( z-- > 0)
                                    *ptr++ = m;
                                
                                [pix computePixMinPixMax];
                                
                                // Then recompute minValueOfSeries
                                for( DCMPix *p in pixList[ x])
                                    p.minValueOfSeries = 0;
                                for( DCMPix *p in pixList[ x])
                                    [p minValueOfSeries];
                                
                                m = [pix minValueOfSeries];
                                ptr = [pix fImage];
                                z = [pix pwidth]*[pix pheight];
                                while( z-- > 0)
                                    *ptr++ = m;
                                
                                // Then recompute maxValueOfSeries
                                for( DCMPix *p in pixList[ x])
                                    p.maxValueOfSeries = 0;
                                
                                for( DCMPix *p in pixList[ x])
                                    [p maxValueOfSeries];
                                
                                [pix kill8bitsImage];
                                [self refresh];
                                [imageView setNeedsDisplay: YES];
                            }
                            else
                            {
                                unsigned char *ptr = (unsigned char*) [pix fImage];
                                int z = [pix pwidth]*[pix pheight]*4;
                                while( z-- > 0)
                                    *ptr++ = 0;
                                
                                [pix kill8bitsImage];
                                [self refresh];
                                [imageView setNeedsDisplay: YES];
                            }
                            
                            DCMPix *otherPix = [pixList[ x] objectAtIndex: [pixList[ x] count]-3];
                            [pix setPixelSpacingX: [otherPix pixelSpacingX]];
                            [pix setPixelSpacingY: [otherPix pixelSpacingY]];
                        }
                        else
                        {
                            [pix setOrigin: savedOrigin];
                            [pix setOrientation: savedOrientation];
                        }
                        
                        isDataVolumicIn4DLevel--;
                        return r;
                    }
                }
            }
        }
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    isDataVolumicIn4DLevel--;
    return volumicData;
}

- (BOOL) isDataVolumicIn4D: (BOOL) check4D
{
    return [self isDataVolumicIn4D: check4D checkEverythingLoaded: YES];
}

- (id) initWithPix:(NSMutableArray*)f withFiles:(NSMutableArray*)d withVolume:(NSData*) v
{
#ifdef WITH_IMPORTANT_NOTICE
    [AppController displayImportantNotice: self];
#endif
    
    //	*(long*)0 = 0xDEADBEEF; // ILCrashReporter test -- DO NOT ACTIVATE THIS LINE
    
    DicomImage* dicomImage = [d objectAtIndex:0];
    self.database = [DicomDatabase databaseForContext:dicomImage.managedObjectContext];
    
    [self setMagnetic: YES];
    
    if( [d count] == 0) d = nil;
    
    [[NSUserDefaults standardUserDefaults] setObject: [NSString stringWithFormat: @"%d%d", 1, 1] forKey: @"LastWindowsTilingRowsColumns"];
    
    self = [super initWithWindowNibName:@"Viewer"];
    
    retainedToolbarItems = [[NSMutableArray alloc] initWithCapacity: 0];
    
    [self setupToolbar];
    
    [ROI loadDefaultSettings];
    
    resampleRatio = 1.0;
    
    [imageView setDrawing: NO];
    
    processorsLock = [[NSConditionLock alloc] initWithCondition: 1];
    
    undoQueue = [[NSMutableArray alloc] initWithCapacity: 0];
    redoQueue = [[NSMutableArray alloc] initWithCapacity: 0];
    
    [self viewerControllerInit];
    [self changeImageData:f :d :v :YES];
    
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver: self
           selector: @selector(updateImageView:)
               name: OsirixDCMUpdateCurrentImageNotification
             object: nil];
    
    [seriesView setPixels:pixList[0] files:fileList[0] rois:roiList[0] firstImage:0 level:'i' reset:YES];	//[pixList[0] count]/2
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"RestoreLeftMouseTool"])
    {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:[[NSUserDefaults standardUserDefaults] integerForKey: @"DEFAULTLEFTTOOL"]], @"toolIndex", nil];
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixDefaultToolModifiedNotification object:nil userInfo: userInfo];
    }
    
    displayOnlyKeyImages = NO;
    
    //	[[IMService notificationCenter] addObserver:self selector:@selector(_stateChanged:) name:IMAVManagerStateChangedNotification object:nil];
    //	[[IMAVManager sharedAVManager] setVideoDataSource:imageView];
    //	[[IMAVManager sharedAVManager] setVideoOptimizationOptions:IMVideoOptimizationStills];
    
    [imageView setDrawing: YES];
    
    [self SetSyncButtonBehavior: self];
    // why turn off sync? let's try making this new window sync with the old ones...
    bool wedidsomethingsmart = NO;
    if (SYNCSERIES) {
        // find other viewer of same study
        ViewerController* samestudyviewer = nil;
        for (ViewerController* iv in [ViewerController getDisplayed2DViewers])
            if (iv != self && [iv.studyInstanceUID isEqualToString:self.studyInstanceUID]) {
                samestudyviewer = iv;
                break;
            }
        if (samestudyviewer) {
            [imageView setSyncRelativeDiff:[[samestudyviewer imageView] syncRelativeDiff]];
            [[self findSyncSeriesButton] setImage: [NSImage toolbarImageNamed: @"SyncLock.pdf"]];
            [imageView setSyncSeriesIndex: 0];
            wedidsomethingsmart = YES;
        }
    }
    if (!wedidsomethingsmart)
        [self turnOffSyncSeriesBetweenStudies: self]; // keep the old behavior
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey:@"AUTOMATIC FUSE"])
        [self blendWindows: nil];
    
    [OpacityPopup setEnabled:YES];
    
    if([AppController canDisplay12Bit]) t12BitTimer = [[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(verify12Bit:) userInfo:nil repeats:YES] retain];
    else t12BitTimer = nil;
    
    [self willChangeValueForKey: @"KeyImageCounter"];
    [self didChangeValueForKey: @"KeyImageCounter"];
    
#ifndef OSIRIX_LIGHT
    [[OSIEnvironment sharedEnvironment] addViewerController:self];
#endif
    
    toolbarPanel = [[ToolbarPanelController alloc] initForViewer: self withToolbar: toolbar];
    
    return self;
}

-(void)awakeFromNib
{
    [speedSlider setAccessibilityLabel:NSLocalizedString(@"Slice cine speed", nil)];
    [speedSlider setAccessibilityHelp:NSLocalizedString(@"Slices per second within the current series. Independent of the 4D phase rate.", nil)];
    [speedSlider setToolTip:speedSlider.accessibilityHelp];
    [speedText setAccessibilityLabel:NSLocalizedString(@"Slice cine rate and direction", nil)];
    [movieRateSlider setAccessibilityLabel:NSLocalizedString(@"4D phase speed", nil)];
    [movieRateSlider setAccessibilityHelp:NSLocalizedString(@"Temporal phases per second. Independent of the slice cine rate.", nil)];
    [movieRateSlider setToolTip:movieRateSlider.accessibilityHelp];
    [movieTextSlide setAccessibilityLabel:NSLocalizedString(@"4D phase rate", nil)];
    // The control A224 is about had no label at all, while its two neighbours did.
    [moviePlayStop setAccessibilityLabel:NSLocalizedString(@"Play 4D phases", nil)];
    [moviePlayStop setAccessibilityHelp:NSLocalizedString(@"Plays through the temporal phases of this series. Off for a series with a single time.", nil)];
    [moviePlayStop setToolTip:moviePlayStop.accessibilityHelp];
    [moviePosSlider setAccessibilityLabel:NSLocalizedString(@"4D phase", nil)];
    [moviePosSlider setAccessibilityHelp:NSLocalizedString(@"Which temporal phase is shown. Off for a series with a single time.", nil)];
    [moviePosSlider setToolTip:moviePosSlider.accessibilityHelp];

    /*
    NSButton* zoomButton = [[self window] standardWindowButton:NSWindowZoomButton];
    [zoomButton setTarget:[self window]];
    [zoomButton setAction:@selector(zoom:)];
    */
     
    DisplayUseInvertedPolarity = [[[[NSUserDefaults standardUserDefaults] persistentDomainForName: @"com.apple.CoreGraphics"] objectForKey: @"DisplayUseInvertedPolarity"] boolValue];
    
    // Keep a dock in both modes. ThumbnailsListPanel may borrow its scroll
    // view, but the split view must always retain its two layout subviews.
    if( splitView == nil) { // Older localized nibs have no split view.
        splitViewAllocated = YES;
        NSView *imagePane = [[self.window.contentView subviews] lastObject];
        splitView = [[NSSplitView alloc] initWithFrame: self.window.contentView.bounds];
        [splitView addSubview: [[[NSView alloc] initWithFrame: NSZeroRect] autorelease]];
        [splitView addSubview: imagePane];
        [splitView setVertical: YES];
        [splitView setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
        [self.window.contentView addSubview: splitView];
    }
    else
    {
        previewMatrix.translatesAutoresizingMaskIntoConstraints = NO;
        splitView.translatesAutoresizingMaskIntoConstraints = NO;
    }
    [self updateSeriesListMode];

    [splitView setDelegate: self];
    [splitView adjustSubviews];
    
    [previewMatrix setIntercellSpacing:NSMakeSize(-1, -1)];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(observeScrollerStyleDidChangeNotification:) name:@"NSPreferredScrollerStyleDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSeriesListMode) name:HorosSeriesListLayout.placementDidChangeNotification object:nil];
    [self observeScrollerStyleDidChangeNotification:nil];
    
    NSRect frame = [comparativesButton frame];
    frame.origin.y += frame.size.height-15;
    frame.size.height = 15;
    [comparativesButton setFrame:frame];
    
    flagListPODComparatives = [[NSNumber alloc] initWithBool:YES];
    [self bind:@"flagListPODComparatives" toObject:[NSUserDefaultsController sharedUserDefaultsController] withKeyPath:@"values.listPODComparativesIn2DViewer" options:nil];
    
    [ViewerController clearFrontMost2DViewerCache];
    
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_2D_VIEWER_LAUNCHED detail:@"{}"];
#endif
}

-(void)comparativeRefresh:(NSString*) patientUID
{
    DicomImage* firstObject = [fileList[curMovieIndex] count]? [fileList[curMovieIndex] objectAtIndex:0] : nil;
    
    if( firstObject && [patientUID compare: firstObject.series.study.patientUID options: NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch] == NSOrderedSame)
        [self buildMatrixPreview: NO];
}

static int avoidReentryRefreshDatabase = 0;

-(void)refreshDatabase:(NSArray*)newImages
{
    if( avoidReentryRefreshDatabase > 0)
        return;
    
    avoidReentryRefreshDatabase++;
    @try
    {
        if( [[self imageView] mouseDragging])
        {
            [self performSelector:@selector(refreshDatabase:) withObject:newImages afterDelay:0.1];
            return;
        }
        
        BOOL rebuild = NO, reload = NO;
        
        if( !newImages)
            rebuild = YES;
        
        DicomImage* firstObject = [fileList[curMovieIndex] count]? [fileList[curMovieIndex] objectAtIndex:0] : nil;
        for( DicomImage* dicomImage in newImages)
        {
            if( [[dicomImage.series objectID] isEqualTo: [firstObject.series objectID]])
                reload = YES;
            else if( !firstObject || [dicomImage.series.study.patientUID isEqualToString:firstObject.series.study.patientUID])
                rebuild = YES;
            
            if( reload == YES && rebuild == YES)
                break;
        }
        
        if( rebuild)
            [self buildMatrixPreview: NO];
        
        if( reload) {
            // Instances of the open series arrived (#604). Reload at most twice a
            // second and never later than two seconds after the first request,
            // and keep the operator on the image being looked at: the index is
            // meaningless when instances arrive out of order, the SOP instance
            // and frame are not.
            HorosRefreshCoalescer *coalescer = [self horosRefreshCoalescer];
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            NSTimeInterval wait = coalescer ? [coalescer requestAt: now] : 0;
            if( wait > 0)
            {
                [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(refreshDatabase:) object: newImages];
                [self performSelector: @selector(refreshDatabase:) withObject: newImages afterDelay: wait];
                return;
            }
            DicomImage *shown = [imageView curImage] < [fileList[curMovieIndex] count] ? [fileList[curMovieIndex] objectAtIndex: [imageView curImage]] : nil;
            NSString *shownSOP = [shown sopInstanceUID] ?: @"";
            int shownFrame = [[shown frameID] intValue];
            int shownIndex = [imageView curImage];
            
            BrowserController* bc = [BrowserController currentBrowser];
            [bc openViewerFromImages:[NSArray arrayWithObject:[bc childrenArray:firstObject.series]] movie:NO viewer:self keyImagesOnly:NO tryToFlipData:YES];
            [coalescer appliedAt: [NSDate timeIntervalSinceReferenceDate]];
            
            if( shownSOP.length && [fileList[curMovieIndex] count])
            {
                NSMutableArray *sops = [NSMutableArray array], *frames = [NSMutableArray array];
                for( DicomImage *image in fileList[curMovieIndex])
                {
                    [sops addObject: [image sopInstanceUID] ?: @""];
                    [frames addObject: [image frameID] ?: @0];
                }
                NSInteger restored = [HorosRetrieveViewing indexOfSOPInstanceUID: shownSOP frame: shownFrame inSOPInstanceUIDs: sops frames: frames fallback: shownIndex];
                if( restored != [imageView curImage])
                {
                    [imageView setIndex: (short) restored];
                    [self adjustSlider];
                }
            }
            [[HorosRetrieveViewing shared] localCountChangedForStudyUID: [[self currentStudy] studyInstanceUID] ?: @""
                seriesUID: [[self currentSeries] seriesDICOMUID] ?: @"" localCount: [HorosRetrieveViewing uniqueInstanceCountOfImages: fileList[curMovieIndex]]];
        }
        
        [super refreshDatabase: newImages];
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    @finally {
        avoidReentryRefreshDatabase--;
    }
}

#pragma mark retrieve and view (#604)
// The methods of this block are implemented in Swift since #832
// (ViewerController+RetrieveAndView.swift), with the same selectors, except
// -dealloc, which sends [super dealloc], and -copyViewerWindow: Swift would
// return the result of a copy-family method retained, the Objective-C
// returns it autoreleased.
- (void) dealloc
{
    [ViewerController clearFrontMost2DViewerCache];
    [openingContentBoundsByPixels release];
    
    if( [NSThread isMainThread] == NO)
        N2LogStackTrace( @"dealloc NOT on main thread");
    
    // A viewer closed while a job is still spooled must not leave the pages.
    [self discardPrintSpoolDirectory];
    
    @try
    {
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:@"SeriesListVisible"];
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    
    [[self window] setDelegate: nil];
    
    [splitView setDelegate: nil];
    if( splitViewAllocated)
    {
        [splitView release];
        splitView = nil;
    }
    
    NSArray *windows = [NSApp windows];
    
    if([windows count] < 2)
        [[BrowserController currentBrowser] showDatabase:self];
    
    [self ActivateBlending: nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    
    //[self finalizeSeriesViewing]; /**** CALLED IN windowWillClose *****/
    
    [self.horosSeriesLoad cancel];
    
    [seriesPopupContextualMenu release];
    seriesPopupContextualMenu = nil;
    
    [undoQueue release];
    undoQueue = nil;
    
    [redoQueue release];
    redoQueue = nil;
    
    [curOpacityMenu release];
    curOpacityMenu = nil;
    
    [imageView release];
    imageView = nil;
    
    [seriesView release];
    seriesView = nil;
    
    [exportDCM release];
    exportDCM = nil;
    
    [blendedWindow release];
    blendedWindow = nil;
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"])
    {
        for( int i = 0 ; i < [[NSScreen screens] count]; i++)
            [thumbnailsListPanel[ i] thumbnailsListWillClose: previewMatrixScrollView];
    }
    
    [ROINamesArray release];
    ROINamesArray = nil;
    
    [roiLock release];
    roiLock = nil;
    
//    [contextualDictionaryPath release];
//    contextualDictionaryPath = nil;
    
    [backCurCLUTMenu release]; backCurCLUTMenu = nil;
    [curCLUTMenu release]; curCLUTMenu = nil;
    [curConvMenu release]; curConvMenu = nil;
    [curWLWWMenu release]; curWLWWMenu = nil;
    [processorsLock release]; processorsLock = nil;
    [retainedToolbarItems release]; retainedToolbarItems = nil;
    [editedRadiopharmaceuticalStartTime release]; editedRadiopharmaceuticalStartTime = nil;
    [editedAcquisitionTime release]; editedAcquisitionTime = nil;
    [toolbar release]; toolbar = nil;
    [injectionDateTime release]; injectionDateTime = nil;
    [convThread release];
    [flipDataThread release];
    self.windowsStateName = nil;
    
    [self unbind:@"flagListPODComparatives"];
    self.flagListPODComparatives = nil;
    
    //	[[AppController sharedAppController] tileWindows: nil];	<- We cannot do this, because:
    //	This is very important, or if we have a queue of closing windows, it will crash....
    
    for( ViewerController *v in [ViewerController getDisplayed2DViewers])
    {
        if( v != self) [v buildMatrixPreview: NO];
    }
    
    [toolbarPanel release];
    toolbarPanel = nil;
    
    [NSObject cancelPreviousPerformRequestsWithTarget: self];
    [super dealloc];
    
    NSLog(@"ViewController dealloc");
}
- (ViewerController*) copyViewerWindow
{
    ViewerController *new2DViewer = nil;
    
    // We will read our current series, and duplicate it by creating a new series!
    
    for( int v = 0; v < self.maxMovieIndex; v++)
    {
        NSData *vD = nil;
        NSMutableArray *newPixList = nil;
        
        [self copyVolumeData: &vD andDCMPix:&newPixList forMovieIndex: v];
        
        if( vD)
        {
            // We don't need to duplicate the DicomFile array, because it is identical!
            
            // A 2D Viewer window needs 3 things:
            // A mutable array composed of DCMPix objects
            // A mutable array composed of DicomFile objects
            // Number of DCMPix and DicomFile has to be EQUAL !
            // NSData volumeData contains the images, represented in the DCMPix objects
            if( new2DViewer == nil)
            {
                new2DViewer = [self newWindow:newPixList :[self fileList: v] :vD];
                [new2DViewer roiDeleteAll: self];
            }
            else
                [new2DViewer addMovieSerie:newPixList :[self fileList: v] :vD];
        }
    }
    
    return new2DViewer;
}


- (double) computeOriginalOrientation
{
    if( [pixList[ curMovieIndex] count] <= 2)
        return 0.0;
    
    double vectors[ 9], vectorsB[ 9];
    BOOL equalVector = YES;
    
    [[pixList[ curMovieIndex] objectAtIndex:1] orientationDouble: vectors];
    [[pixList[ curMovieIndex] objectAtIndex:2] orientationDouble: vectorsB];
    
    for( int i = 0; i < 9; i++)
    {
        const double epsilon = fabs(vectors[ i] - vectorsB[ i]);
        if (epsilon > ORIENTATION_SENSIBILITY)
        {
            equalVector = NO;
            break;
        }
    }
    
    double interval = 0;
    BOOL equalZero = YES;
    
    for( int i = 0; i < 9; i++)
    {
        if( vectors[ i] != 0) { equalZero = NO; break;}
        if( vectorsB[ i] != 0) { equalZero = NO; break;}
    }
    
    if( equalVector == YES && equalZero == NO)
    {
        if( fabs( vectors[6]) > fabs(vectors[7]) && fabs( vectors[6]) > fabs(vectors[8]))
        {
            interval = [[pixList[curMovieIndex] objectAtIndex:1] originX] - [[pixList[curMovieIndex] objectAtIndex:2] originX];
            
            if( vectors[6] > 0)
            {
                interval = -interval;
                orientationVector = eSagittalPos;
            }
            else orientationVector = eSagittalNeg;
            currentOrientationTool = 2;
        }
        
        if( fabs( vectors[7]) > fabs(vectors[6]) && fabs( vectors[7]) > fabs(vectors[8]))
        {
            interval = [[pixList[curMovieIndex] objectAtIndex:1] originY] - [[pixList[curMovieIndex] objectAtIndex:2] originY];
            
            if( vectors[7] > 0)
            {
                interval = -interval;
                orientationVector = eCoronalPos;
            }
            else orientationVector = eCoronalNeg;
            currentOrientationTool = 1;
        }
        
        if( fabs( vectors[8]) > fabs(vectors[6]) && fabs( vectors[8]) > fabs(vectors[7]))
        {
            interval = [[pixList[curMovieIndex] objectAtIndex:1] originZ] - [[pixList[curMovieIndex] objectAtIndex:2] originZ];
            
            if( vectors[8] > 0)
            {
                interval = -interval;
                orientationVector = eAxialPos;
            }
            else orientationVector = eAxialNeg;
            currentOrientationTool = 0;
        }
        
        if( originalOrientation == -1)
            originalOrientation = currentOrientationTool;
    }
    
    return interval;
}

+ (void) loadImageData:(id) dict
{
    NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
    NSLog( @"start loading");

    @autoreleasepool
    {
        // The request retains its pixels and volume storage until every decode
        // finishes. The worker never consults a replacement viewer/thread or
        // AppKit window; UI and geometry are updated only on accepted delivery.
        NSThread *loadThread = [NSThread currentThread];
        NSArray *pixListArray = [dict objectForKey: @"pixListArray"];
        ViewerController *viewer = [dict objectForKey: @"viewerController"];
        loadThread.name = @"Load Image Data";
        if (loadThread.isCancelled) return;

        BOOL compressed = NO;
        @try {
            DCMPix *firstPix = [[pixListArray objectAtIndex: 0] objectAtIndex: 0];
            [DicomFile isDICOMFile: [firstPix srcFile] compressed: &compressed];
            if (compressed && [BrowserController isItCD: [firstPix srcFile]])
                compressed = NO;
        }
        @catch (NSException *exception) {
            N2LogException( exception);
        }

        NSUInteger maxPix = 0, count = 0;
        for (NSArray *array in pixListArray) maxPix += array.count;
        if (!compressed)
        {
            NSTimeInterval lastSet = 0;
            for (NSArray *array in pixListArray)
            {
                for (DCMPix *pix in array)
                {
                    if (loadThread.isCancelled) return;
                    [pix CheckLoadFromThread: loadThread];
                    ++count;
                    if ([NSDate timeIntervalSinceReferenceDate] - lastSet > 0.3)
                    {
                        @synchronized (loadThread) {
                            loadThread.threadDictionary[@"loadingPercentage"] = @(maxPix ? (float)count / maxPix : 1);
                        }
                        lastSet = [NSDate timeIntervalSinceReferenceDate];
                    }
                }
            }
        }
        else
        {
            NSOperationQueue *queue = [[[NSOperationQueue alloc] init] autorelease];
            NSInteger processors = [[NSProcessInfo processInfo] processorCount];
            queue.maxConcurrentOperationCount = processors > 4 ? processors - 1 : MAX(1, processors);
            for (NSArray *array in pixListArray)
            {
                if (loadThread.isCancelled) break;
                for (DCMPix *pix in array)
                {
                    if (loadThread.isCancelled) break;
                    [queue addOperationWithBlock: ^{
                        [pix CheckLoadFromThread: loadThread];
                    }];
                }
            }
            while (queue.operationCount)
            {
                if (loadThread.isCancelled)
                {
                    loadThread.progress = -1;
                    loadThread.status = NSLocalizedString( @"Cancelling...", nil);
                    [queue cancelAllOperations];
                    break;
                }
                @synchronized (loadThread) {
                    loadThread.threadDictionary[@"loadingPercentage"] = @(maxPix ? 1.0 - (float)queue.operationCount / maxPix : 1);
                }
                [NSThread sleepForTimeInterval: 0.1];
            }
            // An in-flight decoder still owns bytes in volumeDataArray. Keep
            // that storage alive until it leaves, even when delivery is cancelled.
            [queue waitUntilAllOperationsAreFinished];
        }
        if (loadThread.isCancelled) return;
        @synchronized (loadThread) {
            loadThread.threadDictionary[@"loadingPercentage"] = @1.0;
        }
        // Only the completion copy retains its originating thread; putting it
        // in the NSThread's input dictionary would create a retain cycle.
        NSMutableDictionary *completion = [[dict mutableCopy] autorelease];
        completion[@"loadThread"] = loadThread;
        if ([dict[@"computeOpeningContentBounds"] boolValue])
        {
            NSDictionary *bounds = [self openingContentBoundsForPixLists:pixListArray loadThread:loadThread];
            if (loadThread.isCancelled) return;
            if (bounds) completion[@"openingContentBounds"] = bounds;
        }
        [viewer performSelectorOnMainThread: @selector(finishLoadImageData:) withObject: completion waitUntilDone: NO];
    }
    NSLog( @"end loading: %f [s]", [NSDate timeIntervalSinceReferenceDate] - start);
}

- (short) getNumberOfImages
{
    return [pixList[curMovieIndex] count];
}

-(short) maxMovieIndex { return maxMovieIndex;}


- (void) CloseViewerNotification: (NSNotification*) note
{
    if([note object] == blendingController) // our blended serie is closing itself....
    {
        [self ActivateBlending: nil];
    }
    
    if( [[self window] isMainWindow] || [[self window] isKeyWindow])
    {
        [self refreshToolbar];
    }
}

- (void)updateImageView:(NSNotification *)note
{
    if ([[self window] isEqual:[[note object] window]])
    {
        [imageView release];
        imageView = [[note object] retain];
        
        if( [imageView columns] != 1 || [imageView rows] != 1)
            [imageView updateTilingViews];
    }
}

-(IBAction) calibrate:(id) sender
{
    NSInteger result = HorosRunCriticalAlertPanel( NSLocalizedString( @"Warning !", nil), NSLocalizedString( @"Modifying these parameters will:\r\r- Change the measurements results (length, surface, volume, ...)\r-Change the orientation of the slices and of the 3D objects (Left, Right, ...)\r-Change the aspect of the 3D images. It can introduce distortions.\r\rONLY change these parameters if you know WHAT and WHY you are doing it.", nil), NSLocalizedString( @"I agree", nil), NSLocalizedString( @"Cancel", nil), nil);
    
    if( result == HorosAlertDefaultResponse)
    {
        [self computeInterval];
        [self SetThicknessInterval:sender];
    }
}

- (void)checkView:(NSView *)aView :(BOOL) OnOff
{
    id view;
    NSEnumerator *enumerator;
    
    if ([aView isKindOfClass: [NSControl class] ])
    {
        [(NSControl*) aView setEnabled: OnOff];
        return;
    }
    // Recursively check all the subviews in the view
    enumerator = [ [aView subviews] objectEnumerator];
    while (view = [enumerator nextObject]) {
        [self checkView:view :OnOff];
    }
}


#pragma mark 4.1.1. DICOM pipeline

#pragma mark 4.1.1.1 Filters


// filter from plugin
- (void)executeFilterFromString:(NSString*)name {
    [self executeFilterFromBundle:nil title:name];
}

- (void)executeFilterFromBundle:(NSBundle*)bundle title:(NSString*)name
{
    long			result;
    id				filter = nil;
    
    if (bundle) {
        
    } else
        filter = [[PluginManager plugins] objectForKey:name];
    
    if( [AppController willExecutePlugin: filter] == NO)
        return;
    
    if( filter == nil)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Plugins Error", nil), NSLocalizedString(@"The plugin %@ is not loaded. Open Plugins Manager and inspect Loading Details.", nil), nil, nil, nil, name);
        return;
    }
    
    [self checkEverythingLoaded];
    [self computeInterval];
    
    [imageView stopROIEditingForce: YES];
    
    [PluginManager startProtectForCrashWithFilter: filter];
    
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_PLUGIN_LAUNCHED detail:[NSString stringWithFormat:@"{\"PluginName\": \"%@\"}",name]];
#endif

    NSLog( @"executeFilter");
    
    @try
    {
        result = [filter prepareFilter: self];
        if( result)
        {
            HorosRunAlertPanel(NSLocalizedString(@"Plugins Error", nil), NSLocalizedString(@"Plugin %@ failed during preparation (error %ld).", nil), nil, nil, nil, name, result);
            [PluginManager endProtectForCrash];
            
            return;
        }
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
        HorosRunAlertPanel(NSLocalizedString(@"Plugins Error", nil), NSLocalizedString(@"Plugin %@ failed during preparation: %@ (%@).", nil), nil, nil, nil, name, e.reason ?: @"", e.name);
        [PluginManager endProtectForCrash];
        
        return;
    }
    
    @try
    {
        result = [filter filterImage: name];
        if( result)
        {
            HorosRunAlertPanel(NSLocalizedString(@"Plugins Error", nil), NSLocalizedString(@"Plugin %@ failed during processing (error %ld).", nil), nil, nil, nil, name, result);
            [PluginManager endProtectForCrash];
            
            return;
        }
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
        HorosRunAlertPanel(NSLocalizedString(@"Plugins Error", nil), NSLocalizedString(@"Plugin %@ failed during processing: %@ (%@).", nil), nil, nil, nil, name, e.reason ?: @"", e.name);
    }
    
    [PluginManager endProtectForCrash];
    
    [imageView roiSet];
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRecomputeROINotification object:self userInfo: nil];
}


- (void)executeFilter:(id)sender
{
    [self executeFilterFromString: [sender title]];
}

- (void) executeFilterFromToolbar:(id) sender
{
    [self executeFilterFromString: [sender label]];
}

#pragma mark resample image

- (IBAction)resampleDataBy2:(id)sender;
{
    id waitWindow = [self startWaitWindow: NSLocalizedString( @"Resampling data...", nil)];
    BOOL isResampled = [self resampleDataBy2];
    [self endWaitWindow: waitWindow];
    if(!isResampled)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Not enough memory", nil), NSLocalizedString(@"Cannot complete the resampling.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", nil), NSLocalizedString(@"OK", nil), nil, nil);
    }
}

- (BOOL)resampleDataBy2;
{
    return [self resampleDataWithFactor:2.0];
}

- (BOOL)resampleDataWithFactor:(float)factor;
{
    return [self resampleDataWithXFactor:factor yFactor:factor zFactor:factor];
}

- (BOOL)resampleDataWithXFactor:(float)xFactor yFactor:(float)yFactor zFactor:(float)zFactor;
{
    [self checkEverythingLoaded];
    [imageView stopROIEditingForce: YES];
    
    NSMutableArray *xPix = [NSMutableArray array];
    NSMutableArray *xFiles = [NSMutableArray array];
    NSMutableArray *xData = [NSMutableArray array];
    
    BOOL wasDataFlipped = [imageView flippedData];
    int index = [imageView curImage];
    BOOL isResampled = YES;
    
    NSMutableArray *savedROIs[ MAX4D];
    
    for( int j = 0 ; j < maxMovieIndex && isResampled == YES ; j ++)
    {
        NSMutableArray *newPixList = [NSMutableArray array];
        NSMutableArray *newDcmList = [NSMutableArray array];
        NSData *newData = nil;
        
        savedROIs[ j] = [NSMutableArray array];
        
        for( NSArray *r in roiList[ j])
        {
            NSMutableArray *snapshot = [NSMutableArray arrayWithCapacity:r.count];
            for( ROI *roi in r)
            {
                ROI *copy = [[roi copy] autorelease];
                if( copy == nil) return NO;
                [snapshot addObject:copy];
            }
            [savedROIs[ j] addObject:snapshot];
        }
        
        isResampled = [ViewerController resampleDataFromViewer:self inPixArray:newPixList fileArray:newDcmList data:&newData withXFactor:xFactor yFactor:yFactor zFactor:zFactor movieIndex: j];
        
        if( isResampled)
        {
            [xPix addObject: newPixList];
            [xFiles addObject: newDcmList];
            [xData addObject: newData];
            postprocessed = YES;
        }
    }
    
    if( isResampled)
    {
        resampleRatio = xFactor;
        
        int mx = maxMovieIndex;
        for( int j = 0 ; j < mx ; j ++)
        {
            if( j == 0)
                [self changeImageData: [xPix objectAtIndex: j] :[xFiles objectAtIndex: j] :[xData objectAtIndex: j] :NO];
            else
                [self addMovieSerie: [xPix objectAtIndex: j] :[xFiles objectAtIndex: j] :[xData objectAtIndex: j]];
        }
        
        [self setPostprocessed: YES];
        
        [self computeInterval];
        [self setWindowTitle:self];
        
        if( wasDataFlipped) [self flipDataSeries: self];
        
        [imageView setIndex: index];
        [imageView sendSyncMessage: 0];
        
        [self adjustSlider];
        
        for( int j = 0 ; j < maxMovieIndex; j ++)
        {
            
            for( int x = 0 ; x < [pixList[ j] count] ; x++)
            {
                int index = (x * [savedROIs[ j] count]) / [pixList[ j] count];
                
                if( index >= [savedROIs[ j] count]) index = (long)[savedROIs[ j] count] -1;
                
                NSArray *snapshot = [savedROIs[ j] objectAtIndex: index];
                // Each destination slice owns distinct ROIs, even when several map to one source.
                for( ROI *roi in snapshot)
                {
                    ROI *copy = [[roi copy] autorelease];
                    if( copy) [[roiList[ j] objectAtIndex: x] addObject:copy];
                }
                
                for( ROI *r in [roiList[ j] objectAtIndex: x])
                    [r setOriginAndSpacing :[imageView curDCM].pixelSpacingX : [imageView curDCM].pixelSpacingY :[DCMPix originCorrectedAccordingToOrientation: [imageView curDCM]]];	//NSMakePoint( [imageView curDCM].originX, [imageView curDCM].originY)];
            }
        }
        [imageView roiSet];
        [imageView setScaleValue: [imageView scaleValue] * xFactor];
    }
    
    return isResampled;
}

+ (BOOL)resampleDataFromViewer:(ViewerController *)aViewer inPixArray:(NSMutableArray*)aPixList fileArray:(NSMutableArray*)aFileList data:(NSData**)aData withXFactor:(float)xFactor yFactor:(float)yFactor zFactor:(float)zFactor;
{
    return [ViewerController resampleDataFromViewer:(ViewerController *)aViewer inPixArray:(NSMutableArray*)aPixList fileArray:(NSMutableArray*)aFileList data:(NSData**)aData withXFactor:(float)xFactor yFactor:(float)yFactor zFactor:(float)zFactor movieIndex: 0];
}

+ (BOOL)resampleDataFromViewer:(ViewerController *)aViewer inPixArray:(NSMutableArray*)aPixList fileArray:(NSMutableArray*)aFileList data:(NSData**)aData withXFactor:(float)xFactor yFactor:(float)yFactor zFactor:(float)zFactor movieIndex:(int) j;
{
    [aViewer setPostprocessed: YES];
    
    BOOL result =  [ViewerController resampleDataFromPixArray:[aViewer pixList: j] fileArray:[aViewer fileList: j] inPixArray:aPixList fileArray:aFileList data:aData withXFactor:xFactor yFactor:yFactor zFactor:zFactor];
    
    return result;
}

+ (BOOL)resampleDataFromPixArray:(NSArray *)originalPixlist fileArray:(NSArray*)originalFileList inPixArray:(NSMutableArray*)aPixList fileArray:(NSMutableArray*)aFileList data:(NSData**)aData withXFactor:(float)xFactor yFactor:(float)yFactor zFactor:(float)zFactor;
{
    NSLog( @"resampleDataFromPixArray - factor : %f", xFactor);
    
    long				i, y, z;
    unsigned long long	size, newX, newY, newZ, imageSize;
    float				*srcImage, *dstImage, *emptyData;
    DCMPix				*curPix;
    
    int originWidth = [[originalPixlist objectAtIndex:0] pwidth];
    int originHeight = [[originalPixlist objectAtIndex:0] pheight];
    int originZ = [originalPixlist count];
    float sliceInterval = [[originalPixlist objectAtIndex:0] sliceInterval];
    
    if( sliceInterval == 0)
    {
        NSLog( @"NOT A VOLUMIC SERIES: sliceInterval == 0. Cannot resample in Z direction");
        zFactor = 1.0;
    }
    
    newX = (unsigned long long)((float)originWidth / xFactor + 0.5);
    newY = (unsigned long long)((float)originHeight / yFactor + 0.5);
    newZ = (unsigned long long)((float)originZ / zFactor + 0.5);
    
    if( newZ <= 0) newZ = 1;
    if( originZ == 1) newZ = 1;
    
    if( sliceInterval == 0) newZ = originZ;
    
    int maxZ = originZ;
    if( maxZ < newZ) maxZ = newZ;
    
    imageSize = newX * newY;
    size = sizeof(float) * maxZ * imageSize;
    
    emptyData = malloc( size);		// Just to be sure we have enough memory to play with them !
    
    if( emptyData)
    {
        float vectors[ 9], vectorsB[ 9], interval = 0, origin[ 3], newOrigin[ 3];
        BOOL equalVector = YES;
        int o;
        
        if( [originalPixlist count] > 1)
        {
            DCMPix	*firstObject = [originalPixlist objectAtIndex:0];
            DCMPix	*secondObject = [originalPixlist objectAtIndex:1];
            
            [firstObject orientation: vectors];
            [secondObject orientation: vectorsB];
            
            origin[ 0] = [firstObject originX];
            origin[ 1] = [firstObject originY];
            origin[ 2] = [firstObject originZ];
            
            // DICOM Origin is the CENTER of the first pixel !
            
            origin[ 0] -= firstObject.pixelSpacingX/2.;
            origin[ 1] -= firstObject.pixelSpacingY/2.;
            origin[ 2] -= firstObject.sliceThickness/2.;
            
            for( i = 0; i < 9; i++)
            {
                if( vectors[ i] != vectorsB[ i]) equalVector = NO;
            }
            
            if( equalVector)
            {
                if( fabs( vectors[6]) > fabs(vectors[7]) && fabs( vectors[6]) > fabs(vectors[8]))
                {
                    interval = [secondObject originX] - [firstObject originX];
                    
                    o = 0;
                }
                
                if( fabs( vectors[7]) > fabs(vectors[6]) && fabs( vectors[7]) > fabs(vectors[8]))
                {
                    interval = [secondObject originY] - [firstObject originY];
                    
                    o = 1;
                }
                
                if( fabs( vectors[8]) > fabs(vectors[6]) && fabs( vectors[8]) > fabs(vectors[7]))
                {
                    interval = [secondObject originZ] - [firstObject originZ];
                    
                    o = 2;
                }
            }
        }
        
        interval *= (float) zFactor;
        
        NSMutableArray	*newPixList = [NSMutableArray array];
        NSData *newData = [NSData dataWithBytesNoCopy:emptyData length:size freeWhenDone:YES];
        
        for( z = 0 ; z < newZ; z ++)
        {
            curPix = [originalPixlist objectAtIndex: (z * originZ) / newZ];
            
            DCMPix	*copyPix = [curPix copy];
            
            [newPixList addObject: copyPix];
            
            [copyPix setPwidth: newX];
            [copyPix setPheight: newY];
            
            [copyPix setfImage: (float*) (emptyData + imageSize * z)];
            [copyPix setTot: newZ];
            [copyPix setFrameNo: z];
            [copyPix setID: z];
            
            [copyPix setPixelSpacingX: [curPix pixelSpacingX] * xFactor];
            [copyPix setPixelSpacingY: [curPix pixelSpacingY] * yFactor];
            [copyPix setSliceThickness: [curPix sliceThickness] * zFactor];
            [copyPix setPixelRatio:  [curPix pixelRatio] / xFactor * yFactor];
            
            newOrigin[ 0] = origin[ 0];	newOrigin[ 1] = origin[ 1];	newOrigin[ 2] = origin[ 2];
            
            switch( o)
            {
                case 0:
                    newOrigin[ 0] = origin[ 0] + (float) z * interval;
                    break;
                    
                case 1:
                    newOrigin[ 1] = origin[ 1] + (float) z * interval;
                    break;
                    
                case 2:
                    newOrigin[ 2] = origin[ 2] + (float) z * interval;
                    break;
            }
            
            newOrigin[ 0] += copyPix.pixelSpacingX/2.;
            newOrigin[ 1] += copyPix.pixelSpacingY/2.;
            newOrigin[ 2] += copyPix.sliceThickness/2.;
            
            [copyPix setOrigin: newOrigin];
            
            [copyPix computeSliceLocation];
            
            [copyPix setSliceInterval: 0];
            
            [copyPix release];	// It's added to the newPixList array
        }
        
        // X - Y RESAMPLING
        
        if( originHeight != newY || originWidth != newX)
        {
            for( z = 0; z < originZ; z++)
            {
                vImage_Buffer	srcVimage, dstVimage;
                
                curPix = [originalPixlist objectAtIndex: z];
                
                srcImage = [curPix fImage];
                dstImage = emptyData + imageSize * z;
                
                srcVimage.data = srcImage;
                srcVimage.height =  originHeight;
                srcVimage.width = originWidth;
                srcVimage.rowBytes = originWidth*4;
                
                dstVimage.data = dstImage;
                dstVimage.height =  newY;
                dstVimage.width = newX;
                dstVimage.rowBytes = newX*4;
                
                if( [curPix isRGB])
                    vImageScale_ARGB8888( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
                else
                    vImageScale_PlanarF( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
            }
        }
        else
        {
            memcpy( emptyData, [[originalPixlist objectAtIndex: 0] fImage], originHeight * originWidth * 4 * originZ);
        }
        
        // Z RESAMPLING
        
        if( sliceInterval != 0)
        {
            if( originZ != newZ)
            {
                curPix = [newPixList objectAtIndex: 0];
                
                for( y = 0; y < newY; y++)
                {
                    vImage_Buffer	srcVimage, dstVimage;
                    
                    srcImage = [curPix  fImage] + y * newX;
                    dstImage = emptyData + y * newX;
                    
                    srcVimage.data = srcImage;
                    srcVimage.height =  originZ;
                    srcVimage.width = newX;
                    srcVimage.rowBytes = newY*newX*4;
                    
                    dstVimage.data = dstImage;
                    dstVimage.height =  newZ;
                    dstVimage.width = newX;
                    dstVimage.rowBytes = newY*newX*4;
                    
                    if( [curPix isRGB])
                        vImageScale_ARGB8888( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
                    else
                        vImageScale_PlanarF( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
                }
            }
        }
        
        for( z = 0 ; z < newZ; z ++)
        {
            [aFileList addObject: [originalFileList objectAtIndex: (z * originZ) / newZ]];
            [aPixList addObject: [newPixList objectAtIndex: z]];
            
            [[aPixList lastObject] setArrayPix: aPixList :z];
            [[aPixList lastObject] setID: z];
        }
        *aData = newData;
        return YES;
    }
    
    return NO;
}

//xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

#pragma mark 4.1.1.2. Mask Subtraction
// These methods are enabled only if enableSubtraction
//(which is calculated in ViewerController -(void) loadImageData:(id) sender)
// is set to TRUE

- (IBAction) subCtrlOnOff:(id) sender
{
    [self checkEverythingLoaded];
    
    if (enableSubtraction)
    {
        //asked from menu (tag=0) or keyboard (tag=15 => asked from button)
        if( [sender tag] == 0) [subCtrlOnOff setState: ![subCtrlOnOff state]]; //"on"
        
        long i;
        
        [self computeSubCtrlMinMax];
        
        if([subCtrlOnOff state])			// subtraction asked for
        {
            [self checkView: subCtrlView :YES];
            
            [imageView setWLWW:128 :256];
            
            DCMPix *mask = [[imageView dcmPixList] objectAtIndex:subCtrlMaskID];

            for ( i = 0; i < [[imageView dcmPixList] count]; i ++)
            {
                DCMPix *pix = [[imageView dcmPixList] objectAtIndex:i];

                // subtractImages:: reads the mask with this image's width and
                // height: in a series of mixed sizes a smaller mask was read
                // past its end. An image of another size than the mask is
                // left without the subtraction.
                if( [pix pwidth] == [mask pwidth] && [pix pheight] == [mask pheight] && [mask fImage])
                    [pix setSubtractedfImage:[mask fImage] :subCtrlMinMax];
                else
                    [pix setSubtractedfImage:nil :subCtrlMinMax];
            }
        }
        else //without subtraction
        {
            for ( i = 0; i < [[imageView dcmPixList] count]; i ++)
            {
                [[[imageView dcmPixList] objectAtIndex:i]	setSubtractedfImage:nil :subCtrlMinMax];
            }
            
            [imageView setWLWW:0 :0];
            
            [self checkView: subCtrlView :NO];
            [subCtrlOnOff setEnabled: YES];
        }
        
        [self subSumSlider: nil];
        
        [imageView setIndex: [imageView curImage]]; //refresh viewer only
    }
    else
    {
        // The reason enableSubtraction is off: not XA, a single image, or
        // images of different sizes. Nil only if the series changed since it
        // was loaded.
        NSString *reason = [self subtractionUnavailableReason];
        if( reason == nil) reason = NSLocalizedString(@"Subtraction works only for XA modality.", nil);
        HorosRunAlertPanel(NSLocalizedString(@"Subtraction", nil), @"%@", nil, nil, nil, reason);
        [subCtrlOnOff setState: NSControlStateValueOff];
    }
}

- (IBAction) subCtrlNewMask:(id) sender
{
    if (enableSubtraction)
    {
        [self computeSubCtrlMinMax];
        
        if( [imageView flippedData]) subCtrlMaskID = [pixList[ curMovieIndex] count] - [imageView curImage] -1;
        else                         subCtrlMaskID = [imageView curImage];//starts at 1;
        
        [subCtrlMaskText setStringValue: [NSString stringWithFormat:@"%d", (int) (subCtrlMaskID+1)]];//changes tool text
        
        //---------------------------------------define min value of the subtraction
        long subCtrlMin = 1024;
        long subCtrlMax = 0;
        long i;
        DCMPix *mask = [[imageView dcmPixList] objectAtIndex:subCtrlMaskID];
        float newMaskTime = [mask fImageTime];
        for ( i = 0; i < [[imageView dcmPixList] count]; i ++)
        {
            DCMPix *pix = [[imageView dcmPixList] objectAtIndex:i];

            // subMinMax:: reads the mask with this image's width and height.
            // An image of another size than the mask is not subtracted
            // (subCtrlOnOff:) and does not count in the range.
            if( [pix pwidth] == [mask pwidth] && [pix pheight] == [mask pheight] && [mask fImage])
            {
                subCtrlMinMax = [pix subMinMax:[pix fImage] :[mask fImage]];
                if (subCtrlMinMax.x < subCtrlMin) subCtrlMin = subCtrlMinMax.x ;
                if (subCtrlMinMax.y > subCtrlMax) subCtrlMax = subCtrlMinMax.y ;
            }

            [pix maskID: subCtrlMaskID];
            [pix maskTime: newMaskTime];
        }
        subCtrlMinMax.x = subCtrlMin;
        subCtrlMinMax.y = subCtrlMax;
        
        [subCtrlOnOff setState: NSControlStateValueOn]; //"on"
        [self subCtrlOnOff: subCtrlOnOff];//subtracts
    }
}

- (IBAction) subCtrlOffset:(id) sender
{
    if( enableSubtraction)
    {
        if ([subCtrlOnOff state] == NSControlStateValueOn) //only when in subtraction mode
        {
            subCtrlOffset = [[[imageView dcmPixList] objectAtIndex:[imageView curImage]] subPixOffset];
            
            NSLog( @"subPixOffset before x: %2.2f y: %2.2f", subCtrlOffset.x, subCtrlOffset.y);
            
            switch( [sender tag]) //same tags in the main menu and in the subtraction tool
            {
                case 1://SW
                    --subCtrlOffset.x;
                    --subCtrlOffset.y;
                    break;
                    
                case 2://S
                    --subCtrlOffset.y;
                    break;
                    
                case 3://SE
                    ++subCtrlOffset.x;
                    --subCtrlOffset.y;
                    break;
                    
                case 4://W
                    --subCtrlOffset.x;
                    break;
                    
                case 5://No Pixel shift
                    subCtrlOffset.x = 0;
                    subCtrlOffset.y = 0;
                    break;
                    
                case 6://E
                    ++subCtrlOffset.x;
                    break;
                    
                case 7://NW
                    --subCtrlOffset.x;
                    ++subCtrlOffset.y;
                    break;
                    
                case 8://N
                    ++subCtrlOffset.y;
                    break;
                    
                case 9://NE
                    ++subCtrlOffset.x;
                    ++subCtrlOffset.y;
                    break;
            }
        }
        
        if ((subCtrlOffset.x > -30) && (subCtrlOffset.x < 30) && (subCtrlOffset.y > -30) && (subCtrlOffset.y < 30))
        {
            for(int i = 0; i < [[imageView dcmPixList] count]; i ++)
                [[[imageView dcmPixList] objectAtIndex:i] setSubPixOffset: subCtrlOffset];
            
            [self offsetMatrixSetting:([self threeTestsFivePosibilities: (int)subCtrlOffset.y] * 5) + [self threeTestsFivePosibilities: (int)subCtrlOffset.x]];
            
            [imageView setIndex:[imageView curImage]];
        }
    }
}

- (int) threeTestsFivePosibilities: (int) f
{
    //  -2  -1  0  1  2
    //   0   1  4  2  3
    if (f == 0) return 4;
    else
    {
        if (abs(f) > 1)
        {
            if (f > 1) return 3;
            else return 0;
        }
        else
        {
            if (f == 1) return 2;
            else return 1;
        }
    }
}

- (void) offsetMatrixSetting: (int) twentyFiveCodes
{
    switch(twentyFiveCodes)
    {
            // On stronger than Off
            //----------------------------------------------------------------------------------  y=-2
        case 0://x=-2 (On On Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOff];	//Off
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];	//On
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];	//On
            break;
        case 1://x=-1 (On Off Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOff];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            break;
        case 4:// x=0 (Off Off Off)
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOff];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            break;
        case 2://x=1
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            break;
        case 3:// x=2
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            
            break;//------------------------------------------------------------------------------y=-1
        case 5://x=-2 (On On Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOff];	//Off
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOff];	//Off
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];	//On
            break;
        case 6://x=-1 (On Off Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOff];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOff];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            break;
        case 9:// x=0 (Off Off Off)
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOff];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOff];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            break;
        case 7://x=1 y=-1
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            break;
        case 8:// x=2 y=-1
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            
            break;//--------------------------------------------------------------------------------y=0
        case 20://x=-2 (On On Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOff];	//Off
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOff];	//Off
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOff];	//Off
            break;
        case 21://x=-1 (On Off Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOff];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOff];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOff];
            break;
        case 24:// x=0 (Off Off Off)
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOff];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOff];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOff];
            break;
        case 22://x=1 (Off Off On)
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOff];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOn];
            break;
        case 23:// x=2 (Off On On)
            [sc7 setState: NSControlStateValueOff];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            
            break;//-------------------------------------------------------------------------------y=1
        case 10://x=-2 (On On Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];	//On
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOff];	//Off
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOff];	//Off
            break;
        case 11://x=-1 (On Off Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOff];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOff];
            break;
        case 14:// x=0 (Off Off Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOff];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOff];
            break;
        case 12://x=1 (Off Off On)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOff];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOn];
            break;
        case 13:// x=2 (Off On On)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOff];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            
            break;//------------------------------------------------------------------------------ y=2
        case 15://x=-2 (On On Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];	//On
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];	//On
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOff];	//Off
            break;
        case 16://x=-1 (On Off Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOn];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOff];
            break;
        case 19:// x=0 (Off Off Off)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOff];
            break;
        case 17://x=1 (Off Off On)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOff];	[sc3 setState: NSControlStateValueOn];
            break;
        case 18:// x=2 (Off On On)
            [sc7 setState: NSControlStateValueOn];	[sc8 setState: NSControlStateValueOn];	[sc9 setState: NSControlStateValueOn];
            [sc4 setState: NSControlStateValueOn];	[sc5 setState: NSControlStateValueOn];	[sc6 setState: NSControlStateValueOn];
            [sc1 setState: NSControlStateValueOff];	[sc2 setState: NSControlStateValueOn];	[sc3 setState: NSControlStateValueOn];
            break;
    }
    
}

- (IBAction) subCtrlSliders:(id) sender
{
    if( enableSubtraction)
    {
        if ([subCtrlOnOff state] == NSControlStateValueOn) //only when in subtraction mode
        {
            float	cwl, cww;
            [imageView getWLWW:&cwl :&cww];
            
            switch([sender tag]) //menu shortcut
            {
                    
                    // Gamma : wl
                    // Zero : ww
                    
                case 37: [imageView setWLWW:cwl-5	:cww];			break;
                case 38: [imageView setWLWW:128		:cww];			break;
                case 39: [imageView setWLWW:cwl+5	:cww];			break;
                    
                case 34: [imageView setWLWW:cwl	:cww-5];		break;
                case 35: [imageView setWLWW:cwl	:256];			break;
                case 36: [imageView setWLWW:cwl	:cww+5];		break;
            }
            
            for(int i = 0; i < [[imageView dcmPixList] count]; i ++)
            {
                [[[imageView dcmPixList] objectAtIndex:i]	setSubSlidersPercent:	[subCtrlPercent floatValue]];
                //															gamma:					[subCtrlGamma floatValue]
                //															zero:					[subCtrlZero floatValue]];
            }
            
            //NSLog(@"percent:%f   gamma:%f  zero:%f",[subCtrlPercent floatValue],[subCtrlGamma floatValue],[subCtrlZero floatValue]);
            [imageView setIndex:[imageView curImage]]; //refresh window image
        }
    }
}

- (IBAction) subSumSlider:(id) sender
{
    switch([sender tag]) //menu shortcut
    {
        case 31: [subCtrlSum setFloatValue:[subCtrlSum floatValue]-1];	break;  //Sum - (min 1)
        case 32: [subCtrlSum setFloatValue:1];							break;
        case 33: [subCtrlSum setFloatValue:[subCtrlSum floatValue]+1];	break;  //Sum + (max 10)
    }
    [self setFusionMode: 3];
    
    [imageView setFusion:-1 :[subCtrlSum intValue]];
    
    for( int x = 0; x < maxMovieIndex; x++)
    {
        if( x != curMovieIndex) // [imageView setFusion] already did it for current serie!
        {
            for( int i = 0; i < [pixList[ x] count]; i ++)
            {
                [[pixList[ x] objectAtIndex:i] setFusion:-1 :[subCtrlSum intValue] :-1];
            }
        }
    }
    
    [stacksFusion setIntValue:[subCtrlSum intValue]];
    [sliderFusion setIntValue:[subCtrlSum intValue]];
    
    if( [subCtrlSum intValue] <= 1)
    {
        [activatedFusion setState: NSControlStateValueOff];
        [sliderFusion setEnabled:NO];
    }
    
    [[NSUserDefaults standardUserDefaults] setInteger:[subCtrlSum intValue] forKey:@"stackThickness"];
    
    [imageView sendSyncMessage: 0];
    
}

- (IBAction) subSharpen:(id) sender
{
    if ([sender tag] == 30) [subCtrlSharpenButton  setState: ![subCtrlSharpenButton state]];
    if ([subCtrlSharpenButton state] == NSControlStateValueOn)	[self ApplyConvString:@"Sharpen 5x5"];
    else [self ApplyConvString:NSLocalizedString(@"No Filter", nil)];
}

#pragma mark-
#pragma mark 4.1.1.3. VOI LUT transformation

- (void) setCurWLWWMenu:(NSString*) s
{
    if( s != curWLWWMenu && [s isEqualToString: curWLWWMenu] == NO)
    {
        [curWLWWMenu release];
        curWLWWMenu = [s retain];
        [wlwwPopup setTitle: curWLWWMenu];
    }
}

- (IBAction) resetImage:(id) sender
{
    [self setUpdateTilingViewsValue: YES];
    
    for( DCMView *v in [seriesView imageViews])
    {
        [v setOrigin: NSMakePoint( 0, 0)];
        [v scaleToFit];
        [v setRotation: 0];
        
        [v setWLWW:[[v curDCM] savedWL] :[[v curDCM] savedWW]];
    }
    
    [self setUpdateTilingViewsValue: NO];
    
    [self selectFirstTilingView];
    [imageView updateTilingViews];
}

-(IBAction) ConvertToRGBMenu:(id) sender
{
    long	x, i;
    float	cwl, cww;
    
    [imageView getWLWW:&cwl :&cww];
    
    if( [[pixList[ curMovieIndex] objectAtIndex: 0] isRGB] == YES)
    {
        HorosRunAlertPanel(NSLocalizedString(@"RGB", nil), NSLocalizedString(@"Sorry, these images are already in RGB mode", nil), nil, nil, nil);
    }
    else
    {
        for( x = 0; x < maxMovieIndex; x++)
        {
            for( i = 0; i < [pixList[ x] count]; i++)
            {
                if( [[pixList[ x] objectAtIndex: i] isRGB] == NO)
                {
                    [[pixList[ x] objectAtIndex: i] ConvertToRGB: [sender tag] :cwl :cww];
                }
            }
        }
        
        [imageView setWLWW:127 : 256];
        [imageView loadTextures];
        [imageView setNeedsDisplay:YES];
    }
}

-(IBAction) ConvertToBWMenu:(id) sender
{
    long x, i;
    
    if( [[pixList[ curMovieIndex] objectAtIndex: 0] isRGB] == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"BW", nil), NSLocalizedString(@"Sorry, these images are already in BW mode", nil), nil, nil, nil);
    }
    else
    {
        for( x = 0; x < maxMovieIndex; x++)
        {
            for( i = 0; i < [pixList[ x] count]; i++)
            {
                if( [[pixList[ x] objectAtIndex: i] isRGB] == YES)
                {
                    [[pixList[ x] objectAtIndex: i] ConvertToBW: [sender tag]];
                }
            }
        }
        
        [imageView loadTextures];
        [imageView setNeedsDisplay:YES];
    }
}

- (void) flipDataThread: (NSDictionary*) d
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    long size = [[d objectForKey: @"size"] intValue];
    char *ptr = [[d objectForKey: @"ptr"] pointerValue];
    int start = [[d objectForKey: @"start"] intValue];
    int end = [[d objectForKey: @"end"] intValue];
    int no = [[d objectForKey: @"no"] intValue];
    
    size *= 4;
    char* tempData = (char*) malloc( size);
    if( tempData)
    {
        for( int i = start; i < end; i++)
        {
            memmove( tempData, ptr + size*i, size);
            memmove( ptr + size*i, ptr + size*(no-1-i), size);
            memmove( ptr + size*(no-1-i), tempData, size);
        }
        free( tempData);
    }
    
    [flipDataThread lock];
    [flipDataThread unlockWithCondition: [flipDataThread condition]-1];
    
    [pool release];
}

- (void) flipData:(char*) ptr :(long) no :(long) x :(long) y
{
    NSLog(@"flip data");
    //	NSLog(@"flip data-A");
    
    //	long size = x*y;
    //
    //	size *= 4;
    //	char* tempData = (char*) malloc( size);
    //
    //	for( int i = 0; i < no/2; i++)
    //	{
    //		memcpy( tempData, ptr + size*i, size);
    //		memcpy( ptr + size*i, ptr + size*(no-1-i), size);
    //		memcpy( ptr + size*(no-1-i), tempData, size);
    //	}
    //	free( tempData);
    
    if( no > 50)
    {
        int mpprocessors = [[NSProcessInfo processInfo] processorCount];
        
        if( flipDataThread == nil)
            flipDataThread = [[NSConditionLock alloc] initWithCondition: 0];
        
        [flipDataThread lockWhenCondition: 0];
        [flipDataThread unlockWithCondition: mpprocessors];
        
        int no2 = no/2;
        
        NSMutableDictionary *baseDict = [NSMutableDictionary dictionary];
        
        [baseDict setObject: [NSNumber numberWithInt: x*y] forKey: @"size"];
        [baseDict setObject: [NSValue valueWithPointer: ptr] forKey: @"ptr"];
        [baseDict setObject: [NSNumber numberWithInt: no] forKey: @"no"];
        
        for( int i = 0; i < mpprocessors; i++)
        {
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: baseDict];
            
            int from = (i * no2) / mpprocessors;
            int to = ((i+1) * no2) / mpprocessors;
            
            [d setObject: [NSNumber numberWithInt: from] forKey: @"start"];
            [d setObject: [NSNumber numberWithInt: to] forKey: @"end"];
            
            [NSThread detachNewThreadSelector: @selector(flipDataThread:) toTarget: self withObject: d];
        }
        
        [flipDataThread lockWhenCondition: 0];
        [flipDataThread unlock];
    }
    //	NSLog(@"flip data-B");
    else
    {
        vImage_Buffer src, dest;
        src.height = dest.height = no;
        src.width = dest.width = x*y;
        src.rowBytes = dest.rowBytes = x*y*4;
        src.data = dest.data = ptr;
        vImageVerticalReflect_PlanarF ( &src, &dest, 0);
    }
    //	NSLog(@"flip data-C");
}

- (IBAction) flipDataSeries: (id) sender
{
    if( windowWillClose) return;
    
    int activatedFusionState = [activatedFusion state];
    int previousFusion = [popFusion selectedTag];
    int previousCurImage = [imageView curImage];
    
    imageView.drawing = NO;
    
    [seriesView setFlippedData: ![imageView flippedData]];
    [self setFusionMode: 0];
    
    [imageView setIndex: (long)[pixList[ 0] count] -1 -previousCurImage];
    
    [self adjustSlider];
    
    [imageView sendSyncMessage: 0];
    
    if( activatedFusionState == NSControlStateValueOn)
        [self setFusionMode: previousFusion];
    
    imageView.drawing = YES;
    
    [popFusion selectItemWithTag:previousFusion];
    
    [imageView sendSyncMessage: 0];
}

- (short) orthogonalOrientation
{
    float		vectors[ 9];
    
    NSArray* localPixList = [[DCMView class] cleanedOutDcmPixArray:pixList[curMovieIndex]];
    
    [[localPixList objectAtIndex:0] orientation: vectors];
    
    if( fabs( vectors[6]) > fabs(vectors[7]) && fabs( vectors[6]) > fabs(vectors[8]))
    {
        if( vectors[6] > 0) orientationVector = eSagittalPos;
        else orientationVector = eSagittalNeg;
    }
    
    if( fabs( vectors[7]) > fabs(vectors[6]) && fabs( vectors[7]) > fabs(vectors[8]))
    {
        if( vectors[7] > 0) orientationVector = eCoronalPos;
        else orientationVector = eCoronalNeg;
    }
    
    if( fabs( vectors[8]) > fabs(vectors[6]) && fabs( vectors[8]) > fabs(vectors[7]))
    {
        if( vectors[8] > 0) orientationVector = eAxialPos;
        else orientationVector = eAxialNeg;
    }
    
    switch( orientationVector)
    {
        case eAxialPos:
        case eAxialNeg:
            return 0;
            break;
            
        case eCoronalNeg:
        case eCoronalPos:
            return 1;
            break;
            
        case eSagittalNeg:
        case eSagittalPos:
            return 2;
            break;
    }
    
    return 0;
}

-(short) orientationVector
{
    return orientationVector;
}

-(void) displayWarningIfGantryTitled
{
    if( titledGantry)
    {
        NSString *message = nil;
#ifdef OSIRIX_LIGHT
        message = [NSString stringWithFormat: NSLocalizedString(@"These images were acquired with a gantry tilt: %0.2f\u00B0. This gantry tilt will produce a distortion in 3D post-processing. You can use the plugin 'Gantry Tilt Correction' to convert these images.", nil), titledGantryDegrees];
        HorosRunInformationalAlertPanel( NSLocalizedString(@"Warning!", nil), @"%@", NSLocalizedString(@"OK", nil), nil, nil, message);
#else
        message = [NSString stringWithFormat: NSLocalizedString(@"These images were acquired with a gantry tilt: %0.2f\u00B0. This gantry tilt will produce a distortion in 3D post-processing. Should I convert these images to a real 3D dataset.", nil), titledGantryDegrees];
        NSInteger r = HorosRunInformationalAlertPanel( NSLocalizedString(@"Warning!", nil), @"%@", NSLocalizedString(@"Yes", nil), NSLocalizedString(@"No", nil), nil, message);
        
        if( r == HorosAlertDefaultResponse)
            [ViewerController correctGangtryTilt: self];
#endif
    }
}

- (void) computeIntervalAsync
{
    [self computeIntervalFlipNow: [NSNumber numberWithBool: NO]];
    [imageView setNeedsDisplay: YES];
}

+ (float) computeIntervalForDCMPix: (DCMPix*) p1 And: (DCMPix*) p2
{
    double vectors[ 9], vectorsB[ 9];
    BOOL equalVector = YES;
    float interval = 0;
    
    [p1 orientationDouble: vectors];
    [p2 orientationDouble: vectorsB];
    
    for( int i = 0; i < 9; i++)
    {
        const double epsilon = fabs(vectors[ i] - vectorsB[ i]);
        if (epsilon > ORIENTATION_SENSIBILITY)
        {
            equalVector = NO;
            break;
        }
    }
    
    BOOL equalZero = YES;
    
    for( int i = 0; i < 9; i++)
    {
        if( vectors[ i] != 0) { equalZero = NO; break;}
        if( vectorsB[ i] != 0) { equalZero = NO; break;}
    }
    
    if( equalVector == YES && equalZero == NO)
    {
        if( fabs( vectors[6]) > fabs(vectors[7]) && fabs( vectors[6]) > fabs(vectors[8]))
        {
            interval = [p1 originX] - [p2 originX];
            
            if( vectors[6] > 0) interval = -( interval);
            else interval = ( interval);
        }
        
        if( fabs( vectors[7]) > fabs(vectors[6]) && fabs( vectors[7]) > fabs(vectors[8]))
        {
            interval = [p1 originY] - [p2 originY];
            
            if( vectors[7] > 0) interval = -( interval);
            else interval = ( interval);
        }
        
        if( fabs( vectors[8]) > fabs(vectors[6]) && fabs( vectors[8]) > fabs(vectors[7]))
        {
            interval = [p1 originZ] - [p2 originZ];
            
            if( vectors[8] > 0) interval = -( interval);
            else interval = ( interval);
        }
    }
    
    return interval;
}

- (BOOL) isGantryTitled
{
    BOOL v = NO;
    
    if( pixList[ 0].count>= 3)
    {
        double Pn1[ 3];
        Pn1[ 0] = [[pixList[ 0] objectAtIndex: 2] originX] - [[pixList[ 0] objectAtIndex: 1] originX];
        Pn1[ 1] = [[pixList[ 0] objectAtIndex: 2] originY] - [[pixList[ 0] objectAtIndex: 1] originY];
        Pn1[ 2] = [[pixList[ 0] objectAtIndex: 2] originZ] - [[pixList[ 0] objectAtIndex: 1] originZ];
        
        double vectors[ 9];
        [[pixList[ 0] objectAtIndex:1] orientationDouble: vectors];
        
        double angle = fabs( [DCMView angleBetweenVectorD: Pn1 andVectorD: vectors+6]);
        angle /= deg2rad;
        if( angle < 90)
        {
            if( angle > [[NSUserDefaults standardUserDefaults] floatForKey: @"MinimumTitledGantryTolerance"]) {
                NSLog( @"---- titledGantry - Not a real 3D data set: %f degrees", angle);
                v = YES;
            }
            else if( angle > 0.001)
                NSLog( @"---- titledGantry (tolerated) - Not a real 3D data set: %f degrees", angle);
            
            titledGantryDegrees = angle;
        }
    }
    
    return v;
}

- (float) computeIntervalFlipNow: (NSNumber*) flipNowNumber
{
    [self selectFirstTilingView];
    
    int z = curMovieIndex;
    {
        double				interval = [[pixList[ z] objectAtIndex:0] sliceInterval];
        long				i, x;
        BOOL				flipNow = [flipNowNumber boolValue];
        
        if( flipNow)
            flipNow = [self isEverythingLoaded];
        
        if( [pixList[ z] count] > 1)
        {
            if( flipNow)
                interval = 0;
        }
        
        if( interval == 0 && [pixList[ z] count] > 2)
        {
            titledGantry = NO;
            
            double vectors[ 9], vectorsB[ 9];
            BOOL equalVector = YES;
            
            [[pixList[ z] objectAtIndex:1] orientationDouble: vectors];
            [[pixList[ z] objectAtIndex:2] orientationDouble: vectorsB];
            
            for( i = 0; i < 9; i++)
            {
                const double epsilon = fabs(vectors[ i] - vectorsB[ i]);
                if (epsilon > ORIENTATION_SENSIBILITY)
                {
                    equalVector = NO;
                    break;
                }
            }
            
            BOOL equalZero = YES;
            
            for( i = 0; i < 9; i++)
            {
                if( vectors[ i] != 0) { equalZero = NO; break;}
                if( vectorsB[ i] != 0) { equalZero = NO; break;}
            }
            
            if( equalVector == YES && equalZero == NO)
            {
                if( fabs( vectors[6]) > fabs(vectors[7]) && fabs( vectors[6]) > fabs(vectors[8]))
                {
                    interval = [[pixList[ z] objectAtIndex:1] originX] - [[pixList[ z] objectAtIndex:2] originX];
                    
                    if( vectors[6] > 0) interval = -( interval);
                    else interval = ( interval);
                    
                    if( vectors[6] > 0) orientationVector = eSagittalPos;
                    else orientationVector = eSagittalNeg;
                    
                    [orientationMatrix selectCellWithTag: 2];
                    if( interval != 0) [orientationMatrix setEnabled: YES];
                    currentOrientationTool = 2;
                }
                
                if( fabs( vectors[7]) > fabs(vectors[6]) && fabs( vectors[7]) > fabs(vectors[8]))
                {
                    interval = [[pixList[ z] objectAtIndex:1] originY] - [[pixList[ z] objectAtIndex:2] originY];
                    
                    if( vectors[7] > 0) interval = -( interval);
                    else interval = ( interval);
                    
                    if( vectors[7] > 0) orientationVector = eCoronalPos;
                    else orientationVector = eCoronalNeg;
                    
                    [orientationMatrix selectCellWithTag: 1];
                    if( interval != 0) [orientationMatrix setEnabled: YES];
                    currentOrientationTool = 1;
                }
                
                if( fabs( vectors[8]) > fabs(vectors[6]) && fabs( vectors[8]) > fabs(vectors[7]))
                {
                    interval = [[pixList[ z] objectAtIndex:1] originZ] - [[pixList[ z] objectAtIndex:2] originZ];
                    
                    if( vectors[8] > 0) interval = -( interval);
                    else interval = ( interval);
                    
                    if( vectors[8] > 0) orientationVector = eAxialPos;
                    else orientationVector = eAxialNeg;
                    
                    [orientationMatrix selectCellWithTag: 0];
                    if( interval != 0) [orientationMatrix setEnabled: YES];
                    currentOrientationTool = 0;
                }
                
                if( originalOrientation == -1)
                {
                    switch( orientationVector)
                    {
                        case eAxialPos:
                        case eAxialNeg:
                            originalOrientation = 0;
                            break;
                            
                        case eCoronalNeg:
                        case eCoronalPos:
                            originalOrientation = 1;
                            break;
                            
                        case eSagittalNeg:
                        case eSagittalPos:
                            originalOrientation = 2;
                            break;
                    }
                }
                
                double xd = [[pixList[ z] objectAtIndex: 2] originX] - [[pixList[ z] objectAtIndex: 1] originX];
                double yd = [[pixList[ z] objectAtIndex: 2] originY] - [[pixList[ z] objectAtIndex: 1] originY];
                double zd = [[pixList[ z] objectAtIndex: 2] originZ] - [[pixList[ z] objectAtIndex: 1] originZ];
                
                double interval3d = sqrt(xd*xd + yd*yd + zd*zd);
                
                xd /= interval3d;
                yd /= interval3d;
                zd /= interval3d;
                
                if( interval == 0 && [[pixList[ z] objectAtIndex: 0] originX] == 0 && [[pixList[ z] objectAtIndex: 0] originY] == 0 && [[pixList[ z] objectAtIndex: 0] originZ] == 0)
                {
                    interval = [[pixList[ z] objectAtIndex:0] spacingBetweenSlices];
                    if( interval)
                    {
                        interval3d = -interval;
                        orientationVector = eAxialNeg;
                        [orientationMatrix setEnabled: YES];
                        
                        float v[ 9], o[ 3];
                        
                        o[ 0] = 0; o[ 1] = 0; o[ 2] = 0;
                        
                        v[ 0] = 1;	v[ 1] = 0;	v[ 2] = 0;
                        v[ 3] = 0;	v[ 4] = 1;	v[ 5] = 0;
                        v[ 6] = 1;	v[ 7] = 0;	v[ 8] = 1;
                        
                        for( DCMPix *pix in pixList[ z])
                        {
                            [pix setOrientation: v];
                            [pix setOrigin: o];
                            o[ 2] += interval;
                        }
                    }
                }
                
                // FLIP DATA !!!!!! FOR 3D TEXTURE MAPPING !!!!!
                if( interval < 0 && flipNow == YES)
                {
                    BOOL sameSize = YES;
                    
                    DCMPix	*firstObject = [pixList[ z] objectAtIndex: 0];
                    
                    for(  i = 0 ; i < [pixList[ z] count]; i++)
                    {
                        if( [firstObject pheight] != [[pixList[ z] objectAtIndex: i] pheight]) sameSize = NO;
                        if( [firstObject pwidth] != [[pixList[ z] objectAtIndex: i] pwidth]) sameSize = NO;
                    }
                    
                    if( sameSize)
                    {
                        if( interval3d)
                            interval = fabs( interval3d);	//interval3d;	//-interval;
                        else
                            interval = fabs( interval);
                        
                        for( x = 0; x < maxMovieIndex; x++)
                        {
                            firstObject = [pixList[ x] objectAtIndex: 0];
                            
                            float	*volumeDataPtr = [firstObject fImage];
                            
                            [self flipData: (char*) volumeDataPtr :[pixList[ x] count] :[firstObject pwidth] :[firstObject pheight]];
                            
                            for(  i = 0 ; i < [pixList[ x] count]; i++)
                            {
                                long offset = ((long)[pixList[ x] count]-1-i)*[firstObject pheight] * [firstObject pwidth];
                                
                                [[pixList[ x] objectAtIndex: i] setfImage: volumeDataPtr + offset];
                                [[pixList[ x] objectAtIndex: i] setSliceInterval: interval];
                            }
                            
                            id tempObj;
                            
                            for( i = 0; i < [pixList[ x] count]/2 ; i++)
                            {
                                tempObj = [[pixList[ x] objectAtIndex: i] retain];
                                [pixList[ x] replaceObjectAtIndex: i withObject:[pixList[ x] objectAtIndex: [pixList[ x] count]-i-1]];
                                [pixList[ x] replaceObjectAtIndex: [pixList[ x] count]-i-1 withObject: tempObj];
                                [tempObj release];
                                
                                tempObj = [[fileList[ x] objectAtIndex: i] retain];
                                [fileList[ x] replaceObjectAtIndex: i withObject:[fileList[ x] objectAtIndex: [fileList[ x] count]-i-1]];
                                [fileList[ x] replaceObjectAtIndex: [fileList[ x] count]-i-1 withObject: tempObj];
                                [tempObj release];
                                
                                tempObj = [[roiList[ x] objectAtIndex: i] retain];
                                [roiList[ x] replaceObjectAtIndex: i withObject:[roiList[ x] objectAtIndex: [roiList[ x] count]-i-1]];
                                [roiList[ x] replaceObjectAtIndex: [roiList[ x] count]-i-1 withObject: tempObj];
                                [tempObj release];
                            }
                        }
                        
                        for( x = 0; x < maxMovieIndex; x++)
                        {
                            for( i = 0; i < [pixList[ x] count]; i++)
                            {
                                [[pixList[ x] objectAtIndex: i] setArrayPix: pixList[ x] :i];
                                [[pixList[ x] objectAtIndex: i] setID: i];
                            }
                        }
                        
                        subCtrlMaskID = [pixList[ z] count] - subCtrlMaskID -1;
                        
                        [self flipDataSeries: self];
                    }
                    else NSLog( @"sameSize = NO");
                }
                else
                {
                    if( interval3d)
                    {
                        if( interval < 0) interval = -interval3d;
                        else interval = interval3d;
                    }
                    else
                    {
                        if( interval < 0) interval = -interval;
                        else interval = interval;
                    }
                    
                    for( x = 0; x < maxMovieIndex; x++)
                    {
                        for( i = 0; i < [pixList[ x] count]; i++)
                        {
                            [[pixList[ x] objectAtIndex: i] setSliceInterval: interval];
                        }
                    }
                }
                
                if( flipNow == YES)
                    titledGantry = [self isGantryTitled];
            }
        }
    }
    
    [blendingController computeInterval];
    
    float val = [[pixList[ curMovieIndex] objectAtIndex:0] sliceInterval];
    
    return val;
}

- (void) displayAWarningIfNonTrueVolumicData
{
    [self isDataVolumicIn4D: YES]; // Let this function try to correct the scout image first / GE SCAN
    
    if( nonVolumicDataWarningDisplayed == NO)
    {
        double previousInterval3d = 0;
        double minInterval = 0, maxInterval = 0;
        BOOL nonContinuous = NO;
        
        for( int i = 0 ; i < (long)[pixList[ 0] count] -1; i++)
        {
            double xd = [[pixList[ 0] objectAtIndex: i+1] originX] - [[pixList[ 0] objectAtIndex: i] originX];
            double yd = [[pixList[ 0] objectAtIndex: i+1] originY] - [[pixList[ 0] objectAtIndex: i] originY];
            double zd = [[pixList[ 0] objectAtIndex: i+1] originZ] - [[pixList[ 0] objectAtIndex: i] originZ];
            
            double interval3d = sqrt(xd*xd + yd*yd + zd*zd);
            
            xd /= interval3d;
            yd /= interval3d;
            zd /= interval3d;
            
            int sss = fabs( previousInterval3d - interval3d) * 100.;
            
            if( i == 0)
            {
                maxInterval = fabs( interval3d);
                minInterval = fabs( interval3d);
            }
            else
            {
                if( fabs( interval3d) > maxInterval) maxInterval = fabs( interval3d);
                if( fabs( interval3d) < minInterval) minInterval = fabs( interval3d);
            }
            
            if( sss != 0 && previousInterval3d != 0)
            {
                nonContinuous = YES;
                //				NSLog(@"nonContinuous interval: %f", previousInterval3d - interval3d);
            }
            
            previousInterval3d = interval3d;
        }
        
        if( nonContinuous)
        {
            HorosRunInformationalAlertPanel( NSLocalizedString(@"Warning!", nil), NSLocalizedString(@"These slices have a non regular slice interval, varying from %.3f mm to %.3f mm. This will produce distortion in 3D representations, and in measurements.", nil), NSLocalizedString(@"OK", nil), nil, nil, minInterval, maxInterval);
            //
            //            // Resample origins, according to first and last image
            //
            //            double fullLength;
            //
            //            double xd = [[pixList[ 0] lastObject] originX] - [[pixList[ 0] objectAtIndex: 0] originX];
            //            double yd = [[pixList[ 0] lastObject] originY] - [[pixList[ 0] objectAtIndex: 0] originY];
            //            double zd = [[pixList[ 0] lastObject] originZ] - [[pixList[ 0] objectAtIndex: 0] originZ];
            //
            //            double interval3d = sqrt(xd*xd + yd*yd + zd*zd);
            //            NSLog( @"full length = %f, new mean interval: %f", interval3d, interval3d / (pixList[ 0].count-1));
            //
            //            interval3d /= (pixList[ 0].count-1);
            //
            //            double vectors[ 9];
            //
            //            [[pixList[0] objectAtIndex: 0] orientationDouble: vectors];
            //
            //            for( int i = 1 ; i < [pixList[ 0] count]; i++)
            //            {
            //                double newOrigin[ 3];
            //                newOrigin[ 0] = [[pixList[ 0] objectAtIndex: 0] originX] + interval3d*(float)i*vectors[6];
            //                newOrigin[ 1] = [[pixList[ 0] objectAtIndex: 0] originY] + interval3d*(float)i*vectors[7];
            //                newOrigin[ 2] = [[pixList[ 0] objectAtIndex: 0] originZ] + interval3d*(float)i*vectors[8];
            //
            //                [[pixList[ 0] objectAtIndex: i] setOriginDouble: newOrigin];
            //                [[pixList[ 0] objectAtIndex: i] setSliceInterval: 0];
            //            }
            //
            //            xd = [[pixList[ 0] lastObject] originX] - [[pixList[ 0] objectAtIndex: 0] originX];
            //            yd = [[pixList[ 0] lastObject] originY] - [[pixList[ 0] objectAtIndex: 0] originY];
            //            zd = [[pixList[ 0] lastObject] originZ] - [[pixList[ 0] objectAtIndex: 0] originZ];
            //
            //            interval3d = sqrt(xd*xd + yd*yd + zd*zd);
            //            NSLog( @"new full length = %f", interval3d);
            
        }
        else if( [self isDataVolumicIn4D: YES] == NO)
        {
            HorosRunInformationalAlertPanel( NSLocalizedString(@"Warning!", nil), NSLocalizedString(@"These slices doesn't represent a true 3D volumic data. This will produce distortion in 3D representations, and in measurements.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        }
        
        nonVolumicDataWarningDisplayed = YES;
    }
}

-(float) computeInterval
{
    float s = 0;
    
    if( computeInterval == NO) // avoid re-entry
    {
        computeInterval = YES;
        s = [self computeIntervalFlipNow: [NSNumber numberWithBool: YES]];
        computeInterval = NO;
    }
    return s;
}

- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(id)contextInfo;
{
    if( returnCode == 1)
    {
        switch( [contextInfo tag])
        {
                //			case 1: [self MPR2DViewer:contextInfo];		break;  //2DMPR
#ifndef OSIRIX_LIGHT
            case 10: [self mprViewer:contextInfo];		break;  //3DMPR
            case 3: [self VRViewer:contextInfo];		break;  //MIP
            case 4: [self VRViewer:contextInfo];		break;  //VR
            case 5: [self SRViewer:contextInfo];		break;  //SR
#endif
        }
    }
}

-(IBAction) endThicknessInterval:(id) sender
{
    float interval = 0, xSpacing = 0, ySpacing = 0;
    float v[9] = {0}, o[3] = {0};
    if ([sender tag])
    {
        NSLocale *locale = [NSLocale currentLocale];
        BOOL valid = HorosCalibrationFloat([customInterval stringValue], locale, &interval) &&
            HorosCalibrationFloat([customXSpacing stringValue], locale, &xSpacing) &&
            HorosCalibrationFloat([customYSpacing stringValue], locale, &ySpacing) &&
            xSpacing > 0 && ySpacing > 0 &&
            (interval != 0 || [pixList[curMovieIndex] count] <= 1);
        for (int i = 0; i < 6; i++)
            valid = HorosCalibrationFloat([[customVectors cellWithTag:i] stringValue], locale, &v[i]) && valid;
        for (int i = 0; i < 3; i++)
            valid = HorosCalibrationFloat([[customOrigin cellWithTag:i] stringValue], locale, &o[i]) && valid;
        if (!valid)
        {
            HorosRunCriticalAlertPanel(NSLocalizedString(@"Error", nil),
                NSLocalizedString(@"Enter finite numeric values. Pixel spacing must be positive, and the slice interval must be nonzero for a series with multiple images.", nil),
                NSLocalizedString(@"OK", nil), nil, nil);
            return;
        }
    }

    [ThickIntervalWindow orderOut:sender];
    
    if( [sender tag])   //User clicks OK Button
    {
        long i, x;
        
        for( i = 0 ; i < maxMovieIndex; i++)
        {
            int		dir = 2;
            
            v[6] = v[1]*v[5] - v[2]*v[4];
            v[7] = v[2]*v[3] - v[0]*v[5];
            v[8] = v[0]*v[4] - v[1]*v[3];
            
            if( fabs( v[6]) > fabs(v[7]) && fabs( v[6]) > fabs(v[8])) dir = 0;
            if( fabs( v[7]) > fabs(v[6]) && fabs( v[7]) > fabs(v[8])) dir = 1;
            if( fabs( v[8]) > fabs(v[6]) && fabs( v[8]) > fabs(v[7])) dir = 2;
            
            for( x = 0; x < [pixList[ i] count]; x++)
            {
                DCMPix	*pix = nil;
                
                pix = [pixList[ i] objectAtIndex:x];
                
                [pix setSliceInterval: 0];
                [pix setPixelSpacingX: xSpacing];
                [pix setPixelSpacingY: ySpacing];
                if( xSpacing != 0 && ySpacing != 0) [pix setPixelRatio: ySpacing / xSpacing];
                [pix setOrientation: v];
                [pix setOrigin: o];
                [pix computeSliceLocation];
                
                switch( dir)
                {
                    case 0:	o[ 0] += interval;	break;
                    case 1:	o[ 1] += interval;	break;
                    case 2: o[ 2] += interval;	break;
                }
            }
        }
        
        [imageView setIndex: [imageView curImage]];
        
        [self computeInterval];
    }
    
    [ThickIntervalWindow.sheetParent endSheet:ThickIntervalWindow returnCode:[sender tag]];
}

- (IBAction) updateZVector:(id) sender
{
    float v[ 9];
    int i;
    
    for( i = 0; i < 9; i++) v[ i] = [[customVectors cellWithTag: i] floatValue];
    
    // Compute normal vector
    v[6] = v[1]*v[5] - v[2]*v[4];
    v[7] = v[2]*v[3] - v[0]*v[5];
    v[8] = v[0]*v[4] - v[1]*v[3];
    
    for( i = 6; i < 9; i++)  [[customVectors cellWithTag: i] setFloatValue: v[ i]];
}

- (IBAction) setAxialOrientation:(id) sender
{
    [customInterval selectText: self];
    
    float v[ 9];
    int i;
    
    v[ 0] = 1;		v[ 1] = 0;		v[ 2] = 0;
    v[ 3] = 0;		v[ 4] = 1;		v[ 5] = 0;
    v[ 6] = 0;		v[ 7] = 0;		v[ 8] = 1;
    
    for( i = 0; i < 9; i++) [[customVectors cellWithTag: i] setFloatValue: v[ i]];
}

- (void) SetThicknessInterval:(id) sender
{
    float v[ 9], o[ 3];
    long i;
    DCMPix *p = [pixList[ curMovieIndex] objectAtIndex:0];
    
    // Always populate the field, including zero, so a cancelled edit cannot survive reopening.
    [customInterval setFloatValue: [p sliceInterval] != 0 ? [p sliceInterval] : [p spacingBetweenSlices]];

    [customXSpacing setFloatValue: [p pixelSpacingX]];
    [customYSpacing setFloatValue: [p pixelSpacingY]];
    
    [p orientation: v];
    
    if( v[ 0] == 0 && v[ 1] == 0 && v[ 2] == 0)
    {
        v[ 0] = 1;		v[ 1] = 0;		v[ 2] = 0;
        v[ 3] = 0;		v[ 4] = 1;		v[ 5] = 0;
        v[ 6] = 0;		v[ 7] = 0;		v[ 8] = 1;
    }
    
    for( i = 0; i < 9; i++) [[customVectors cellWithTag: i] setFloatValue: v[ i]];
    
    o[ 0] = [p originX];
    o[ 1] = [p originY];
    o[ 2] = [p originZ];
    for( i = 0; i < 3; i++) [[customOrigin cellWithTag: i] setFloatValue: o[ i]];
    
    [[self window] beginSheet:ThickIntervalWindow completionHandler:^(NSModalResponse returnCode) {
        [self sheetDidEnd:ThickIntervalWindow returnCode:(int)returnCode contextInfo:sender];
    }];
}

- (void)deleteWLWW:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    NSString	*name = (id) contextInfo;
    
    if( returnCode == 1)
    {
        NSMutableDictionary *presetsDict = [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"WLWW3"] mutableCopy] autorelease];
        [presetsDict removeObjectForKey: name];
        [[NSUserDefaults standardUserDefaults] setObject: presetsDict forKey:@"WLWW3"];
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateWLWWMenuNotification object: curWLWWMenu userInfo: [NSDictionary dictionary]];
    }
    
    [name release];
}

- (void) ApplyWLWW:(id) sender
{
    NSString *name = [sender title];
    
    if( [[sender title] isEqualToString:NSLocalizedString(@"Other", nil)])
    {
    }
    else if( [[sender title] isEqualToString:NSLocalizedString(@"Default WL & WW", nil)])
    {
        [imageView setWLWW:[[imageView curDCM] savedWL] :[[imageView curDCM] savedWW]];
    }
    else if( [[sender title] isEqualToString:NSLocalizedString(@"Full dynamic", nil)])
    {
        [imageView setWLWW:0 :0];
    }
    else
    {
        name = [[sender title] substringFromIndex: 4];
        
        if ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift)
        {
            void *presetContext = [name retain];
            [HorosAlertPanel beginWithTitle:NSLocalizedString(@"Remove a WL/WW preset", nil)
                                   message:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete preset : '%@'?", nil), name]
                             defaultButton:NSLocalizedString(@"Delete", nil) alternateButton:NSLocalizedString(@"Cancel", nil) otherButton:nil
                            modalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
                [self deleteWLWW:nil returnCode:(int)returnCode contextInfo:presetContext];
            }];
            
            return;
        }
        else
        {
            NSArray		*value = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"WLWW3"] objectForKey: name];
            [imageView setWLWW:[[value objectAtIndex: 0] floatValue] :[[value objectAtIndex: 1] floatValue]];
        }
    }
    
    [[[wlwwPopup menu] itemAtIndex:0] setTitle: [sender title]];
    [self propagateSettings];
    
    if( curWLWWMenu != name)
    {
        [curWLWWMenu release];
        curWLWWMenu = [name retain];
    }
    
    [wlwwPopup setTitle: curWLWWMenu];
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateWLWWMenuNotification object: curWLWWMenu userInfo: nil];
    
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:[imageView curImage]]  forKey:@"curImage"];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixDCMUpdateCurrentImageNotification object: imageView userInfo: userInfo];
}

-(IBAction) updateSetWLWW:(id) sender
{
    if( [sender tag] == 0)
    {
        float level = [HorosWindowLevelText valueFromString: [wlset stringValue] fallback: 0];
        float width = [HorosWindowLevelText widthFromString: [wwset stringValue] fallback: 1];
        
        [imageView setWLWW: level : width];
        
        [fromset setStringValue: [HorosWindowLevelText stringForValue: level - width/2]];
        [toset setStringValue: [HorosWindowLevelText stringForValue: level + width/2]];
    }
    else
    {
        float from = [HorosWindowLevelText valueFromString: [fromset stringValue] fallback: 0];
        float to = [HorosWindowLevelText valueFromString: [toset stringValue] fallback: 0];
        
        [imageView setWLWW: from + (to - from)/2 : to - from];
        [wlset setStringValue: [HorosWindowLevelText stringForValue: from + (to - from)/2]];
        [wwset setStringValue: [HorosWindowLevelText stringForValue: to - from]];
    }
}

static float oldsetww, oldsetwl;

-(IBAction) endSetWLWW:(id) sender
{
    [wlset selectText: self];
    
    [setWLWWWindow orderOut:sender];
    
    [setWLWWWindow.sheetParent endSheet:setWLWWWindow returnCode:[sender tag]];
    
    if( [sender tag])   //User clicks OK Button
    {
        [imageView setWLWW: [HorosWindowLevelText valueFromString: [wlset stringValue] fallback: oldsetwl]
                          : [HorosWindowLevelText widthFromString: [wwset stringValue] fallback: oldsetww]];
    }
    else
    {
        [imageView setWLWW: oldsetwl :oldsetww ];
    }
}

- (IBAction) SetWLWW:(id) sender
{
    float cwl, cww;
    
    [imageView getWLWW:&cwl :&cww];
    
    oldsetww = cww;
    oldsetwl = cwl;
    
    [wlset setStringValue: [HorosWindowLevelText stringForValue: cwl]];
    [wwset setStringValue: [HorosWindowLevelText stringForValue: cww]];
    
    [fromset setStringValue: [HorosWindowLevelText stringForValue: cwl - cww/2]];
    [toset setStringValue: [HorosWindowLevelText stringForValue: cwl + cww/2]];
    
    [[self window] beginSheet:setWLWWWindow completionHandler:nil];
}

//static NSMutableArray		*TEMPviewersList;
//
//-(IBAction) endSyncSetOffset:(id) sender
//{
//    NSLog(@"endSyncSetOffset");
//
//    [syncOffsetWindow orderOut:sender];
//
//    [syncOffsetWindow.sheetParent endSheet:syncOffsetWindow returnCode:[sender tag]];
//
//    if( [sender tag])   //User clicks OK Button
//    {
//		[imageView setSyncRelativeDiff: [syncOffsetText floatValue]];
//    }
//
//	[TEMPviewersList release];
//}
//
//- (IBAction) syncSelectSeriesPopup: (id) sender
//{
//	long				i, x;
//
//	float diff = [[[[TEMPviewersList objectAtIndex:[sender tag]] imageView] curDCM] sliceLocation] - [[imageView curDCM] sliceLocation];
//
//	[syncOffsetText setFloatValue: diff];
//}
//
//- (void) syncSetOffset
//{
//	NSArray				*winList = [NSApp windows];
//	BOOL				found = NO;
//	long				i, x;
//
//	TEMPviewersList = [[NSMutableArray alloc] initWithCapacity:0];
//
//	[syncOffsetToSeries removeAllItems];
//
//	for( x = 0, i = 0; i < [winList count]; i++)
//	{
//		if( [[[winList objectAtIndex:i] windowController] isKindOfClass:[ViewerController class]])
//		{
//			if( [[winList objectAtIndex:i] windowController] != self)
//			{
//				[syncOffsetToSeries addItemWithTitle: [[[[winList objectAtIndex:i] windowController] window] title]];
//				[[syncOffsetToSeries lastItem] setTag: x++];
//				[TEMPviewersList addObject: [[winList objectAtIndex:i] windowController]];
//			}
//		}
//	}
//
//	[syncOffsetSeries setStringValue: [[self window] title]];
//
//	[syncOffsetText setIntValue: [imageView syncRelativeDiff]];
//    [[self window] beginSheet:syncOffsetWindow completionHandler:nil];
//}


- (NSString*) curWLWWMenu
{
    return curWLWWMenu;
}

- (NSString*) curOpacityMenu
{
    return curOpacityMenu;
}

#pragma mark convolution
// The methods of this block are implemented in Swift since #832
// (ViewerController+Convolution.swift), with the same selectors.

#pragma mark-
#pragma mark 4.1.1.4.a Presentation LUT

#pragma mark-
#pragma mark 4.1.1.4.b Pseudo Color

- (void)deleteCLUT:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    if( returnCode == 1)
    {
        NSMutableDictionary *clutDict	= [[[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"CLUT"] mutableCopy] autorelease];
        [clutDict removeObjectForKey: (id) contextInfo];
        [[NSUserDefaults standardUserDefaults] setObject: clutDict forKey: @"CLUT"];
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateCLUTMenuNotification object: curCLUTMenu userInfo: [NSDictionary dictionary]];
    }
}

-(void) ApplyCLUTString:(NSString*) str
{
    if( blendingController && [[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] isEqualToString: @"B/W Inverse"])
    {
        NSString *c = [[NSUserDefaults standardUserDefaults] stringForKey: @"PET Blending CLUT"];
        [[NSUserDefaults standardUserDefaults] setValue: str forKey: @"PET Blending CLUT"];
        [DCMView computePETBlendingCLUT];
        [[NSUserDefaults standardUserDefaults] setValue: c forKey: @"PET Blending CLUT"];
        
        [curCLUTMenu release];
        curCLUTMenu = [str copy];
        
        [[[clutPopup menu] itemAtIndex:0] setTitle: str];
    }
    else
    {
        if( [str isEqualToString:NSLocalizedString(@"No CLUT", nil)])
        {
            for( int x = 0; x < maxMovieIndex; x++)
            {
                for( DCMPix *p in pixList[ x]) [p setBlackIndex: 0];
            }
            
            [imageView setCLUT: nil :nil :nil];
            if( thickSlab)
            {
                [thickSlab setCLUT:nil :nil :nil];
            }
            
            [imageView setIndex:[imageView curImage]];
            
            if( str != curCLUTMenu)
            {
                [curCLUTMenu release];
                curCLUTMenu = [str retain];
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateCLUTMenuNotification object: curCLUTMenu userInfo: nil];
            
            [[[clutPopup menu] itemAtIndex:0] setTitle:str];
            
            [self propagateSettings];
        }
        else
        {
            NSDictionary		*aCLUT;
            NSArray				*array;
            long				i;
            unsigned char		red[256], green[256], blue[256];
            
            aCLUT = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"CLUT"] objectForKey:str];
            if( aCLUT)
            {
                array = [aCLUT objectForKey:@"Red"];
                for( i = 0; i < 256; i++)
                {
                    red[i] = [[array objectAtIndex: i] longValue];
                }
                
                array = [aCLUT objectForKey:@"Green"];
                for( i = 0; i < 256; i++)
                {
                    green[i] = [[array objectAtIndex: i] longValue];
                }
                
                array = [aCLUT objectForKey:@"Blue"];
                for( i = 0; i < 256; i++)
                {
                    blue[i] = [[array objectAtIndex: i] longValue];
                }
                
                if( thickSlab)
                {
                    [thickSlab setCLUT:red :green :blue];
                }
                
                int darkness = 256 * 3;
                int darknessIndex = 0;
                
                for( i = 0; i < 256; i++)
                {
                    if( red[i] + green[i] + blue[i] < darkness)
                    {
                        darknessIndex = i;
                        darkness = red[i] + green[i] + blue[i];
                    }
                }
                
                int x;
                for ( x = 0; x < maxMovieIndex; x++)
                {
                    for ( i = 0; i < [pixList[ x] count]; i ++)
                    {
                        [[pixList[ x] objectAtIndex:i] setBlackIndex: darknessIndex];
                    }
                }
                
                [imageView setCLUT:red :green: blue];
                
                [imageView setIndex:[imageView curImage]];
                if( str != curCLUTMenu)
                {
                    [curCLUTMenu release];
                    curCLUTMenu = [str retain];
                }
                
                [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateCLUTMenuNotification object: curCLUTMenu userInfo: nil];
                
                [self propagateSettings];
                [[[clutPopup menu] itemAtIndex:0] setTitle:str];
            }
        }
    }
    
    if( [curCLUTMenu isEqualToString: @"B/W Inverse"])
        imageView.whiteBackground = YES;
    else
        imageView.whiteBackground = NO;
    
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:[imageView curImage]]  forKey:@"curImage"];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixDCMUpdateCurrentImageNotification object: imageView userInfo: userInfo];
    
    float   iwl, iww;
    [imageView getWLWW:&iwl :&iww];
    [imageView setWLWW:iwl :iww];
}

- (void) CLUTChanged: (NSNotification*) note
{
    unsigned char   r[256], g[256], b[256];
    
    [[note object] ConvertCLUT: r :g :b];
    
    [imageView setCLUT :r : g : b];
    [imageView setIndex:[imageView curImage]];
}

- (void) ApplyCLUT:(id) sender
{
    if ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift)
    {
        NSString *title = [sender title];
        [HorosAlertPanel beginWithTitle:NSLocalizedString(@"Remove a Color Look Up Table", nil)
                               message:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete this CLUT : '%@'", nil), title]
                         defaultButton:NSLocalizedString(@"Delete", nil) alternateButton:NSLocalizedString(@"Cancel", nil) otherButton:nil
                        modalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
            [self deleteCLUT:nil returnCode:(int)returnCode contextInfo:title];
        }];
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateCLUTMenuNotification object: curCLUTMenu userInfo: [NSDictionary dictionary]];
    }
    else if ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagOption)
    {
        NSDictionary		*aCLUT;
        
        [self ApplyCLUTString:[sender title]];
        
        aCLUT = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"CLUT"] objectForKey: curCLUTMenu];
        if( aCLUT)
        {
            if( [aCLUT objectForKey:@"Points"] != nil)
            {
                [self clutAction:self];
                [clutName setStringValue: [sender title]];
                
                NSMutableArray	*pts = [clutView getPoints];
                NSMutableArray	*cols = [clutView getColors];
                
                [pts removeAllObjects];
                [cols removeAllObjects];
                
                [pts addObjectsFromArray: [aCLUT objectForKey:@"Points"]];
                [cols addObjectsFromArray: [aCLUT objectForKey:@"Colors"]];
                
                [[self window] beginSheet:addCLUTWindow completionHandler:nil];
                
                [clutView setNeedsDisplay:YES];
            }
            else
            {
                HorosRunAlertPanel(NSLocalizedString(@"Error", nil), NSLocalizedString(@"Only CLUT created in OsiriX 1.3.1 or higher can be edited...", nil), nil, nil, nil);
            }
        }
    }
    else
    {
        [self ApplyCLUTString:[sender title]];
    }
}

-(IBAction) endCLUT:(id) sender
{
    [addCLUTWindow orderOut:sender];
    
    [addCLUTWindow.sheetParent endSheet:addCLUTWindow returnCode:[sender tag]];
    
    if( [sender tag])   //User clicks OK Button
    {
        NSMutableDictionary *clutDict		= [[[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"CLUT"] mutableCopy] autorelease];
        NSMutableDictionary *aCLUTFilter	= [NSMutableDictionary dictionary];
        unsigned char		red[256], green[256], blue[256];
        long				i;
        
        [clutView ConvertCLUT: red: green: blue];
        
        
        NSMutableArray		*rArray = [NSMutableArray array];
        NSMutableArray		*gArray = [NSMutableArray array];
        NSMutableArray		*bArray = [NSMutableArray array];
        for( i = 0; i < 256; i++) [rArray addObject: [NSNumber numberWithLong: red[ i]]];
        for( i = 0; i < 256; i++) [gArray addObject: [NSNumber numberWithLong: green[ i]]];
        for( i = 0; i < 256; i++) [bArray addObject: [NSNumber numberWithLong: blue[ i]]];
        
        [aCLUTFilter setObject:rArray forKey:@"Red"];
        [aCLUTFilter setObject:gArray forKey:@"Green"];
        [aCLUTFilter setObject:bArray forKey:@"Blue"];
        
        [aCLUTFilter setObject:[NSArray arrayWithArray: [[[clutView getPoints] copy] autorelease]] forKey:@"Points"];
        [aCLUTFilter setObject:[NSArray arrayWithArray: [[[clutView getColors] copy] autorelease]] forKey:@"Colors"];
        
        [clutDict setObject: aCLUTFilter forKey: [clutName stringValue]];
        [[NSUserDefaults standardUserDefaults] setObject: clutDict forKey: @"CLUT"];
        
        // Apply it!
        
        if( [clutName stringValue] != curCLUTMenu)
        {
            [curCLUTMenu release];
            curCLUTMenu = [[clutName stringValue] retain];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateCLUTMenuNotification object: curCLUTMenu userInfo: [NSDictionary dictionary]];
        
        [self ApplyCLUTString:curCLUTMenu];
    }
    else
    {
        [self ApplyCLUTString:curCLUTMenu];
    }
}

- (IBAction) clutAction:(id)sender
{
    //	[imageView setCLUT:matrix :[[sizeMatrix selectedCell] tag] :[matrixNorm intValue]];
    [imageView setIndex:[imageView curImage]];
}


- (void) OpacityChanged: (NSNotification*) note
{
    NSArray *array = [[note object] getPoints];
    
    [thickSlab setOpacity: array];
    
    NSData *table = nil;
    
    if( [array count] == 0)
        table = nil;
    else
        table = [OpacityTransferView tableWith4096Entries: array];
    
    for( int x = 0; x < maxMovieIndex; x++)
    {
        for( DCMPix * pix in pixList[ x])
            [pix setTransferFunction: table];
    }
    
    [self updateImage:self];
}

-(void) ApplyOpacityString:(NSString*) str
{
    NSDictionary		*aOpacity;
    NSArray				*array;
    
    if( [str isEqualToString:NSLocalizedString(@"Linear Table", nil)])
    {
        [thickSlab setOpacity:[NSArray array]];
        
        if( curOpacityMenu != str)
        {
            [curOpacityMenu release];
            curOpacityMenu = [str retain];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateOpacityMenuNotification object: curOpacityMenu userInfo: nil];
        
        [[[OpacityPopup menu] itemAtIndex:0] setTitle:str];
        
        for( int x = 0; x < maxMovieIndex; x++)
        {
            for( int i = 0; i < [pixList[ x] count]; i++)
                [[pixList[ x] objectAtIndex: i] setTransferFunction: nil];
        }
        
        [self updateImage:self];
    }
    else
    {
        aOpacity = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"OPACITY"] objectForKey: str];
        if (aOpacity)
        {
            array = [aOpacity objectForKey:@"Points"];
            
            [thickSlab setOpacity:array];
            if( curOpacityMenu != str)
            {
                [curOpacityMenu release];
                curOpacityMenu = [str retain];
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateOpacityMenuNotification object: curOpacityMenu userInfo: nil];
            
            [[[OpacityPopup menu] itemAtIndex:0] setTitle:str];
            
            NSData *table = nil;
            
            if( [array count] == 0)
                table = nil;
            else
                table = [OpacityTransferView tableWith4096Entries: [aOpacity objectForKey:@"Points"]];
            
            for( int x = 0; x < maxMovieIndex; x++)
            {
                for( int i = 0; i < [pixList[ x] count]; i++)
                    [[pixList[ x] objectAtIndex: i] setTransferFunction: table];
            }
        }
        [self updateImage:self];
    }
    
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:[imageView curImage]]  forKey:@"curImage"];
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixDCMUpdateCurrentImageNotification object: imageView userInfo: userInfo];
    
    NSArray *viewers = [ViewerController getDisplayed2DViewers];
    
    for( ViewerController *v in viewers)
        [v updateImage: self];
}

- (void)deleteOpacity:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    if( returnCode == 1)
    {
        NSMutableDictionary *clutDict	= [[[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"OPACITY"] mutableCopy] autorelease];
        [clutDict removeObjectForKey: (id) contextInfo];
        [[NSUserDefaults standardUserDefaults] setObject: clutDict forKey: @"OPACITY"];
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateOpacityMenuNotification object: curCLUTMenu userInfo: [NSDictionary dictionary]];
    }
}

- (void) ApplyOpacity: (id) sender
{
    if ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift)
    {
        NSString *title = [sender title];
        [HorosAlertPanel beginWithTitle:NSLocalizedString(@"Remove a Color Look Up Table", nil)
                               message:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete this Opacity Table : '%@'", nil), title]
                         defaultButton:NSLocalizedString(@"Delete", nil) alternateButton:NSLocalizedString(@"Cancel", nil) otherButton:nil
                        modalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
            [self deleteOpacity:nil returnCode:(int)returnCode contextInfo:title];
        }];
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateOpacityMenuNotification object: curOpacityMenu userInfo: [NSDictionary dictionary]];
    }
    else if ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagOption)
    {
        NSDictionary		*aOpacity, *aCLUT;
        NSArray				*array;
        long				i;
        unsigned char		red[256], green[256], blue[256];
        
        [self ApplyOpacityString:[sender title]];
        
        aOpacity = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"OPACITY"] objectForKey: curOpacityMenu];
        if( aOpacity)
        {
            aCLUT = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"CLUT"] objectForKey: curCLUTMenu];
            if( aCLUT)
            {
                array = [aCLUT objectForKey:@"Red"];
                for( i = 0; i < 256; i++)
                {
                    red[i] = [[array objectAtIndex: i] longValue];
                }
                
                array = [aCLUT objectForKey:@"Green"];
                for( i = 0; i < 256; i++)
                {
                    green[i] = [[array objectAtIndex: i] longValue];
                }
                
                array = [aCLUT objectForKey:@"Blue"];
                for( i = 0; i < 256; i++)
                {
                    blue[i] = [[array objectAtIndex: i] longValue];
                }
                
                [OpacityView setCurrentCLUT:red :green: blue];
            }
            
            if( [aOpacity objectForKey:@"Points"] != nil)
            {
                [OpacityName setStringValue: curOpacityMenu];
                
                NSMutableArray	*pts = [OpacityView getPoints];
                
                [pts removeAllObjects];
                
                [pts addObjectsFromArray: [aOpacity objectForKey:@"Points"]];
                
                [[self window] beginSheet:addOpacityWindow completionHandler:nil];
                
                [OpacityView setNeedsDisplay:YES];
            }
        }
    }
    else
    {
        [self ApplyOpacityString:[sender title]];
    }
}

-(IBAction) endOpacity: (id) sender
{
    [addOpacityWindow orderOut: sender];
    
    [addOpacityWindow.sheetParent endSheet:addOpacityWindow returnCode: [sender tag]];
    
    if ([sender tag])   //User clicks OK Button
    {
        NSMutableDictionary		*opacityDict	= [[[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"OPACITY"] mutableCopy] autorelease];
        NSMutableDictionary		*aOpacityFilter	= [NSMutableDictionary dictionary];
        
        [aOpacityFilter setObject: [[[OpacityView getPoints] copy] autorelease] forKey: @"Points"];
        [opacityDict setObject: aOpacityFilter forKey: [OpacityName stringValue]];
        [[NSUserDefaults standardUserDefaults] setObject: opacityDict forKey: @"OPACITY"];
        
        // Apply it!
        
        if( curOpacityMenu != [OpacityName stringValue])
        {
            [curOpacityMenu release];
            curOpacityMenu = [[OpacityName stringValue] retain];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateOpacityMenuNotification object: curOpacityMenu userInfo: [NSDictionary dictionary]];
        
        [self ApplyOpacityString:curOpacityMenu];
    }
    else
    {
        [self ApplyOpacityString:curOpacityMenu];
    }
}

- (NSString*) curCLUTMenu
{
    if( backCurCLUTMenu)
        return backCurCLUTMenu;
    else
        return curCLUTMenu;
}


#pragma mark-
#pragma mark 4.1.1.4.c True Color

#pragma mark-
#pragma mark 4.1.1.4.d Indexed Color

#pragma mark-
#pragma mark 4.1.1.5 ICC input Profile

#pragma mark-
#pragma mark 4.1.2 Composition of various images

-(NSSlider*) sliderFusion { return sliderFusion;}

-(ThickSlabController*) thickSlabController { return thickSlab;}

-(NSString *) thicknessInMm
{
    float thickness = 0, location = 0;
    
    [imageView getThickSlabThickness:&thickness location:&location];
    
    return [NSString stringWithFormat: @"%2.1f mm", thickness];
}

- (void) setFusionMode:(long) m
{
    int i, x;
    
    if( m != 0)
    {
        if( [fileList[ curMovieIndex] count])
        {
            int pw = [[[fileList[ curMovieIndex] lastObject] valueForKey:@"width"] intValue];
            int ph = [[[fileList[ curMovieIndex] lastObject] valueForKey:@"height"] intValue];
            
            for( NSManagedObject *f in fileList[ curMovieIndex])
            {
                if( pw != [[f valueForKey:@"width"] intValue])
                    m = 0;
                if( ph != [[f valueForKey:@"height"] intValue])
                    m = 0;
            }
        }
    }
    
    // Thick Slab
    if( m == 4 || m == 5)
    {
        BOOL	flip;
        
        //		[OpacityPopup setEnabled:YES];
        
        if( m == 4) flip = YES;
        else flip = NO;
        
        if( thickSlab == nil)
        {
            unsigned char *r, *g, *b;
            DCMPix  *pix = [pixList[ curMovieIndex] objectAtIndex:0];
            
#ifndef OSIRIX_LIGHT
            thickSlab = [[ThickSlabController alloc] init];
#endif
            
            [thickSlab setImageData :[pix pwidth] :[pix pheight] :100 :[pix pixelSpacingX] :[pix pixelSpacingY] :[pix sliceThickness] :flip];
            
            [imageView getCLUT: &r :&g :&b];
            [thickSlab setCLUT:r :g :b];
        }
        
        [thickSlab setFlip: flip];
        
        for ( x = 0; x < maxMovieIndex; x++)
        {
            for ( i = 0; i < [pixList[ x] count]; i ++)
            {
                [[pixList[ x] objectAtIndex:i] setThickSlabController: thickSlab];
            }
        }
    }
    //	else [OpacityPopup setEnabled:NO];
    
    [imageView setFusion:m :[sliderFusion intValue]];
    
    for ( x = 0; x < maxMovieIndex; x++)
    {
        if( x != curMovieIndex) // [imageView setFusion] already did it for current serie!
        {
            for ( i = 0; i < [pixList[ x] count]; i ++)
            {
                [[pixList[ x] objectAtIndex:i] setFusion:m :[sliderFusion intValue] :-1];
            }
        }
    }
    
    if( m == 0)
    {
        [activatedFusion setState: NSControlStateValueOff];
        [sliderFusion setEnabled:NO];
    }
    else
    {
        [activatedFusion setState: NSControlStateValueOn];
        [sliderFusion setEnabled:YES];
    }
    
    //	[imageView sendSyncMessage: 0];
    
    float   iwl, iww;
    [imageView getWLWW:&iwl :&iww];
    [imageView setWLWW:iwl :iww];
    
    // The toolbar shows the slab's thickness: it changed with the mode (#985).
    [self willChangeValueForKey: @"thicknessInMm"];
    [self didChangeValueForKey: @"thicknessInMm"];
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRecomputeROINotification object:self userInfo: nil];
}

- (void) adjustThickSlabBySteps:(NSInteger)steps
{
    if (!steps || windowWillClose) return;
    NSInteger maximum = (NSInteger)sliderFusion.maxValue;
    for (int movie = 0; movie < maxMovieIndex; ++movie)
        maximum = MIN(maximum, (NSInteger)[pixList[movie] count]);
    if (maximum < 2) return;

    BOOL active = activatedFusion.state == NSControlStateValueOn;
    NSInteger current = active ? sliderFusion.integerValue : 1;
    // Activating always starts at two, regardless of saved thickness or the
    // amplitude of this first event. Clamp before adding to avoid overflow.
    NSInteger next = active ? MAX(1, MIN(maximum, current + MAX(-128, MIN(128, steps)))) : (steps > 0 ? 2 : 1);
    if (next == current) return;
    if (next == 1)
    {
        [self setFusionMode:0];
        [stacksFusion setIntValue:1];
        [imageView sendSyncMessage:0];
        return; // The disabled slider retains a valid value >= 2.
    }

    [sliderFusion setIntegerValue:next];
    if (!active)
    {
        [self popFusionAction:popFusion]; // Existing preparation, mode and refusal checks.
        if (activatedFusion.state != NSControlStateValueOn)
        {
            [stacksFusion setIntValue:1];
            return;
        }
        // setFusionMode already updated all phases; do not project twice.
        [stacksFusion setIntegerValue:next];
        [[NSUserDefaults standardUserDefaults] setInteger:next forKey:@"stackThickness"];
    }
    else
        [self sliderFusionAction:sliderFusion];
}

- (void) activateFusion:(id) sender
{
    if( [sender state] == NSControlStateValueOff)
        [self setFusionMode: 0];
    else
        [self setFusionMode: [[popFusion selectedItem] tag]];
    
    [imageView sendSyncMessage: 0];
}

- (void) popFusionAction:(id) sender
{
    int tag = [[sender selectedItem] tag];
    
    [self checkEverythingLoaded];
    [self computeInterval];
    
    [self setFusionMode: tag];
    
    [imageView sendSyncMessage: 0];
}

- (void) sliderFusionAction:(id) sender
{
    [imageView setFusion:-1 :[sender intValue]];
    
    for( int x = 0; x < maxMovieIndex; x++)
    {
        if( x != curMovieIndex) // [imageView setFusion] already did it for current serie!
        {
            for( int i = 0; i < [pixList[ x] count]; i ++)
            {
                [[pixList[ x] objectAtIndex:i] setFusion:-1 :[sender intValue] :-1];
            }
        }
    }
    
    [stacksFusion setIntValue:[sender intValue]];
    
    [self willChangeValueForKey: @"thicknessInMm"];
    [self didChangeValueForKey: @"thicknessInMm"];
    
    [[NSUserDefaults standardUserDefaults] setInteger:[sender intValue] forKey:@"stackThickness"];
    
    [imageView sendSyncMessage: 0];
}
#pragma mark blending
// The methods of this block are implemented in Swift since #832
// (ViewerController+Blending.swift), with the same selectors, except
// -blendedWindow, the getter of the declared property.
-(ViewerController*) blendedWindow
{
    return blendedWindow;
}

#pragma mark-
#pragma mark 4.1.3 Anchored graphical layer
#pragma mark ROI
// The methods of this block are implemented in Swift since #832
// (ViewerController+ROI.swift and ViewerController+ROI+Editing.swift), with
// the same selectors, except -newROI: and -newPoint::: Swift would return the
// result of a new-family method retained, the Objective-C returns it
// autoreleased.
- (ROI*) newROI: (ToolMode) type
{
    DCMPix *curPix = [imageView curDCM];
    ROI		*theNewROI;
    
    theNewROI = [[[ROI alloc] initWithType: type :[curPix pixelSpacingX] :[curPix pixelSpacingY] :[DCMPix originCorrectedAccordingToOrientation: curPix]] autorelease];
    
    [imageView roiSet: theNewROI];
    
    return theNewROI;
}
- (MyPoint*) newPoint: (float) x :(float) y
{
    return( [MyPoint point: NSMakePoint(x, y)]);
}

#pragma mark BrushTool and ROI filters

-(void) brushTool:(id) sender
{
    BOOL	found = NO;
    NSArray *winList = [NSApp windows];
    
    for( id loopItem in winList)
    {
        // Not a palette whose window is closing: its -windowWillClose:
        // autoreleased it, and it goes with a window shown again on screen.
        if( [[[loopItem windowController] windowNibName] isEqualToString:@"PaletteBrush"] && !([[loopItem windowController] respondsToSelector: @selector(windowWillClose)] && [(id) [loopItem windowController] windowWillClose]))
        {
            found = YES;
        }
    }
    
    if( !found)
    {
        /*PaletteController *palette = */[[PaletteController alloc] initWithViewer: self];
    }
    //	else [self setROIToolTag: tPlain];
}

- (NSRecursiveLock*) roiLock { return roiLock;}

#ifndef OSIRIX_LIGHT
- (void) applyMorphology: (NSArray*) rois action:(NSString*) action	radius: (long) radius sendNotification: (BOOL) sendNotification
{
    NSLog( @"****** applyMorphology - START");
    
    
    [roiLock lock];
    
    ITKBrushROIFilter *filter = nil;
    
    @try
    {
        filter = [[ITKBrushROIFilter alloc] init];
        
        NSOperationQueue *queue = [[[NSOperationQueue alloc] init] autorelease];
        
        for ( int i = 0; i < [rois count]; i++)
        {
            ViewerControllerOperation *op = [[[ViewerControllerOperation alloc] initWithController: self dict: [NSDictionary dictionaryWithObjectsAndKeys: [rois objectAtIndex:i], @"roi", action, @"action", filter, @"filter", [NSNumber numberWithInt: radius], @"radius", nil]] autorelease];
            
            [queue addOperation: op];
        }
        
        [queue waitUntilAllOperationsAreFinished];
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [roiLock unlock];
    
    if( sendNotification)
        for ( int i = 0; i < [rois count]; i++) [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIChangeNotification object:[rois objectAtIndex:i] userInfo: nil];
    
    [filter release];
    
    NSLog( @"****** applyMorphology - END");
}

- (IBAction) setStructuringElementRadius: (id) sender
{
    [structuringElementRadiusTextField setStringValue:[NSString stringWithFormat:@"%d",[structuringElementRadiusSlider intValue]]];
}

- (IBAction) morphoSelectedBrushROIWithRadius: (id) sender
{
    [brushROIFilterOptionsWindow orderOut: sender];
    [brushROIFilterOptionsWindow.sheetParent endSheet:brushROIFilterOptionsWindow];
    
    if( [sender tag])
    {
        ROI *selectedROI = [self selectedROI];
        
        // do the morpho function...
        ITKBrushROIFilter *filter = [[ITKBrushROIFilter alloc] init];
        
        WaitRendering	*wait = [[WaitRendering alloc] init: NSLocalizedString(@"Processing...",nil)];
        [wait showWindow:self];
        if ([brushROIFilterOptionsAllWithSameName state]==NSControlStateValueOff)
        {
            [self applyMorphology: [NSArray arrayWithObject:selectedROI] action:morphoFunction radius: [structuringElementRadiusSlider intValue] sendNotification:YES];
        }
        else
        {
            [self applyMorphology: [self roisWithName:[selectedROI name] in4D:YES] action:morphoFunction radius: [structuringElementRadiusSlider intValue] sendNotification:YES];
        }
        [filter release];
        [wait close];
        [wait autorelease];
    }
}

- (IBAction) morphoSelectedBrushROI: (id) sender
{
    ROI *selectedROI = [self selectedROI];
    
    [morphoFunction release];
    
    switch( [sender tag])
    {
        case 0:		morphoFunction = [@"erode" retain];		break;
        case 1:		morphoFunction = [@"dilate" retain];	break;
        case 2:		morphoFunction = [@"close" retain];		break;
        case 3:		morphoFunction = [@"open" retain];		break;
    }
    
    if (selectedROI && [selectedROI type] == tPlain)
    {
        [self addToUndoQueue: @"roi"];
        
        [[self window] beginSheet:brushROIFilterOptionsWindow completionHandler:nil];
    }
    else
    {
        HorosRunCriticalAlertPanel(NSLocalizedString(@"Brush ROI Error", nil), NSLocalizedString(@"Select a Brush ROI before to run the filter.", nil) , NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
}
#endif

- (ROI*) convertPolygonROItoBrush:(ROI*) selectedROI
{
    ROI *theNewROI = nil;
    
    if( selectedROI.type == tOval)
    {
        NSMutableArray *points = selectedROI.points;
        if( selectedROI.type == tROI)
            selectedROI.isSpline = NO;
        
        selectedROI.type = tCPolygon;
        selectedROI.points = points;
    }
    
    if( selectedROI.type == tCPolygon || selectedROI.type == tOPolygon || selectedROI.type == tPencil)
    {
        NSSize s;
        NSPoint o;
        unsigned char* texture = [DCMPix getMapFromPolygonROI: selectedROI size: &s origin: &o];
        
        if( texture)
        {
            theNewROI = [[ROI alloc]		initWithTexture: texture
                                            textWidth: s.width
                                           textHeight: s.height
                                             textName: @""
                                            positionX: o.x
                                            positionY: o.y
                                             spacingX: [[imageView curDCM] pixelSpacingX]
                                             spacingY: [[imageView curDCM] pixelSpacingY]
                                          imageOrigin: NSMakePoint([[imageView curDCM] originX], [[imageView curDCM] originY])];
            if( [theNewROI reduceTextureIfPossible] == NO)	// NO means that the ROI is NOT empty
            {
            }
            else
            {
                [theNewROI release];
                theNewROI = nil;
            }
            
            free( texture);
        }
    }
    
    return [theNewROI autorelease];
}


- (ROI*) convertBrushROItoPolygon:(ROI*) selectedROI numPoints: (int) numPoints
{
    ROI* newROI = nil;
    
#ifndef OSIRIX_LIGHT
    if( [selectedROI type] == tPlain)
    {
        // Convert it to Brush
        newROI = [self newROI: tCPolygon];
        
        NSArray	*points = [ITKSegmentation3D extractContour: [selectedROI textureBuffer] width: [selectedROI textureWidth] height: [selectedROI textureHeight] numPoints: numPoints];
        
        int		i;
        NSMutableArray	*pts = [NSMutableArray array];
        
        for( i = 0 ; i < [points count] ; i++)
        {
            [[points objectAtIndex: i] move: [selectedROI textureUpLeftCornerX] :[selectedROI textureUpLeftCornerY]];
        }
        
        for( i = 0 ; i < numPoints ; i++)
        {
            float x = (float) (i * [points count]) / (float) numPoints;
            int xint = (int) x;
            
            MyPoint *a = [points objectAtIndex: xint];
            
            MyPoint *b;
            if( xint+1 == [points count])  b = [points objectAtIndex: 0];
            else b = [points objectAtIndex: xint+1];
            
            NSPoint c = [ROI pointBetweenPoint: [a point] and: [b point] ratio: x - (float) xint];
            
            [pts addObject: [MyPoint point: c]];
        }
        
        [newROI setPoints: pts];
    }
#endif
    
    return newROI;
}

-(int) imageIndexOfROI:(ROI*) c
{
    int x, i;
    
    for( x = 0; x < [pixList[ curMovieIndex] count]; x++)
    {
        for( i = 0; i < [[roiList[ curMovieIndex] objectAtIndex: x] count]; i++)
        {
            ROI *curROI = [[roiList[ curMovieIndex] objectAtIndex: x] objectAtIndex:i];
            
            if( curROI == c) return x;
        }
    }
    
    return -1;
}

- (IBAction) mergeBrushROI: (id) sender ROIs: (NSArray*) s ROIList: (NSMutableArray*) roiListContained
{
    if( [s count])
    {
        NSMutableArray *rois = [NSMutableArray array];
        
        for( ROI *r in s)
        {
            if( [r type] == tPlain) [rois addObject: r];
        }
        
        if( [rois count])
        {
            ROI *f = [rois lastObject];
            
            [rois removeLastObject];
            
            for( ROI *r in rois)
            {
                [f mergeWithTexture: r];
            }
            
            for( ROI *r in rois)
            {
                [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object: r userInfo: nil];
                [roiListContained removeObject: r];
            }
        }
    }
}

- (IBAction) mergeBrushROI: (id) sender
{
    return [self mergeBrushROI: sender ROIs: [self selectedROIs] ROIList: [roiList[ curMovieIndex] objectAtIndex: [imageView curImage]] ];
}

- (IBAction) convertBrushPolygon: (id) sender
{
    [self addToUndoQueue: @"roi"];
    [imageView stopROIEditingForce: YES];
    
    for( int i = 0; i < maxMovieIndex; i++)
        [self saveROI: i];
    
    NSArray *selectedROIs = [self roiApplyWindow: self];
    
    int tag;
    
    for( ROI *selectedROI in selectedROIs)
    {
        
        NSInteger index = [self imageIndexOfROI: selectedROI];
        
        if( index >= 0)
        {
            ROI	*newROI = nil;
            
            if( [selectedROI type] == tPlain) tag = 1;
            else tag = 0;
            
            switch( tag)
            {
                case 1:
                {
                    newROI = [self convertBrushROItoPolygon: selectedROI numPoints:100];
                    
                    if( newROI)
                    {
                        // Add the new ROI
                        [[selectedROI curView] roiSet: newROI];
                        [[roiList[curMovieIndex] objectAtIndex: index] addObject: newROI];
                        [newROI setROIMode: ROI_selected];
                        [newROI setName: [selectedROI name]];
                        [newROI setComments: [selectedROI comments]];
                    }
                }
                    break;
                    
                case 0:
                {
                    newROI = [self convertPolygonROItoBrush: selectedROI];
                    
                    if( newROI)
                    {
                        // Add the new ROI
                        [[selectedROI curView] roiSet: newROI];
                        [[roiList[curMovieIndex] objectAtIndex: index] addObject: newROI];
                        [newROI setROIMode: ROI_selected];
                        [newROI setName: [selectedROI name]];
                        [newROI setComments: [selectedROI comments]];
                    }
                }
                    break;
            }
            
            // Remove the old ROI
            if( newROI)
            {
                [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object:selectedROI userInfo: nil];
                [[roiList[curMovieIndex] objectAtIndex: index] removeObject: selectedROI];
            }
        }
    }
    
    [imageView setIndex: [imageView curImage]];
}

#pragma mark SUV

- (IBAction) cancel:(id)sender
{
    [NSApp stopModal];
    self.injectionDateTime = nil;
}

- (IBAction) ok:(id)sender
{
    [NSApp stopModal];
}

- (IBAction) editSUVinjectionTime:(id)sender
{
    if( [sender tag] == 0)
        self.injectionDateTime = [[[[imageView curDCM] radiopharmaceuticalStartTime] copy] autorelease];
    
    if( [sender tag] == 1)
        self.injectionDateTime = [[[[imageView curDCM] acquisitionTime] copy] autorelease];
    
    [displaySUVWindow beginSheet:injectionTimeWindow completionHandler:nil];
    
    [NSApp runModalForWindow: injectionTimeWindow];
    [injectionTimeWindow.sheetParent endSheet:injectionTimeWindow];
    [injectionTimeWindow orderOut: self];
    
    if( injectionDateTime != nil)
    {
        if( [sender tag] == 0)
        {
            [editedRadiopharmaceuticalStartTime release];
            editedRadiopharmaceuticalStartTime = [injectionDateTime copy];
        }
        
        if( [sender tag] == 1)
        {
            [editedAcquisitionTime release];
            editedAcquisitionTime = [injectionDateTime copy];
        }
        
        for( int y = 0; y < maxMovieIndex; y++)
        {
            for( DCMPix *p in pixList[y])
            {
                if( [sender tag] == 0)
                    p.radiopharmaceuticalStartTime = injectionDateTime;
                
                if( [sender tag] == 1)
                    p.acquisitionTime = injectionDateTime;
            }
        }
        
        if( [sender tag] == 0)
            [[suvForm cellAtIndex: 3] setObjectValue: injectionDateTime];
        
        if( [sender tag] == 1)
            [[suvForm cellAtIndex: 4] setObjectValue: injectionDateTime];
    }
}

- (float) factorPET2SUV
{
    return factorPET2SUV;
}

- (void) recomputePixMinMax
{
    for( int y = 0; y < maxMovieIndex; y++)
    {
        for( DCMPix * p in pixList[ y])
        {
            [p computePixMinPixMax];
            p.minValueOfSeries = 0;
            p.maxValueOfSeries = 0;
        }
    }
}

- (void) convertPETtoSUV
{
    long	y, x, i;
    BOOL	updatewlww = NO;
    double	updatefactor;
    
    if( [[imageView curDCM] isRGB]) return;
    if( [[[imageView curDCM] units] isEqualToString:@"CNTS"] && [[imageView curDCM] philipsFactor])
    {
        
    }
    else
    {
        if( [[imageView curDCM] radionuclideTotalDoseCorrected] <= 0) return;
        if( [[imageView curDCM] patientsWeight] <= 0) return;
    }
    if( [[imageView curDCM] hasSUV] == NO) return;
    
    if( [[imageView curDCM] SUVConverted] == NO)
    {
        updatewlww = YES;
        
        if( [[[imageView curDCM] units] isEqualToString:@"CNTS"]) updatefactor = [[imageView curDCM] philipsFactor];
        else updatefactor = [[imageView curDCM] patientsWeight] * 1000. / ([[imageView curDCM] radionuclideTotalDoseCorrected] * [[imageView curDCM] decayFactor]);
    }
    
    for( y = 0; y < maxMovieIndex; y++)
    {
        for( x = 0; x < [pixList[y] count]; x++)
        {
            DCMPix	*pix = [pixList[y] objectAtIndex: x];
            
            if( [pix SUVConverted] == NO)
            {
                float	*imageData = [pix fImage];
                if( [[pix units] isEqualToString:@"CNTS"])	// Philips
                {
                    factorPET2SUV = [pix philipsFactor];
                }
                else factorPET2SUV = ([pix patientsWeight] * 1000.) / ([pix radionuclideTotalDoseCorrected] * [pix decayFactor]);
                
                i = [pix pheight] * [pix pwidth];
                while( i--> 0)
                    *imageData++ *=  factorPET2SUV;
                
                pix.SUVConverted = YES;
                pix.factorPET2SUV = factorPET2SUV;
            }
            
            [pix computePixMinPixMax];
        }
    }
    
    NSLog(@"Convert to SUV - factor: %f", factorPET2SUV);
    
    for( y = 0; y < maxMovieIndex; y++)
    {
        for( DCMPix *p in pixList[y])
        {
            [p setMaxValueOfSeries: 0];
            [p setMinValueOfSeries: 0];
            
            [p setSavedWL: [p savedWL] * updatefactor];
            [p setSavedWW: [p savedWW] * updatefactor];
            p.displaySUVValue = YES;
        }
    }
    
    if(  updatewlww)
    {
        float cwl, cww;
        
        [imageView getWLWW:&cwl :&cww];
        
        if( [[NSUserDefaults standardUserDefaults] integerForKey:@"DEFAULTPETWLWW"] != 0)
            [imageView updatePresentationStateFromSeries];
        else [imageView setWLWW: cwl * updatefactor : cww * updatefactor];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateVolumeDataNotification object: pixList[ curMovieIndex] userInfo: nil];
    
    [self setWindowTitle:self];
}

- (void) restoreConvertPETtoSUVautomaticallyValue: (NSNumber*) valueToRestore
{
    [[NSUserDefaults standardUserDefaults] setBool: valueToRestore.boolValue forKey:@"ConvertPETtoSUVautomatically"];
}

-(IBAction) endDisplaySUV:(id) sender
{
    long y, x;
    
    if( [sender tag] == 1)
    {
        [self updateSUVValues: self];
        
        BOOL savedDefault = [[NSUserDefaults standardUserDefaults] boolForKey: @"ConvertPETtoSUVautomatically"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ConvertPETtoSUVautomatically"];
        
        if( [[imageView curDCM] SUVConverted])
        {
            [self revertSeries:self];
            
            for( y = 0; y < maxMovieIndex; y++)
            {
                for( DCMPix *p in pixList[ y])
                {
                    if( editedAcquisitionTime)
                        p.acquisitionTime = editedAcquisitionTime;
                    
                    if( editedRadiopharmaceuticalStartTime)
                        p.radiopharmaceuticalStartTime = editedRadiopharmaceuticalStartTime;
                }
            }
        }
        
        // Why this? Because SUV conversion happen on the main thread in the finishLoadImageData...
        [self performSelector: @selector( restoreConvertPETtoSUVautomaticallyValue:) withObject: [NSNumber numberWithBool: savedDefault] afterDelay: 2];
        
        for( y = 0; y < maxMovieIndex; y++)
        {
            for( DCMPix *p in pixList[ y])
                [p setDisplaySUVValue: NO];
        }
        
        if( [[suvForm cellAtIndex: 0] floatValue] > 0)
        {
            for( y = 0; y < maxMovieIndex; y++)
            {
                for( x = 0; x < [pixList[y] count]; x++)
                {
                    [[pixList[y] objectAtIndex: x] setPatientsWeight: [[suvForm cellAtIndex: 0] floatValue]];
                    [[pixList[y] objectAtIndex: x] setRadionuclideTotalDose: [[suvForm cellAtIndex: 1] floatValue] * 1000000.];
                    [[pixList[y] objectAtIndex: x] setRadiopharmaceuticalStartTime: [[suvForm cellAtIndex: 3] objectValue]];
                    [[pixList[y] objectAtIndex: x] computeTotalDoseCorrected];
                }
            }
            
            [[NSUserDefaults standardUserDefaults] setInteger: [[suvConversion selectedCell] tag] forKey:@"SUVCONVERSION"];
            
            switch( [[suvConversion selectedCell] tag])
            {
                case 1:	// Convert all pixels to SUV
                    [self convertPETtoSUV];
                    break;
                    
                case 2:	// Display SUV
                    for( y = 0; y < maxMovieIndex; y++)
                    {
                        for( x = 0; x < [pixList[y] count]; x++) [[pixList[y] objectAtIndex: x] setDisplaySUVValue: YES];
                    }
                case 0: // Do nothing
                    for( y = 0; y < maxMovieIndex; y++)
                    {
                        for( x = 0; x < [pixList[y] count]; x++)
                        {
                            [[pixList[y] objectAtIndex: x] setMaxValueOfSeries: 0];
                            [[pixList[y] objectAtIndex: x] setMinValueOfSeries: 0];
                        }
                    }
                    break;
            }
            
            [displaySUVWindow orderOut:sender];
            [displaySUVWindow.sheetParent endSheet:displaySUVWindow returnCode:[sender tag]];
        }
        else HorosRunAlertPanel(NSLocalizedString(@"SUV Error", nil), NSLocalizedString(@"These values (weight and dose) are not correct.", nil), nil, nil, nil);
    }
    else
    {
        [displaySUVWindow orderOut:sender];
        [displaySUVWindow.sheetParent endSheet:displaySUVWindow returnCode:[sender tag]];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRecomputeROINotification object:self userInfo: nil];
}

- (IBAction) updateSUVValues:(id) sender
{
    int			x, y;
    NSDate		*newDate = [[suvForm cellAtIndex: 3] objectValue];
    float		newInjectedDose = [[suvForm cellAtIndex: 1] floatValue] * 1000000.;
    
    if( -[newDate timeIntervalSinceDate: [[imageView curDCM] acquisitionTime]] <= 0)
    {
        HorosRunAlertPanel(NSLocalizedString(@"SUV Error", nil), NSLocalizedString(@"Injection time CANNOT be after acquisition time !", nil), nil, nil, nil);
        
        if( [[imageView curDCM] radiopharmaceuticalStartTime])
            [[suvForm cellAtIndex: 3] setObjectValue: [[imageView curDCM] radiopharmaceuticalStartTime]];
    }
    else
    {
        for( y = 0; y < maxMovieIndex; y++)
        {
            for( x = 0; x < [pixList[y] count]; x++)
            {
                [[pixList[y] objectAtIndex: x] setRadionuclideTotalDose: newInjectedDose];
                [[pixList[y] objectAtIndex: x] setRadiopharmaceuticalStartTime: [[suvForm cellAtIndex: 3] objectValue]];
                [[pixList[y] objectAtIndex: x] computeTotalDoseCorrected];
            }
        }
        
        [[suvForm cellAtIndex: 1] setStringValue: [NSString stringWithFormat:@"%2.3f", [[imageView curDCM] radionuclideTotalDose] / 1000000. ]];
        
        [[suvForm cellAtIndex: 2] setStringValue: [NSString stringWithFormat:@"%2.3f", [[imageView curDCM] radionuclideTotalDoseCorrected] / 1000000. ]];
        
        if( [[imageView curDCM] radiopharmaceuticalStartTime])
            [[suvForm cellAtIndex: 3] setObjectValue: [[imageView curDCM] radiopharmaceuticalStartTime]];
    }
}

- (void) displaySUV:(id) sender
{
    [suvConversion selectCellWithTag: [[NSUserDefaults standardUserDefaults] integerForKey: @"SUVCONVERSION"]];
    
    if( [[imageView curDCM] hasSUV] == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"SUV Error", nil), NSLocalizedString(@"Cannot compute SUV on these data.", nil), nil, nil, nil);
    }
    else
    {
        [[suvForm cellAtIndex: 0] setStringValue: [NSString stringWithFormat:@"%2.3f", [[imageView curDCM] patientsWeight]]];
        [[suvForm cellAtIndex: 1] setStringValue: [NSString stringWithFormat:@"%2.3f", [[imageView curDCM] radionuclideTotalDose] / 1000000.]];
        [[suvForm cellAtIndex: 2] setStringValue: [NSString stringWithFormat:@"%2.3f", [[imageView curDCM] radionuclideTotalDoseCorrected] / 1000000. ]];
        
        if( [[imageView curDCM] radiopharmaceuticalStartTime])
            [[suvForm cellAtIndex: 3] setObjectValue: [[imageView curDCM] radiopharmaceuticalStartTime]];
        
        if( [[imageView curDCM] acquisitionTime])
            [[suvForm cellAtIndex: 4] setObjectValue: [[imageView curDCM] acquisitionTime]];
        
        [[suvForm cellAtIndex: 5] setStringValue: [NSString stringWithFormat:@"%2.2f", [[imageView curDCM] halflife] / 60.]];
        
        [editedRadiopharmaceuticalStartTime release];
        editedRadiopharmaceuticalStartTime = nil;
        
        [editedAcquisitionTime release];
        editedAcquisitionTime = nil;
        
        [[self window] beginSheet:displaySUVWindow completionHandler:nil];
    }
}


#pragma mark-
#pragma mark 4.1.4 Anchored textual layer

- (void) contextualMenuEvent:(id)sender
{
    // Receives a NSMenuItem (each intermediate NSMenu is also a NSMenuItem)
    // The complete title is obtain joining the ITEM title menu title with all its MENU supermenu titles, excepted the last one
    
    // Window anchored annotations need to be updated
    // Point clicked available in [imageView contextualMenuInWindowPosX] [imageView contextualMenuInWindowPosY]
    
    NSMenu *currentMenu = [sender menu];//init of menu
    NSMenu *superMenu = [currentMenu supermenu];//init of supermenu
    NSString *currentMenuTitle = [currentMenu title];
    NSString *tail;
    NSString *composedMenuTitle = [sender title];
    int i=0;
    while ( superMenu != nil)
    {
        tail = [[composedMenuTitle copy] autorelease];
        
        composedMenuTitle = [NSString stringWithFormat:@"%@ %@",currentMenuTitle, tail];
        currentMenu = superMenu;
        currentMenuTitle = [currentMenu title];
        superMenu = [currentMenu supermenu];
        i++;
    }
    
    if ([composedMenuTitle isEqualToString:@"?"]) //creating a content panel
    {
        [[self window] beginSheet:CommentsWindow completionHandler:nil];
    }
    else //same action as endSetComments, but with composedMenuTitle
    {
        [[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] setValue:composedMenuTitle forKeyPath:@"series.comment"];
        
        if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
        {
            [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[CommentsEditField stringValue] forKey:@"series.comment"];
        }
        
        [[[BrowserController currentBrowser] databaseOutline] reloadData];
        
        [CommentsField setTitle: composedMenuTitle];
        
        [self buildMatrixPreview: NO];
    }
}

#pragma mark-
#pragma mark 4.1.5 Presentation in viewport


- (void) flipVertical:(id) sender
{
    [imageView flipVertical:sender];
}

- (void) flipHorizontal:(id) sender
{
    [imageView flipHorizontal:sender];
}

- (void) increaseFontSize:(id) sender
{
    [imageView increaseFontSize: sender];
}

- (void) decreaseFontSize:(id) sender
{
    [imageView decreaseFontSize: sender];
}

- (void) rotate0:(id) sender
{
    [imageView setRotation: 0];
    [self propagateSettings];
    
    [imageView setNeedsDisplay: YES];
}

- (void) rotate90:(id) sender
{
    [imageView setRotation: 90];
    [self propagateSettings];
    
    [imageView setNeedsDisplay: YES];
}

- (void) rotate180:(id) sender
{
    [imageView setRotation: 180];
    [self propagateSettings];
    
    [imageView setNeedsDisplay: YES];
}

- (void)displayDICOMOverlays: (id)sender
{
    [self revertSeries: self];
}

- (void) applyLUT: (id) sender
{
    [DCMPix checkUserDefaults: YES];
    [self revertSeries: self];
    [imageView setWLWW:[[imageView curDCM] savedWL] :[[imageView curDCM] savedWW]];
}

- (void)useVOILUT: (id)sender
{
    [[NSUserDefaults standardUserDefaults] setBool: ![[NSUserDefaults standardUserDefaults] boolForKey: @"UseVOILUT"] forKey: @"UseVOILUT"];
    
    [self performSelector:@selector(applyLUT:) withObject: self afterDelay:0.2];
}


#pragma mark-
#pragma mark 4.1.6 Fixed graphical layer

#pragma mark-
#pragma mark 4.1.7 Fixed textual layer

#pragma mark-
#pragma mark 4.2 Tiling

#pragma mark-
#pragma mark 4.3 Multi viewport series synchronization

-(id) findSyncSeriesButton
{
    
    NSArray *items = [toolbar items];
    
    for( id loopItem in items)
    {
        if( [[loopItem itemIdentifier] isEqualToString:SyncSeriesToolbarItemIdentifier])
        {
            return loopItem;
        }
    }
    return nil;
}

- (void) notificationSyncSeries:(NSNotification*)note
{
    if( SyncButtonBehaviorIsBetweenStudies)
    {
        if( SYNCSERIES)
        {
            NSNumber *sliceLocation = [[note userInfo] objectForKey:@"sliceLocation"];
            float offset = [(DCMPix*)[[imageView dcmPixList] objectAtIndex:[imageView  curImage]] sliceLocation] - [sliceLocation floatValue];
            
            [imageView setSyncRelativeDiff:offset];
            [[self findSyncSeriesButton] setImage: [NSImage toolbarImageNamed: @"SyncLock.pdf"]];
            
            [imageView setSyncSeriesIndex: 0];
        }
        else
        {
            [[self findSyncSeriesButton] setImage: [NSImage toolbarImageNamed: SyncSeriesToolbarItemIdentifier]];
            [imageView setSyncSeriesIndex: -1];
        }
    }
    else
    {
        if( [imageView syncro] != syncroOFF)
        {
            [[self findSyncSeriesButton] setImage: [NSImage toolbarImageNamed: @"SyncLock.pdf"]];
        }
        else
        {
            [[self findSyncSeriesButton] setImage: [NSImage toolbarImageNamed: SyncSeriesToolbarItemIdentifier]];
        }
    }
}

- (void) turnOffSyncSeriesBetweenStudies:(id) sender
{
    if( SyncButtonBehaviorIsBetweenStudies)
    {
        if( SYNCSERIES)
        {
            [self SyncSeries: self];
        }
    }
}

+ (void) activateSYNCSERIESBetweenStudies
{
    if( SyncButtonBehaviorIsBetweenStudies)
    {
        SYNCSERIES = YES;
        
        for( ViewerController *v in [ViewerController getDisplayed2DViewers])
        {
            [[v findSyncSeriesButton] setImage: [NSImage toolbarImageNamed: @"SyncLock.pdf"]];
            [v.imageView setSyncSeriesIndex: 0];
        }
    }
}

- (void) SyncSeries:(id) sender
{
    if( SyncButtonBehaviorIsBetweenStudies)
    {
        SYNCSERIES = !SYNCSERIES;
        
        float sliceLocation =  [(DCMPix*)[[imageView dcmPixList] objectAtIndex:[imageView  curImage]] sliceLocation];
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject: [NSNumber numberWithFloat:sliceLocation] forKey:@"sliceLocation"];
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixSyncSeriesNotification object: self userInfo: userInfo];
    }
    else
    {
        if( [imageView syncro] == syncroOFF)
        {
            if( [[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagOption)
                [imageView setSyncro: syncroREL];
            else
                [imageView setSyncro: syncroLOC];
        }
        else [imageView setSyncro: syncroOFF];
        
        [imageView becomeMainWindow];
    }
}

- (NSString*) studyInstanceUID
{
    return [[fileList[ curMovieIndex] objectAtIndex:0] valueForKeyPath: @"series.study.studyInstanceUID"];
}

- (void) SetSyncButtonBehavior:(id) sender
{
    BOOL				allFromSameStudy = YES, previousSyncButtonBehaviorIsBetweenStudies = SyncButtonBehaviorIsBetweenStudies;
    NSMutableArray		*viewersList = [ViewerController getDisplayed2DViewers];
    
    [viewersList removeObject: self];
    
    
    if( [viewersList count])
    {
        NSString	*studyID = [self studyInstanceUID];
        
        for( ViewerController *v in viewersList)
        {
            if( [studyID isEqualToString: [v studyInstanceUID]] == NO)
            {
                allFromSameStudy = NO;
            }
        }
    }
    
    if( allFromSameStudy == NO) SyncButtonBehaviorIsBetweenStudies = YES;
    else SyncButtonBehaviorIsBetweenStudies = NO;
    
    if(( SyncButtonBehaviorIsBetweenStudies == YES && previousSyncButtonBehaviorIsBetweenStudies == NO) || SyncButtonBehaviorIsBetweenStudies == NO)
    {
        //NSLog( @"SyncButtonBehaviorIsBetweenStudies = %d", SyncButtonBehaviorIsBetweenStudies);
        
        [[AppController sharedAppController] willChangeValueForKey:@"SYNCSERIES"];
        SYNCSERIES = NO;
        [[AppController sharedAppController] didChangeValueForKey:@"SYNCSERIES"];
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixSyncSeriesNotification object:nil userInfo: nil];
        
        for( ViewerController *v in viewersList)
            v.imageView.syncSeriesIndex = -1;
    }
}

- (IBAction) reSyncOrigin:(id) sender
{
    float	o[ 3];
    int		x, i;
    
    if( blendingController)
    {
        if( [[NSUserDefaults standardUserDefaults] boolForKey:@"COPYSETTINGS"] == NO || [imageView syncro] != syncroLOC)
        {
            float zDiff = [[[blendingController imageView] curDCM] sliceLocation] - [[imageView curDCM] sliceLocation];
            
            for( i = 0; i < maxMovieIndex; i++)
            {
                for( x = 0; x < [pixList[ i] count]; x++)
                {
                    DCMPix		*pic = [pixList[ i] objectAtIndex:x];
                    float		vectorP[ 9], tempOrigin[ 3], tempOriginBlending[ 3];
                    NSPoint		offset;
                    
                    // Compute blended view offset
                    [pic orientation: vectorP];
                    
                    tempOrigin[ 0] = [pic originX] * vectorP[ 0] + [pic originY] * vectorP[ 1] + [pic originZ] * vectorP[ 2];
                    tempOrigin[ 1] = [pic originX] * vectorP[ 3] + [pic originY] * vectorP[ 4] + [pic originZ] * vectorP[ 5];
                    tempOrigin[ 2] = [pic originX] * vectorP[ 6] + [pic originY] * vectorP[ 7] + [pic originZ] * vectorP[ 8];
                    
                    tempOriginBlending[ 0] = [[[blendingController imageView] curDCM] originX] * vectorP[ 0] + [[[blendingController imageView] curDCM] originY] * vectorP[ 1] + [[[blendingController imageView] curDCM] originZ] * vectorP[ 2];
                    tempOriginBlending[ 1] = [[[blendingController imageView] curDCM] originX] * vectorP[ 3] + [[[blendingController imageView] curDCM] originY] * vectorP[ 4] + [[[blendingController imageView] curDCM] originZ] * vectorP[ 5];
                    tempOriginBlending[ 2] = [[[blendingController imageView] curDCM] originX] * vectorP[ 6] + [[[blendingController imageView] curDCM] originY] * vectorP[ 7] + [[[blendingController imageView] curDCM] originZ] * vectorP[ 8];
                    
                    [pic setPixelSpacingX: [[imageView curDCM] pixelSpacingX] * ([[blendingController imageView] pixelSpacingX] / [[blendingController imageView] scaleValue]) /  ([[imageView curDCM] pixelSpacingX]/[imageView scaleValue])];
                    [pic setPixelSpacingY: [[imageView curDCM] pixelSpacingY] * ([[blendingController imageView] pixelSpacingY] / [[blendingController imageView] scaleValue]) / ([[imageView curDCM] pixelSpacingY]/[imageView scaleValue])];
                    
                    offset.x = (tempOrigin[0] + [pic pwidth]*[pic pixelSpacingX]/2. - (tempOriginBlending[ 0] + [[[blendingController imageView] curDCM] pwidth]*[[[blendingController imageView] curDCM] pixelSpacingX]/2.));
                    offset.y = (tempOrigin[1] + [pic pheight]*[pic pixelSpacingY]/2. - (tempOriginBlending[ 1] + [[[blendingController imageView] curDCM] pheight]*[[[blendingController imageView] curDCM] pixelSpacingY]/2.));
                    
                    o[ 0] = [pic originX];		o[ 1] = [pic originY];		o[ 2] = [pic originZ];
                    
                    o[ 0] -= ([[blendingController imageView] origin].x*[[[blendingController imageView] curDCM] pixelSpacingX]/[[blendingController imageView] scaleValue] - [imageView origin].x*[pic pixelSpacingX]/[imageView scaleValue]) + offset.x;
                    o[ 1] += ([[blendingController imageView] origin].y*[[[blendingController imageView] curDCM] pixelSpacingY]/[[blendingController imageView] scaleValue] - [imageView origin].y*[pic pixelSpacingY]/[imageView scaleValue]) - offset.y;
                    o[ 2] += zDiff;
                    
                    [pic setOrigin: o];
                    [pic computeSliceLocation];
                }
            }
            
            [[NSUserDefaults standardUserDefaults] setBool: YES forKey:@"COPYSETTINGS"];
            [imageView setSyncro: syncroLOC];
            [imageView sendSyncMessage: 0];
            [self propagateSettings];
        }
        else HorosRunAlertPanel(NSLocalizedString(@"Error", nil), NSLocalizedString(@"Only useful if propagate settings is OFF.", nil), nil, nil, nil);
    }
    else HorosRunAlertPanel(NSLocalizedString(@"Error", nil), NSLocalizedString(@"Only useful if image fusion is activated.", nil), nil, nil, nil);
}

- (void) propagateSettingsToViewer: (ViewerController*) vC
{
    float   iwl, iww;
    float   dwl, dww;
    
    // 4D data
    if( curMovieIndex != [vC curMovieIndex] && maxMovieIndex ==  [vC maxMovieIndex] && ![NavigatorWindowController navigatorWindowController])
    {
        [vC setMovieIndex: curMovieIndex];
    }
    
    BOOL registeredViewers = NO;
    
    if( [self registeredViewer] == vC || [vC registeredViewer] == self)
        registeredViewers = YES;
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey:@"COPYSETTINGS"] == YES)
    {
        if( [[vC curCLUTMenu] isEqualToString:[self curCLUTMenu]])
        {
            BOOL	 propagate = YES;
            
            if( [[imageView curDCM] isRGB] != [[[vC imageView] curDCM] isRGB]) propagate = NO;
            
            if( [[vC modality] isEqualToString:[self modality]] == NO) propagate = NO;
            
            if( [vC subtractionActivated] != [self subtractionActivated]) propagate = NO;
            
            if( [[vC modality] isEqualToString: @"CR"]) propagate = NO;
            if( [[self modality] isEqualToString: @"CR"]) propagate = NO;
            
            if( [[vC modality] isEqualToString: @"NM"]) propagate = NO;
            
            if( [[vC modality] isEqualToString:@"PT"] && [[self modality] isEqualToString:@"PT"])
            {
                if( [[imageView curDCM] SUVConverted] != [[[vC imageView] curDCM] SUVConverted]) propagate = NO;
            }
            
            //			if( [[vC modality] isEqualToString:@"MR"] && [[self modality] isEqualToString:@"MR"])
            //			{
            //
            //			}
            
            if( [[NSUserDefaults standardUserDefaults] boolForKey:@"DONTCOPYWLWWSETTINGS"] == NO)
            {
                if( propagate)
                {
                    [imageView getWLWW:&iwl :&iww];
                    [[vC imageView] getWLWW:&dwl :&dww];
                    
                    if( iwl != dwl || iww != dww)
                        [[vC imageView] setWLWW:iwl :iww];
                }
            }
        }
        
        
        float vectorsA[9], vectorsB[9];
        
        [[pixList[ 0] objectAtIndex: [pixList[ 0] count]/2] orientation: vectorsA];
        [[[vC pixList] objectAtIndex: [[vC pixList] count]/2] orientation: vectorsB];
        
        float fValue;
        
        //		if(  curvedController == nil && [vC curvedController] == nil)
        {
            if( [DCMView angleBetweenVector: vectorsA+6 andVector: vectorsB+6] < [[NSUserDefaults standardUserDefaults] floatForKey: @"PARALLELPLANETOLERANCE"] || [[NSUserDefaults standardUserDefaults] boolForKey:@"AlwaysPropagateScaleLevel"])
                //				&&
                //				curvedController == nil)
            {
                BOOL propagateScale = YES;
                
                if( [DCMView noPropagateSettingsInSeriesForModality: [vC modality]] && [DCMView noPropagateSettingsInSeriesForModality: [self modality]])
                    propagateScale = NO;
                
                if( propagateScale)
                {
                    if( [imageView pixelSpacing] != 0 && [[vC imageView] pixelSpacing] != 0)
                    {
                        if( [imageView scaleValue] != 0)
                        {
                            fValue = [imageView scaleValue] / [imageView pixelSpacing];
                            [[vC imageView] setScaleValue: fValue * [[vC imageView] pixelSpacing]];
                        }
                    }
                    else
                    {
                        if( [imageView scaleValue] != 0)
                            [[vC imageView] setScaleValue: [imageView scaleValue]];
                    }
                }
            }
        }
        
        if( [DCMView angleBetweenVector: vectorsA+6 andVector: vectorsB+6] < [[NSUserDefaults standardUserDefaults] floatForKey: @"PARALLELPLANETOLERANCE"])
            //			&& curvedController == nil)
        {
            //if( [self isEverythingLoaded])
            {
                //	if( [[vC modality] isEqualToString:[self modality]])	For PET CT, we have to sync this even if the modalities are not equal!
                
                if( [DCMView noPropagateSettingsInSeriesForModality: [vC modality]] && [DCMView noPropagateSettingsInSeriesForModality: [self modality]])
                {
                    
                }
                else
                {
                    if( [[[[self fileList] objectAtIndex:0] valueForKeyPath:@"series.study.studyInstanceUID"] isEqualToString: [[[vC fileList] objectAtIndex:0] valueForKeyPath:@"series.study.studyInstanceUID"]] || registeredViewers == YES)
                    {
                        // Overlapping rect? to avoid pan if left/right limb are acquired in the same study for example
                        if( NSIntersectsRect( vC.imageView.curDCM.rectCoordinates,imageView.curDCM.rectCoordinates))
                        {
                            if( [[vC imageView] curDCM].isOriginDefined && [imageView curDCM].isOriginDefined)
                            {
                                NSPoint pan = [imageView origin];
                                NSPoint delta = [DCMPix originDeltaBetween:[[vC imageView] curDCM] And:[imageView curDCM]];
                                
                                delta.x *= [imageView scaleValue];
                                delta.y *= [imageView scaleValue];
                                
                                [[vC imageView] setOrigin: NSMakePoint( pan.x + delta.x, pan.y - delta.y)];
                            }
                        }
                    }
                    
                    fValue = [imageView rotation];
                    [[vC imageView] setRotation: fValue];
                }
            }
        }
    }
    
    if( [vC blendingController])
    {
        if( [vC blendingController] != self)
            [self propagateSettingsToViewer: [vC blendingController]];
        else
            [vC refresh];
    }
}

-(void) propagateSettings
{
    NSMutableArray *viewersList;
    
    if( [[[[fileList[0] objectAtIndex: 0] valueForKey:@"completePath"] lastPathComponent] isEqualToString:@"Empty.tif"])
        return;
    
    //	if( [[self window] isVisible] == NO) return;
    if( windowWillClose) return;
    
    // *** 2D Viewers ***
    viewersList = [ViewerController getDisplayed2DViewers];
    [viewersList removeObject: self];
    
    for( ViewerController *vC in viewersList)
    {
        if( vC != self)
        {
            if( [[vC imageView] shouldPropagate] == YES)
                [self propagateSettingsToViewer: vC];
        }
    }
    
    //	// *** 3D MPR Viewers ***
    //	viewersList = [[NSMutableArray alloc] initWithCapacity:0];
    //
    //	for( i = 0; i < [winList count]; i++)
    //	{
    //		if( [[[[winList objectAtIndex:i] windowController] windowNibName] isEqualToString:@"MPR"])
    //		{
    //			if( self != [[winList objectAtIndex:i] windowController]) [viewersList addObject: [[winList objectAtIndex:i] windowController]];
    //		}
    //	}
    //
    //	for( i = 0; i < [viewersList count]; i++)
    //	{
    //		MPRController	*vC = [viewersList objectAtIndex: i];
    //
    //		if( self == [vC blendingController])
    //		{
    //			[vC updateBlendingImage];
    //		}
    //	}
    //	[viewersList release];
    
    //	// *** 3D MIP Viewers ***
    //	viewersList = [[NSMutableArray alloc] initWithCapacity:0];
    //
    //	for( i = 0; i < [winList count]; i++)
    //	{
    //		if( [[[[winList objectAtIndex:i] windowController] windowNibName] isEqualToString:@"MIP"])
    //		{
    //			if( self != [[winList objectAtIndex:i] windowController]) [viewersList addObject: [[winList objectAtIndex:i] windowController]];
    //		}
    //	}
    //
    //	for( i = 0; i < [viewersList count]; i++)
    //	{
    //		MIPController	*vC = [viewersList objectAtIndex: i];
    //
    //		if( self == [vC blendingController])
    //		{
    //			[vC updateBlendingImage];
    //		}
    //	}
    //	[viewersList release];
    
    //	// *** 2D MPR Viewers ***
    //	viewersList = [NSMutableArray array];
    //
    //	for( NSWindow *win in winList)
    //	{
    //		if( [[[win windowController] windowNibName] isEqualToString:@"MPR2D"])
    //		{
    //			if( self != [win windowController]) [viewersList addObject: [win windowController]];
    //		}
    //	}
    //
    //	for( MPR2DController *vC in viewersList)
    //	{
    //		if( [vC blendingController])
    //			[vC updateBlendingImage];
    //	}
    
#ifndef OSIRIX_LIGHT
    // *** VR Viewers ***
    viewersList = [NSMutableArray array];
    
    for( NSWindow *win in [NSApp windows])
    {
        if( [[[win windowController] windowNibName] isEqualToString:@"VR"] ||
           [[[win windowController] windowNibName] isEqualToString:@"VRPanel"])
        {
            if( self != [win windowController]) [viewersList addObject: [win windowController]];
        }
    }
    
    for( VRController *vC in viewersList)
    {
        if( [vC blendingController])
            [vC updateBlendingImage];
    }
#endif
}

#pragma mark Registration

- (ViewerController*) registeredViewer
{
    return registeredViewer;
}

- (void) setRegisteredViewer: (ViewerController*) viewer
{
    registeredViewer = viewer;
}

- (NSMutableArray*) point2DList
{
    NSMutableArray * points2D = [NSMutableArray array];
    NSMutableArray * allROIs = [self roiList];
    
    ROI *curRoi;
    int s,i;
    
    for(s=0; s<[allROIs count]; s++)
    {
        for(i=0; i<[[allROIs objectAtIndex:s] count]; i++)
        {
            curRoi = (ROI*)[[allROIs objectAtIndex:s] objectAtIndex:i];
            [curRoi setPix: [[self pixList] objectAtIndex: s]];
            if([curRoi type] == t2DPoint)
            {
                [points2D addObject:curRoi];
            }
        }
    }
    return points2D;
}

#ifndef OSIRIX_LIGHT
- (ViewerController*) resampleSeriesInNewOrientation
{
    return nil;
}

- (ViewerController*) resampleSeries:(ViewerController*) movingViewer
{
    return [self resampleSeries: movingViewer rescale: YES];
}

- (ViewerController*) resampleSeries:(ViewerController*) movingViewer rescale: (BOOL) rescale
{
    [movingViewer displayWarningIfGantryTitled];
    [self displayWarningIfGantryTitled];
    
    ViewerController *newViewer = nil;
    
    BOOL volumicSelf = YES;
    BOOL volumicMoving = YES;
    
    if( self.pixList.count > 1)
    {
        if( [self isDataVolumicIn4D: YES] == NO)
            volumicSelf = NO;
        
        if( [self computeInterval] == 0)
            volumicSelf = NO;
    }
    else
    {
        DCMPix *p = self.pixList.lastObject;
        
        double orientation[ 9];
        [p orientationDouble: orientation];
        
        if( orientation[ 6] == 0 && orientation[ 7] == 0 && orientation[ 8] == 0)
            volumicSelf = NO;
    }
    
    if( movingViewer.pixList.count > 1)
    {
        if( [movingViewer isDataVolumicIn4D: YES] == NO)
            volumicMoving = NO;
        
        if( [movingViewer computeInterval] == 0)
            volumicMoving = NO;
    }
    else
    {
        DCMPix *p = movingViewer.pixList.lastObject;
        
        double orientation[ 9];
        [p orientationDouble: orientation];
        
        if( orientation[ 6] == 0 && orientation[ 7] == 0 && orientation[ 8] == 0)
            volumicMoving = NO;
    }
    
    if( volumicSelf == NO || volumicMoving == NO)
    {
        HorosRunCriticalAlertPanel(NSLocalizedString(@"Resampling Error", nil),
                                NSLocalizedString(@"3D Resampling requires volumic data.", nil),
                                NSLocalizedString(@"OK", nil), nil, nil);
        
        return nil;
    }
    
    if( [[self studyInstanceUID] isEqualToString: [movingViewer studyInstanceUID]])
    {
        float vectorModel[ 9], vectorSensor[ 9];
        
        [[[movingViewer pixList] objectAtIndex:0] orientation: vectorSensor];
        [[[self pixList] objectAtIndex:0] orientation: vectorModel];
        
        double matrix[ 12], length;
        
        // No translation -> same origin, same study
        matrix[ 9] = 0;
        matrix[ 10] = 0;
        matrix[ 11] = 0;
        
        // --
        
        matrix[ 0] = vectorSensor[ 0] * vectorModel[ 0] + vectorSensor[ 1] * vectorModel[ 1] + vectorSensor[ 2] * vectorModel[ 2];
        matrix[ 1] = vectorSensor[ 0] * vectorModel[ 3] + vectorSensor[ 1] * vectorModel[ 4] + vectorSensor[ 2] * vectorModel[ 5];
        matrix[ 2] = vectorSensor[ 0] * vectorModel[ 6] + vectorSensor[ 1] * vectorModel[ 7] + vectorSensor[ 2] * vectorModel[ 8];
        
        length = sqrt(matrix[0]*matrix[0] + matrix[1]*matrix[1] + matrix[2]*matrix[2]);
        
        matrix[0] = matrix[ 0] / length;
        matrix[1] = matrix[ 1] / length;
        matrix[2] = matrix[ 2] / length;
        
        // --
        
        matrix[ 3] = vectorSensor[ 3] * vectorModel[ 0] + vectorSensor[ 4] * vectorModel[ 1] + vectorSensor[ 5] * vectorModel[ 2];
        matrix[ 4] = vectorSensor[ 3] * vectorModel[ 3] + vectorSensor[ 4] * vectorModel[ 4] + vectorSensor[ 5] * vectorModel[ 5];
        matrix[ 5] = vectorSensor[ 3] * vectorModel[ 6] + vectorSensor[ 4] * vectorModel[ 7] + vectorSensor[ 5] * vectorModel[ 8];
        
        length = sqrt(matrix[3]*matrix[3] + matrix[4]*matrix[4] + matrix[5]*matrix[5]);
        
        matrix[3] = matrix[ 3] / length;
        matrix[4] = matrix[ 4] / length;
        matrix[5] = matrix[ 5] / length;
        
        // --
        
        matrix[6] = matrix[1]*matrix[5] - matrix[2]*matrix[4];
        matrix[7] = matrix[2]*matrix[3] - matrix[0]*matrix[5];
        matrix[8] = matrix[0]*matrix[4] - matrix[1]*matrix[3];
        
        length = sqrt(matrix[6]*matrix[6] + matrix[7]*matrix[7] + matrix[8]*matrix[8]);
        
        matrix[6] = matrix[ 6] / length;
        matrix[7] = matrix[ 7] / length;
        matrix[8] = matrix[ 8] / length;
        
        // --
        
        ITKTransform * transform = [[ITKTransform alloc] initWithViewer:movingViewer];
        
        newViewer = [transform computeAffineTransformWithParameters: matrix resampleOnViewer: self rescale: rescale];
        
        [imageView sendSyncMessage: 0];
        [self adjustSlider];
        
        [transform release];
    }
    else
    {
        HorosRunCriticalAlertPanel(NSLocalizedString(@"Resampling Error", nil),
                                NSLocalizedString(@"Resampling is only available for series in the SAME study.", nil),
                                NSLocalizedString(@"OK", nil), nil, nil);
    }
    
    return newViewer;
}

- (void) computeRegistrationWithMovingViewer:(ViewerController*) movingViewer
{
    BOOL volumicSelf = YES;
    BOOL volumicMoving = YES;
    
    if( self.pixList.count > 1)
    {
        if( [self isDataVolumicIn4D: YES] == NO)
            volumicSelf = NO;
        
        if( [self computeInterval] == 0)
            volumicSelf = NO;
    }
    else
    {
        DCMPix *p = self.pixList.lastObject;
        
        double orientation[ 9];
        [p orientationDouble: orientation];
        
        if( orientation[ 6] == 0 && orientation[ 7] == 0 && orientation[ 8] == 0)
            volumicSelf = NO;
    }
    
    if( movingViewer.pixList.count > 1)
    {
        if( [movingViewer isDataVolumicIn4D: YES] == NO)
            volumicMoving = NO;
        
        if( [movingViewer computeInterval] == 0)
            volumicMoving = NO;
    }
    else
    {
        DCMPix *p = movingViewer.pixList.lastObject;
        
        double orientation[ 9];
        [p orientationDouble: orientation];
        
        if( orientation[ 6] == 0 && orientation[ 7] == 0 && orientation[ 8] == 0)
            volumicMoving = NO;
    }
    
    if( volumicSelf == NO || volumicMoving == NO)
    {
        HorosRunCriticalAlertPanel(NSLocalizedString(@"Registration Error", nil),
                                NSLocalizedString(@"3D Resampling requires volumic data.", nil),
                                NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    
    
    //	NSLog(@" ***** Points 2D ***** ");
    // find all the Point ROIs on this viewer (fixed)
    NSMutableArray * modelPointROIs = [self point2DList];
    // find all the Point ROIs on the dragged viewer (moving)
    NSMutableArray * sensorPointROIs = [movingViewer point2DList];
    
    // order the Points by name. Not necessary but useful for debugging.
    [modelPointROIs sortUsingFunction:sortROIByName context:NULL];
    [sensorPointROIs sortUsingFunction:sortROIByName context:NULL];
    
    int numberOfPoints = [modelPointROIs count];
    // we need the same number of points
    BOOL sameNumberOfPoints = ([sensorPointROIs count] == numberOfPoints);
    // we need at least 3 points
    BOOL enoughPoints = (numberOfPoints>=3);
    // each point on the moving viewer needs a twin on the fixed viewer.
    // two points are twin brothers if and only if they have the same name.
    BOOL pointsNamesMatch2by2 = YES;
    // triplets are illegal (since we don't know which point to map)
    BOOL triplets = NO;
    
    NSMutableArray *previousNames = [[NSMutableArray alloc] initWithCapacity:0];
    
    NSString *modelName, *sensorName;
    NSMutableString *errorString = [NSMutableString stringWithString:@""];
    
    BOOL foundAMatchingName;
    
    if (sameNumberOfPoints && enoughPoints)
    {
        HornRegistration *hr = [[HornRegistration alloc] init];
        
        float vectorModel[ 9], vectorSensor[ 9];
        
        [[[movingViewer pixList] objectAtIndex:0] orientation: vectorSensor];
        [[[self pixList] objectAtIndex:0] orientation: vectorModel];
        
        int i,j; // 'for' indexes
        for (i=0; i<[modelPointROIs count] && pointsNamesMatch2by2 && !triplets; i++)
        {
            ROI *curModelPoint2D = [modelPointROIs objectAtIndex:i];
            modelName = [curModelPoint2D name];
            foundAMatchingName = NO;
            
            for (j=0; j<[sensorPointROIs count] && !foundAMatchingName; j++)
            {
                ROI *curSensorPoint2D = [sensorPointROIs objectAtIndex:j];
                sensorName = [curSensorPoint2D name];
                
                for (id loopItem2 in previousNames)
                {
                    triplets = triplets || [modelName isEqualToString:loopItem2]
                    || [sensorName isEqualToString:loopItem2];
                }
                
                pointsNamesMatch2by2 = [sensorName isEqualToString:modelName];
                
                if(pointsNamesMatch2by2)
                {
                    foundAMatchingName = YES; // stop the research
                    [sensorPointROIs removeObjectAtIndex:j]; // to accelerate the research
                    j--;
                    
                    [previousNames addObject:sensorName]; // to avoid triplets
                    
                    if(!triplets)
                    {
                        float modelLocation[3], sensorLocation[3];
                        
                        [[curModelPoint2D pix]	convertPixX:	[[[curModelPoint2D points] objectAtIndex:0] x]
                                                      pixY:			[[[curModelPoint2D points] objectAtIndex:0] y]
                                             toDICOMCoords:	modelLocation
                                               pixelCenter: YES];
                        
                        [[curSensorPoint2D pix]	convertPixX:	[[[curSensorPoint2D points] objectAtIndex:0] x]
                                                       pixY:			[[[curSensorPoint2D points] objectAtIndex:0] y]
                                              toDICOMCoords:	sensorLocation
                                                pixelCenter: YES];
                        
                        // Convert the point in 3D orientation of the model
                        
                        float modelLocationConverted[ 3];
                        
                        modelLocationConverted[ 0] = modelLocation[ 0];
                        modelLocationConverted[ 1] = modelLocation[ 1];
                        modelLocationConverted[ 2] = modelLocation[ 2];
                        modelLocationConverted[ 0] = modelLocation[ 0] * vectorModel[ 0] + modelLocation[ 1] * vectorModel[ 1] + modelLocation[ 2] * vectorModel[ 2];
                        modelLocationConverted[ 1] = modelLocation[ 0] * vectorModel[ 3] + modelLocation[ 1] * vectorModel[ 4] + modelLocation[ 2] * vectorModel[ 5];
                        modelLocationConverted[ 2] = modelLocation[ 0] * vectorModel[ 6] + modelLocation[ 1] * vectorModel[ 7] + modelLocation[ 2] * vectorModel[ 8];
                        
                        float sensorLocationConverted[ 3];
                        
                        sensorLocationConverted[ 0] = sensorLocation[ 0];
                        sensorLocationConverted[ 1] = sensorLocation[ 1];
                        sensorLocationConverted[ 2] = sensorLocation[ 2];
                        sensorLocationConverted[ 0] = sensorLocation[ 0] * vectorSensor[ 0] + sensorLocation[ 1] * vectorSensor[ 1] + sensorLocation[ 2] * vectorSensor[ 2];
                        sensorLocationConverted[ 1] = sensorLocation[ 0] * vectorSensor[ 3] + sensorLocation[ 1] * vectorSensor[ 4] + sensorLocation[ 2] * vectorSensor[ 5];
                        sensorLocationConverted[ 2] = sensorLocation[ 0] * vectorSensor[ 6] + sensorLocation[ 1] * vectorSensor[ 7] + sensorLocation[ 2] * vectorSensor[ 8];
                        
                        // add the points to the registration method
                        [hr addModelPointX: modelLocationConverted[0] Y: modelLocationConverted[1] Z: modelLocationConverted[2]];
                        [hr addSensorPointX: sensorLocationConverted[0] Y: sensorLocationConverted[1] Z: sensorLocationConverted[2]];
                    }
                }
            }
        }
        
        if(pointsNamesMatch2by2 && !triplets)
        {
            double matrix[ 16];
            
            [hr computeVTK :matrix];
            
            ITKTransform * transform = [[ITKTransform alloc] initWithViewer:movingViewer];
            
            /*ViewerController *newViewer =*/ [transform computeAffineTransformWithParameters: matrix resampleOnViewer: self];
            
            [imageView sendSyncMessage: 0];
            [self adjustSlider];
            
            [transform release];
        }
        [hr release];
    }
    else
    {
        if(!sameNumberOfPoints)
        {
            // warn user to set the same number of points on both viewers
            [errorString appendString:NSLocalizedString(@"Needs same number of points on both viewers.",nil)];
        }
        
        if(!enoughPoints)
        {
            // warn user to set at least 3 points on both viewers
            if([errorString length]!=0) [errorString appendString:@"\n"];
            [errorString appendString:NSLocalizedString(@"Needs at least 3 points on both viewers.",nil)];
        }
    }
    
    if(!pointsNamesMatch2by2)
    {
        // warn user
        if([errorString length]!=0) [errorString appendString:@"\n"];
        [errorString appendString:NSLocalizedString(@"Points names must match 2 by 2.",nil)];
    }
    
    if(triplets)
    {
        // warn user
        if([errorString length]!=0) [errorString appendString:@"\n"];
        [errorString appendString:NSLocalizedString(@"Max. 2 points with the same name.",nil)];
    }
    
    if([errorString length]!=0)
    {
        HorosRunCriticalAlertPanel(NSLocalizedString(@"Point-Based Registration Error", nil),
                                @"%@",
                                NSLocalizedString(@"OK", nil), nil, nil, errorString);
    }
    
    [previousNames release];
}
#endif

#pragma mark-
#pragma mark 4.4 Navigation
#pragma mark 4.4.1 Series navigation

- (NSMutableArray*) pixList: (long) i
{
    i = [HorosFourDSeriesGuard wrappedIndex: i count: maxMovieIndex];
    
    return pixList[ i];
}

- (NSMutableArray*) pixList
{
    return pixList[ curMovieIndex];
}

- (NSMutableArray*) fileList
{
    return fileList[ curMovieIndex];
}

- (NSMutableArray*) fileList: (long) i
{
    i = [HorosFourDSeriesGuard wrappedIndex: i count: maxMovieIndex];
    
    return fileList[ i];
}

-(void) addMovieSerie:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v
{
    long	i;
    
    if( [HorosFourDSeriesGuard canStoreTimeAt: maxMovieIndex capacity: MAX4D] == NO)
    {
        HorosRunCriticalAlertPanel(NSLocalizedString(@"4D Player", nil),
                                 NSLocalizedString(@"4D Player is limited to a maximum number of %d series.", nil),
                                 NSLocalizedString(@"OK", nil), nil, nil, MAX4D);
        return;
    }
    
    volumeData[ maxMovieIndex] = v;
    [volumeData[ maxMovieIndex] retain];
    [self sendDidAllocateVolumeDataNotificationWithVolumeData:volumeData[ maxMovieIndex] movieIndex:maxMovieIndex];
    
    [f retain];
    pixList[ maxMovieIndex] = f;
    
    [d retain];
    fileList[ maxMovieIndex] = d;
    
    // Prepare pixList for image thick slab
    for( i = 0; i < [pixList[maxMovieIndex] count]; i++)
    {
        [[pixList[maxMovieIndex] objectAtIndex: i] setArrayPix: pixList[maxMovieIndex] :i];
    }
    
    // create empty ROI List for this new serie
    copyRoiList[maxMovieIndex] = [[NSMutableArray alloc] initWithCapacity: 0];
    roiList[maxMovieIndex] = [[NSMutableArray alloc] initWithCapacity: 0];
    
    for( i = 0; i < [pixList[maxMovieIndex] count]; i++)
    {
        [roiList[maxMovieIndex] addObject:[NSMutableArray array]];
        [copyRoiList[maxMovieIndex] addObject: [NSData data]];
    }
    [self loadROI: maxMovieIndex];
    
    maxMovieIndex++;
    
    [moviePosSlider setMaxValue:maxMovieIndex-1];
    [moviePosSlider setNumberOfTickMarks:maxMovieIndex];
    
    [movieRateSlider setEnabled: YES];
    [moviePosSlider setEnabled: YES];
    [moviePlayStop setEnabled: YES];
    
    if( [pixList[ 0] count])
    {
        NSData *tf = [[pixList[ 0] lastObject] transferFunction];
        
        for( DCMPix *d in pixList[ maxMovieIndex-1])
            [d setTransferFunction: tf];
    }
}

- (float) frameRate
{
    return [speedSlider floatValue];
}

- (float) movieRate
{
    return [movieRateSlider floatValue];
}

- (void) speedSliderAction:(id) sender
{
    [speedText setStringValue:[NSString stringWithFormat: NSLocalizedString( @"%0.1f im/s", @"im/s = images per second"), (float) [self frameRate] * direction]];
    
    if( [[self window] isKeyWindow])
    {
        for( ViewerController *v in [ViewerController getDisplayed2DViewers])
        {
            if( v != self)
            {
                if( [v frameRate] == [[NSUserDefaults standardUserDefaults] floatForKey: @"defaultFrameRate"])
                {
                    if( v.speedSlider.floatValue != self.frameRate)
                    {
                        v.speedSlider.floatValue = self.frameRate;
                        v.speedText.stringValue = [NSString stringWithFormat: NSLocalizedString( @"%0.1f im/s", @"im/s = images per second"), (float) [self frameRate] * v->direction];
                    }
                }
            }
        }
        [[NSUserDefaults standardUserDefaults] setFloat: [self frameRate] forKey: @"defaultFrameRate"];
    }
}

- (void) movieRateSliderAction:(id) sender
{
    float movieRate = (float) [self movieRate];

    [movieTextSlide setStringValue:[NSString stringWithFormat: NSLocalizedString( @"%0.0f im/s", @"im/s = images per second"), movieRate]];

    if( [[self window] isKeyWindow])
    {
        for( ViewerController *v in [ViewerController getDisplayed2DViewers])
        {
            if( v != self)
            {
                if( [v movieRate] == [[NSUserDefaults standardUserDefaults] floatForKey: @"defaultMovieRate"])
                {
                    if( v.movieRateSlider.floatValue != movieRate)
                    {
                        v.movieRateSlider.floatValue = movieRate;
                        v.movieTextSlide.stringValue = [NSString stringWithFormat: NSLocalizedString( @"%0.0f im/s", @"im/s = images per second"), movieRate];
                    }
                }
            }
        }
        [[NSUserDefaults standardUserDefaults] setFloat: movieRate forKey: @"defaultMovieRate"];
    }
}

-(NSSlider*) moviePosSlider
{
    return moviePosSlider;
}

- (void) setMovieIndex: (short) i
{
    [[[NavigatorWindowController navigatorWindowController] navigatorView] removeNotificationObserver];
    
    int index = [imageView curImage];
    BOOL wasDataFlipped = [imageView flippedData];
    
    curMovieIndex = (short)[HorosFourDSeriesGuard wrappedIndex: i count: maxMovieIndex];
    
    [moviePosSlider setIntValue:curMovieIndex];
    
    if( pixList[ curMovieIndex] == nil)
    {
        [[[NavigatorWindowController navigatorWindowController] navigatorView] addNotificationObserver];
        return;
    }
    
    [seriesView setPixels:pixList[ curMovieIndex] files:fileList[ curMovieIndex] rois:roiList[ curMovieIndex] firstImage:0 level:'i' reset: NO];	//[pixList[0] count]/2
    
    [self setWindowTitle: self];
    
    if( wasDataFlipped) [self flipDataSeries: self];
    
    [[[NavigatorWindowController navigatorWindowController] navigatorView] addNotificationObserver];
    
    if( [imageView columns] > 1 || [imageView rows] > 1)
    {
        if( index == 0)
            [imageView setIndex: (long)[pixList[ curMovieIndex] count] -1];
        else
            [imageView setIndex: 0];
    }
    
    [imageView setIndex: index];
    
    [imageView sendSyncMessage: 0];
    
    [self adjustSlider];
    
    [self showCurrentThumbnail:self];
}

- (void) moviePosSliderAction:(id) sender
{
    [self setMovieIndex: [moviePosSlider intValue]];
    [self propagateSettings];
}

- (void)adjustSlider
{
    if( [imageView flippedData]) [slider setIntValue: [pixList[ curMovieIndex] count] - [imageView curImage] -1];
    else [slider setIntValue:[imageView curImage]];
    
    [self adjustKeyImage];
}

- (short) curMovieIndex { return curMovieIndex;}

- (void) performMovieAnimation:(id) sender
{
    @synchronized( loadingThread)
    {
        if( loadingThread.isExecuting && [[loadingThread.threadDictionary objectForKey: @"loadingPercentage"] floatValue] < 0.5)
            return;
    }
    
    // Playback intervals must not change when the civil clock is corrected.
    NSTimeInterval  thisTime = [NSProcessInfo processInfo].systemUptime;
    
    if( thisTime - lastMovieTime > 1.0 / [movieRateSlider floatValue])
    {
        short val = (short)[HorosFourDSeriesGuard nextIndex: curMovieIndex count: maxMovieIndex];
        
        curMovieIndex = val;
        
        [self setMovieIndex: val];
        [self propagateSettings];
        
        lastMovieTime = thisTime;
    }
}

- (long) imageIndex
{
    if( [imageView flippedData]) return [self getNumberOfImages] -1 - [imageView curImage];
    return  [imageView curImage];
}

- (void) setImageIndex:(long) i
{
    if( i < 0) i = 0;
    if( i >= [self getNumberOfImages]) i = [self getNumberOfImages] -1;
    
    if( [imageView flippedData]) [imageView setIndex: [self getNumberOfImages] -1 -i];
    else [imageView setIndex: i];
    
    [imageView sendSyncMessage: 0];
    
    [self adjustSlider];
    
    [imageView displayIfNeeded];
}

- (void) setImage:(NSManagedObject*) image
{
    for( int x = 0 ; x < maxMovieIndex ; x++)
    {
        for( NSManagedObject* i in fileList[ x])
        {
            if( image == i)
            {
                [self setMovieIndex: x];
                [imageView setIndex: [fileList[ x] indexOfObject: i]];
                [imageView sendSyncMessage: 0];
                [self adjustSlider];
                [imageView displayIfNeeded];
                
                return;
            }
        }
    }
}

- (void) performAnimation:(id) sender
{
    // Playback intervals must not change when the civil clock is corrected.
    NSTimeInterval  thisTime = [NSProcessInfo processInfo].systemUptime;
    short           val;
    
    if( windowWillClose)
        return;
    
    @synchronized( loadingThread)
    {
        if( loadingThread.isExecuting && [[loadingThread.threadDictionary objectForKey: @"loadingPercentage"] floatValue] < 0.5)
            return;
    }
    
    if( [pixList[ curMovieIndex] count] <= 1) return;
    
    if( thisTime - lastTimeFrame > 1.0)
    {
        [speedText setStringValue:[NSString stringWithFormat: NSLocalizedString( @"%0.1f im/s", @"im/s = images per second"), (float) speedometer * direction / (thisTime - lastTimeFrame) ]];
        
        speedometer = 0;
        
        lastTimeFrame = thisTime;
    }
    
    if( thisTime - lastTime > 1.0 / [speedSlider floatValue])
    {
        val = [imageView curImage];
        
        if( [imageView flippedData]) val -= direction;
        else val += direction;
        
        if( [loopButton state] == NSControlStateValueOn)
        {
            if( val < 0) val = (long)[pixList[ curMovieIndex] count]-1;
            if( val >= [pixList[ curMovieIndex] count]) val = 0;
        }
        else
        {
            if( val < 0)
            {
                val = 0;
                direction = -direction;
                val += direction;
                if( val < 0) val = 0;
            }
            
            if( val >= [pixList[ curMovieIndex] count])
            {
                val = (long)[pixList[ curMovieIndex] count]-1;
                direction = -direction;
                val += direction;
                if( val >= [pixList[ curMovieIndex] count]) val = (long)[pixList[ curMovieIndex] count]-1;
            }
        }
        
        [imageView setIndex:val];
        
        [self adjustSlider];
        
        [imageView sendSyncMessage: 0];
        
        lastTime = thisTime;
        
        //		if( TICKPLAY)
        //		{
        //			if( [[self modality] isEqualToString:@"XA"])
        //			{
        //				[tickSound stop];
        //				[tickSound play];
        //			}
        //		}
        
        [imageView displayIfNeeded];
        speedometer++;
    }
}

- (void) MovieStop:(id) sender
{
    if( movieTimer)
    {
        [movieTimer invalidate];
        [movieTimer release];
        movieTimer = nil;
    }
    
    // The title used to be reset only by -MoviePlayStop:, so every other way of
    // stopping - opening a 3D viewer, or another viewer starting to play - left
    // this one reading "Stop" with nothing playing (#374, A224).
    [moviePlayStop setTitle: NSLocalizedString(@"Play", nil)];
    [movieTextSlide setStringValue: [NSString stringWithFormat: NSLocalizedString( @"%0.0f im/s", @"im/s = images per second"), (float) [movieRateSlider floatValue]]];
}

- (void) MoviePlayStop:(id) sender
{
    if( movieTimer)
    {
        [self MovieStop: self];
    }
    else
    {
        NSArray		*winList = [NSApp windows];
        
        for( id loopItem in winList)
        {
            if( [[loopItem windowController] isKindOfClass:[ViewerController class]])
            {
                [[loopItem windowController] MovieStop: self];
            }
        }
        
        [self checkEverythingLoaded];
        
        movieTimer = [[NSTimer scheduledTimerWithTimeInterval:0 target:self selector:@selector(performMovieAnimation:) userInfo:nil repeats:YES] retain];
        [[NSRunLoop currentRunLoop] addTimer:movieTimer forMode:NSModalPanelRunLoopMode];
        [[NSRunLoop currentRunLoop] addTimer:movieTimer forMode:NSEventTrackingRunLoopMode];
        
        lastMovieTime = [NSProcessInfo processInfo].systemUptime;
        
        [moviePlayStop setTitle: NSLocalizedString(@"Stop", nil)];
    }
}

- (BOOL)isPlaying4D;
{
    if(movieTimer) return YES;
    return NO;
}

- (void) notificationStopPlaying:(NSNotification*)note
{
    if( timer) [self PlayStop:[self findPlayStopButton]];
}


- (void) PlayStop:(id) sender
{
    if( timer)
    {
        [timer invalidate];
        [timer release];
        timer = nil;
        
        [sender setImage: [NSImage toolbarImageNamed: PlayToolbarItemIdentifier]];
        [sender setLabel: NSLocalizedString(@"Browse", nil)];
        [sender setPaletteLabel: NSLocalizedString(@"Browse", nil)];
        [sender setToolTip: NSLocalizedString(@"Browse this series", nil)];
        
        [speedText setStringValue:[NSString stringWithFormat: NSLocalizedString( @"%0.1f im/s", @"im/s = images per second"), (float) [self frameRate]*direction]];
    }
    else
    {
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixStopPlayingNotification object: self userInfo: nil];
        
        timer = [[NSTimer scheduledTimerWithTimeInterval:0 target:self selector:@selector(performAnimation:) userInfo:nil repeats:YES] retain];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
        
        lastTime = [NSProcessInfo processInfo].systemUptime;
        lastTimeFrame = [NSProcessInfo processInfo].systemUptime;
        
        [sender setImage: [NSImage toolbarImageNamed: PauseToolbarItemIdentifier]];
        [sender setLabel: NSLocalizedString(@"Stop", nil)];
        [sender setPaletteLabel: NSLocalizedString(@"Stop", nil)];
    }
}

#pragma mark-
#pragma mark 4.4.2 4D navigation

- (float) frame4DRate
{
    return [movieRateSlider floatValue];
}


#pragma mark-
#pragma mark 4.5 External functions
#pragma mark 4.5.1 Exportation of image
#pragma mark 4.5.1.1 Exportation of image produced
// The methods of this block are implemented in Swift since #832
// (ViewerController+Export+PrintMovie.swift and ViewerController+Export.swift),
// with the same selectors.

#pragma mark-
#pragma mark 4.5.1.2 Exportation of image raw

#pragma mark-
#pragma mark 4.5.2 Importation

#pragma mark-
#pragma mark 4.5.3 3D

- (void) clear8bitRepresentations
{
    // This function will free about 1/4 of the data
    
    for( int i = 0; i < maxMovieIndex; i++)
    {
        for( int x = 0; x < [pixList[ i] count]; x++)
        {
            if( [pixList[ i] objectAtIndex:x] != [imageView curDCM])
                [[pixList[ i] objectAtIndex:x] kill8bitsImage];
        }
    }
    
    [self updateImage: self];	// <- compute at least current image...
}

-(float*) volumePtr
{
    return  (float*) [volumeData[ curMovieIndex] bytes];
}

-(float*) volumePtr: (long) i
{
    i = [HorosFourDSeriesGuard wrappedIndex: i count: maxMovieIndex];
    
    return  (float*) [volumeData[ i] bytes];
}

- (NSData*)volumeData;
{
    return volumeData[ curMovieIndex];
}

- (NSData*)volumeData:(long)i;
{
    i = [HorosFourDSeriesGuard wrappedIndex: i count: maxMovieIndex];
    
    return volumeData[ i];
}

#ifndef OSIRIX_LIGHT
- (float) computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts error:(NSString**) error
{
    return [self computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts generateMissingROIs: NO generatedROIs: nil computeData: nil error:(NSString**) error];
}

- (float) computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts generateMissingROIs:(BOOL) generateMissingROIs error:(NSString**) error
{
    return [self computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts generateMissingROIs:(BOOL) generateMissingROIs generatedROIs: nil computeData: nil error:(NSString**) error];
}

- (float) computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts generateMissingROIs:(BOOL) generateMissingROIs generatedROIs:(NSMutableArray*) generatedROIs computeData:(NSMutableDictionary*) data error:(NSString**) error
{
    long globalCount, imageCount, lastImageIndex;
    double volume;
    ROI	*lastROI;
    BOOL missingSlice = NO;
    NSMutableArray *theSlices = [NSMutableArray array];
    NSMutableArray *volumeSlices = [NSMutableArray array];
    NSMutableArray *seriesOrigins = [NSMutableArray array];
    
    if( pts) *pts = [NSMutableArray array];
    
    lastROI = nil;
    lastImageIndex = -1;
    if( error) *error = nil;
    
    NSLog( @"computeVolume started");
    
    // Explicit interpolation only. Occupied-only volume is HorosROIVolumeGeometry.
    if( generateMissingROIs)
    {
        // Surface preparation tracks temporary additions in generatedROIs.
        // Keep existing interpolated contours: deleting them here and then
        // removing their replacements changes the source ROI and its volume.
        // The explicit Generate Missing ROIs command still regenerates them.
        if( generatedROIs == nil)
            [self roiDeleteGeneratedROIsForName: [selectedRoi name]];
        
        for( int x = 0; x < [pixList[curMovieIndex] count]; x++)
        {
            imageCount = 0;
            
            for( int i = 0; i < [[roiList[curMovieIndex] objectAtIndex: x] count]; i++)
            {
                ROI	*curROI = [[roiList[curMovieIndex] objectAtIndex: x] objectAtIndex: i];
                
                if( [[curROI name] isEqualToString: [selectedRoi name]] && [curROI isValidForVolume])
                {
                    imageCount++;
                    
                    if( generateMissingROIs)
                    {
                        if( lastROI && (lastImageIndex+1) < x)
                        {
                            for( int y = lastImageIndex+1; y < x; y++)
                            {
                                ROI	*c = [self roiMorphingBetween: lastROI  and: curROI ratio: (float) (y - lastImageIndex) / (float) (x - lastImageIndex)];
                                
                                if( c)
                                {
                                    [c setComments: @"morphing generated"];
                                    [c setName: [selectedRoi name]];
                                    [imageView roiSet: c];
                                    [[roiList[curMovieIndex] objectAtIndex: y] addObject: c];
                                    
                                    [generatedROIs addObject: c];
                                    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixAddROINotification object:self
                                                                                      userInfo:@{@"ROI": c, @"sliceNumber": [NSNumber numberWithLong:x]}];
                                }
                            }
                        }
                    }
                    
                    lastImageIndex = x;
                    lastROI = curROI;
                }
            }
        }
        
        NSLog( @"generated ROI done");
    }
    
    lastROI = nil;
    globalCount = 0;
    lastImageIndex = -1;
    volume = 0;
    for( DCMPix *seriesPix in pixList[curMovieIndex])
    {
        [seriesOrigins addObject: [[[HorosROIPatientPoint alloc] initWithX: seriesPix.originX
                                                                         y: seriesPix.originY
                                                                         z: seriesPix.originZ] autorelease]];
    }
    
    ROI *fROI = nil, *lROI = nil;
    int	fROIIndex, lROIIndex;
    ROI	*curROI = nil;
    NSOperationQueue* queue = [[[NSOperationQueue alloc] init] autorelease];
    
    for( int x = 0; x < [pixList[curMovieIndex] count]; x++)
    {
        DCMPix	*pic = [pixList[curMovieIndex] objectAtIndex: x];
        imageCount = 0;
        double sliceArea = 0;
        
        // TODO : convert to NSOperation: ITKSegmentation3D extractContour is slow
        
        for( int i = 0; i < [[roiList[curMovieIndex] objectAtIndex: x] count]; i++)
        {
            curROI = [[roiList[curMovieIndex] objectAtIndex: x] objectAtIndex: i];
            if( [[curROI name] isEqualToString: [selectedRoi name]] == YES  && [curROI isValidForVolume])		//&& [[curROI comments] isEqualToString:@"morphing generated"] == NO)
            {
                if( fROI == nil)
                {
                    fROI = curROI;
                    fROIIndex = x;
                }
                lROI = curROI;
                lROIIndex = x;
                
                globalCount++;
                imageCount++;
                
                DCMPix *curPix = [pixList[ curMovieIndex] objectAtIndex: x];
                float curArea = [curROI roiArea];
                
                [curROI setPix: curPix];
                
                if( curArea == 0)
                {
                    if( error) *error = [NSString stringWithString: NSLocalizedString(@"One ROI has an area equal to ZERO!", nil)];
                    return 0;
                }
                
                sliceArea += curArea;
                
                if( pts)
                {
                    [queue addOperationWithBlock:^{
                        NSMutableArray	*points = nil;
                        
                        if( [curROI type] == tPlain)
                        {
                            points = [ITKSegmentation3D extractContour:[curROI textureBuffer] width:[curROI textureWidth] height:[curROI textureHeight] numPoints: 100 largestRegion: NO];
                            
                            float mx = [curROI textureUpLeftCornerX], my = [curROI textureUpLeftCornerY];
                            
                            for( int zz = 0; zz < [points count]; zz++)
                            {
                                MyPoint	*pt = [points objectAtIndex: zz];
                                [pt move: mx :my];
                            }
                        }
                        else points = [curROI splinePoints];
                        
                        for( int y = 0; y < [points count]; y++)
                        {
                            float location[ 3];
                            
                            [pic convertPixX: [[points objectAtIndex: y] x] pixY: [[points objectAtIndex: y] y] toDICOMCoords: location pixelCenter: YES];
                            
                            NSArray	*pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]], [NSNumber numberWithFloat:location[1]], [NSNumber numberWithFloat:location[2]], nil];
                            
                            @synchronized( self)
                            {
                                [*pts addObject: pt3D];
                            }
                        }
                    }];
                }
                
                [theSlices addObject: [NSDictionary dictionaryWithObjectsAndKeys: curROI, @"roi", curPix, @"dcmPix", nil]];
                
                lastROI = curROI;
            }
        }
        
        if( imageCount > 0)
        {
            if( lastImageIndex >= 0 && (lastImageIndex+1) < x)
                missingSlice = YES;
            
            float orientation[ 9];
            [pic orientation: orientation];
            HorosROIVolumeSlice *volumeSlice = [[[HorosROIVolumeSlice alloc] initWithAreaCm2: sliceArea
                                                                                     originX: pic.originX
                                                                                     originY: pic.originY
                                                                                     originZ: pic.originZ
                                                                                     normalX: orientation[ 6]
                                                                                     normalY: orientation[ 7]
                                                                                     normalZ: orientation[ 8]
                                                                              componentCount: imageCount
                                                                              maskPixelCount: 0
                                                                                pixelAreaMm2: 0
                                                                    spacingBetweenSlicesMm: pic.spacingBetweenSlices] autorelease];
            [volumeSlices addObject: volumeSlice];
            lastImageIndex = x;
        }
    }
    
    while (queue.operationCount)
    {
        [NSThread sleepForTimeInterval:0.05];
    }
    
    HorosROIVolumeResult *measured = [HorosROIVolumeGeometry volumeFromSlices: volumeSlices
                                                               seriesOrigins: seriesOrigins
                                                          interpolateMissing: NO
                                                              meshPointCount: 0];
    if( measured == nil || measured.occupiedPlaneCount < 2)
    {
        if( error)
            *error = NSLocalizedString(@"I found only ONE ROI : not possible to compute a volume!", nil);
        return 0L;
    }
    volume = measured.volumeCm3;
    if( volume == 0)
    {
        if( error)
            *error = NSLocalizedString(@"Not possible to compute a volume!", nil);
        return 0L;
    }
    
    NSLog( @"********");
    
    if( pts)
    {
        if( fROI && lROI)
        {
            // Close the floor and the ceil of the volume
            
            //			float *data;
            //			float *locations;
            //			long dataSize;
            //			
            //			data = [[fROI pix] getROIValue:&dataSize :fROI :&locations];
            //			
            //			for( i = 0 ; i < dataSize; i +=4)
            //			{
            //				float location[ 3];
            //				NSArray	*pt3D;
            //				
            //				[[fROI pix] convertPixX: locations[i*2] pixY: locations[i*2+1] toDICOMCoords: location];
            //				
            //				pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]], [NSNumber numberWithFloat:location[1]], [NSNumber numberWithFloat:location[2]], nil];
            //				NSLog( [pt3D description]);
            //				[*pts addObject: pt3D];
            //			}
            //			
            //			free( data);
            //			free( locations);
            //			
            //			data = [[lROI pix] getROIValue:&dataSize :lROI :&locations];
            //			
            //			for( i = 0 ; i < dataSize; i +=4)
            //			{
            //				float location[ 3];
            //				NSArray	*pt3D;
            //				
            //				[[lROI pix] convertPixX: locations[i*2] pixY: locations[i*2+1] toDICOMCoords: location];
            //				
            //				pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]], [NSNumber numberWithFloat:location[1]], [NSNumber numberWithFloat:location[2]], nil];
            //				NSLog( [pt3D description]);
            //				[*pts addObject: pt3D];
            //			}
            //			
            //			free( data);
            //			free( locations);
            
            float location[ 3];
            NSArray	*pt3D;
            NSPoint centroid;
            DCMPix	*pic;
            
            if( fROIIndex > 0) fROIIndex--;
            if( lROIIndex < (long)[pixList[curMovieIndex] count]-1) lROIIndex++;
            
            pic = [pixList[curMovieIndex] objectAtIndex: fROIIndex];
            centroid = [fROI centroid];
            [pic  convertPixX: centroid.x pixY: centroid.y toDICOMCoords: location pixelCenter: YES];
            pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]-1], [NSNumber numberWithFloat:location[1]-1], [NSNumber numberWithFloat:location[2]], nil];
            [*pts addObject: pt3D];
            pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]-1], [NSNumber numberWithFloat:location[1]+1], [NSNumber numberWithFloat:location[2]], nil];
            [*pts addObject: pt3D];
            pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]], [NSNumber numberWithFloat:location[1]], [NSNumber numberWithFloat:location[2]], nil];
            [*pts addObject: pt3D];
            
            pic = [pixList[curMovieIndex] objectAtIndex: lROIIndex];
            centroid = [lROI centroid];
            [pic  convertPixX: centroid.x pixY: centroid.y toDICOMCoords: location pixelCenter: YES];
            pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]-1], [NSNumber numberWithFloat:location[1]-1], [NSNumber numberWithFloat:location[2]], nil];
            [*pts addObject: pt3D];
            pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]-1], [NSNumber numberWithFloat:location[1]+1], [NSNumber numberWithFloat:location[2]], nil];
            [*pts addObject: pt3D];
            pt3D = [NSArray arrayWithObjects: [NSNumber numberWithFloat: location[0]], [NSNumber numberWithFloat:location[1]], [NSNumber numberWithFloat:location[2]], nil];
            [*pts addObject: pt3D];
        }
        
        if( [*pts count] == 0)
        {
            if( error)
                *error = NSLocalizedString(@"Not possible to compute a volume!", nil);
            return 0L;
        }
    }
    
    NSLog( @"volume computation done");
    
    if( pts && [*pts count] > 0)
    {
        NSLog( @"number of points: %d", (int) [*pts count]);
        
#define MAXPOINTS 7000
        // Display-only decimation. The source volume is HorosROIVolumeGeometry, already stored.
        
        if( [*pts count] > MAXPOINTS*2)
        {
            NSMutableArray *newpts = [NSMutableArray arrayWithCapacity: MAXPOINTS*2];
            
            int add = [*pts count] / MAXPOINTS;
            
            if( add > 1)
            {
                for( int i = 0; i < [*pts count]; i += add)
                {
                    [newpts addObject: [*pts objectAtIndex: i]];
                }
                
                NSLog( @"too much points, reducing from: %d, to: %d", (int) [*pts count], (int) [newpts count]);
                
                [*pts removeAllObjects];
                [*pts addObjectsFromArray: newpts];
            }
        }
    }
    
    if( data)
    {
        if( missingSlice) NSLog( @"**** Warning cannot compute data on a ROI with missing slices. Turn generateMissingROIs to TRUE to solve this.");
        else
        {
            double gmean = 0, gtotal = 0, gmin = 0, gmax = 0, gdev = 0, gskewness = 0, gkurtosis = 0;
            
            //			for( i = 0 ; i < [theSlices count]; i++)
            //			{
            //				DCMPix	*curPix = [[theSlices objectAtIndex: i] objectForKey:@"dcmPix"];
            //				ROI		*curROI = [[theSlices objectAtIndex: i] objectForKey:@"roi"];
            //				
            //				float mean = 0, total = 0, dev = 0, min = 0, max = 0;
            //				[curPix computeROIInt: curROI :&mean :&total :&dev :&min :&max];
            //				
            //				gmean  = ((gmean * gtotal) + (mean*total)) / (gtotal+total);
            //				gdev  = ((gdev * gtotal) + (dev*total)) / (gtotal+total);
            //				
            //				gtotal += total;
            //
            //				if( i == 0)
            //				{
            //					gmin = min;
            //					gmax = max;
            //				}
            //				else
            //				{
            //					if( min < gmin) gmin = min;
            //					if( max > gmax) gmax = max;
            //				}
            //			}
            //			
            //			NSLog( @"%f\r%f\r%f\r%f\r%f", gtotal, gmean, gdev, gmin, gmax);
            
            long				memSize = 0;
            float				*totalPtr = nil;
            NSMutableArray		*rois = [NSMutableArray array];
            
            for( int i = 0 ; i < [theSlices count]; i++)
            {
                DCMPix	*curPix = [[theSlices objectAtIndex: i] objectForKey:@"dcmPix"];
                ROI		*curROI = [[theSlices objectAtIndex: i] objectForKey:@"roi"];
                
                [rois addObject: curROI];
                
                long numberOfValues;
                
                float *tempPtr = [curPix getROIValue: &numberOfValues :curROI :nil];
                if( tempPtr)
                {
                    float *newPtr = malloc( (memSize + numberOfValues)*sizeof( float));
                    if( newPtr)
                    {
                        if( totalPtr)
                            memcpy( newPtr, totalPtr, memSize * sizeof(float));
                        
                        free( totalPtr);
                        totalPtr = newPtr;
                        
                        memcpy( newPtr + memSize, tempPtr, numberOfValues * sizeof(float));
                        
                        memSize += numberOfValues;
                    }
                    
                    free( tempPtr);
                }
            }
            
            if( memSize > 0 && totalPtr != nil)
            {
                gtotal = 0;
                for( int i = 0; i < memSize; i++)
                {
                    gtotal += totalPtr[ i];
                }
                
                gmean = gtotal / memSize;
                
                gdev = 0;
                gmin = totalPtr[ 0];
                gmax = totalPtr[ 0];
                for( int i = 0; i < memSize; i++)
                {
                    float val = totalPtr[ i];
                    
                    float temp = gmean - val;
                    temp *= temp;
                    gdev += temp;
                    
                    if( val < gmin) gmin = val;
                    if( val > gmax) gmax = val;
                }
                gdev = gdev / (double) (memSize-1);
                gdev = sqrt( gdev);
                
                if( [[NSUserDefaults standardUserDefaults] boolForKey: @"ROIComputeSkewnessAndKurtosis"])
                {
                    gskewness = [DCMPix skewness: totalPtr length: memSize mean: gmean];
                    gkurtosis = [DCMPix kurtosis: totalPtr length: memSize mean: gmean];
                }
            }
            
            free( totalPtr);
            
            [data setObject: [NSNumber numberWithDouble: gmin] forKey:@"min"];
            [data setObject: [NSNumber numberWithDouble: gmax] forKey:@"max"];
            [data setObject: [NSNumber numberWithDouble: gmean] forKey:@"mean"];
            [data setObject: [NSNumber numberWithDouble: gtotal] forKey:@"total"];
            [data setObject: [NSNumber numberWithDouble: gdev] forKey:@"dev"];
            if( [[NSUserDefaults standardUserDefaults] boolForKey: @"ROIComputeSkewnessAndKurtosis"])
            {
                [data setObject: [NSNumber numberWithDouble: gskewness] forKey:@"skewness"];
                [data setObject: [NSNumber numberWithDouble: gkurtosis] forKey:@"kurtosis"];
            }
            [data setObject: [NSNumber numberWithDouble: fabs( volume)] forKey:@"volume"];
            [data setObject: rois forKey:@"rois"];
        }
    }
    
    NSLog( @"data computation done");
    
    if( globalCount == 1)
    {
        if( error) *error = NSLocalizedString(@"I found only ONE ROI : not possible to compute a volume!", nil);
        return 0;
    }
    
    if( volume < 0) volume = -volume;
    
    return volume;
}
#endif

-(void) updateVolumeData: (NSNotification*) note
{
    if( [note object] == pixList[ curMovieIndex])
    {
        float iwl, iww;
        
        [imageView getWLWW:&iwl :&iww];
        
        for( int y = 0; y < maxMovieIndex; y++)
        {
            for( DCMPix *p in pixList[ y])
                [p changeWLWW:iwl :iww];	//recompute WLWW
            
            for( NSArray *r in roiList[ y])
            {
                for( ROI *roi in r)
                    [roi recompute];
            }
        }
        
        [imageView setWLWW:iwl :iww];
    }
}

- (void) viewerControllerInit
{
    BOOL matrixVisible = [[NSUserDefaults standardUserDefaults] boolForKey: @"SeriesListVisible"];
    
    [[self window] zoom: self];
    
    numberOf2DViewer++;
    
    @synchronized( arrayOf2DViewers)
    {
        if( arrayOf2DViewers == nil)
            arrayOf2DViewers = [[NSMutableArray alloc] init];
        
        [arrayOf2DViewers addObject: self];
    }
    
    if( numberOf2DViewer > 1 || [[NSUserDefaults standardUserDefaults] boolForKey: @"USEALWAYSTOOLBARPANEL2"] == YES)
    {
        if( [AppController USETOOLBARPANEL] == NO)
        {
            [AppController setUSETOOLBARPANEL: YES];
            
            for( NSWindow *win in [NSApp windows])
            {
                if( [[win windowController] isKindOfClass:[ViewerController class]])
                {
                    if( [win toolbar])
                        [win setToolbar: nil];
                }
            }
        }
    }
    
    roiLock = [[NSRecursiveLock alloc] init];
    
    factorPET2SUV = 1.0;
    
    subCtrlMaskID = -2;
    maxMovieIndex = 1;
    
    [curCLUTMenu release];
    [curConvMenu release];
    [curWLWWMenu release];
    
    curCLUTMenu = [NSLocalizedString(@"No CLUT", nil) retain];
    curConvMenu = [NSLocalizedString(@"No Filter", nil) retain];
    curWLWWMenu = [NSLocalizedString(@"Default WL & WW", nil) retain];
    
    direction = 1;
    
    [[self window] center];
    
    [[self window] setDelegate:self];
    
    [wlwwPopup setTitle:NSLocalizedString(@"Default WL & WW", nil)];
    [convPopup setTitle:NSLocalizedString(@"No Filter", nil)];
    curOpacityMenu = [NSLocalizedString(@"Linear Table", nil) retain];
    
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    [nc addObserver:self selector:@selector(applicationDidResignActive:) name:NSApplicationDidResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(UpdateWLWWMenu:) name:OsirixUpdateWLWWMenuNotification object:nil];
    //	[nc	addObserver:self selector:@selector(Display3DPoint:) name:OsirixDisplay3dPointNotification object:nil];
    [nc addObserver:self selector:@selector(ViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(ViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:nil];
    
    [nc addObserver:self selector:@selector(revertSeriesNotification:) name:OsirixRevertSeriesNotification object:nil];
    [nc addObserver:self selector:@selector(updateVolumeData:) name:OsirixUpdateVolumeDataNotification object:nil];
    [nc addObserver:self selector:@selector(retrieveViewingStateChanged:) name:@"HorosRetrieveViewingStateDidChange" object:nil];
    [nc addObserver:self selector:@selector(roiChange:) name:OsirixROIChangeNotification object:nil];
    [nc addObserver:self selector:@selector(OpacityChanged:) name:OsirixOpacityChangedNotification object:nil];
    [nc addObserver:self selector:@selector(defaultToolModified:) name:OsirixDefaultToolModifiedNotification object:nil];
    [nc addObserver:self selector:@selector(defaultRightToolModified:) name:OsirixDefaultRightToolModifiedNotification object:nil];
    [nc addObserver:self selector:@selector(UpdateConvolutionMenu:) name:OsirixUpdateConvolutionMenuNotification object:nil];
    [nc addObserver:self selector:@selector(CLUTChanged:) name:OsirixCLUTChangedNotification object:nil];
    [nc addObserver:self selector:@selector(UpdateCLUTMenu:) name:OsirixUpdateCLUTMenuNotification object:nil];
    [nc addObserver:self selector:@selector(UpdateOpacityMenu:) name:OsirixUpdateOpacityMenuNotification object:nil];
    [nc addObserver:self selector:@selector(CloseViewerNotification:) name:OsirixCloseViewerNotification object:nil];
    [nc addObserver:self selector:@selector(recomputeROI:) name:OsirixRecomputeROINotification object:nil];
    [nc addObserver:self selector:@selector(notificationStopPlaying:) name:OsirixStopPlayingNotification object:nil];
    //	[nc addObserver:self selector:@selector(notificationiChatBroadcast:) name:OsirixChatBroadcastNotification object:nil];
    [nc addObserver:self selector:@selector(notificationSyncSeries:) name:OsirixSyncSeriesNotification object:nil];
    [nc	addObserver:self selector:@selector(exportTextFieldDidChange:) name:NSControlTextDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(updateReportToolbarIcon:) name:OsirixReportModeChangedNotification object:nil];
    [nc addObserver:self selector:@selector(updateReportToolbarIcon:) name:OsirixDeletedReportNotification object:nil];
    [nc addObserver:self selector:@selector(reportToolbarItemWillPopUp:) name:NSPopUpButtonWillPopUpNotification object:nil];
    
    
    NSMutableArray *draggedTypes = [NSMutableArray arrayWithObject:@"NSFilenamesPboardType"];
    [draggedTypes addObjectsFromArray:BrowserController.DatabaseObjectXIDsPasteboardTypes];
    [draggedTypes addObjectsFromArray:DCMView.PasteboardTypes];
    [draggedTypes addObjectsFromArray:DCMView.PluginPasteboardTypes];
    [[self window] registerForDraggedTypes:draggedTypes];
    
    if( [[pixList[0] objectAtIndex: 0] isRGB] == NO)
    {
        if( [[self modality] isEqualToString:@"PT"] || ([[NSUserDefaults standardUserDefaults] boolForKey:@"clutNM"] == YES && [[self modality] isEqualToString:@"NM"]))
        {
            if( [[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] isEqualToString: @"B/W Inverse"])
                [self ApplyCLUTString: @"B/W Inverse"];
            else
                [self ApplyCLUTString: [[NSUserDefaults standardUserDefaults] stringForKey:@"PET Default CLUT"]];
        }
        
        if( [[self modality] isEqualToString:@"PT"] || ([[NSUserDefaults standardUserDefaults] boolForKey:@"OpacityTableNM"] == YES && [[self modality] isEqualToString:@"NM"]))
        {
            if( [[NSUserDefaults standardUserDefaults] boolForKey:@"PETOpacityTable"])
                [self ApplyOpacityString: [[NSUserDefaults standardUserDefaults] stringForKey:@"PET Default Opacity Table"]];
        }
        
        if(([[self modality] isEqualToString:@"CR"] || [[self modality] isEqualToString:@"MG"] || [[self modality] isEqualToString:@"XA"] || [[self modality] isEqualToString:@"RF"]) && [[NSUserDefaults standardUserDefaults] boolForKey:@"automatic12BitTotoku"] && [AppController canDisplay12Bit])
        {
            [imageView setIsLUT12Bit:YES];
            [display12bitToolbarItemMatrix selectCellWithTag:0];
        }
    }
    
    //
    for( int i = 0; i < [popupRoi numberOfItems]; i++)
    {
        if( [[popupRoi itemAtIndex: i] image] == nil)
        {
            [[popupRoi itemAtIndex: i] setImage: [self imageForROI: [[popupRoi itemAtIndex: i] tag]]];
            [[[popupRoi itemAtIndex: i] image] setSize:ToolsMenuIconSize];
        }
    }
    
    for( int i = 0; i < [ReconstructionRoi numberOfItems]; i++)
    {
        if( [[ReconstructionRoi itemAtIndex: i] image] == nil)
        {
            switch( [[ReconstructionRoi itemAtIndex: i] tag])
            {
                case 1:	[[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"MPR"]];				break;
                case 2:	[[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"MPR3D"]];				break;
                case 3: [[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"MIP"]];				break;
                case 4: [[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"VolumeRendering"]];	break;
                case 5: [[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"Surface"]];			break;
                case 6: [[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"VolumeRendering"]];	break;
                case 7:
                    //				if( [VRPROController available] == NO)
                {
                    [ReconstructionRoi removeItemAtIndex: i];
                    i--;
                }
                    //				else
                    //					[[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"VolumeRendering"]];
                    break;
                case 8: [[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"orthogonalReslice"]];	break;
                case 9: [[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"Endoscopy"]];	break;
                case 10: [[ReconstructionRoi itemAtIndex: i] setImage: [NSImage imageNamed: @"MPR"]];	break;
            }
        }
    }
    
    [[self window] setInitialFirstResponder: imageView];
    
    NSNumber	*status = [[fileList[ curMovieIndex] objectAtIndex:[imageView curImage]] valueForKeyPath:@"series.study.stateText"];
    
    if( status == nil) [StatusPopup selectItemWithTitle: @"empty"];
    else [StatusPopup selectItemWithTag: [status intValue]];
    
    NSString *com = [[fileList[ curMovieIndex] objectAtIndex:[imageView curImage]] valueForKeyPath:@"series.comment"];//JF20070103
    
    if( com == nil || [com isEqualToString:@""]) [CommentsField setTitle: NSLocalizedString(@"Add a comment", nil)];
    else [CommentsField setTitle: com];
    
    [previewMatrixScrollView setPostsFrameChangedNotifications:YES];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"UseFloatingThumbnailsList"] == NO && [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOHIDEMATRIX"] == NO)
        [self setMatrixVisible: matrixVisible];
    
    [[NSUserDefaults standardUserDefaults] addObserver: self forKeyPath: @"SeriesListVisible" options:NSKeyValueObservingOptionNew context:nil];
    
    originalOrientation = -1;
    [orientationMatrix setEnabled: NO];
}

- (NSString *)fourDReconstructionRefusalReason
{
    if( maxMovieIndex < 1)
        return [HorosFourDSeriesGuard reconstructionRefusalComparing: nil to: nil atTime: 0];
    NSString *capacity = [HorosFourDSeriesGuard capacityReasonAt: maxMovieIndex - 1 capacity: MAX4D];
    if( capacity)
        return capacity;
    NSString *slices = [HorosFourDSeriesGuard reasonForInconsistentSlices: pixList[0] atTime: 0];
    if( slices)
        return slices;
    HorosFourDTimeGeometry *reference = [HorosFourDSeriesGuard geometryFromPixList: pixList[0] volume: volumeData[0]];
    NSString *first = [HorosFourDSeriesGuard reconstructionRefusalComparing: reference to: reference atTime: 0];
    if( first)
        return first;
    for( int i = 1; i < maxMovieIndex; i++)
    {
        NSString *timeSlices = [HorosFourDSeriesGuard reasonForInconsistentSlices: pixList[i] atTime: i];
        if( timeSlices)
            return timeSlices;
        HorosFourDTimeGeometry *candidate = [HorosFourDSeriesGuard geometryFromPixList: pixList[i] volume: volumeData[i]];
        NSString *reason = [HorosFourDSeriesGuard reconstructionRefusalComparing: candidate to: reference atTime: i];
        if( reason)
            return reason;
    }
    return nil;
}

- (BOOL) refuseFourDReconstructionWithTitle: (NSString *) title
{
    NSString *reason = [self fourDReconstructionRefusalReason];
    if( reason == nil)
        return NO;
    HorosRunAlertPanel(title, @"%@", nil, nil, nil, reason);
    return YES;
}

- (NSString *)fourDFusionRefusalReasonForOverlay: (ViewerController *) overlay
{
    if( overlay == nil)
        return nil;
    NSString *overlayReason = [overlay fourDReconstructionRefusalReason];
    if( overlayReason)
        return overlayReason;
    return [HorosFourDSeriesGuard fusionRefusalHostTimes: maxMovieIndex overlayTimes: [overlay maxMovieIndex]];
}

- (NSString *)fourDFusionRefusalReason
{
    return [self fourDFusionRefusalReasonForOverlay: blendingController];
}

- (BOOL) refuseFourDFusionWithTitle: (NSString *) title
{
    NSString *reason = [self fourDFusionRefusalReason];
    if( reason == nil)
        return NO;
    HorosRunAlertPanel(title, @"%@", nil, nil, nil, reason);
    return YES;
}

#ifndef OSIRIX_LIGHT
- (IBAction) Panel3D:(id) sender
{
    long i;
    
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if( [self isDataVolumicIn4D: YES] == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Volume Rendering", nil), NSLocalizedString(@"Volume Rendering requires volumic data.", nil), nil, nil, nil);
        return;
    }
    if( [self refuseFourDReconstructionWithTitle: NSLocalizedString(@"Volume Rendering", nil)])
        return;
    
    if( [self computeInterval] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
       ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
    }
    else
    {
        [self displayAWarningIfNonTrueVolumicData];
        [self displayWarningIfGantryTitled];
        
        [self MovieStop: self];
        
        NSArray *viewers = [[AppController sharedAppController] FindRelatedViewers:pixList[0]];
        
        VRController *viewer = nil;
        
        for( NSWindowController *v in viewers)
        {
            // Not a viewer whose window is closing, as -[AppController FindViewer::].
            if( [v.windowNibName isEqualToString: @"VR"] && [(VRController*) v windowWillClose] == NO)
            {
                VRController *vv = (VRController*) v;
                
                if( [vv.style isEqualToString: @"panel"])
                    viewer = vv;
            }
        }
        
        if( viewer)
        {
            [[viewer window] makeKeyAndOrderFront:self];
        }
        else
        {
            NSInteger time = [HorosFourDSeriesGuard alignedTimeIndexRequested: curMovieIndex count: maxMovieIndex];
            if( pixList[0] == nil || fileList[0] == nil || volumeData[0] == nil || pixList[time] == nil)
                return;
            
            // Same ordering contract as openVRViewerForMode: time 0 first, then
            // the rest, so setMovieFrame: lands on the time the player shows.
            viewer = [[VRController alloc] initWithPix:pixList[0] :fileList[0] :volumeData[ 0] :blendingController :self style:@"panel" mode:@"MIP"];
            for( i = 1; i < maxMovieIndex; i++)
            {
                [viewer addMoviePixList:pixList[ i] :volumeData[ i]];
            }
            [viewer setMovieFrame: time];
            
            if( [[pixList[time] objectAtIndex: 0] isRGB] == NO)
            {
                if( [[self modality] isEqualToString:@"PT"])
                {
                    if( [[imageView curDCM] SUVConverted] == YES)
                    {
                        [viewer setWLWW: 3 : 6];
                    }
                    else
                    {
                        [viewer setWLWW:[[pixList[time] objectAtIndex: 0] maxValueOfSeries]/4 : [[pixList[time] objectAtIndex: 0] maxValueOfSeries]/2];
                    }
                }
            }
            
            [viewer load3DState];
            
            if( [[self modality] isEqualToString:@"PT"] && [[pixList[time] objectAtIndex: 0] isRGB] == NO)
            {
                if( [[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] isEqualToString: @"B/W Inverse"])
                    [viewer ApplyCLUTString: @"B/W Inverse"];
                else
                    [viewer ApplyCLUTString: [[NSUserDefaults standardUserDefaults] stringForKey:@"PET Default CLUT"]];
                
                [viewer ApplyOpacityString: @"Logarithmic Table"];
            }
            else
            {
                float   iwl, iww;
                [imageView getWLWW:&iwl :&iww];
                [viewer setWLWW:iwl :iww];
            }
            
            [[viewer window] setFrameOrigin: [[[self window] screen] visibleFrame].origin];
            [viewer showWindow:self];
            [[viewer window] makeKeyAndOrderFront:self];
            [[viewer window] display];
            [[viewer window] setTitle: [NSString stringWithFormat:@"%@: %@", [[viewer window] title], [[self window] title]]];
        }
    }
}
#endif

#ifndef OSIRIX_LIGHT
-(IBAction) segmentationTest:(id) sender
{
    BOOL volumicData = [self isDataVolumicIn4D: NO];
    
    if( volumicData == NO)
        // Force 2D mode
        [[NSUserDefaults standardUserDefaults] setInteger: 0 forKey: @"growingRegionType"];
    else
        [self displayAWarningIfNonTrueVolumicData];
    
    [self clear8bitRepresentations];
    
    float ci = [self computeInterval];
    
    if( [pixList[ curMovieIndex] count] <= 1) ci = 1;
    
    if( ci == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
       ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
    }
    else
    {
        ITKSegmentation3DController *itk = [[ITKSegmentation3DController alloc] initWithViewer: self];
        if( itk)
        {
            [itk showWindow:self];
            [[itk window] makeKeyAndOrderFront:self];
        }
    }
}
#endif

#ifndef OSIRIX_LIGHT
- (VRController *)openVRViewerForMode:(NSString *)mode
{
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_3DVOL_LAUNCHED detail:[NSString stringWithFormat:@"{\"Mode\": \"%@\"}",mode]];
#endif

    long i;
    
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];	
    [self MovieStop: self];
    if( [self fourDReconstructionRefusalReason])
        return nil;
    
    NSArray *viewers = [[AppController sharedAppController] FindRelatedViewers:pixList[0]];
    
    VRController *viewer = nil;
    
    for( NSWindowController *v in viewers)
    {
        // Not a viewer whose window is closing, as -[AppController FindViewer::].
        if( [v.windowNibName isEqualToString: @"VR"] && [(VRController*) v windowWillClose] == NO)
        {
            VRController *vv = (VRController*) v;
            
            if( [vv.style isEqualToString: @"standard"] && ([vv.renderingMode isEqualToString:@"VR"] || [vv.renderingMode isEqualToString:@"MIP"]))
                viewer = vv;
        }
    }
    
    if( viewer)
    {
        return viewer;
    }
    else
    {
        NSInteger time = [HorosFourDSeriesGuard alignedTimeIndexRequested: curMovieIndex count: maxMovieIndex];
        if( pixList[0] == nil || fileList[0] == nil || volumeData[0] == nil || pixList[time] == nil)
            return nil;
        
        // Time 0 first, then the remaining times in order: the renderer indexes
        // its own movie slots the way this viewer does, so the shared index is
        // a valid subscript there too.
        viewer = [[VRController alloc] initWithPix:pixList[0] :fileList[0] :volumeData[ 0] :blendingController :self style:@"standard" mode: mode];
        for( i = 1; i < maxMovieIndex; i++)
        {
            [viewer addMoviePixList:pixList[ i] :volumeData[ i]];
        }
        [viewer setMovieFrame: time];
        
        if( [[self modality] isEqualToString:@"PT"] && [[pixList[time] objectAtIndex: 0] isRGB] == NO)
        {
            if( [[imageView curDCM] SUVConverted] == YES)
            {
                [viewer setWLWW: 2 : 6];
            }
            else
            {
                [viewer setWLWW:[[pixList[time] objectAtIndex: 0] maxValueOfSeries]/2 : [[pixList[time] objectAtIndex: 0] maxValueOfSeries]];
            }
            
            if( [[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] isEqualToString: @"B/W Inverse"])
                [viewer ApplyCLUTString: @"B/W Inverse"];
            else
                [viewer ApplyCLUTString: [[NSUserDefaults standardUserDefaults] stringForKey:@"PET Default CLUT"]];
            
            [viewer ApplyOpacityString: @"Logarithmic Table"];
        }
        else
        {
            float   iwl, iww;
            [imageView getWLWW:&iwl :&iww];
            [viewer setWLWW:iwl :iww];
        }
    }
    return viewer;
}
#endif

- (NSScreen*) get3DViewerScreen: (ViewerController*) v
{
    if( [[NSUserDefaults standardUserDefaults] boolForKey:@"ThreeDViewerOnAnotherScreen"])
    {
        NSArray		*allScreens = [NSScreen screens];
        
        for( NSScreen *loopItem in allScreens)
        {
            if( [[[v window] screen] frame].origin.x != [loopItem frame].origin.x || [[[v window] screen] frame].origin.y != [loopItem frame].origin.y)
            {
                return loopItem;
            }
        }
        
        return [[v window] screen];
    }
    else
    {
        return [[v window] screen];
    }
}

- (void) place3DViewerWindow:(NSWindowController*) viewer
{
    [[viewer window] setFrame: [[self get3DViewerScreen: self] visibleFrame] display:NO];
}

#ifndef OSIRIX_LIGHT
-(IBAction) VRViewer:(id) sender
{
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if( [self isDataVolumicIn4D: YES] == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Volume Rendering", nil), NSLocalizedString(@"Volume Rendering requires volumic data.", nil), nil, nil, nil);
        return;
    }
    if( [self refuseFourDReconstructionWithTitle: NSLocalizedString(@"Volume Rendering", nil)])
        return;
    
    if( [self computeInterval] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
       ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
    }
    else
    {
        [self displayAWarningIfNonTrueVolumicData];
        
        [self displayWarningIfGantryTitled];
        
        if( [curConvMenu isEqualToString:NSLocalizedString(@"No Filter", nil)] == NO)
        {
            if( HorosRunInformationalAlertPanel( NSLocalizedString(@"Convolution", nil), NSLocalizedString(@"Should I apply current convolution filter on raw data? 2D/3D post-processing viewers can only display raw data.", nil), NSLocalizedString(@"OK", nil), NSLocalizedString(@"Cancel", nil), nil) == HorosAlertDefaultResponse)
                [self applyConvolutionOnSource: self];
        }
        
        [self MovieStop: self];
        
        NSArray *viewers = [[AppController sharedAppController] FindRelatedViewers:pixList[0]];
        
        VRController *viewer = nil;
        
        for( NSWindowController *v in viewers)
        {
            // Not a viewer whose window is closing, as -[AppController FindViewer::].
            if( [v.windowNibName isEqualToString: @"VR"] && [(VRController*) v windowWillClose] == NO)
            {
                VRController *vv = (VRController*) v;
                
                if( [vv.style isEqualToString: @"standard"])
                    viewer = vv;
            }
        }
        
        if( viewer)
        {
            [[viewer window] makeKeyAndOrderFront:self];
            if( [sender tag] == 3) 
                [viewer setModeIndex: 1];
            else
                [viewer setModeIndex: 0];
        }
        else
        {
            NSString	*mode;
            if( [sender tag] == 3) mode = @"MIP";
            else mode = @"VR";
            viewer = [self openVRViewerForMode:mode];
            
            NSString *c;
            
            if( backCurCLUTMenu) c = backCurCLUTMenu;
            else c = curCLUTMenu;
            
            [viewer ApplyCLUTString: c];
            float   iwl, iww;
            [imageView getWLWW:&iwl :&iww];
            [viewer setWLWW:iwl :iww];
            [self place3DViewerWindow: viewer];
            [viewer load3DState];
            [viewer showWindow:self];			
            [[viewer window] makeKeyAndOrderFront:self];
            [[viewer window] display];
            [[viewer window] setTitle: [NSString stringWithFormat:@"%@: %@", [[viewer window] title], [[self window] title]]];
        }
    }
}

- (SRController *)openSRViewer
{
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_3DSUR_LAUNCHED detail:@"{}"];
#endif

    SRController *viewer;
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    if ((viewer = [[AppController sharedAppController] FindViewer :@"SR" :pixList[0]]))
        return viewer;
    NSInteger time = [HorosFourDSeriesGuard wrappedIndex: curMovieIndex count: maxMovieIndex];
    if( pixList[time] == nil || fileList[time] == nil || volumeData[time] == nil)
        return nil;
    viewer = [[SRController alloc] initWithPix:pixList[time] :fileList[time] :volumeData[time] :blendingController :self];
    return viewer;
    
}

-(IBAction) SRViewer:(id) sender
{
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if( [self isDataVolumicIn4D: YES] == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Surface Rendering", nil), NSLocalizedString(@"Surface Rendering requires volumic data.", nil), nil, nil, nil);
        return;
    }
    if( [self refuseFourDReconstructionWithTitle: NSLocalizedString(@"Surface Rendering", nil)])
        return;
    
    if( [self computeInterval] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
       ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
    }
    else
    {
        [self displayAWarningIfNonTrueVolumicData];
        [self displayWarningIfGantryTitled];
        
        [self MovieStop: self];
        
        SRController *viewer = [[AppController sharedAppController] FindViewer :@"SR" :pixList[0]];
        
        if( viewer)
        {
            [[viewer window] makeKeyAndOrderFront:self];
        }
        else
        {
            viewer = [self openSRViewer];
            [self place3DViewerWindow: viewer];
            //			[[viewer window] performZoom:self];
            [viewer showWindow:self];
            [[viewer window] makeKeyAndOrderFront:self];
            [viewer ChangeSettings:self];
            [[viewer window] setTitle: [NSString stringWithFormat:@"%@: %@", [[viewer window] title], [[self window] title]]];
        }
    }
}
#endif

- (OrthogonalMPRViewer *)openOrthogonalMPRViewer
{
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_2DMPR_LAUNCHED detail:@"{}"];
#endif

    OrthogonalMPRViewer *viewer;
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if( blendingController)
    {
        viewer = [[AppController sharedAppController] FindViewer :@"PETCT" :pixList[0]];
    }
    else
    {
        viewer = [[AppController sharedAppController] FindViewer :@"OrthogonalMPR" :pixList[0]];
    }
    if (viewer)
        return viewer;

    NSInteger time = [HorosFourDSeriesGuard alignedTimeIndexRequested: curMovieIndex count: maxMovieIndex];
    if( pixList[time] == nil || fileList[time] == nil || volumeData[time] == nil)
        return nil;
    viewer = [[OrthogonalMPRViewer alloc] initWithPixList:pixList[time] :fileList[time] :volumeData[time] :self :nil];
    
    float sww = imageView.curWW;
    float swl = imageView.curWL;
    
    NSString *c;
    
    if( backCurCLUTMenu) c = backCurCLUTMenu;
    else c = curCLUTMenu;
    
    if( [[pixList[time] objectAtIndex: 0] isRGB] == NO)
    {
        if( [[self modality] isEqualToString:@"PT"] || ([[NSUserDefaults standardUserDefaults] boolForKey:@"clutNM"] == YES && [[self modality] isEqualToString:@"NM"]))
        {
            if( [[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] isEqualToString: @"B/W Inverse"])
                [viewer ApplyCLUTString: @"B/W Inverse"];
            else
                [viewer ApplyCLUTString: [[NSUserDefaults standardUserDefaults] stringForKey:@"PET Default CLUT"]];
        }
        else [viewer ApplyCLUTString: c];
    }
    else [viewer ApplyCLUTString: c];
    
    [viewer ApplyOpacityString: curOpacityMenu];
    
    [viewer setWLWW: swl :sww];
    
    return viewer;
}

#ifndef OSIRIX_LIGHT
- (OrthogonalMPRPETCTViewer *)openOrthogonalMPRPETCTViewer
{
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_2DMPR_LAUNCHED detail:@"{}"];
#endif

    OrthogonalMPRPETCTViewer  *viewer;
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if ((viewer = [[AppController sharedAppController] FindViewer :@"PETCT" :pixList[0]]))
        return viewer;
    
    if (blendingController)
    {
        float orientA[9], orientB[9];
        
        [[[self imageView] curDCM] orientation:orientA];
        [[[blendingController imageView] curDCM] orientation:orientB];
        
        if( [DCMView angleBetweenVector: orientA+6 andVector:orientB+6] > [[NSUserDefaults standardUserDefaults] floatForKey: @"PARALLELPLANETOLERANCE"])  // Planes are not paralel!
        {
            HorosRunCriticalAlertPanel(NSLocalizedString(@"2D Planes",nil),NSLocalizedString(@"These 2D planes are not parallel, you cannot use the 2D Orthogonal MPR viewer. Instead, try the 3D MPR viewer.",nil), NSLocalizedString(@"OK",nil), nil, nil);
        }
        else
        {
            NSInteger time = [HorosFourDSeriesGuard alignedTimeIndexRequested: curMovieIndex count: maxMovieIndex];
            if( pixList[time] == nil || fileList[time] == nil || volumeData[time] == nil)
                return nil;
            NSInteger overlayTime = [HorosFourDSeriesGuard fusionOverlayIndexForHostTime: time
                                                                               hostCount: maxMovieIndex
                                                                            overlayCount: [blendingController maxMovieIndex]];
            if( [blendingController curMovieIndex] != overlayTime)
                [blendingController setMovieIndex: (short)overlayTime];
            viewer = [[OrthogonalMPRPETCTViewer alloc] initWithPixList:pixList[time] :fileList[time] :volumeData[time] :self : blendingController];
            [self place3DViewerWindow: viewer];
            
            NSString *c;
            
            if( backCurCLUTMenu) c = backCurCLUTMenu;
            else c = curCLUTMenu;
            
            [[viewer CTController] ApplyCLUTString: c];
            [[viewer PETController] ApplyCLUTString: [blendingController curCLUTMenu]];
            [[viewer PETCTController] ApplyCLUTString: c];
            
            [[viewer CTController] ApplyOpacityString: curOpacityMenu];
            [[viewer PETController] ApplyOpacityString:[blendingController curOpacityMenu]];
            [[viewer PETCTController] ApplyOpacityString: curOpacityMenu];
            
            [(OrthogonalMPRPETCTView*)[[viewer PETCTController] originalView] setCurCLUTMenu: [blendingController curCLUTMenu]];
            [(OrthogonalMPRPETCTView*)[[viewer PETCTController] xReslicedView] setCurCLUTMenu: [blendingController curCLUTMenu]];
            [(OrthogonalMPRPETCTView*)[[viewer PETCTController] yReslicedView] setCurCLUTMenu: [blendingController curCLUTMenu]];
            
            [(OrthogonalMPRPETCTView*)[[viewer PETCTController] originalView] setCurOpacityMenu: [blendingController curOpacityMenu]];
            [(OrthogonalMPRPETCTView*)[[viewer PETCTController] xReslicedView] setCurOpacityMenu: [blendingController curOpacityMenu]];
            [(OrthogonalMPRPETCTView*)[[viewer PETCTController] yReslicedView] setCurOpacityMenu: [blendingController curOpacityMenu]];
            
            [viewer showWindow:self];
            
            float   iwl, iww;
            [imageView getWLWW:&iwl :&iww];
            [[viewer CTController] setWLWW:iwl :iww];
            [[blendingController imageView] getWLWW:&iwl :&iww];
            [[viewer PETController] setWLWW:iwl :iww];
            
            [viewer setBlendingMode: [[NSUserDefaults standardUserDefaults] integerForKey: @"DEFAULTPETFUSION"]];
            
            return viewer;
        }
    }
    return nil;	
}
#endif

-(IBAction) orthogonalMPRViewer:(id) sender
{
    
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if( [self computeInterval] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
       ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
    }
    else
    {
        if( [self isDataVolumicIn4D: YES] == NO) // || [[imageView curDCM] isRGB] == YES)
        {
            HorosRunAlertPanel(NSLocalizedString(@"MPR", nil), NSLocalizedString(@"MPR requires volumic data.", nil), nil, nil, nil);
            return;
        }
        // A series that passes the volumic check can still be one this
        // reconstruction cannot resample - mixed matrices, mixed orientations, a
        // non-finite interval. The oblique MPR has named those since #217; this
        // door drew empty planes instead (#374, A205).
        HorosMPROpenDecision *geometry = [self reconstructionOpeningDecision];
        if( geometry.accepted == NO)
        {
            HorosRunAlertPanel(NSLocalizedString(@"MPR", nil), @"%@", nil, nil, nil, geometry.diagnosis);
            return;
        }
        if( [self refuseFourDReconstructionWithTitle: NSLocalizedString(@"MPR", nil)])
            return;
        if( blendingController && [self refuseFourDFusionWithTitle: NSLocalizedString(@"PET-CT Fusion", nil)])
            return;
        
        [self displayAWarningIfNonTrueVolumicData];
        [self displayWarningIfGantryTitled];
        
        [blendingController displayAWarningIfNonTrueVolumicData];
        [blendingController displayWarningIfGantryTitled];
        
        [self MovieStop: self];
        
        OrthogonalMPRViewer *viewer;
        
        if( blendingController)
        {
            viewer = [[AppController sharedAppController] FindViewer :@"PETCT" :pixList[0]];
        }
        else
        {
            viewer = [[AppController sharedAppController] FindViewer :@"OrthogonalMPR" :pixList[0]];
        }
        
        if( viewer)
        {
            [[viewer window] makeKeyAndOrderFront:self];
        }
        else
        {
#ifndef OSIRIX_LIGHT
            if( blendingController)
            {
                OrthogonalMPRPETCTViewer *pcviewer = [self openOrthogonalMPRPETCTViewer];
                NSInteger time = [HorosFourDSeriesGuard alignedTimeIndexRequested: curMovieIndex count: maxMovieIndex];
                NSDate *studyDate = [[fileList[time] objectAtIndex:0] valueForKeyPath:@"series.study.date"];
                
                [[pcviewer window] setTitle: [NSString stringWithFormat:@"%@: %@ - %@", [[pcviewer window] title], [[NSUserDefaults dateTimeFormatter] stringFromDate:studyDate], [[self window] title]]];
            }
            else
#endif
            {
                viewer = [self openOrthogonalMPRViewer];
                
                [self place3DViewerWindow: viewer];
                [viewer showWindow:self];
                
                float   iwl, iww;
                [imageView getWLWW:&iwl :&iww];
                [viewer setWLWW:iwl :iww];
                
                [[viewer window] setTitle: [NSString stringWithFormat:@"%@: %@ - %@", [[viewer window] title], [NSUserDefaults formatDateTime: [[fileList[0] objectAtIndex:0]  valueForKeyPath:@"series.study.date"]], [[self window] title]]];
            }
        }
    }
}

#ifndef OSIRIX_LIGHT
- (EndoscopyViewer *)openEndoscopyViewer
{
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_3DEND_LAUNCHED detail:@"{}"];
#endif

    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    EndoscopyViewer *viewer;
    
    viewer = [[AppController sharedAppController] FindViewer :@"Endoscopy" :pixList[0]];
    if (viewer)
        return viewer;

    NSInteger time = [HorosFourDSeriesGuard alignedTimeIndexRequested: curMovieIndex count: maxMovieIndex];
    if( pixList[time] == nil || fileList[time] == nil || volumeData[time] == nil)
        return nil;
    viewer = [[EndoscopyViewer alloc] initWithPixList:pixList[time] :fileList[time] :volumeData[time] :blendingController : self];
    return viewer;
}


-(IBAction) endoscopyViewer:(id) sender
{
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if( [self isDataVolumicIn4D: YES] == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Endoscopy", nil), NSLocalizedString(@"Endoscopy requires volumic data.", nil), nil, nil, nil);
        return;
    }
    if( [self refuseFourDReconstructionWithTitle: NSLocalizedString(@"Endoscopy", nil)])
        return;
    
    if( [self computeInterval] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
       ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
    }
    else
    {
        [self displayAWarningIfNonTrueVolumicData];
        [self displayWarningIfGantryTitled];
        
        [self MovieStop: self];
        
        EndoscopyViewer *viewer;
        
        viewer = [[AppController sharedAppController] FindViewer :@"Endoscopy" :pixList[0]];
        
        if( viewer)
        {
            [[viewer window] makeKeyAndOrderFront:self];
        }
        else
        {
            viewer = [self openEndoscopyViewer];
            [self place3DViewerWindow: viewer];
            [viewer showWindow:self];
            [[viewer window] setTitle: [NSString stringWithFormat:@"%@: %@", [[viewer window] title], [[self window] title]]];
        }
    }
}
#endif

//-(IBAction) MIPViewer:(id) sender
//{
//	long i;
//	
//	[self checkEverythingLoaded];
//	[self clear8bitRepresentations];
//	
//	if( [self computeInterval] == 0 ||
//		[[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
//		[[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
//		([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
//	{
//		[self SetThicknessInterval:sender];
//	}
//	else
//	{
//		MIPController *viewer = [[AppController sharedAppController] FindViewer :@"MIP" :pixList[0]];
//		
//		if( viewer)
//		{
//			[[viewer window] makeKeyAndOrderFront:self];
//		}
//		else
//		{
//			viewer = [[MIPController alloc] initWithPix :pixList[curMovieIndex] :fileList[0] :volumeData[curMovieIndex] :blendingController];
//			for( i = 1; i < maxMovieIndex; i++)
//			{
//				[viewer addMoviePixList:pixList[ i] :volumeData[ i]];
//			}
//			
//			[viewer ApplyCLUTString:curCLUTMenu];
//			long   iwl, iww;
//			[imageView getWLWW:&iwl :&iww];
//			[viewer setWLWW:iwl :iww];
//			[viewer load3DState];
//			[viewer showWindow:self];
//			[[viewer window] makeKeyAndOrderFront:self];
//		}
//	}
//}

#ifndef OSIRIX_LIGHT
- (MPRController *)openMPRViewer
{
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_3DMPR_LAUNCHED detail:@"{}"];
#endif

    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    if( [self fourDReconstructionRefusalReason])
        return nil;
    
    MPRController *viewer;
    viewer = [[AppController sharedAppController] FindViewer:@"MPR" :pixList[0]];
    if (viewer)
        return viewer;
    
    viewer = [[MPRController alloc] initWithDCMPixList:pixList[0]
                                             filesList:fileList[0]
                                            volumeData:volumeData[0]
                                      viewerController:self
                                 fusedViewerController:blendingController];
    for( int i = 1; i < maxMovieIndex; i++)
    {
        [viewer addMoviePixList:pixList[ i] :volumeData[ i]];
    }
    
    return viewer;
}


// The geometry every reconstruction door has to agree about (#374, A205).
//
// This used to live inside -mprViewer:, so the oblique MPR refused an
// incompatible series with a named reason while the orthogonal MPR and the CPR
// went ahead and drew empty planes. A205 asks the opposite: valid input gives
// the expected planes, and incompatible input gives a *specific* error.
- (HorosMPROpenDecision*) reconstructionOpeningDecision
{
    float interval = [self computeInterval];
    DCMPix *firstPix = [pixList[0] objectAtIndex:0];
    double minInterval = fabs(interval), maxInterval = fabs(interval);
    int mismatchedSlices = 0;
    int mismatchedOrientations = 0;
    float referenceOrientation[9];
    NSUInteger referenceIndex = [pixList[0] count] > 1 ? 1 : 0;
    [[pixList[0] objectAtIndex:referenceIndex] orientation: referenceOrientation];
    NSUInteger roiCount = 0;
    for (NSUInteger j = 0; j < [pixList[0] count]; j++)
    {
        DCMPix *slice = [pixList[0] objectAtIndex:j];
        if ([slice pwidth] != [firstPix pwidth] || [slice pheight] != [firstPix pheight])
            mismatchedSlices++;
        float sliceOrientation[9];
        [slice orientation: sliceOrientation];
        for (int k = 0; k < 9; k++)
        {
            if (fabs(sliceOrientation[k] - referenceOrientation[k]) > ORIENTATION_SENSIBILITY)
            {
                mismatchedOrientations++;
                break;
            }
        }
        if (j + 1 < [pixList[0] count])
        {
            double xd = [[pixList[0] objectAtIndex:j + 1] originX] - [slice originX];
            double yd = [[pixList[0] objectAtIndex:j + 1] originY] - [slice originY];
            double zd = [[pixList[0] objectAtIndex:j + 1] originZ] - [slice originZ];
            double step = sqrt(xd * xd + yd * yd + zd * zd);
            if (j == 0)
                minInterval = maxInterval = step;
            else
            {
                if (step > maxInterval) maxInterval = step;
                if (step < minInterval) minInterval = step;
            }
        }
    }
    for (NSArray *sliceRois in roiList[curMovieIndex])
        roiCount += [sliceRois count];

    return [HorosMPROpenGeometry openingWithSliceCount:(int)[pixList[0] count]
                                              spacingX:[firstPix pixelSpacingX]
                                              spacingY:[firstPix pixelSpacingY]
                                         sliceInterval:interval
                                           minInterval:minInterval
                                           maxInterval:maxInterval
                                                 width:[firstPix pwidth]
                                                height:[firstPix pheight]
                                      mismatchedSlices:mismatchedSlices
                                              roiCount:(int)roiCount
                                mismatchedOrientations:mismatchedOrientations];
}

- (IBAction) mprViewer:(id) sender
{
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];

    HorosMPROpenDecision *geometry = [self reconstructionOpeningDecision];
    float interval = [self computeInterval];
    DCMPix *firstPix = [pixList[0] objectAtIndex:0];

    if ([geometry.phase isEqualToString:@"calibrate"] ||
        interval == 0 ||
        [firstPix pixelSpacingX] == 0 ||
        [firstPix pixelSpacingY] == 0 ||
        ([[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
        return;
    }
    if (geometry.accepted == NO)
    {
        HorosRunAlertPanel(NSLocalizedString(@"MPR", nil), @"%@", nil, nil, nil, geometry.diagnosis);
        return;
    }

    if( [self isDataVolumicIn4D: YES] == NO) // || [[imageView curDCM] isRGB] == YES)
    {
        HorosRunAlertPanel(NSLocalizedString(@"MPR", nil), NSLocalizedString(@"MPR requires volumic data.", nil), nil, nil, nil);
        return;
    }
    if( [self refuseFourDReconstructionWithTitle: NSLocalizedString(@"MPR", nil)])
        return;

    [self displayAWarningIfNonTrueVolumicData];
    [self displayWarningIfGantryTitled];

    [self MovieStop: self];

    MPRController *viewer;

    viewer = [[AppController sharedAppController] FindViewer :@"MPR" :pixList[0]];

    // The Series Selection item of an MPR (#895) asks for the new series here and
    // closes itself afterwards: the MPR that replaces it takes its frame.
    NSWindow *replacedMPRWindow = [sender isKindOfClass: [MPRController class]] ? [sender window] : nil;

    if( viewer)
    {
        if( replacedMPRWindow && viewer != sender)
            [[viewer window] setFrame: [replacedMPRWindow frame] display: YES];
        [[viewer window] makeKeyAndOrderFront:self];
    }
    else
    {
        viewer = [self openMPRViewer];
        if( replacedMPRWindow)
            [[viewer window] setFrame: [replacedMPRWindow frame] display: NO];
        else
            [self place3DViewerWindow:viewer];
        [viewer showWindow:self];
        [[viewer window] setTitle: [NSString stringWithFormat:@"%@: %@", [[viewer window] title], [[self window] title]]];
        dispatch_async(dispatch_get_main_queue(), ^(){
            [viewer showWindow:self];
            [viewer showWindow:self];
        });
    }
}

/** Action to open the CPRViewer */
- (CPRController *)openCPRViewer
{
#if defined(USEHOMEPHONE)
    [[HorosHomePhone sharedHomePhone] callHomeInformingFunctionType:HOME_PHONE_3DCPR_LAUNCHED detail:@"{}"];
#endif

    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    if( [self fourDReconstructionRefusalReason])
        return nil;
    
    CPRController *viewer;
    viewer = [[AppController sharedAppController] FindViewer:@"CPR" :pixList[0]];
    if (viewer)
        return viewer;
    
    viewer = [[CPRController alloc] initWithDCMPixList:pixList[0] filesList:fileList[0] volumeData:volumeData[0] viewerController:self fusedViewerController:blendingController];
    for( int i = 1; i < maxMovieIndex; i++)
    {
        [viewer addMoviePixList:pixList[ i] :volumeData[ i]];
    }
    
    return viewer;
}


- (IBAction) cprViewer:(id) sender
{
    [self checkEverythingLoaded];
    [self clear8bitRepresentations];
    
    if( [self computeInterval] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingX] == 0 ||
       [[pixList[0] objectAtIndex:0] pixelSpacingY] == 0 ||
       ([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [self SetThicknessInterval:sender];
    }
    else
    {
        if( [self isDataVolumicIn4D: YES] == NO || [[imageView curDCM] isRGB] == YES)
        {
            HorosRunAlertPanel(NSLocalizedString(@"CPR", nil), NSLocalizedString(@"CPR requires volumic data and BW images.", nil), nil, nil, nil);
            return;
        }
        // The curved path a TAVR plan is drawn on is resampled from the same
        // volume, so the same geometry has to hold. Without this the CPR opened
        // on a series it could not resample and showed empty planes (#374, A205).
        HorosMPROpenDecision *geometry = [self reconstructionOpeningDecision];
        if( geometry.accepted == NO)
        {
            HorosRunAlertPanel(NSLocalizedString(@"CPR", nil), @"%@", nil, nil, nil, geometry.diagnosis);
            return;
        }
        if( [self refuseFourDReconstructionWithTitle: NSLocalizedString(@"CPR", nil)])
            return;
        
        [self displayAWarningIfNonTrueVolumicData];
        [self displayWarningIfGantryTitled];
        
        [self MovieStop: self];
        
        CPRController *viewer;
        
        viewer = [[AppController sharedAppController] FindViewer :@"CPR" :pixList[0]];
        
        if( viewer)
        {
            [[viewer window] makeKeyAndOrderFront:self];
        }
        else
        {
            id waitWindow = [self startWaitWindow:NSLocalizedString(@"Loading...",nil)];
            viewer = [self openCPRViewer];
            [self place3DViewerWindow:viewer];
            [viewer showWindow:self];
            [[viewer window] setTitle: [NSString stringWithFormat:@"%@: %@", [[viewer window] title], [[self window] title]]];
            dispatch_async(dispatch_get_main_queue(), ^(){
                [viewer showWindow:self];
                [viewer showWindow:self];
                [self endWaitWindow:waitWindow];
            });
        }
    }
}

#endif

#pragma mark-
#pragma mark 4.5.4 Study navigation


-(IBAction) loadPatient:(id) sender
{
    if( windowWillClose) return;
    
    if( delayedTileWindows)
    {
        delayedTileWindows = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:[AppController sharedAppController] selector:@selector(tileWindows:) object:nil];
        [[AppController sharedAppController] tileWindows: nil];
    }
    
    [[BrowserController currentBrowser] loadNextPatient:[fileList[0] objectAtIndex:0] :[sender tag] :self :YES keyImagesOnly: displayOnlyKeyImages];
}

-(void) loadSeries:(NSNumber*) t
{
    if( windowWillClose) return;
    
    int dir = [t intValue];
    
    BOOL b = [[NSUserDefaults standardUserDefaults] boolForKey:@"nextSeriesToAllViewers"];
    
    if( b)
        [[NSUserDefaults standardUserDefaults] setBool: NO forKey:@"nextSeriesToAllViewers"];
    
    int curImage;
    
    if( dir == -1)
    {
        if( [imageView flippedData]) curImage = 0;
        else curImage = (long)[[imageView dcmPixList] count]-1;
    }
    else
    {
        if( [imageView flippedData]) curImage = (long)[[imageView dcmPixList] count]-1;
        else curImage = 0;
    }
    [imageView setIndex: curImage];
    
    [[BrowserController currentBrowser] loadNextSeries:[fileList[0] objectAtIndex:0] :dir :self :YES keyImagesOnly: displayOnlyKeyImages];
    
    if( dir == -1)
    {
        if( [imageView flippedData]) curImage = 0;
        else curImage = (long)[[imageView dcmPixList] count]-1;
    }
    else
    {
        if( [imageView flippedData]) curImage = (long)[[imageView dcmPixList] count]-1;
        else curImage = 0;
    }
    
    [imageView setIndex: curImage];
    [self adjustSlider];
    [imageView sendSyncMessage: 0];
    [imageView setNeedsDisplay: YES];
    
    if( b)
        [[NSUserDefaults standardUserDefaults] setBool: b forKey:@"nextSeriesToAllViewers"];
}

-(void) loadSeriesUp
{
    if( windowWillClose) return;
    
    [self loadSeries: [NSNumber numberWithInt: 1]];
}

-(void) loadSeriesDown
{
    if( windowWillClose) return;
    
    [self loadSeries: [NSNumber numberWithInt: -1]];
}

-(IBAction) loadSerie:(id) sender
{
    if( windowWillClose) return;
    
    if( delayedTileWindows)
    {
        delayedTileWindows = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:[AppController sharedAppController] selector:@selector(tileWindows:) object:nil];
        [[AppController sharedAppController] tileWindows: nil];
    }
    // tag=-1 backwards, tag=1 forwards, tag=3 ???
    if( [sender tag] == 3)
    {
        [[sender selectedItem] setImage:nil];
        
        (void)[[BrowserController currentBrowser] loadSeries :[[[sender selectedItem] representedObject] object] :self :YES keyImagesOnly: displayOnlyKeyImages];
    }
    else
    {
        [[BrowserController currentBrowser] loadNextSeries:[fileList[0] objectAtIndex:0] :[sender tag] :self :YES keyImagesOnly: displayOnlyKeyImages];
    }
}

- (BOOL) isEverythingLoaded
{
    if (loadingThread)
    {
        @synchronized( loadingThread)
        {
            if( loadingThread)
                return !loadingThread.isExecuting;
        }
    }
    
    if( [[pixList[0] objectAtIndex: pixList[0].count/2] isLoaded] == NO) // The loadingThread was maybe not yet created...
        return NO;
    
    return YES;
}

-(void) checkEverythingLoaded
{
    BOOL isExecuting;
    
    @synchronized( loadingThread)
    {
        if( loadingThread)
            isExecuting = loadingThread.isExecuting && requestLoadingCancel == NO;
        else
            isExecuting = NO;
    }
    
    if( isExecuting)
    {
        checkEverythingLoaded = YES;
        
        Wait *splash = [[Wait alloc] initWithString:NSLocalizedString(@"Data loading...", nil)];
        [splash showWindow:self];
        
        {
            BOOL isExecuting;
            int percentage = 0, lastPercentage = 0;
            
            do
            {
                [NSThread sleepForTimeInterval: 0.1];
                
                @synchronized( loadingThread)
                {
                    isExecuting = loadingThread.isExecuting && requestLoadingCancel == NO;
                    percentage = [[loadingThread.threadDictionary objectForKey: @"loadingPercentage"] floatValue] * 100.;
                }
                
                if(isExecuting && percentage != lastPercentage)
                {
                    [self setWindowTitle: self];
                    [[self window] display];
                    
                    [splash incrementBy: percentage - lastPercentage];
                    lastPercentage = percentage;
                }
            }
            while( isExecuting);
        }
        
        [splash close];
        [splash autorelease];
        
        [self setWindowTitle: self];
        
        checkEverythingLoaded = NO;
        
        if (blendingController && blendingController->requestLoadingCancel == NO)
            [blendingController checkEverythingLoaded];
    }
    
    if (windowWillClose == NO && requestLoadingCancel == NO)
        [self computeInterval];
}

-(void) executeRevert
{
    [self checkEverythingLoaded];
    
    for( int x = 0; x < maxMovieIndex; x++)
    {
        for( int i = 0 ; i < [pixList[ x] count]; i++)
        {
            DCMPix* pix = [pixList[ x] objectAtIndex: i];
            [pix revert];
        }
    }
    
    [self startLoadImageThread];
    
    [imageView updatePresentationStateFromSeries];
    
    [self checkEverythingLoaded];
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateVolumeDataNotification object: pixList[ curMovieIndex] userInfo: nil];
}

-(void) revertSeries:(id) sender
{
    if( postprocessed)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Revert", nil), NSLocalizedString(@"This dataset has been post processed (reslicing, MPR, ...). You cannot revert it.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        
        return;
    }
    
    [self executeRevert];
}

-(void) revertSeriesNotification:(id) note
{
    long x;
    
    for( x = 0; x < maxMovieIndex; x++)
    {
        if( [note object] == pixList[ x])
        {
            [self revertSeries:self];
        }
    }
}

#pragma mark key image

- (IBAction) keyImageCheckBox:(id) sender
{
    if( postprocessed == NO)
    {
        [[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[NSNumber numberWithBool:[sender state]] forKey:@"isKeyImage"];
        
        if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
        {
            [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[NSNumber numberWithBool:[sender state]] forKey:@"isKeyImage"];
        }
        
        [self willChangeValueForKey: @"KeyImageCounter"];
        [self didChangeValueForKey: @"KeyImageCounter"];
        
        [self buildMatrixPreview: NO];
        
        [imageView setNeedsDisplay:YES];
        
        (void)[[[BrowserController currentBrowser] database] save:nil];
    }
}

- (IBAction) findNextPreviousKeyImage:(id)sender
{
    if( postprocessed)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Key Images", nil), NSLocalizedString(@"This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    
    [self checkEverythingLoaded];
    
    BOOL tag = [sender tag];
    
    if( [imageView flippedData]) tag = !tag;
    
    if( tag == 0)
    {
        // First find in this series
        for( int i = [imageView curImage]+1; i < [fileList[ curMovieIndex] count]; i++)
        {
            NSManagedObject *image = [fileList[ curMovieIndex] objectAtIndex: i];
            
            if( [[image valueForKey:@"isKeyImage"] boolValue])
            {
                [imageView setIndex: i];
                [imageView sendSyncMessage: 0];
                [self adjustSlider];
                [imageView displayIfNeeded];
                return;
            }
        }
    }
    else
    {
        for( int i = [imageView curImage]-1; i >= 0 ; i--)
        {
            NSManagedObject *image = [fileList[ curMovieIndex] objectAtIndex: i];
            
            if( [[image valueForKey:@"isKeyImage"] boolValue])
            {
                [imageView setIndex: i];
                [imageView sendSyncMessage: 0];
                [self adjustSlider];
                [imageView displayIfNeeded];
                return;
            }
        }
    }
    
    if( [imageView flippedData]) tag = !tag; // We RE-inverse the tag !
    
    if( tag == 0)
    {
        //Nothing found -> search in next series
        NSArray *seriesArray = [[BrowserController currentBrowser] childrenArray: [[imageView seriesObj] valueForKey:@"study"]];
        
        NSUInteger indexOfObject = [seriesArray indexOfObject: [imageView seriesObj]];
        if( indexOfObject != NSNotFound)
        {
            for( int i = indexOfObject+1; i < seriesArray.count; i++)
            {
                if( [[[seriesArray objectAtIndex: i] keyImages] count])
                {
                    //Load this series
                    (void)[[BrowserController currentBrowser] loadSeries :[seriesArray objectAtIndex: i] :self :YES keyImagesOnly: displayOnlyKeyImages];
                    
                    [self showCurrentThumbnail:self];
                    [self updateNavigator];
                    
                    if( [imageView flippedData])
                    {
                        for( int i = (long)[fileList[ curMovieIndex] count]-1; i >= 0 ; i--)
                        {
                            NSManagedObject *image = [fileList[ curMovieIndex] objectAtIndex: i];
                            
                            if( [[image valueForKey:@"isKeyImage"] boolValue])
                            {
                                [imageView setIndex: i];
                                [imageView sendSyncMessage: 0];
                                [self adjustSlider];
                                [imageView displayIfNeeded];
                                return;
                            }
                        }
                    }
                    else
                    {
                        for( int i = 0; i < [fileList[ curMovieIndex] count]; i++)
                        {
                            NSManagedObject *image = [fileList[ curMovieIndex] objectAtIndex: i];
                            
                            if( [[image valueForKey:@"isKeyImage"] boolValue])
                            {
                                [imageView setIndex: i];
                                [imageView sendSyncMessage: 0];
                                [self adjustSlider];
                                [imageView displayIfNeeded];
                                return;
                            }
                        }
                    }
                }
            }
        }
        
        NSBeep();
    }
    else
    {
        //Nothing found -> search in next series
        NSArray *seriesArray = [[BrowserController currentBrowser] childrenArray: [[imageView seriesObj] valueForKey:@"study"]];
        
        NSUInteger indexOfObject = [seriesArray indexOfObject: [imageView seriesObj]];
        if( indexOfObject != NSNotFound)
        {
            for( int i = indexOfObject-1; i >= 0; i++)
            {
                if( [[[seriesArray objectAtIndex: i] keyImages] count])
                {
                    //Load this series
                    (void)[[BrowserController currentBrowser] loadSeries :[seriesArray objectAtIndex: i] :self :YES keyImagesOnly: displayOnlyKeyImages];
                    
                    [self showCurrentThumbnail:self];
                    [self updateNavigator];
                    
                    if( [imageView flippedData] == NO)
                    {
                        for( int i = (long)[fileList[ curMovieIndex] count]-1; i >= 0 ; i--)
                        {
                            NSManagedObject *image = [fileList[ curMovieIndex] objectAtIndex: i];
                            
                            if( [[image valueForKey:@"isKeyImage"] boolValue])
                            {
                                [imageView setIndex: i];
                                [imageView sendSyncMessage: 0];
                                [self adjustSlider];
                                [imageView displayIfNeeded];
                                return;
                            }
                        }
                    }
                    else
                    {
                        for( int i = 0; i < [fileList[ curMovieIndex] count]; i++)
                        {
                            NSManagedObject *image = [fileList[ curMovieIndex] objectAtIndex: i];
                            
                            if( [[image valueForKey:@"isKeyImage"] boolValue])
                            {
                                [imageView setIndex: i];
                                [imageView sendSyncMessage: 0];
                                [self adjustSlider];
                                [imageView displayIfNeeded];
                                return;
                            }
                        }
                    }
                }
            }
        }
        
        NSBeep();
    }
}

- (IBAction) keyImageDisplayButton:(id) sender
{
    if( postprocessed)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Key Images", nil), NSLocalizedString(@"This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    
    NSManagedObject	*series = [[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] valueForKey:@"series"];
    
    [self checkEverythingLoaded];
    
    displayOnlyKeyImages = [keyImagePopUpButton indexOfSelectedItem];
    if( series)
    {
        if(!displayOnlyKeyImages)
        {
            // ALL IMAGES ARE DISPLAYED			
            NSArray	*images = [[BrowserController currentBrowser] childrenArray: series];
            [[BrowserController currentBrowser] openViewerFromImages :[NSArray arrayWithObject: images] movie: NO viewer :self keyImagesOnly: displayOnlyKeyImages];
        }
        else
        {
            // ONLY KEY IMAGES
            NSArray	*images = [[BrowserController currentBrowser] childrenArray: series];
            NSArray *keyImagesArray = [NSArray array];
            
            for( NSManagedObject *image in images)
            {
                if( [[image valueForKey:@"isKeyImage"] boolValue] == YES)
                    keyImagesArray = [keyImagesArray arrayByAddingObject: image];
            }
            
            if( [keyImagesArray count] == 0)
            {
                HorosRunAlertPanel(NSLocalizedString(@"Key Images", nil), NSLocalizedString(@"No key images have been selected in this series.", nil), nil, nil, nil);
                [keyImagePopUpButton selectItemAtIndex: 0];
            }
            else
            {
                [[BrowserController currentBrowser] openViewerFromImages :[NSArray arrayWithObject: keyImagesArray] movie: NO viewer :self keyImagesOnly: displayOnlyKeyImages];
                
            }
        }
    }
}

- (IBAction) setROIsImagesKeyImages:(id)sender
{
    if( postprocessed)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Key Images", nil), NSLocalizedString(@"This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    
    NSNumber *yes = [NSNumber numberWithBool: YES];
    
    for( int x = 0 ; x < maxMovieIndex ; x++)
    {
        for( int i = 0 ; i < [fileList[ x] count] ; i++)
        {
            NSManagedObject *o = [fileList[ x] objectAtIndex: i];
            if( [[roiList[ x] objectAtIndex: i] count])
                [o setValue: yes forKey:@"isKeyImage"];
        }
    }
    
    if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
    {
        for( int x = 0 ; x < maxMovieIndex ; x++)
        {
            for( int i = 0 ; i < [fileList[ x] count] ; i++)
            {
                NSManagedObject *o = [fileList[ x] objectAtIndex: i];
                if( [[roiList[ x] objectAtIndex: i] count])
                    [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:o setValue:yes forKey:@"isKeyImage"];
            }
        }
    }
    
    [self buildMatrixPreview: NO];
    [imageView setNeedsDisplay:YES];
    (void)[[[BrowserController currentBrowser] database] save:nil];
    
    [self adjustKeyImage];
}

- (IBAction) setAllNonKeyImages:(id)sender
{
    if( postprocessed)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Key Images", nil), NSLocalizedString(@"This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    
    NSNumber *yes = [NSNumber numberWithBool: NO];
    
    for( int x = 0 ; x < maxMovieIndex ; x++)
        for( NSManagedObject *o in fileList[ x])
            [o setValue: yes forKey:@"isKeyImage"];
    
    if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
    {
        for( int x = 0 ; x < maxMovieIndex ; x++)
            for( NSManagedObject *o in fileList[ x])
                [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:o setValue:yes forKey:@"isKeyImage"];
    }
    
    [self willChangeValueForKey: @"KeyImageCounter"];
    [self didChangeValueForKey: @"KeyImageCounter"];
    
    [self buildMatrixPreview: NO];
    [imageView setNeedsDisplay:YES];
    (void)[[[BrowserController currentBrowser] database] save:nil];
    
    [self adjustKeyImage];
}

- (IBAction) setAllKeyImages:(id)sender
{
    if( postprocessed)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Key Images", nil), NSLocalizedString(@"This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    
    NSNumber *yes = [NSNumber numberWithBool: YES];
    
    for( int x = 0 ; x < maxMovieIndex ; x++)
        for( NSManagedObject *o in fileList[ x])
            [o setValue: yes forKey:@"isKeyImage"];
    
    if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
    {
        for( int x = 0 ; x < maxMovieIndex ; x++)
            for( NSManagedObject *o in fileList[ x])
                [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:o setValue:yes forKey:@"isKeyImage"];
    }
    
    [self willChangeValueForKey: @"KeyImageCounter"];
    [self didChangeValueForKey: @"KeyImageCounter"];
    
    [self buildMatrixPreview: NO];
    [imageView setNeedsDisplay:YES];
    (void)[[[BrowserController currentBrowser] database] save:nil];
    
    [self adjustKeyImage];
}

- (IBAction) setKeyImage:(id)sender
{
    if( postprocessed)
    {
        HorosRunAlertPanel(NSLocalizedString(@"Key Images", nil), NSLocalizedString(@"This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    
    [keyImageCheck setState: ![keyImageCheck state]];
    [self keyImageCheckBox: keyImageCheck];
}

- (void) adjustKeyImage
{
    if( postprocessed)
    {
        [keyImageCheck setEnabled: NO];
        [keyImagePopUpButton setEnabled: NO];
        return;
    }
    
    // multiframes
    // it is impossible in Osirix to select only one frame of a multiframe
    // the condition below was disabling the possibility to see only key images
    // but since end of 2008 multiframe cached loading modification, the controls WERE NOT DISABLED at 2D Viewer opening
    // it is better not disabling them later
    //
    // keyImage remains usefull with multiframes in order to make key files, that is sequences or series	
    //
    // nota: elsewhere in the programm, the popup is moved back from "key image" to "all images" when all the images are key images
    /*
     if( [fileList[ curMovieIndex] count] != 1)
     {
     if( [fileList[ curMovieIndex] objectAtIndex: 0] == [fileList[ curMovieIndex] lastObject])
     {
     [keyImageCheck setState: NSControlStateValueOff];
     [keyImageCheck setEnabled: NO];
     //			[keyImageDisplay setEnabled: NO];
     [keyImagePopUpButton setEnabled: NO];
     
     return;
     }
     }
     */
    
    
    //	[keyImageDisplay setEnabled: YES];
    [keyImageCheck setEnabled: YES];
    [keyImagePopUpButton setEnabled: YES];
    
    // Update Key Image check box
    if( [imageView curImage] >= 0 && [[[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] valueForKey:@"isKeyImage"] boolValue] == YES)
    {
        [keyImageCheck setState: NSControlStateValueOn];
    }
    else
    {
        [keyImageCheck setState: NSControlStateValueOff];
    }
}

- (BOOL)isKeyImage:(int)index
{
    if( postprocessed)
        return NO;
    
    return [[[fileList[curMovieIndex] objectAtIndex:index] valueForKey:@"isKeyImage"] boolValue];
}

#pragma mark-

- (IBAction) endSetComments:(id) sender
{
    [CommentsWindow orderOut:sender];
    
    [CommentsWindow.sheetParent endSheet:CommentsWindow returnCode:[sender tag]];
    
    if( [sender tag] == 1) //series
    {
        [[fileList[ curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[CommentsEditField stringValue] forKeyPath:@"series.comment"];
        
        if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
            [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[CommentsEditField stringValue] forKey:@"series.comment"];
        
        [[[BrowserController currentBrowser] databaseOutline] reloadData];
        
        [self buildMatrixPreview: NO];
    }
    else if( [sender tag] == 2) //study
    {
        [[fileList[ curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[CommentsEditField stringValue] forKeyPath:@"series.study.comment"];
        
        if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
            [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[CommentsEditField stringValue] forKey:@"series.study.comment"];
        
        [[[BrowserController currentBrowser] databaseOutline] reloadData];
        
        [self buildMatrixPreview: NO];
    }
    
    NSString *com = [[fileList[ curMovieIndex] objectAtIndex: [imageView curImage]] valueForKeyPath:@"series.comment"];
    
    if( com == nil || [com isEqualToString:@""])
        com = [[fileList[ curMovieIndex] objectAtIndex: [imageView curImage]] valueForKeyPath:@"series.study.comment"];
    
    if( com == nil || [com isEqualToString:@""]) [CommentsField setTitle: NSLocalizedString(@"Add a comment", nil)];
    else [CommentsField setTitle: com];
}

- (IBAction) setComments:(id) sender
{
    if( [[CommentsField title] isEqualToString:NSLocalizedString(@"Add a comment", nil)]) [CommentsEditField setStringValue: @""];
    else [CommentsEditField setStringValue: [CommentsField title]];
    
    [CommentsEditField selectText: self];
    
    [[self window] beginSheet:CommentsWindow completionHandler:nil];
}

- (void) applyStatusValue
{
    if( statusValueToApply != -1)
    {
        [[fileList[ curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[NSNumber numberWithInt: statusValueToApply] forKeyPath:@"series.study.stateText"];
        
        if([[BrowserController currentBrowser] isCurrentDatabaseBonjour])
        {
            [(RemoteDicomDatabase *)[[BrowserController currentBrowser] database] object:[fileList[curMovieIndex] objectAtIndex:[imageView curImage]] setValue:[NSNumber numberWithInt: statusValueToApply] forKey:@"series.study.stateText"];
        }
        
        [StatusPopup selectItemWithTag: statusValueToApply];
        
        [[[BrowserController currentBrowser] databaseOutline] reloadData];
        [self buildMatrixPreview: NO];
    }
}

- (void) setStatusValue:(int) v
{
    statusValueToApply = v;
}

- (IBAction) setStatus:(id) sender
{
    [self setStatusValue: [[sender selectedItem] tag]];
}

- (IBAction) databaseWindow : (id) sender
{
    if (!([[[NSApplication sharedApplication] currentEvent] modifierFlags]  & NSEventModifierFlagShift))
    {
        [ViewerController closeAllWindows];
    }
    [[BrowserController currentBrowser] showDatabase:self];
}

- (void)setStandardRect:(NSRect)rect
{
    standardRect = rect;
}

#pragma mark-
#pragma mark Key Objects
//- (IBAction)createKeyObjectNote:(id)sender
//{
//	id study = [[imageView seriesObj] valueForKey:@"study"];
//	KeyObjectController *controller = [[KeyObjectController alloc] initWithStudy:(id)study];
//	[NSApp beginSheet:[controller window]  modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(keyObjectSheetDidEnd:returnCode:contextInfo:) contextInfo:controller];
//}
//
//- (void)keyObjectSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode  contextInfo:(id)contextInfo
//{
//	[contextInfo autorelease];
//	[keyImagePopUpButton selectItemAtIndex:displayOnlyKeyImages];
//}

- (BOOL)displayOnlyKeyImages
{
    return displayOnlyKeyImages;
}

#pragma mark-
#pragma mark report

- (IBAction)deleteReport:(id)sender;
{
    [[BrowserController currentBrowser] deleteReport:sender];
    [self performSelector: @selector(updateReportToolbarIcon:) withObject: nil afterDelay: 0.1];
}

#ifndef OSIRIX_LIGHT
- (IBAction)generateReport:(id)sender;
{
    [[BrowserController currentBrowser] generateReport:sender];
    [self performSelector: @selector(updateReportToolbarIcon:) withObject: nil afterDelay: 0.1];
}
#endif

- (NSImage*)reportIcon;
{
    NSString *iconName = @"Report.icns";
    switch([[[NSUserDefaults standardUserDefaults] stringForKey:@"REPORTSMODE"] intValue])
    {
        case 0: // M$ Word
        {
            iconName = @"ReportWord.icns";
        }
            break;
        case 1: // TextEdit (RTF)
        {
            iconName = @"ReportRTF.icns";
        }
            break;
        case 2: // Pages.app
        {
            iconName = @"ReportPages.icns";
        }
            break;
    }
    return [NSImage toolbarImageNamed:iconName];
}

- (void) updateReportToolbarIcon:(NSNotification *)note
{
    long i;
    NSToolbarItem *item;
    NSArray *toolbarItems = [toolbar items];
    for(i=0; i<[toolbarItems count]; i++)
    {
        item = [toolbarItems objectAtIndex:i];
        if ([[item itemIdentifier] isEqualToString: ReportToolbarItemIdentifier])
        {
            [toolbar removeItemAtIndex:i];
            [toolbar insertItemWithItemIdentifier: ReportToolbarItemIdentifier atIndex:i];
        }
    }
}


- (void)setToolbarReportIconForItem:(NSToolbarItem *)item;
{
#ifndef OSIRIX_LIGHT
    NSMutableArray* templatesArray = nil;
    switch ([[[NSUserDefaults standardUserDefaults] stringForKey:@"REPORTSMODE"] intValue]) {
        case 2:
            templatesArray = [Reports pagesTemplatesList];
            break;
        case 0:
            templatesArray = [Reports wordTemplatesList];
            break;
    }
    
    DicomStudy* studySelected = [[fileList[0] objectAtIndex:0] valueForKeyPath:@"series.study"];
    
    if (!studySelected.reportURL && templatesArray.count > 1)
    {
        [reportTemplatesImageView setImage:[self reportIcon]];
        [item setView:reportTemplatesView];
        NSSize size = [HorosToolbarPolicy designedSizeForToolbarView:reportTemplatesView];
        [HorosToolbarPolicy constrainViewForItem:item minimumSize:size maximumSize:size];
    }
    else
    {
        [item setImage:[self reportIcon]];
    }
#else
    [item setImage: [NSImage toolbarImageNamed: @"Report.icns"]];
#endif
}


- (void)reportToolbarItemWillPopUp:(NSNotification *)notif;
{
#ifndef OSIRIX_LIGHT
    if([[notif object] isEqualTo:reportTemplatesListPopUpButton])
    {
        [reportTemplatesListPopUpButton removeAllItems];
        [reportTemplatesListPopUpButton addItemWithTitle:@""];
        
        switch ([[[NSUserDefaults standardUserDefaults] stringForKey:@"REPORTSMODE"] intValue]) {
            case 2:
                [reportTemplatesListPopUpButton addItemsWithTitles:[Reports pagesTemplatesList]];
                break;
            case 0:
                [reportTemplatesListPopUpButton addItemsWithTitles:[Reports wordTemplatesList]];
                break;
        }
        
        [reportTemplatesListPopUpButton setAction:@selector(generateReport:)];
    }
#endif
}


#pragma mark-
#pragma mark current Core Data Objects
- (DicomStudy *)currentStudy
{
    return [[imageView seriesObj] valueForKey:@"study"];
}
- (DicomSeries *)currentSeries
{
    return [imageView seriesObj];
}
- (DicomImage *)currentImage
{
    return [imageView imageObj];
}


#pragma mark-
#pragma mark Convience methods for accessing values in the current imageView
-(float)curWW
{
    return [imageView curWW];
}

-(float)curWL
{
    return [imageView curWL];
}

- (void)setWL:(float)cwl  WW:(float)cww
{
    [imageView setWLWW:cwl :cww];
}

- (BOOL)xFlipped
{
    return [imageView xFlipped];
}

- (BOOL)yFlipped
{
    return [imageView yFlipped];
}

- (float)rotation
{
    return [imageView rotation];
}

- (void)setRotation:(float)rotation
{
    [imageView setRotation:rotation];
}

- (void)setOrigin:(NSPoint) o
{
    [imageView setOrigin:o];
}

- (float)scaleValue
{
    return [imageView scaleValue];
}

- (void)setScaleValue:(float)scaleValue
{
    [imageView setScaleValue:scaleValue];
}

- (void)setYFlipped:(BOOL) v
{
    [imageView setYFlipped:(BOOL) v];
}

- (void)setXFlipped:(BOOL) v
{
    [imageView setXFlipped:(BOOL) v];
}

- (SeriesView *) seriesView
{
    return seriesView;
}

- (void)setImageRows:(int)rows columns:(int)columns
{
    [self setImageRows: rows columns: columns rescale: YES];
}

- (void)setImageRows:(int)rows columns:(int)columns rescale: (BOOL) rescale
{
    if( rows > 8) rows = 8;
    if( columns > 8) columns = 8;
    
    if( rows < 1) rows = 1;
    if( columns < 1) columns = 1;
    
    [seriesView setImageViewMatrixForRows: rows columns: columns rescale: rescale];
    
    [imageView updateTilingViews];
}

- (IBAction)setImageTiling: (id)sender
{
    int columns = 1;
    int rows = 1;
    int tag = 0;
    NSMenuItem *item;
    
    if ([sender class] == [NSMenuItem class])
    {
        NSArray *menuItems = [[sender menu] itemArray];
        for(item in menuItems)
            [item setState:NSControlStateValueOff];
        tag = [(NSMenuItem *)sender tag];
    }
    
    if (tag < 16)
    {
        rows = (tag / 4) + 1;
        columns =  (tag %  4) + 1;
    }
    
    [self setImageRows: rows columns: columns];
}

#ifndef OSIRIX_LIGHT
- (IBAction)calciumScoring:(id)sender
{
    BOOL	found = NO;
    NSArray *winList = [NSApp windows];
    
    for( id loopItem in winList)
    {
        // Not a window whose controller is closing, as -brushTool:.
        if( [[[loopItem windowController] windowNibName] isEqualToString:@"CalciumScoring"] && !([[loopItem windowController] respondsToSelector: @selector(windowWillClose)] && [(id) [loopItem windowController] windowWillClose])) found = YES;
    }
    
    if( !found)
    {
        CalciumScoringWindowController *calciumScoringWindowController = [[CalciumScoringWindowController alloc] initWithViewer:self];
        [calciumScoringWindowController showWindow:self];
    }
}
#endif

//- (IBAction)centerline: (id)sender
//{
//	BOOL	found = NO;
//	NSArray *winList = [NSApp windows];
//	
//	for( id loopItem in winList)
//	{
//		if( [[[loopItem windowController] windowNibName] isEqualToString:@"CenterlineSegmentation"]) found = YES;
//	}
//	
//	if( !found)
//	{
//		EndoscopySegmentationController *endoscopySegmentationController = [[EndoscopySegmentationController alloc] initWithViewer:self];
//		[endoscopySegmentationController showWindow:self];
//	}
//}

#pragma mark-
#pragma mark 12 Bit

-(IBAction)enable12Bit:(id)sender;
{
    BOOL t12Bit = ([[sender selectedCell] tag]==0);
    [imageView setIsLUT12Bit:t12Bit];
    [imageView updateImage];
}

- (void)verify12Bit:(NSTimer*)theTimer
{
    BOOL t12Bit = [imageView isLUT12Bit];
    if(t12Bit) [display12bitToolbarItemMatrix selectCellWithTag:0];
    else [display12bitToolbarItemMatrix selectCellWithTag:1];
}

#pragma mark-
#pragma mark Navigator

- (IBAction)navigator:(id)sender;
{
    if([[[self imageView] curDCM] isRGB])
    {
        HorosRunAlertPanel(NSLocalizedString(@"Data Error", nil), NSLocalizedString(@"This tool currently does not work with RGB data series.", nil), nil, nil, nil);
        return;
    }
    
    if( [NavigatorWindowController navigatorWindowController] == nil)
    {
        BOOL volumicData = [self isDataVolumicIn4D: YES];
        
        if( volumicData == NO)
        {
            HorosRunAlertPanel(NSLocalizedString(@"Data Error", nil), NSLocalizedString(@"This tool works only with 3D data series with identical matrix sizes.", nil), nil, nil, nil);
            return;
        }
        
        NavigatorWindowController *navigatorWindowController = [[NavigatorWindowController alloc] initWithViewer:self];
        [navigatorWindowController showWindow:self];
        [[AppController sharedAppController] tileWindows: nil];
    }
    else [[NavigatorWindowController navigatorWindowController] setViewer:self];
}

- (IBAction)threeDPanel:(id)sender;
{
    if( [ThreeDPositionController threeDPositionController] == nil)
    {
        BOOL volumicData = [self isDataVolumicIn4D: YES];
        
        if( volumicData == NO)
        {
            HorosRunAlertPanel(NSLocalizedString(@"Data Error", nil), NSLocalizedString(@"This tool works only with 3D data series with identical matrix sizes.", nil), nil, nil, nil);
            return;
        }
        
        ThreeDPositionController *threeDPositionController = [[ThreeDPositionController alloc] initWithViewer:self];
        [threeDPositionController showWindow:self];
    }
    else [[ThreeDPositionController threeDPositionController] setViewer:self];
}

- (void)updateNavigator;
{
    [[ThreeDPositionController threeDPositionController] setViewer:self];
    
    [[NavigatorWindowController navigatorWindowController] setViewer:self];
    
    NSRect navigatorFrame = [[[NavigatorWindowController navigatorWindowController] window] frame];
    navigatorFrame.origin.x = [[[self window] screen] visibleFrame].origin.x;
    navigatorFrame.size.width = [[[self window] screen] visibleFrame].size.width;
    [[[NavigatorWindowController navigatorWindowController] window] setFrame:navigatorFrame display:YES];
}

#pragma mark Comparatives GUI

- (IBAction)toggleComparativesVisibility:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:![[NSUserDefaults standardUserDefaults] boolForKey:@"listPODComparativesIn2DViewer"] forKey:@"listPODComparativesIn2DViewer"];
    for (ViewerController* vc in [ViewerController get2DViewers])
        [vc buildMatrixPreview:YES];
}


@end

// What the Swift extensions of #832 read of the file-scope statics of this
// file (declared in ViewerController+SwiftIvars.h).
@implementation ViewerController (SwiftStatics)

+ (BOOL)horos_SYNCSERIES
{
    return SYNCSERIES;
}

+ (int)horos_numberOf2DViewer
{
    return numberOf2DViewer;
}

+ (NSString*)horos_PlayToolbarItemIdentifier
{
    return PlayToolbarItemIdentifier;
}

+ (NSArray *)horos_volumeLengthReadArchive:(NSString *)path
{
    return HorosVolumeLengthReadArchive(path);
}

@end

// What the Swift extensions of #832 cannot write themselves and that needs
// what only this file declares (declared in ViewerController+SwiftIvars.h).
@implementation ViewerController (SwiftBridges)

- (NSOperation*) horos_viewerControllerOperationWithDict:(id) dict
{
    return [[[ViewerControllerOperation alloc] initWithController: self dict: dict] autorelease];
}

- (void)horos_sendWillFreeVolumeDataNotificationForMovieIndex:(NSInteger)movieIndex
{
    [self sendWillFreeVolumeDataNotificationWithVolumeData:volumeData[ movieIndex] movieIndex:movieIndex];
}

- (void)horos_sendDidAllocateVolumeDataNotificationForMovieIndex:(NSInteger)movieIndex
{
    [self sendDidAllocateVolumeDataNotificationWithVolumeData:volumeData[ movieIndex] movieIndex:movieIndex];
}

- (void)horos_clearVolumeLengthState
{
    objc_setAssociatedObject(self, &HorosVolumeLengthStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
