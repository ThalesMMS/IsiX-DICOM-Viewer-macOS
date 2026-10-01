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

// What the Swift extensions of BrowserController (Sources, SourcesCopy,
// Activity, and the blocks of the class moved by #831) read from the class
// that stays Objective-C. A Swift extension
// cannot see instance variables, so the ones the former categories used are
// reached through these accessors, implemented in BrowserController+SwiftIvars.m.
// This header is for the bridging header only: it is not part of the SDK.

#import "BrowserController.h"

@class DicomAlbum, DicomImage, DCMPix, HorosPreviewFrame, ViewerController, WaitRendering, LogWindowController, DCMTKStudyQueryNode, HorosPreviewWindowPolicy, HorosPreviewRedrawCoalescer, MyOutlineView, BrowserMatrix, PreviewView;

@interface BrowserController (SwiftIvars)

/// _sourcesTableView, the Sources list outlet. Nil until the nib is loaded:
/// -setDatabase:, sent by -initWithWindow:, already selects the current source.
@property(readonly, nullable) NSTableView* horos_sourcesTableView;
/// _sourcesHelper, retained by the browser as before (set by -awakeSources,
/// released by -deallocSources).
@property(retain, null_unspecified) id horos_sourcesHelper;
/// _activityTableView, the activity list outlet.
@property(readonly, nullable) NSTableView* horos_activityTableView;
/// _activityHelper, retained by the browser as before (set by -awakeActivity,
/// released by -deallocActivity).
@property(retain, null_unspecified) id horos_activityHelper;


// The instance variables the blocks moved to Swift by #831 read or write. An
// object ivar the Objective-C assigned with a release of the old value and a
// retain of the new one has a retain setter; an outlet is nullable, because
// -initWithWindow: already runs part of the class before the nib is loaded.

