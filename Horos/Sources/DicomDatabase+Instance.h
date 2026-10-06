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

// The "Instance" methods of DicomDatabase are implemented in Swift
// (DicomDatabase+Instance.swift): a Swift extension of the class, which stays
// Objective-C, with the same selectors. DicomDatabase.h imports this header, so
// that whoever imports it, plugins included, still sees them: the generated
// interface declares them.

#import "DicomDatabase.h"

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extension itself.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift, the Decompress helper: DCMPix.m imports
// DicomDatabase.h. The former declarations, without their implementation.
@interface DicomDatabase (Instance)

-(BOOL)isLocal;

-(DataNodeIdentifier*)dataNodeIdentifier;

#pragma mark Entities
-(NSEntityDescription*)imageEntity;
-(NSEntityDescription*)seriesEntity;
-(NSEntityDescription*)studyEntity;
-(NSEntityDescription*)albumEntity;
-(NSEntityDescription*)logEntryEntity;

#pragma mark Paths
// these paths are inside baseDirPath
-(NSString*)modelVersionFilePath; // this should become private
-(NSString*)loadingFilePath; // this should become private
// these paths are inside dataBaseDirPath
-(NSString*)dataDirPath;
-(NSString*)incomingDirPath;
-(NSString*)errorsDirPath;
-(NSString*)decompressionDirPath;
-(NSString*)toBeIndexedDirPath;
-(NSString*)reportsDirPath;
-(NSString*)tempDirPath;
-(NSString*)dumpDirPath;
-(NSString*)pagesDirPath;
-(NSString*)htmlTemplatesDirPath;
- (NSString *)statesDirPath;
- (NSString *)clutsDirPath;
- (NSString *)presetsDirPath;

-(NSUInteger)computeDataFileIndex; // this method should be private, but is declared because called from deprecated api
-(NSString*)uniquePathForNewDataFileWithExtension:(NSString*)ext;

@end
#endif
