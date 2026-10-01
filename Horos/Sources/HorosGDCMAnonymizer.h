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

// C++ boundary for selected-field anonymization through DCMTK. The class name
// and selector remain stable for Swift and SDK callers.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called for each problem found in a file, in the order the former code
/// recorded them. `tag` is "(GGGG,EEEE)" when a field was not replaced, and
/// nil otherwise. Every call means the batch is not a success.
typedef void (^HorosGDCMAnonymizerFailure)(NSString *reason, NSString * _Nullable tag);

@interface HorosGDCMAnonymizer : NSObject

/// Reads the staged copy at `path` with DCMTK and replaces the `tags`
/// (arrays of a DCMAttributeTag and, optionally, a value whose -description is
/// written in the file's character set; no value writes an empty one).
/// Code-extension text is limited to verified ASCII; other replacements that
/// cannot be encoded faithfully report a field failure. VRs outside the
/// declared repertoire use ASCII. The charset declaration cannot be changed.
/// Commits a verified temporary result in the original transfer syntax as
/// "anon_<name>". Returns the written path, or nil when nothing was written.
/// Each field failure invalidates the calling batch. The helper may still
/// write the remaining changes, but reports write or SOP identity failures as nil.
+ (nullable NSString *)anonymizeStagedFile:(NSString *)path
                                  withTags:(NSArray *)tags
                                   failure:(NS_NOESCAPE HorosGDCMAnonymizerFailure)failure
    NS_SWIFT_NAME(anonymizeStagedFile(_:tags:failure:));

@end

NS_ASSUME_NONNULL_END
