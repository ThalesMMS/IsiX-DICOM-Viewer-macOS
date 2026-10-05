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


#import <Cocoa/Cocoa.h>

#include "options.h"

extern int HorosRunNonInteractiveKeychainHelper(void);

// Looked up by name: the generated Swift header pulls in the whole application
// and this file needs one class method of it.
static void HorosImportPreviousPreferences(void)
{
    Class continuity = NSClassFromString(@"HorosPreferencesContinuity");
    SEL import = NSSelectorFromString(@"importPreviousPreferences");
    if ([continuity respondsToSelector:import])
        ((void (*)(id, SEL))[continuity methodForSelector:import])(continuity, import);
}

// Shift and Option held now, or -ProtectedMode YES: protected mode is on before
// the first plugin, nib or listener is loaded.
static void HorosActivateProtectedModeIfRequested(void)
{
    Class protectedMode = NSClassFromString(@"HorosProtectedMode");
    SEL activate = NSSelectorFromString(@"activateIfRequested");
    if ([protectedMode respondsToSelector:activate])
        ((void (*)(id, SEL))[protectedMode methodForSelector:activate])(protectedMode, activate);
}

#ifndef OSIRIX_LIGHT
#include "FVTiff.h"
#endif

int main(int argc, const char *argv[])
{	
    if (HorosRunNonInteractiveKeychainHelper()) return 0;
    // Before anything reads a preference: an installation made under the
    // previous identifier keeps its settings and its database location.
    @autoreleasepool { HorosImportPreviousPreferences(); }
    @autoreleasepool { HorosActivateProtectedModeIfRequested(); }
	#ifndef OSIRIX_LIGHT
    FVTIFFInitialize();
	#endif
	
    return NSApplicationMain(argc, argv);
}
