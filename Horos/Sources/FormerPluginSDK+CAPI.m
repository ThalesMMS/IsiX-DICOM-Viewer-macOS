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

// Constants of the Horos and OsiriX plugin SDK whose classes are Swift now. A
// plugin built for that SDK is not rebuilt: it looks these names up in the
// application's flat namespace when it loads or when it first uses them, and a
// Swift constant has no C symbol to be found. Each has the type and the value
// the SDK gave it, is marked used so that the linker keeps it although nothing
// here reads it, and is declared by the header of its class, which this file
// imports so that the compiler compares the two.

#import "NSError+OsiriX.h"
#import "OSIROIManager.h"
#import "CPRCurvedPath.h"
#import "WebPortalDatabase.h"
#import "WebPortalSession.h"

#import <objc/runtime.h>

#define FORMER_SDK __attribute__((used))

FORMER_SDK NSString * const OsirixErrorDomain = @"OsiriXDomain";

FORMER_SDK NSString * const OSIROIManagerROIsDidUpdateNotification = @"OSIROIManagerROIsDidUpdateNotification";
FORMER_SDK NSString * const OSIROIUpdatedROIKey = @"OSIROIUpdatedROIKey";
FORMER_SDK NSString * const OSIROIRemovedROIKey = @"OSIROIRemovedROIKey";
FORMER_SDK NSString * const OSIROIAddedROIKey = @"OSIROIAddedROIKey";

FORMER_SDK const int32_t CPRCurvedPathControlTokenNone = -1;

FORMER_SDK NSString * const WebPortalDatabaseUserEntityName = @"User";
FORMER_SDK NSString * const WebPortalDatabaseStudyEntityName = @"Study";

FORMER_SDK NSString * const SessionCookieName = @"OSID";
FORMER_SDK NSString * const SessionUserIDKey = @"UserID";
FORMER_SDK NSString * const SessionUsernameKey = @"Username";
FORMER_SDK NSString * const SessionTokensDictKey = @"Tokens";
FORMER_SDK NSString * const SessionChallengeKey = @"Challenge";
FORMER_SDK NSString * const SessionLastActivityDateKey = @"LastActivityDate";

#pragma mark - Kakadu

// Horos declared these four in kdu_OsiriXSupport.h for a Kakadu JPEG 2000 codec, which the
// application never had: it decodes and encodes JPEG 2000 with OpenJPEG. A
// plugin built for that SDK of Horos finds the names and is told the codec is not
// available; one that calls a codec function anyway gets no buffer and a size
// of zero. Their header is not in the application: declared here.
int kdu_available(void);
void *kdu_decompressJPEG2K(void *jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel, int num_threads);
void *kdu_decompressJPEG2KWithBuffer(void *inputBuffer, void *jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel, int num_threads);
void *kdu_compressJPEG2K(void *data, int samplesPerPixel, int rows, int columns, int precision, bool sign, int rate, long *compressedDataSize, int num_threads);

FORMER_SDK int kdu_available(void) { return 0; }

FORMER_SDK void *kdu_decompressJPEG2K(void *jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel, int num_threads)
{
    if (decompressedBufferSize) *decompressedBufferSize = 0;
    return NULL;
}

FORMER_SDK void *kdu_decompressJPEG2KWithBuffer(void *inputBuffer, void *jp2Data, long jp2DataSize, long *decompressedBufferSize, int *colorModel, int num_threads)
{
    if (decompressedBufferSize) *decompressedBufferSize = 0;
    return NULL;
}

FORMER_SDK void *kdu_compressJPEG2K(void *data, int samplesPerPixel, int rows, int columns, int precision, bool sign, int rate, long *compressedDataSize, int num_threads)
{
    if (compressedDataSize) *compressedDataSize = 0;
    return NULL;
}

#pragma mark - Functions of classes that are Swift now

// Two C functions the SDK declared with classes that are Swift now, each
// defined here as the SDK's source defined it. This file is also compiled and
// linked alone, where the values of its constants are checked, so neither
// names a symbol of the application: the first finds its class by name when
// it is called, and the second holds its comparison.

// PFMoveApplication.h of the SDK. The offer to move a copy that does not run
// from an Applications folder is HorosApplicationInstaller's, which decides
// by itself whether there is anything to offer (not in a build for the App
// Store, not when the user asked not to be asked again, not for a copy that
// is already there). It shows alerts, so a call from another thread is handed
// to the main run loop and returns before the offer is made.
void PFMoveToApplicationsFolderIfNecessary(void);

@protocol FormerSDKApplicationInstaller
+ (void)moveToApplicationsFolderIfNecessary;
@end

FORMER_SDK void PFMoveToApplicationsFolderIfNecessary(void)
{
    Class<FormerSDKApplicationInstaller> installer = (Class<FormerSDKApplicationInstaller>)objc_getClass("HorosApplicationInstaller");
    if ([NSThread isMainThread]) {
        [installer moveToApplicationsFolderIfNecessary];
        return;
    }
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        [installer moveToApplicationsFolderIfNecessary];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

// PluginManagerController.h of the SDK: the order of the plugin catalogue's
// entries, by their "name" without regard to case, for
// -sortedArrayUsingFunction:context:. It is the order sortPluginArray gives
// the list of the installed plugins.
NSInteger sortPluginArrayByName(id plugin1, id plugin2, void *context);

FORMER_SDK NSInteger sortPluginArrayByName(id plugin1, id plugin2, void *context)
{
    NSString *name1 = [plugin1 objectForKey:@"name"];
    NSString *name2 = [plugin2 objectForKey:@"name"];

    return [name1 compare:name2 options:NSCaseInsensitiveSearch];
}
