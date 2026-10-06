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

// The "database drag export" methods of BrowserController are
// implemented in Swift (BrowserController+DatabaseDragExport.swift
// and BrowserController+DatabaseDragExport+Selection.swift): a Swift extension
// of the class, which stays Objective-C, with the same selectors.
// BrowserController.h imports this header, so that whoever imports it, plugins
// included, still sees them: the generated interface declares them.

#import "BrowserController.h"
@class DicomImage, DicomSeries, DicomStudy, ViewerController;

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extension itself.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift, the Decompress helper: DCMPix.m and
// NSUserDefaults+OsiriX.mm import BrowserController.h. The former
// declarations, without their implementation.
@interface BrowserController (DatabaseDragExport)

+ (BOOL) isReportSeriesForFileExport:(DicomSeries*) series;
+ (NSArray*) databaseObjectXIDsOnPasteboard:(NSPasteboard*) pasteboard;
- (id<NSPasteboardWriting>) filePromiseForDatabaseObjects:(NSArray*) items;
- (id<NSPasteboardWriting>) filePromiseForDatabaseObjects:(NSArray*) items asJPEG:(BOOL) jpeg;
- (id<NSPasteboardWriting>) filePromiseForJPEGData:(NSData*) data name:(NSString*) name;
- (void) writeDatabaseFilePromise:(NSMutableDictionary*) parameters;
- (BOOL)isUsingExternalViewer: (NSManagedObject*) item;
- (void) databaseOpenStudy:(DicomStudy*) currentStudy withProtocol:(NSDictionary*) currentHangingProtocol;
- (void) displayWaitWindowIfNecessary;
- (void) closeWaitWindowIfNecessary;
- (void) databaseOpenStudy: (NSManagedObject*) item;
- (void)printDatabaseSelection:(id)sender;
- (void)printDatabaseSpool:(id)spool;
- (IBAction) databaseDoublePressed:(id)sender;
- (BOOL) findAndSelectFile: (NSString*) path image: (DicomImage*) curImage shouldExpand: (BOOL) expand;
- (BOOL) findAndSelectFile: (NSString*) path image: (DicomImage*) curImage shouldExpand: (BOOL) expand extendingSelection: (BOOL) extendingSelection;
- (BOOL) displayStudy: (DicomStudy*) study object:(NSManagedObject*) element command:(NSString*) execute;
- (int) findObject:(NSString*) request table:(NSString*) table execute: (NSString*) execute elements:(NSString**) elements __deprecated;
- (void) loadNextPatient:(NSManagedObject *) curImage :(long) direction :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
- (void) loadNextSeries:(NSManagedObject *) curImage :(long) direction :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
- (ViewerController*) loadSeries :(NSManagedObject *)curFile :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
- (IBAction) pasteImageForSourceFile: (NSString*) sourceFile;
- (IBAction) paste: (id)sender;
- (void) buildMetadataExportMenuItem;
- (IBAction) exportStudiesByIdentifierList: (id) sender;
- (NSString*) exportStudiesForIdentifiers: (NSArray*) identifiers toDirectory: (NSString*) directory dryRun: (BOOL) dryRun;
- (IBAction) exportStudyMetadataAsCSV: (id) sender;
- (NSString*) metadataCSVForColumns: (NSArray*) columns onlySelected: (BOOL) onlySelected;
- (IBAction) saveDBListAs:(id) sender;

@end
#endif
