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

// What the DicomStudy (Report) category (Swift since #717) keeps in
// Objective-C: the ODT conversion logs its failure with N2LogStackTrace, a C
// variadic function Swift cannot call.

#import "DicomStudy+Report.h"
#import "NSString+N2.h"
#import "N2Debug.h"

@implementation DicomStudy (Report)

+(void)_transformOdtAtPath:(NSString*)odtPath toPdfAtPath:pdfPath
{
    // Search for preferred ODT application on Applications paths (may not be default application associated with ODT file type).
    //
    NSString* preferredOdtAppl = @"LibreOffice.app";
    NSString* applicationPath = @"__NOT_FOUND__";
    BOOL isDirectory;
    NSFileManager *fm = [NSFileManager defaultManager];
    if(![applicationPath contains: preferredOdtAppl])
    {
        NSArray *applDirs = NSSearchPathForDirectoriesInDomains(NSAllApplicationsDirectory, NSAllDomainsMask, YES);
        for (NSString* applDir in applDirs)
        {
            NSString* applPathToCheck = [applDir stringByAppendingPathComponent: preferredOdtAppl];
            if ([fm fileExistsAtPath: applPathToCheck isDirectory: &isDirectory] && isDirectory)
            {
                // Found it.
                //
                applicationPath = [NSString stringWithString: applPathToCheck];
                break;
            }
        }
    }
    
    // One final check of path for preferred application with belt and
    // suspenders check for required executable required.
    //
    NSLog(@"odt2pdf: using %@ found at [%@]", preferredOdtAppl, applicationPath);
    NSString* sofficePath = [applicationPath stringByAppendingPathComponent:@"Contents/MacOS/soffice"];
    if( [applicationPath contains: preferredOdtAppl] &&
        [fm fileExistsAtPath: sofficePath isDirectory: &isDirectory] && !isDirectory)
    {
        @try {
            // Command structure (will render PDF to file in same directory as ODT):
            //   <applicationPath>/Contents/MacOS/soffice --headless --convert-to pdf <odt_path>
            //
            NSTask* task = [[[NSTask alloc] init] autorelease];
            [task setLaunchPath: [applicationPath stringByAppendingPathComponent:@"Contents/MacOS/soffice"]];
            [task setCurrentDirectoryPath: [odtPath stringByDeletingLastPathComponent]];
            [task setArguments: [NSArray arrayWithObjects: @"--headless", @"--convert-to", @"pdf", odtPath, nil]];
            [task setStandardOutput:[NSPipe pipe]];
            [task launch];
            while( [task isRunning])
                [NSThread sleepForTimeInterval: 0.1];
            
            BOOL succeeded = NO;
            
            if ([task terminationStatus] == 0)
                succeeded = YES;
            
            if( succeeded) {
                [[NSFileManager defaultManager] moveItemAtPath: [[odtPath stringByDeletingPathExtension] stringByAppendingPathExtension: @"pdf"] toPath: pdfPath error: nil];
            }
            else
                N2LogStackTrace( @"ODT to PDF conversion failed");
            
        } @catch (NSException* e) {
            N2LogException( e);
        }
    }
    else
    {
        // The caller tells the user, on its own thread's terms: this may run for the web portal or a
        // background validation, where a modal panel does not belong (#649).
        [NSException raise:NSGenericException format:@"%@", NSLocalizedString(@"LibreOffice is required to convert '.odt' reports to PDF. Please install the latest version of LibreOffice.", nil)];
    }
}

@end
