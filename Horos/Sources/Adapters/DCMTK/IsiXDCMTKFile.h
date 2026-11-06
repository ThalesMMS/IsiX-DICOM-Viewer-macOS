//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A DICOM file held by DCMTK (DcmFileFormat): its meta header and its dataset,
// read from a path or made empty, changed element by element and written.
// Objective-C and C types only, as every header of Adapters/DCMTK.
//
// The getters answer what DCMTK answers, with its conventions: a value that
// is absent leaves NULL, or zero, where DCMTK writes them (findAndGet... set
// the value to zero when they fail), so that a reading written over DCMTK
// reads the same over this adapter. A C++ exception is logged and reads as
// absent; the calls that change or write the file give it as an NSError.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

@class IsiXDCMTKItem;

/// The site roots DCMTK makes new UIDs under (SITE_STUDY_UID_ROOT...).
typedef NS_ENUM(NSInteger, IsiXDCMTKUIDRoot) {
    IsiXDCMTKUIDRootStudy,
    IsiXDCMTKUIDRootSeries,
    IsiXDCMTKUIDRootInstance,
};

@interface IsiXDCMTKFile : NSObject

/// An empty file: an empty meta header and an empty dataset.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// The file at `path`, read whole (loadFile with the transfer syntax detected,
/// the group lengths unchanged, every value read). Nil with the condition
/// DCMTK gave, or with a failure for a path that has no file system
/// representation, which DCMTK never sees.
+ (nullable instancetype)fileAtPath:(nullable NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(file(atPath:));

/// A file over a DcmFileFormat already in memory, given as the untyped pointer
/// plugins and DCMPix have always passed it in. The first takes ownership and
/// deletes it with this object; the second only borrows it, and the caller
/// keeps it alive while this object is used.
+ (instancetype)fileTakingOwnershipOfHandle:(void *)handle NS_SWIFT_NAME(init(takingOwnershipOfHandle:));
+ (instancetype)fileBorrowingHandle:(void *)handle NS_SWIFT_NAME(init(borrowingHandle:));

/// The DcmFileFormat, as an untyped pointer.
@property (readonly) void *handle;

/// Leaves the DcmFileFormat of a file that took ownership of it to whoever
/// holds its pointer: it is no longer deleted with this object.
- (void)relinquishOwnership;

/// The dataset and the meta header. They keep this file alive.
@property (readonly) IsiXDCMTKItem *dataset;
@property (readonly) IsiXDCMTKItem *metaInfo;

/// The transfer syntax the dataset was read in, as DcmXfer judges it.
@property (readonly, nullable) NSString *originalTransferSyntax;
/// Its pixel data is encapsulated and compressed.
@property (readonly) BOOL originalTransferSyntaxIsEncapsulated;
/// Its pixel data is native (not in fragments).
@property (readonly) BOOL originalTransferSyntaxIsNative;

/// Writes the file with a meta header in `transferSyntax` (nil: the syntax it
/// was read in), explicit lengths, the group lengths recalculated, the
/// padding left as it is or removed.
- (BOOL)writeToPath:(NSString *)path transferSyntax:(nullable NSString *)transferSyntax
     removingPadding:(BOOL)removingPadding error:(NSError **)error
    NS_SWIFT_NAME(write(toPath:transferSyntax:removingPadding:));

/// A path beside `path` for writing a file before moving it over `path`.
+ (NSString *)temporaryPathBeside:(NSString *)path NS_SWIFT_NAME(temporaryPath(beside:));

/// The file at `source`, its pixel data changed to `transferSyntax` through
/// the codecs the process registered (HorosChooseDICOMRepresentation) when it
/// cannot be written in it as it is, written to `destination`. `quality` is
/// a DCM_CompressionQuality (0 lossless); a JPEG baseline or extended target
/// takes the IJG quality that goes with it. The file is written beside
/// `destination` and moved over it, so that `destination` appears only
/// complete. An unknown syntax, pixel data that cannot become it, a file that
/// does not read, does not write or does not move gives the condition, and
/// leaves nothing behind.
+ (BOOL)transcodeFileAtPath:(NSString *)source toPath:(NSString *)destination
             transferSyntax:(NSString *)transferSyntax quality:(int)quality error:(NSError **)error
    NS_SWIFT_NAME(transcodeFile(atPath:toPath:transferSyntax:quality:));

/// A new UID under the site root DCMTK uses (dcmGenerateUniqueIdentifier).
+ (NSString *)generateUIDWithRoot:(IsiXDCMTKUIDRoot)root NS_SWIFT_NAME(generateUID(root:));

/// The IJG quality a JPEG baseline or extended encoding uses for a
/// DCM_CompressionQuality: 90 for lossless and high, 80 for medium, 70 below.
+ (int)jpegQualityForCompressionQuality:(int)quality;

/// Reads the file at `path` into this one (loadFile with the transfer syntax
/// detected and the group lengths unchanged): what a failed read left in it
/// stays, as DCMTK leaves it.
- (BOOL)readFileAtPath:(NSString *)path error:(NSError **)error NS_SWIFT_NAME(read(fileAtPath:));

/// Reads every value still on disk into memory, so that the file no longer
/// depends on the one it was read from.
- (void)loadAllDataIntoMemory;

/// Changes the pixel data to `transferSyntax` through the codecs the process
/// registered (HorosChooseDICOMRepresentation). Whether DCMTK did.
- (BOOL)changeRepresentationToTransferSyntax:(NSString *)transferSyntax;

/// Whether the file can be written in `transferSyntax` as it is.
- (BOOL)canWriteTransferSyntax:(NSString *)transferSyntax;

/// Today's date (YYYYMMDD) and the time now (HHMMSS), as DCMTK gives them
/// for a new instance; nil when it cannot.
+ (nullable NSString *)currentDate;
+ (nullable NSString *)currentTime;

@end

/// An item of a file: its dataset, its meta header, or an item of a sequence.
/// Tags are (group << 16) | element; nothing searches into sequences.
@interface IsiXDCMTKItem : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// The file the item is in, which it keeps alive.
@property (readonly) IsiXDCMTKFile *file;

/// All the values of `tag` as the file holds them (findAndGetString): a C
/// string inside the file, valid while the file lives and is not changed;
/// NULL when absent or empty.
- (nullable const char *)stringForTag:(uint32_t)tag;
/// The first value (findAndGetOFString), as bytes; nil when absent.
- (nullable NSData *)firstStringForTag:(uint32_t)tag;
/// Every value, separated by backslashes (findAndGetOFStringArray); nil when absent.
- (nullable NSData *)stringArrayForTag:(uint32_t)tag;

/// The value at `index` (findAndGetUint16, Uint32, Float64): whether it was
/// read. `value` is zero when it was not, as DCMTK leaves it.
- (BOOL)getUInt16:(uint16_t *)value forTag:(uint32_t)tag index:(NSUInteger)index;
- (BOOL)getUInt32:(uint32_t *)value forTag:(uint32_t)tag index:(NSUInteger)index;
- (BOOL)getFloat64:(double *)value forTag:(uint32_t)tag index:(NSUInteger)index;
/// Values 0, 1... of `tag` into `values` while they read, `count` at most: how
/// many were read. The slot after the last one read is zeroed when it is
/// within `count`, as reading it one by one with DCMTK does.
- (NSUInteger)getFloat64Values:(double *)values count:(NSUInteger)count forTag:(uint32_t)tag;

/// Whether the item has `tag`, and its length (getLength; 0 for an
/// encapsulated value).
- (BOOL)hasElementForTag:(uint32_t)tag length:(unsigned long * _Nullable)length;
/// The bytes of an OB or OW value (findAndGetUint8Array), without copying
/// them: the data keeps the file alive. Nil when absent.
- (nullable NSData *)bytesForTag:(uint32_t)tag;

/// The item at `index` of the sequence `tag`; nil when there is none.
- (nullable IsiXDCMTKItem *)itemAtIndex:(NSInteger)index ofSequence:(uint32_t)tag
    NS_SWIFT_NAME(item(at:ofSequence:));
/// The item at `index` of the sequence `tag`, the sequence and the item made
/// when absent; -2 appends a new item (findOrCreateSequenceItem).
- (nullable IsiXDCMTKItem *)findOrCreateItemAtIndex:(NSInteger)index ofSequence:(uint32_t)tag
                                              error:(NSError **)error
    NS_SWIFT_NAME(findOrCreateItem(at:ofSequence:));

/// Sets `tag` to the C string `value` (putAndInsertString), replacing it.
- (BOOL)putString:(const char *)value forTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(putString(_:forTag:));
/// Sets `tag` to `value`.
- (BOOL)putUInt16:(uint16_t)value forTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(putUInt16(_:forTag:));
/// Sets `tag` to the bytes of `data` (putAndInsertUint8Array).
- (BOOL)putBytes:(NSData *)data forTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(putBytes(_:forTag:));
/// Sets `tag` to the 16-bit words of `data`, in host order, as an OW element
/// (Pixel Data as DcmPixelData).
- (BOOL)putWords:(NSData *)data forTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(putWords(_:forTag:));
/// Inserts an empty sequence `tag`, replacing it.
- (BOOL)insertEmptySequenceForTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(insertEmptySequence(forTag:));
/// Inserts an empty element `tag` with the dictionary's representation,
/// replacing it (insertEmptyElement).
- (BOOL)insertEmptyElementForTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(insertEmptyElement(forTag:));
/// Sets `tag` to the 16-bit words of `data`, in host order
/// (putAndInsertUint16Array).
- (BOOL)putUInt16Array:(NSData *)data forTag:(uint32_t)tag error:(NSError **)error
    NS_SWIFT_NAME(putUInt16Array(_:forTag:));
/// Removes and deletes the element `tag` of this item, when it has one.
- (void)removeElementForTag:(uint32_t)tag NS_SWIFT_NAME(removeElement(forTag:));
/// Removes and deletes every element of `group`, in this item and in the
/// items of its sequences.
- (void)removeAllElementsOfGroup:(uint16_t)group NS_SWIFT_NAME(removeAllElements(ofGroup:));

@end

NS_ASSUME_NONNULL_END
