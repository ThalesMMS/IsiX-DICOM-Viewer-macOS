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

#import "BrowserController+SwiftIvars.h"
#import "DCMPix.h"
#import "DCMCalendarDate.h"

// Reuse the production calendar-format adapter for this released bridge.
@interface DCMCalendarDate (BrowserFormatter)
- (NSDateFormatter *)formatterForCalendarFormat:(NSString *)format;
@end

@implementation BrowserController (SwiftIvars)

-(NSTableView*)horos_sourcesTableView
{
    return _sourcesTableView;
}

-(id)horos_sourcesHelper
{
    return _sourcesHelper;
}

-(void)setHoros_sourcesHelper:(id)helper
{
    [helper retain];
    [_sourcesHelper release];
    _sourcesHelper = helper;
}

-(NSTableView*)horos_activityTableView
{
    return _activityTableView;
}

-(id)horos_activityHelper
{
    return _activityHelper;
}

-(void)setHoros_activityHelper:(id)helper
{
    [helper retain];
    [_activityHelper release];
    _activityHelper = helper;
}


-(NSMutableArray*)horos_albumNoOfStudiesCache
{
    return _albumNoOfStudiesCache;
}

-(NSSplitView*)horos_bottomSplit
{
    return _bottomSplit;
}

-(NSPredicate*)horos_filterPredicate
{
    return _filterPredicate;
}

-(void)setHoros_filterPredicate:(NSPredicate*)value
{
    [value retain];
    [_filterPredicate release];
    _filterPredicate = value;
}

-(NSString*)horos_filterPredicateDescription
{
    return _filterPredicateDescription;
}

-(void)setHoros_filterPredicateDescription:(NSString*)value
{
    [value retain];
    [_filterPredicateDescription release];
    _filterPredicateDescription = value;
}

-(BOOL)horos_refreshDeferredWhileEditing
{
    return _refreshDeferredWhileEditing;
}

-(void)setHoros_refreshDeferredWhileEditing:(BOOL)value
{
    _refreshDeferredWhileEditing = value;
}

-(NSString*)horos_searchString
{
    return _searchString;
}

-(void)setHoros_searchString:(NSString*)value
{
    [value retain];
    [_searchString release];
    _searchString = value;
}

-(CGFloat)horos_splitViewVertDividerRatio
{
    return _splitViewVertDividerRatio;
}

-(void)setHoros_splitViewVertDividerRatio:(CGFloat)value
{
    _splitViewVertDividerRatio = value;
}

-(NSTimeInterval)horos_timeIntervalOfLastLoadIconsDisplayIcons
{
    return _timeIntervalOfLastLoadIconsDisplayIcons;
}

-(void)setHoros_timeIntervalOfLastLoadIconsDisplayIcons:(NSTimeInterval)value
{
    _timeIntervalOfLastLoadIconsDisplayIcons = value;
}

-(NSTableView*)horos_albumTable
{
    return albumTable;
}

-(NSButton*)horos_animationCheck
{
    return animationCheck;
}

-(NSSlider*)horos_animationSlider
{
    return animationSlider;
}

-(NSButton*)horos_banner
{
    return banner;
}

-(NSSplitView*)horos_bannerSplit
{
    return bannerSplit;
}

-(NSMutableArray*)horos_comparativeRetrieveQueue
{
    return comparativeRetrieveQueue;
}

-(void)setHoros_comparativeRetrieveQueue:(NSMutableArray*)value
{
    [value retain];
    [comparativeRetrieveQueue release];
    comparativeRetrieveQueue = value;
}

-(NSArray*)horos_comparativeStudies
{
    return comparativeStudies;
}

-(DCMTKStudyQueryNode*)horos_comparativeStudyWaited
{
    return comparativeStudyWaited;
}

-(void)setHoros_comparativeStudyWaited:(DCMTKStudyQueryNode*)value
{
    [value retain];
    [comparativeStudyWaited release];
    comparativeStudyWaited = value;
}

-(NSTimeInterval)horos_comparativeStudyWaitedTime
{
    return comparativeStudyWaitedTime;
}

-(void)setHoros_comparativeStudyWaitedTime:(NSTimeInterval)value
{
    comparativeStudyWaitedTime = value;
}

-(BOOL)horos_comparativeStudyWaitedToOpen
{
    return comparativeStudyWaitedToOpen;
}

-(void)setHoros_comparativeStudyWaitedToOpen:(BOOL)value
{
    comparativeStudyWaitedToOpen = value;
}

-(BOOL)horos_comparativeStudyWaitedToSelect
{
    return comparativeStudyWaitedToSelect;
}

-(void)setHoros_comparativeStudyWaitedToSelect:(BOOL)value
{
    comparativeStudyWaitedToSelect = value;
}

