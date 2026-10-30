//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

/// A DCMTK dataset: the identifier of a request, a response of a C-FIND, or
/// the attributes of a file. Tags are (group << 16) | element. Values go in
/// and come out as the bytes DCMTK holds, so that the caller decodes them in
/// the character set it chose, as the code before this adapter did.
///
/// A getter answers nil when the attribute is absent, when DCMTK refuses, or
/// when the call throws (the exception is logged); the calls that can fail
/// for a reason the caller reports take an NSError.
@interface IsiXDCMTKDataset : NSObject <NSCopying>

- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// The attributes of the file at `path` up to its Pixel Data, which is not
/// read, and the transfer syntax its meta header names.
+ (nullable instancetype)datasetOfFileAtPath:(NSString *)path
                              transferSyntax:(NSString * _Nullable * _Nullable)transferSyntax
                                       error:(NSError **)error
    NS_SWIFT_NAME(dataset(ofFileAtPath:transferSyntax:));

/// Adds `tag` with an empty value, replacing it if present.
- (BOOL)insertEmptyElementWithTag:(uint32_t)tag error:(NSError **)error;
/// Sets `tag` to the bytes of `value`, adding it if absent; nil leaves it empty.
- (BOOL)putValue:(nullable NSData *)value forTag:(uint32_t)tag error:(NSError **)error;
/// Sets `tag` in the first item of the sequence `sequenceTag`, adding the
/// sequence and its item if absent; nil leaves it empty.
- (BOOL)putValue:(nullable NSData *)value forTag:(uint32_t)tag inItemOfSequence:(uint32_t)sequenceTag error:(NSError **)error
    NS_SWIFT_NAME(putValue(_:forTag:inItemOfSequence:));

/// The value as it is held, all its values together (findAndGetString); nil
/// when absent or empty.
- (nullable NSData *)rawValueForTag:(uint32_t)tag;
/// The first value, normalized as DCMTK reads it (findAndGetOFString).
- (nullable NSData *)stringValueForTag:(uint32_t)tag;
/// Every value, separated by backslashes, normalized (findAndGetOFStringArray).
- (nullable NSData *)stringArrayValueForTag:(uint32_t)tag;
/// The first value of `tag` in each item of the sequence `sequenceTag` that has one.
- (NSArray<NSData *> *)stringValuesForTag:(uint32_t)tag inItemsOfSequence:(uint32_t)sequenceTag;

/// Calls `block` with each attribute in the dataset's order: its tag, and all
/// its values as DCMTK reads them (nil when it gives none).
- (BOOL)enumerateElementsUsingBlock:(NS_NOESCAPE void (^)(uint32_t tag, NSData * _Nullable value))block
                              error:(NSError **)error;

/// Calls `block` with each attribute in the dataset's order as the listener
/// reads a request: its tag, its value as DCMTK holds it (getString, nil when
/// it gives none), its length and its name in DCMTK's dictionary.
- (BOOL)enumerateRawElementsUsingBlock:(NS_NOESCAPE void (^)(uint32_t tag, NSData * _Nullable value,
                                                             NSUInteger length, NSString *name))block
                                 error:(NSError **)error;

/// The dataset as DCMTK prints it.
@property (readonly, copy) NSString *dump;
/// Prints the dataset to the standard output, as DCMTK's verbose dumps do.
- (void)printToStandardOutput;

/// Whether the transfer syntax `uid` compresses its pixel data with loss.
+ (BOOL)isLossyTransferSyntax:(NSString *)uid;

@end

NS_ASSUME_NONNULL_END