/// _albumNoOfStudiesCache.
@property(readonly, nullable) NSMutableArray* horos_albumNoOfStudiesCache;
/// _bottomSplit, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSplitView* horos_bottomSplit;
/// _filterPredicate.
@property(retain, nullable) NSPredicate* horos_filterPredicate;
/// _filterPredicateDescription.
@property(retain, nullable) NSString* horos_filterPredicateDescription;
/// _refreshDeferredWhileEditing.
@property(assign) BOOL horos_refreshDeferredWhileEditing;
/// _searchString.
@property(retain, nullable) NSString* horos_searchString;
/// _splitViewVertDividerRatio.
@property(assign) CGFloat horos_splitViewVertDividerRatio;
/// _timeIntervalOfLastLoadIconsDisplayIcons.
// NS_SWIFT_NONISOLATED (#1004): read by the preview, copy and retrieve threads,
// atomic or under the locks their users take.
@property(assign) NSTimeInterval horos_timeIntervalOfLastLoadIconsDisplayIcons NS_SWIFT_NONISOLATED;
/// albumTable, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTableView* horos_albumTable;
/// animationCheck, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_animationCheck;
/// animationSlider, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSlider* horos_animationSlider;
/// banner, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSButton* horos_banner;
/// bannerSplit, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSplitView* horos_bannerSplit;
/// comparativeRetrieveQueue.
@property(retain, nullable) NSMutableArray* horos_comparativeRetrieveQueue NS_SWIFT_NONISOLATED;
/// comparativeStudies.
@property(readonly, nullable) NSArray* horos_comparativeStudies;
/// comparativeStudyWaited.
@property(retain, nullable) DCMTKStudyQueryNode* horos_comparativeStudyWaited;
/// comparativeStudyWaitedTime.
@property(assign) NSTimeInterval horos_comparativeStudyWaitedTime;
/// comparativeStudyWaitedToOpen.
@property(assign) BOOL horos_comparativeStudyWaitedToOpen;
/// comparativeStudyWaitedToSelect.
@property(assign) BOOL horos_comparativeStudyWaitedToSelect;
/// comparativeStudyWaitedViewer.
@property(retain, nullable) ViewerController* horos_comparativeStudyWaitedViewer;
/// comparativeTable, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTableView* horos_comparativeTable;
/// compressionMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_compressionMatrix;
/// DatabaseIsEdited.
@property(assign) BOOL horos_DatabaseIsEdited;
/// databaseOutline, outlet: nil until the nib is loaded.
@property(readonly, nullable) MyOutlineView* horos_databaseOutline;
/// distantSearchThread.
@property(retain, nullable) NSThread* horos_distantSearchThread;
/// dontSelectStudyFromComparativeStudies.
@property(readonly) BOOL horos_dontSelectStudyFromComparativeStudies;
/// dontUpdatePreviewPane.
@property(readonly) BOOL horos_dontUpdatePreviewPane;
/// folderTree, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSMatrix* horos_folderTree;
/// imageView, outlet: nil until the nib is loaded.
@property(readonly, nullable) PreviewView* horos_imageView;
/// isNetworkLogsActive.
// Atomic; the store and query threads read it through -isNetworkLogsActive.
@property(assign) BOOL horos_isNetworkLogsActive NS_SWIFT_NONISOLATED;
/// KeyImagesCache.
@property(retain, nullable) NSArray* horos_KeyImagesCache;
/// lastKeyImagesSelectedFiles.
@property(retain, nullable) id horos_lastKeyImagesSelectedFiles;
/// lastROIsAndKeyImagesSelectedFiles.
@property(retain, nullable) id horos_lastROIsAndKeyImagesSelectedFiles;
/// lastROIsImagesSelectedFiles.
@property(retain, nullable) id horos_lastROIsImagesSelectedFiles;
/// loadPreviewIndex.
@property(assign) long horos_loadPreviewIndex;
/// logWindowController.
@property(retain, nullable) LogWindowController* horos_logWindowController;
/// matrixViewArray.
@property(readonly, nullable) NSArray* horos_matrixViewArray;
/// modalityFilterView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_modalityFilterView;
/// notFoundImage.
@property(readonly, nullable) NSImage* horos_notFoundImage NS_SWIFT_NONISOLATED;
/// oMatrix, outlet: nil until the nib is loaded.
@property(readonly, nullable) BrowserMatrix* horos_oMatrix;
/// openReparsedSeriesFlag.
@property(assign) BOOL horos_openReparsedSeriesFlag;
/// originalOutlineViewArray.
@property(readonly, nullable) NSArray* horos_originalOutlineViewArray;
/// outlineViewArray.
@property(readonly, nullable) NSArray* horos_outlineViewArray;
/// password, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSTextField* horos_password;
/// previewPix.
@property(retain, nullable) NSMutableArray* horos_previewPix NS_SWIFT_NONISOLATED;
/// previewPixGeneration.
@property(readonly) NSUInteger horos_previewPixGeneration NS_SWIFT_NONISOLATED;
/// previewPixThumbnails.
@property(readonly, nullable) NSMutableArray* horos_previewPixThumbnails NS_SWIFT_NONISOLATED;
/// previewRedrawCoalescer.
@property(readonly, nullable) HorosPreviewRedrawCoalescer* horos_previewRedrawCoalescer;
/// previewWindowPolicy.
@property(readonly, nullable) HorosPreviewWindowPolicy* horos_previewWindowPolicy;
/// previousFlags.
@property(assign) NSUInteger horos_previousFlags;
/// reportFilesToCheck.
@property(readonly, nullable) NSMutableDictionary* horos_reportFilesToCheck;
/// reportTemplatesImageView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSImageView* horos_reportTemplatesImageView;
/// reportTemplatesListPopUpButton, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSPopUpButton* horos_reportTemplatesListPopUpButton;
/// reportTemplatesView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_reportTemplatesView;
/// reportToolbarItemType.
@property(assign) NSInteger horos_reportToolbarItemType;
/// ROIsAndKeyImagesButtonAvailable.
@property(readonly) BOOL horos_ROIsAndKeyImagesButtonAvailable;
/// ROIsAndKeyImagesCache.
@property(retain, nullable) NSArray* horos_ROIsAndKeyImagesCache;
/// ROIsAndKeyImagesCacheSameSeries.
@property(assign) BOOL horos_ROIsAndKeyImagesCacheSameSeries;
/// ROIsImagesCache.
@property(retain, nullable) NSArray* horos_ROIsImagesCache;
/// ROIsImagesCacheSameSeries.
@property(assign) BOOL horos_ROIsImagesCacheSameSeries;
/// searchField, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSearchField* horos_searchField;
/// searchType.
@property(readonly) int horos_searchType;
/// searchView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_searchView;
/// setDCMDone.
@property(assign) BOOL horos_setDCMDone;
/// splitAlbums, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSplitView* horos_splitAlbums;
/// splitComparative, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSplitView* horos_splitComparative;
/// splitDrawer, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSplitView* horos_splitDrawer;
/// splitViewHorz, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSplitView* horos_splitViewHorz;
/// splitViewVert, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSSplitView* horos_splitViewVert;
/// thumbnailsScrollView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSScrollView* horos_thumbnailsScrollView;
/// timeIntervalEnd.
@property(readonly, nullable) NSDate* horos_timeIntervalEnd;
/// timeIntervalStart.
@property(readonly, nullable) NSDate* horos_timeIntervalStart;
/// timeIntervalView, outlet: nil until the nib is loaded.
@property(readonly, nullable) NSView* horos_timeIntervalView;
/// toolbar.
@property(retain, nullable) NSToolbar* horos_toolbar;
/// toolbarSearchItem.
@property(retain, nullable) NSToolbarItem* horos_toolbarSearchItem;
/// waitOpeningWindow.
@property(retain, nullable) WaitRendering* horos_waitOpeningWindow;

