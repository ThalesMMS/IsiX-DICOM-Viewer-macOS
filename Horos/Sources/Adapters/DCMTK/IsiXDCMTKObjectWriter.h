//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The writing of a DCMObject by DCMTK, which the dataset model (the
// IsiXDICOMDataset module) finds by name and forwards to (IsiXDCMWriting).
// Objective-C and C types only, as every header of Adapters/DCMTK.

#import <Foundation/Foundation.h>
#import "DCMModel.h"

NS_ASSUME_NONNULL_BEGIN

/// The object's attributes become a DcmDataset by tag and value representation
/// - sequences, pixel data native or encapsulated, private elements included -
/// in one pass, and DCMTK changes the pixel encoding and writes it.
///
/// Text keeps the Specific Character Set it declares when every value can be
/// written in it; otherwise, or when it declares several, the object is written
/// in UTF-8 as ISO_IR 192: the rule is in IsiXDICOMCharacterSet's terms, which no
/// internal module can see. `quality` is a DCM_CompressionQuality (0 lossless).
/// A DCMTK condition or a C++ exception is logged and answers NO or nil.
@interface IsiXDCMTKObjectWriter : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// A file with meta header, written beside `path` and moved over it; nil
/// `transferSyntax` keeps the object's own.
+ (BOOL)writeObject:(DCMObject *)object toFile:(NSString *)path transferSyntax:(nullable NSString *)transferSyntax
            quality:(int)quality AET:(nullable NSString *)aet;
/// The dataset alone, as it is sent over the network.
+ (nullable NSData *)datasetOfObject:(DCMObject *)object transferSyntax:(nullable NSString *)transferSyntax
                             quality:(int)quality;
/// The object with its pixel data in another syntax, read back as a new object.
+ (nullable DCMObject *)objectByConvertingObject:(DCMObject *)object toTransferSyntax:(NSString *)transferSyntax
                                         quality:(int)quality;

@end

NS_ASSUME_NONNULL_END
