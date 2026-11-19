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


#import <Cocoa/Cocoa.h>

// The former SDK declared enum Compression (CompressionDont, CompressionCompress,
// CompressionDecompress) in this header. Those names are the cases of the
// Compression enum of the disc burning options now, with the same values.

/** \brief Compresses and decompresses lists of DICOM files

The class of the Horos and OsiriX plugin SDK that converts a list of files: a
plugin built for either looks it up by name and sends it these six messages.
Each returns when every file was tried. The files are converted 200 at a time,
through the Decompress service the database's own conversions use, with the
application's Compression preferences, each replaced by the option of the same
name when options are given: CompressionSettings, CompressionSettingsLowRes,
CompressionResolutionLimit, UseJPEGColorSpace and DecompressMoveIfFail (when
compressing, a file that cannot be read is moved to the destination as it is).
JPEGinsteadJPEG2000 is accepted and changes nothing here, as it changed
nothing in the helper the SDK started: a caller that wants JPEG gives the
CompressionSettings that choose it.

A nil directory and @"sameAsDestination" both convert each file where it is.
An options path is that of a property list holding such a dictionary; a path
with no file gives no options.

Between two batches of 200 the calling thread's -isCancelled is read, and a
cancelled thread starts no other batch. Call from a thread that is not the
main one, as the SDK's callers did: the messages wait for the conversion,
show nothing and never wait for the main thread.

A batch that takes longer than 20 s for each of its files (and than 10 min)
is ended, and its remaining files are left as they are. The SDK waited for
its helper without limit.

DicomCompressor.swift implements the class (@objc @implementation).
*/
@interface DicomCompressor : NSObject

+(void)decompressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath;
+(void)decompressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptions:(NSDictionary*)options;
+(void)decompressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptionsPath:(NSString*)optionsPlistPath;

+(void)compressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath;
+(void)compressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptions:(NSDictionary*)options;
+(void)compressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptionsPath:(NSString*)optionsPlistPath;

@end