@end

// What the Swift of the former categories cannot call itself, kept in
// Objective-C in BrowserController+Sources+CAPI.m.
@interface BrowserController (SourcesCAPI)

/// NSBeginAlertSheet(title, nil, nil, nil, self.window, NSApp, @selector(endSheet:), nil, nil, @"%@", message)
- (void)horos_beginSourcesAlertSheetWithTitle:(NSString* _Null_unspecified)title message:(NSString* _Null_unspecified)message;

/// The @"oneCopyAtATime" literal the local copy thread synchronizes on: the
/// same constant string object as before, which the linker shares with the
/// other literals of that text.
+ (NSObject* _Null_unspecified)horos_oneCopyAtATimeLock NS_SWIFT_NONISOLATED;

@end

// The declarations below restate the class's own. Explicit unspecified
// nullability preserves their existing Swift import and Objective-C nil contract.

// What the Swift extensions of #831 call in the Objective-C of the class:
// methods BrowserController.m implements without declaring them in
// BrowserController.h.
@interface BrowserController (SwiftPrivateMethods)

- (void) checkIfLocalStudyHasMoreOrSameNumberOfImagesOfADistantStudy: (NSArray* _Null_unspecified) studiesToCheck;
- (NSArray* _Null_unspecified) subSearchForComparativeStudies: (id _Null_unspecified) studySelectedID;
- (void) viewerDICOMInt:(BOOL) movieViewer dcmFile:(NSArray * _Null_unspecified)selectedLines viewer:(ViewerController* _Null_unspecified) viewer tileWindows: (BOOL) tileWindows protocol: (NSDictionary* _Null_unspecified) protocol;
- (NSMutableArray* _Null_unspecified)filesForDatabaseOutlineSelection:(NSMutableArray* _Null_unspecified)correspondingManagedObjects treeObjects:(NSMutableSet* _Null_unspecified)treeManagedObjects onlyImages:(BOOL)onlyImages;
- (void) resetROIsAndKeysButton;
- (void)outlineViewSelectionDidChange:(NSNotification * _Null_unspecified)aNotification;
- (id _Null_unspecified)outlineView:(NSOutlineView * _Null_unspecified)outlineView child:(NSInteger)index ofItem:(id _Null_unspecified)item;
- (BOOL)outlineView:(NSOutlineView * _Null_unspecified)outlineView isItemExpandable:(id _Null_unspecified)item;
- (NSInteger)outlineView:(NSOutlineView * _Null_unspecified)outlineView numberOfChildrenOfItem:(id _Null_unspecified)item;
- (id _Null_unspecified)outlineView:(NSOutlineView * _Null_unspecified)outlineView objectValueForTableColumn:(NSTableColumn * _Null_unspecified)tableColumn byItem:(id _Null_unspecified)item;
- (void)outlineView:(NSOutlineView * _Null_unspecified)outlineView setObjectValue:(id _Null_unspecified)object forTableColumn:(NSTableColumn * _Null_unspecified)tableColumn byItem:(id _Null_unspecified)item;
- (void)outlineView:(NSOutlineView * _Null_unspecified)outlineView sortDescriptorsDidChange:(NSArray * _Null_unspecified)oldDescriptors;
- (void)outlineView:(NSOutlineView * _Null_unspecified)outlineView willDisplayCell:(id _Null_unspecified)cell forTableColumn:(NSTableColumn * _Null_unspecified)tableColumn item:(id _Null_unspecified)item;
- (DCMPix* _Null_unspecified) getDCMPixFromViewerIfAvailable: (NSString* _Null_unspecified) pathToFind frameNumber: (int) frameNumber NS_SWIFT_NONISOLATED;
- (DCMPix* _Null_unspecified) getDCMPixFromViewerIfAvailable: (NSString* _Null_unspecified) pathToFind frameNumber: (int) frameNumber expectedFrame: (HorosPreviewFrame* _Null_unspecified) expectedFrame NS_SWIFT_NONISOLATED;
- (void) createROIsFromRTSTRUCT: (id _Null_unspecified)sender;
- (IBAction) mergeSeries:(id _Null_unspecified) sender;
- (void) viewerSubSeriesDICOM: (id _Null_unspecified)sender;
- (void) viewerReparsedSeries: (id _Null_unspecified) sender;
- (void) viewerDICOMROIsImages:(id _Null_unspecified) sender;
- (void) MovieViewerDICOM:(id _Null_unspecified) sender;
- (IBAction) revealInFinder: (id _Null_unspecified)sender;
- (void) exportQuicktime: (id _Null_unspecified)sender;
- (void) exportJPEG: (id _Null_unspecified)sender;
- (void) exportTIFF: (id _Null_unspecified)sender;
- (void) exportROIAndKeyImagesAsDICOMSeries: (id _Null_unspecified) sender;
- (IBAction) addStudiesToUser: (id _Null_unspecified) sender;
- (IBAction) sendEmailNotification:(id _Null_unspecified)sender;
- (IBAction) sendMail:(id _Null_unspecified)sender;
- (void) applyRoutingRule: (id _Null_unspecified) sender;
- (void) searchForSmartAlbumDistantStudies: (NSString* _Null_unspecified) albumName;
- (void) searchForSearchField: (NSDictionary* _Null_unspecified) dict;
- (void) searchForTimeIntervalFromTo: (NSDictionary* _Null_unspecified) dict;
- (void) setDBWindowTitle;
- (NSArray* _Null_unspecified) albumsInDatabase;
- (void) removeAlbumObject:(DicomAlbum* _Null_unspecified)album;