-(ViewerController*)horos_comparativeStudyWaitedViewer
{
    return comparativeStudyWaitedViewer;
}

-(void)setHoros_comparativeStudyWaitedViewer:(ViewerController*)value
{
    [value retain];
    [comparativeStudyWaitedViewer release];
    comparativeStudyWaitedViewer = value;
}

-(NSTableView*)horos_comparativeTable
{
    return comparativeTable;
}

-(NSMatrix*)horos_compressionMatrix
{
    return compressionMatrix;
}

-(BOOL)horos_DatabaseIsEdited
{
    return DatabaseIsEdited;
}

-(void)setHoros_DatabaseIsEdited:(BOOL)value
{
    DatabaseIsEdited = value;
}

-(MyOutlineView*)horos_databaseOutline
{
    return databaseOutline;
}

-(NSThread*)horos_distantSearchThread
{
    return distantSearchThread;
}

-(void)setHoros_distantSearchThread:(NSThread*)value
{
    [value retain];
    [distantSearchThread release];
    distantSearchThread = value;
}

-(BOOL)horos_dontSelectStudyFromComparativeStudies
{
    return dontSelectStudyFromComparativeStudies;
}

-(BOOL)horos_dontUpdatePreviewPane
{
    return dontUpdatePreviewPane;
}

-(NSMatrix*)horos_folderTree
{
    return folderTree;
}

-(PreviewView*)horos_imageView
{
    return imageView;
}

-(BOOL)horos_isNetworkLogsActive
{
    return isNetworkLogsActive;
}

-(void)setHoros_isNetworkLogsActive:(BOOL)value
{
    isNetworkLogsActive = value;
}

-(NSArray*)horos_KeyImagesCache
{
    return KeyImagesCache;
}

-(void)setHoros_KeyImagesCache:(NSArray*)value
{
    [value retain];
    [KeyImagesCache release];
    KeyImagesCache = value;
}

-(id)horos_lastKeyImagesSelectedFiles
{
    return lastKeyImagesSelectedFiles;
}

-(void)setHoros_lastKeyImagesSelectedFiles:(id)value
{
    [value retain];
    [lastKeyImagesSelectedFiles release];
    lastKeyImagesSelectedFiles = value;
}

-(id)horos_lastROIsAndKeyImagesSelectedFiles
{
    return lastROIsAndKeyImagesSelectedFiles;
}

-(void)setHoros_lastROIsAndKeyImagesSelectedFiles:(id)value
{
    [value retain];
    [lastROIsAndKeyImagesSelectedFiles release];
    lastROIsAndKeyImagesSelectedFiles = value;
}

-(id)horos_lastROIsImagesSelectedFiles
{
    return lastROIsImagesSelectedFiles;
}

-(void)setHoros_lastROIsImagesSelectedFiles:(id)value
{
    [value retain];
    [lastROIsImagesSelectedFiles release];
    lastROIsImagesSelectedFiles = value;
}

-(long)horos_loadPreviewIndex
{
    return loadPreviewIndex;
}

-(void)setHoros_loadPreviewIndex:(long)value
{
    loadPreviewIndex = value;
}

-(LogWindowController*)horos_logWindowController
{
    return logWindowController;
}

-(void)setHoros_logWindowController:(LogWindowController*)value
{
    [value retain];
    [logWindowController release];
    logWindowController = value;
}

-(NSArray*)horos_matrixViewArray
{
    return matrixViewArray;
}

-(NSView*)horos_modalityFilterView
{
    return modalityFilterView;
}

-(NSImage*)horos_notFoundImage
{
    return notFoundImage;
}

-(BrowserMatrix*)horos_oMatrix
{
    return oMatrix;
}

-(BOOL)horos_openReparsedSeriesFlag
{
    return openReparsedSeriesFlag;
}

-(void)setHoros_openReparsedSeriesFlag:(BOOL)value
{
    openReparsedSeriesFlag = value;
}

-(NSArray*)horos_originalOutlineViewArray
{
    return originalOutlineViewArray;
}

-(NSArray*)horos_outlineViewArray
{
    return outlineViewArray;
}

-(NSTextField*)horos_password
{
    return password;
}

-(NSMutableArray*)horos_previewPix
{
    return previewPix;
}

-(void)setHoros_previewPix:(NSMutableArray*)value
{
    [value retain];
    [previewPix release];
    previewPix = value;
}

-(NSUInteger)horos_previewPixGeneration
{
    return previewPixGeneration;
}

-(NSMutableArray*)horos_previewPixThumbnails
{
    return previewPixThumbnails;
}

-(HorosPreviewRedrawCoalescer*)horos_previewRedrawCoalescer
{
    return previewRedrawCoalescer;
}

-(HorosPreviewWindowPolicy*)horos_previewWindowPolicy
{
    return previewWindowPolicy;
}

