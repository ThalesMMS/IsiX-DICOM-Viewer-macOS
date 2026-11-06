//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The staged copy of a file the selected-field anonymization changes, held by
// DCMTK: its identity, the facts of each selected tag, the replacement text
// encoded in the file's character set, the replacements, and the verified
// copy written beside it. The rules of what each tag becomes are Swift
// (SelectedFieldAnonymization); this file only does what they decide.
// Objective-C and C types only, as every header of Adapters/DCMTK. A C++
// exception is logged and reads as a refusal.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

/// What a staged file says of a tag at the root of its dataset, and what the
/// frozen catalog of public fields says of it.
@interface IsiXDCMTKSelectedElement : NSObject
@property (readonly) BOOL exists;
/// A DcmPixelData, native or encapsulated.
@property (readonly) BOOL isPixelData;
/// The element's value representation, as DCMTK names it ("" when absent).
@property (readonly, copy) NSString *valueRepresentation;
/// The dictionary's value representation for the tag.
@property (readonly, copy) NSString *dictionaryValueRepresentation;
/// 0 not in the catalog, 1 text, 2 empty only, 3 an empty sequence only.
@property (readonly) NSInteger catalogPolicy;
@end

/// The changes SelectedFieldAnonymization.Replacement names.
typedef NS_ENUM(NSInteger, IsiXDCMTKSelectedReplacement) {
    IsiXDCMTKSelectedReplacementClearExisting,
    IsiXDCMTKSelectedReplacementEmptyPixelData,
    IsiXDCMTKSelectedReplacementInsertEmpty,
    IsiXDCMTKSelectedReplacementInsertEmptySequence,
    IsiXDCMTKSelectedReplacementPutIntoExisting,
    IsiXDCMTKSelectedReplacementInsertText,
};

@interface IsiXDCMTKAnonymizationFile : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// The readable regular file at `path`, read through a seekable private
/// copy in its folder (nesting limited to 16 levels); nil when it is not one
/// or DCMTK cannot read it.
+ (nullable instancetype)stagedFileAtPath:(NSString *)path NS_SWIFT_NAME(init(stagedPath:));

/// A UID at the root of the dataset or of the file meta: present, UI, 1 to
/// 64 bytes, not empty once read. Nil otherwise.
@property (readonly, nullable) NSString *datasetSOPClassUID;
@property (readonly, nullable) NSString *datasetSOPInstanceUID;
@property (readonly, nullable) NSString *metaStorageSOPClassUID;
@property (readonly, nullable) NSString *metaStorageSOPInstanceUID;

/// The transfer syntax the file was serialized in (the file meta's, or the
/// dataset's own without one) is known and the dataset can be written in it.
@property (readonly) BOOL canKeepTransferSyntax;

/// Records the serialized shape of the dataset - every leaf's length and the
/// tree's boundaries, a deferred value probed at its last byte - and checks
/// that the source is still the file that was read. The copy written must
/// read back with the last shape recorded.
- (BOOL)recordShape;

/// The Specific Character Set as declared, all its values; empty when absent.
@property (readonly) NSData *characterSet;

- (IsiXDCMTKSelectedElement *)elementForTag:(uint32_t)tag NS_SWIFT_NAME(element(forTag:));

/// `utf8` encoded for a value of `valueRepresentation` through the declared
/// character set, and decoded back to the same text; nil when it cannot be.
/// With `codeExtensions` the text, which is ASCII, is only checked.
- (nullable NSData *)encodeUTF8:(NSData *)utf8 valueRepresentation:(NSString *)valueRepresentation
                 codeExtensions:(BOOL)codeExtensions;

/// Applies `replacement` to `tag` with `value` (the encoded text, empty for
/// none). Whether DCMTK did it.
- (BOOL)applyReplacement:(IsiXDCMTKSelectedReplacement)replacement toTag:(uint32_t)tag value:(NSData *)value;

/// Writes the file in its transfer syntax to a temporary file in its folder
/// (`temporaryTemplate`, mkstemp), reads it back and checks its syntax, its
/// shape and that its file meta names `storageClass` and `instance`, and
/// renames it to `outputPath`. The temporary file is removed when any step
/// fails. Whether `outputPath` holds the verified copy.
- (BOOL)writeVerifiedCopyToPath:(NSString *)outputPath temporaryTemplate:(NSString *)temporaryTemplate
                   storageClass:(NSString *)storageClass instance:(NSString *)instance;

@end

NS_ASSUME_NONNULL_END