@end

// The file-scope statics of BrowserController.m that the Swift extensions of
// #831 read or write. They stay in BrowserController.m, whose
// BrowserController (SwiftStatics) implements these accessors.
@interface BrowserController (SwiftStatics)

/// contextual, the thumbnails' contextual menu, retained for the life of the
/// application.
@property(class, retain, nullable) NSMenu* horos_contextualMenu;
/// contextualRT, the thumbnails' contextual menu for RT objects.
@property(class, retain, nullable) NSMenu* horos_contextualRTMenu;
/// waitForRunningProcess.
@property(class, readonly) BOOL horos_waitForRunningProcess;
/// dontShowOpenSubSeries.
@property(class, assign) BOOL horos_dontShowOpenSubSeries;
/// withReset.
@property(class, readonly) BOOL horos_withReset;

/// HorosPreviewFrameForImage(image, frame): the identity the preview asks for,
/// built from the database row alone.
+ (nullable HorosPreviewFrame*)horos_previewFrameForImage:(nullable DicomImage*)image frame:(int)frame NS_SWIFT_NONISOLATED;

@end

/// Defined by ViewerController.m: the windows are tiled once the series being
/// opened are loaded. Main thread only.
extern NS_SWIFT_UI_ACTOR int delayedTileWindows;

// What a Swift extension of #831 cannot write itself, kept in Objective-C in
// BrowserController+SwiftIvars.m.
@interface BrowserController (SwiftBridges)

/// [super print:sender], as -printDatabaseSelection: sent it when
/// +[HorosPrintSelection mayPrintOutlineView] allows it: the implementation
/// above BrowserController, which a Swift extension cannot reach.
- (void)horos_superPrint:(id _Null_unspecified)sender;
/// previewPixGeneration++, under the lock the caller already holds (#608).
- (void)horos_incrementPreviewPixGeneration;
/// [[[DCMPix alloc] myinitEmpty] autorelease]: Swift cannot send -myinitEmpty
/// to an allocated, not yet initialized object.
+ (DCMPix* _Null_unspecified)horos_emptyPreviewPix NS_SWIFT_NONISOLATED;
/// [[[NSDateFormatter alloc] initWithDateFormat:format allowNaturalLanguage:flag] autorelease]:
/// the 10.0-style formatter -pdfPreview: names its file with, which Swift
/// marks unavailable.
+ (NSDateFormatter* _Null_unspecified)horos_dateFormatterWithDateFormat:(NSString* _Null_unspecified)format allowNaturalLanguage:(BOOL)flag;

@end
