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

// The per-file GDCM work of +[Anonymization anonymizeFiles:...error:] (#712).
// Anonymization is Swift, which cannot call GDCM's C++ API; this is the part
// of the former Anonymization.mm that does, unchanged: the same GDCM calls, in
// the same order, with the same options, character-set encoding and errors.
// The header is plain Objective-C, so Swift and the SDK can import it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called for each problem found in a file, in the order the former code
/// recorded them. `tag` is "(GGGG,EEEE)" when a field was not replaced, and
/// nil otherwise. Every call means the batch is not a success.
typedef void (^HorosGDCMAnonymizerFailure)(NSString *reason, NSString * _Nullable tag);

@interface HorosGDCMAnonymizer : NSObject

/// Reads the staged copy at `path` with gdcm::Reader, replaces the `tags`
/// (arrays of a DCMAttributeTag and, optionally, a value whose -description is
/// written in the file's character set; no value writes an empty one) with
/// gdcm::Anonymizer, and writes the result with gdcm::Writer next to it, as
/// "anon_<name>". Returns the written path, or nil when nothing was written.
/// A replacement that fails is reported and the file is still written.
+ (nullable NSString *)anonymizeStagedFile:(NSString *)path
                                  withTags:(NSArray *)tags
                                   failure:(NS_NOESCAPE HorosGDCMAnonymizerFailure)failure
    NS_SWIFT_NAME(anonymizeStagedFile(_:tags:failure:));

@end

NS_ASSUME_NONNULL_END
