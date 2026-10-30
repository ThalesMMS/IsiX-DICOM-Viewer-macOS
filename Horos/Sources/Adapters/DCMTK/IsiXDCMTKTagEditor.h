//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Writing DICOM tag edits into files through DCMTK, for +[XMLController
// modifyDicom:dicomFiles:reasons:] and its callers. Objective-C and C types
// only, for the bridging header.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

@interface IsiXDCMTKTagEditor : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Applies `tagAndValues` to each file. An entry is an array whose first
/// element is an IsiXDICOMAttributeTag, or a path answering -steps, -group and
/// -element; an entry of one element removes that tag, of two replaces it
/// with the second (a string; an empty one is a value, NSNull a removal).
/// Accepted edits are published per file atomically; NO may mean partial
/// success. `reasons`, when asked for, says what was saved and why each
/// refused field or file was refused. A C++ exception leaves that file as it
/// was and is one of those reasons.
+ (BOOL)modifyFiles:(NSArray *)dicomFiles withEntries:(NSArray *)tagAndValues
            reasons:(NSArray * _Nullable * _Nullable)reasons;

/// The Specific Character Set a file has to declare before these text values
/// are written into it: nil when its own encodes them, ISO_IR 192 when it
/// declares none and all its text is ASCII. *refused is YES, with nil, when
/// the file cannot take them without re-encoding its other text, or cannot be
/// read.
+ (nullable NSString *)characterSetToDeclareForValues:(NSArray *)values inFileAtPath:(NSString *)path
                                              refused:(nullable BOOL *)refused;

/// Puts each string as the value of its top-level tag (group << 16 | element),
/// inserting the element when absent, with every value of the file loaded into
/// memory, and saves the file in place in the transfer syntax it was read in.
/// For a file the application has just written itself, such as a screen
/// capture. NO, with DCMTK's condition, when the file does not load or the
/// save fails.
+ (BOOL)replaceStringValues:(NSDictionary<NSNumber *, NSString *> *)values inFileAtPath:(NSString *)path
                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
