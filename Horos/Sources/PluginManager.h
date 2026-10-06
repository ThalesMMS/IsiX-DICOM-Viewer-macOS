/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/

// PluginManager is implemented in Swift (Horos/Sources/PluginManager.swift).
// This header keeps <Horos/PluginManager.h>: it brings in the generated interface,
// which declares the same class name and selectors, and PluginFilter.h, which it
// imported before.

#import <Cocoa/Cocoa.h>
#import "PluginFilter.h"

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the class itself: headers it imports may only name it.
@class PluginManager;

// What PluginManager+CAPI.m keeps in Objective-C, declared for the Swift class
// only: the exported gPluginsAlertAlreadyDisplayed and sortPluginArray, and the
// plugin helpers that the HorosPlugin*.h headers define as static functions,
// which Swift cannot compile. They have C names, also for an Objective-C++ file
// that reads this branch after importing Horos-Swift.h.
#ifdef __cplusplus
extern "C" {
#endif
// Read and set around the alerts of the plugin installation, on the main thread.
extern NS_SWIFT_UI_ACTOR BOOL gPluginsAlertAlreadyDisplayed;
NSInteger sortPluginArray(id _Nonnull plugin1, id _Nonnull plugin2, void * _Nullable context);
void PluginManagerCAPIRecordLoad(NSString * _Nullable path, NSString * _Nullable state, NSString * _Nullable reason);
NSDictionary * _Nonnull PluginManagerCAPILoadOutcome(NSString * _Nullable path, BOOL active);
BOOL PluginManagerCAPISignatureAllowsLoading(NSString * _Nullable path, NSError * _Nullable * _Nullable error);
BOOL PluginManagerCAPIInstallPlugin(NSString * _Nullable source, NSString * _Nullable destination, NSError * _Nullable * _Nullable error);
NSArray * _Nullable PluginManagerCAPILoadCatalog(NSURL * _Nullable url, NSTimeInterval timeout, NSError * _Nullable * _Nullable error);
NSString * _Nullable PluginManagerCAPIDownloadName(id _Nullable plugin);
BOOL PluginManagerCAPIVersionIsValid(id _Nullable version);
NSComparisonResult PluginManagerCAPICompareVersions(id _Nullable left, id _Nullable right);
BOOL PluginManagerCAPILoadBundle(NSBundle * _Nullable bundle, NSError * _Nullable * _Nullable error);
BOOL PluginManagerCAPIPreflightBundle(NSBundle * _Nullable bundle, NSError * _Nullable * _Nullable error);
#ifdef __cplusplus
}
#endif
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift, the Decompress helper: DCMPix.m, DicomFile.mm and
// DefaultsOsiriX.m import this header there, as they did before, without the
// implementation. Decompress does not define OSIRIX_VIEWER, so the members the
// former header declared under it are not repeated here.
/** \brief Mangages PluginFilter loading */
@interface PluginManager : NSObject

@property(retain,readwrite) NSMutableArray *downloadQueue;

+ (int) compareVersion: (NSString *) v1 withVersion: (NSString *) v2;
+ (NSMutableDictionary*) plugins;
+ (NSMutableDictionary*) pluginsDict;
+ (NSMutableDictionary*) fileFormatPlugins;
+ (NSMutableDictionary*) reportPlugins;
+ (NSArray*) preProcessPlugins;
+ (NSMenu*) fusionPluginsMenu;
+ (NSArray*) fusionPlugins;

+ (void) startProtectForCrashWithFilter: (id) filter;
+ (void) startProtectForCrashWithPath: (NSString*) path;
+ (void) endProtectForCrash;

@end
#endif