-(NSUInteger)horos_previousFlags
{
    return previousFlags;
}

-(void)setHoros_previousFlags:(NSUInteger)value
{
    previousFlags = value;
}

-(NSMutableDictionary*)horos_reportFilesToCheck
{
    return reportFilesToCheck;
}

-(NSImageView*)horos_reportTemplatesImageView
{
    return reportTemplatesImageView;
}

-(NSPopUpButton*)horos_reportTemplatesListPopUpButton
{
    return reportTemplatesListPopUpButton;
}

-(NSView*)horos_reportTemplatesView
{
    return reportTemplatesView;
}

-(NSInteger)horos_reportToolbarItemType
{
    return reportToolbarItemType;
}

-(void)setHoros_reportToolbarItemType:(NSInteger)value
{
    reportToolbarItemType = value;
}

-(BOOL)horos_ROIsAndKeyImagesButtonAvailable
{
    return ROIsAndKeyImagesButtonAvailable;
}

-(NSArray*)horos_ROIsAndKeyImagesCache
{
    return ROIsAndKeyImagesCache;
}

-(void)setHoros_ROIsAndKeyImagesCache:(NSArray*)value
{
    [value retain];
    [ROIsAndKeyImagesCache release];
    ROIsAndKeyImagesCache = value;
}

-(BOOL)horos_ROIsAndKeyImagesCacheSameSeries
{
    return ROIsAndKeyImagesCacheSameSeries;
}

-(void)setHoros_ROIsAndKeyImagesCacheSameSeries:(BOOL)value
{
    ROIsAndKeyImagesCacheSameSeries = value;
}

-(NSArray*)horos_ROIsImagesCache
{
    return ROIsImagesCache;
}

-(void)setHoros_ROIsImagesCache:(NSArray*)value
{
    [value retain];
    [ROIsImagesCache release];
    ROIsImagesCache = value;
}

-(BOOL)horos_ROIsImagesCacheSameSeries
{
    return ROIsImagesCacheSameSeries;
}

-(void)setHoros_ROIsImagesCacheSameSeries:(BOOL)value
{
    ROIsImagesCacheSameSeries = value;
}

-(NSSearchField*)horos_searchField
{
    return searchField;
}

-(int)horos_searchType
{
    return searchType;
}

-(NSView*)horos_searchView
{
    return searchView;
}

-(BOOL)horos_setDCMDone
{
    return setDCMDone;
}

-(void)setHoros_setDCMDone:(BOOL)value
{
    setDCMDone = value;
}

-(NSSplitView*)horos_splitAlbums
{
    return splitAlbums;
}

-(NSSplitView*)horos_splitComparative
{
    return splitComparative;
}

-(NSSplitView*)horos_splitDrawer
{
    return splitDrawer;
}

-(NSSplitView*)horos_splitViewHorz
{
    return splitViewHorz;
}

-(NSSplitView*)horos_splitViewVert
{
    return splitViewVert;
}

-(NSScrollView*)horos_thumbnailsScrollView
{
    return thumbnailsScrollView;
}

-(NSDate*)horos_timeIntervalEnd
{
    return timeIntervalEnd;
}

-(NSDate*)horos_timeIntervalStart
{
    return timeIntervalStart;
}

-(NSView*)horos_timeIntervalView
{
    return timeIntervalView;
}

-(NSToolbar*)horos_toolbar
{
    return toolbar;
}

-(void)setHoros_toolbar:(NSToolbar*)value
{
    [value retain];
    [toolbar release];
    toolbar = value;
}

-(NSToolbarItem*)horos_toolbarSearchItem
{
    return toolbarSearchItem;
}

-(void)setHoros_toolbarSearchItem:(NSToolbarItem*)value
{
    [value retain];
    [toolbarSearchItem release];
    toolbarSearchItem = value;
}

-(WaitRendering*)horos_waitOpeningWindow
{
    return waitOpeningWindow;
}

-(void)setHoros_waitOpeningWindow:(WaitRendering*)value
{
    [value retain];
    [waitOpeningWindow release];
    waitOpeningWindow = value;
}

@end

@implementation BrowserController (SwiftBridges)

- (void)horos_superPrint:(id)sender
{
    // NSWindowController has no print: action; the database outline owns it.
    [databaseOutline print:sender];
}

- (void)horos_incrementPreviewPixGeneration
{
    previewPixGeneration++;
}

+ (DCMPix*)horos_emptyPreviewPix
{
    return [[[DCMPix alloc] myinitEmpty] autorelease];
}

+ (NSDateFormatter*)horos_dateFormatterWithDateFormat:(NSString*)format allowNaturalLanguage:(BOOL)flag
{
    // The preview caller supplies a fixed calendar format, with no natural language.
    (void)flag;
    return [[DCMCalendarDate date] formatterForCalendarFormat:format];
}

@end
