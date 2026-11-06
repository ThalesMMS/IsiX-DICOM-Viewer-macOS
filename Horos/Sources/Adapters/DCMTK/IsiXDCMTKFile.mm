//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC.

#import "IsiXDCMTKFile.h"
#import "IsiXDCMTKInternal.hpp"

#include <dcmtk/dcmdata/dcfilefo.h>
#include <atomic>
#include <cstdio>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcvrobow.h>
#include <dcmtk/dcmdata/dcsequen.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcvrda.h>
#include <dcmtk/dcmdata/dcvrtm.h>
#include <dcmtk/dcmdata/dcstack.h>
#include <dcmtk/dcmjpeg/djrploss.h>
#include "HorosDICOMRepresentation.h"

#if !__has_feature(objc_arc)
#error "IsiXDCMTKFile.mm is compiled with ARC (-fobjc-arc)"
#endif

typedef std::shared_ptr<DcmFileFormat> IsiXDCMTKFileStorageType;

static DcmTagKey IsiXDCMTKKey(uint32_t tag)
{
    return DcmTagKey((Uint16)(tag >> 16), (Uint16)(tag & 0xffff));
}

static NSData *IsiXDCMTKFileBytes(const OFString &value)
{
    return [NSData dataWithBytes:value.c_str() length:value.length()];
}

// What the getters do when DCMTK throws: nothing was read.
template <typename Body>
static inline void IsiXDCMTKRead(const char *operation, Body &&body)
{
    IsiXDCMTKGuard(NULL, operation, [&]() -> NSError * { body(); return nil; });
}

@interface IsiXDCMTKItem ()
- (instancetype)initWithItem:(DcmItem *)item file:(IsiXDCMTKFile *)file NS_DESIGNATED_INITIALIZER;
@end

@interface IsiXDCMTKFile ()
- (instancetype)initWithStorage:(IsiXDCMTKFileStorageType)storage NS_DESIGNATED_INITIALIZER;
@end

@implementation IsiXDCMTKFile
{
    IsiXDCMTKFileStorageType _storage;
    // Set for a file over a pointer it was given, which it may hand back.
    std::shared_ptr<std::atomic<bool>> _owned;
}

- (instancetype)init
{
    if ((self = [super init])) {
        try { _storage = std::make_shared<DcmFileFormat>(); }
        catch (...) { return nil; }
    }
    return self;
}

- (instancetype)initWithStorage:(IsiXDCMTKFileStorageType)storage
{
    if ((self = [super init])) _storage = std::move(storage);
    return self;
}

+ (instancetype)fileAtPath:(NSString *)path error:(NSError **)error
{
    const char *fileSystemPath = IsiXDCMTKFileSystemPath(path);
    if (fileSystemPath == NULL) {
        if (error) *error = IsiXDCMTKFailure(@"the path has no file system representation");
        return nil;
    }
    IsiXDCMTKFile *file = nil;
    IsiXDCMTKGuard(error, "DcmFileFormat::loadFile", [&]() -> NSError * {
        IsiXDCMTKFileStorageType storage = std::make_shared<DcmFileFormat>();
        OFCondition condition = storage->loadFile(fileSystemPath, EXS_Unknown, EGL_noChange, DCM_MaxReadLength,
                                                  ERM_autoDetect);
        if (condition.bad()) return IsiXDCMTKErrorFromCondition(condition);
        file = [[IsiXDCMTKFile alloc] initWithStorage:std::move(storage)];
        return nil;
    });
    return file;
}

+ (instancetype)fileTakingOwnershipOfHandle:(void *)handle
{
    std::shared_ptr<std::atomic<bool>> owned = std::make_shared<std::atomic<bool>>(true);
    IsiXDCMTKFile *file = [[IsiXDCMTKFile alloc] initWithStorage:IsiXDCMTKFileStorageType(
        static_cast<DcmFileFormat *>(handle), [owned](DcmFileFormat *storage) { if (*owned) delete storage; })];
    file->_owned = owned;
    return file;
}

- (void)relinquishOwnership
{
    if (_owned) *_owned = false;
}

+ (instancetype)fileBorrowingHandle:(void *)handle
{
    return [[IsiXDCMTKFile alloc] initWithStorage:IsiXDCMTKFileStorageType(static_cast<DcmFileFormat *>(handle),
                                                                           [](DcmFileFormat *) {})];
}

- (void *)handle
{
    return _storage.get();
}

- (IsiXDCMTKItem *)dataset
{
    return [[IsiXDCMTKItem alloc] initWithItem:_storage ? _storage->getDataset() : NULL file:self];
}

- (IsiXDCMTKItem *)metaInfo
{
    return [[IsiXDCMTKItem alloc] initWithItem:_storage ? _storage->getMetaInfo() : NULL file:self];
}

- (NSString *)originalTransferSyntax
{
    NSString *uid = nil;
    IsiXDCMTKRead("DcmXfer::getXferID", [&]() {
        if (!_storage || !_storage->getDataset()) return;
        const char *identifier = DcmXfer(_storage->getDataset()->getOriginalXfer()).getXferID();
        uid = identifier && *identifier ? [NSString stringWithUTF8String:identifier] : nil;
    });
    return uid;
}

- (BOOL)originalTransferSyntaxIsEncapsulated
{
    BOOL encapsulated = NO;
    IsiXDCMTKRead("DcmXfer::usesEncapsulatedFormat", [&]() {
        if (!_storage || !_storage->getDataset()) return;
        DcmXfer xfer(_storage->getDataset()->getOriginalXfer());
        encapsulated = xfer.usesEncapsulatedFormat() && xfer.isPixelDataCompressed();
    });
    return encapsulated;
}

- (BOOL)originalTransferSyntaxIsNative
{
    BOOL native = NO;
    IsiXDCMTKRead("DcmXfer::usesNativeFormat", [&]() {
        if (!_storage || !_storage->getDataset()) return;
        native = DcmXfer(_storage->getDataset()->getOriginalXfer()).usesNativeFormat();
    });
    return native;
}

- (BOOL)writeToPath:(NSString *)path transferSyntax:(NSString *)transferSyntax removingPadding:(BOOL)removingPadding
              error:(NSError **)error
{
    const char *fileSystemPath = IsiXDCMTKFileSystemPath(path);
    if (fileSystemPath == NULL) {
        if (error) *error = IsiXDCMTKFailure(@"the path has no file system representation");
        return NO;
    }
    return IsiXDCMTKGuard(error, "DcmFileFormat::saveFile", [&]() -> NSError * {
        const E_TransferSyntax syntax = transferSyntax.length ? DcmXfer(transferSyntax.UTF8String).getXfer() : EXS_Unknown;
        return IsiXDCMTKErrorFromCondition(_storage->saveFile(fileSystemPath, syntax, EET_ExplicitLength, EGL_recalcGL,
                                                              removingPadding ? EPD_withoutPadding : EPD_noChange,
                                                              0, 0, EWM_fileformat));
    });
}

+ (int)jpegQualityForCompressionQuality:(int)quality
{
    return quality <= 1 ? 90 : (quality == 2 ? 80 : 70);
}

+ (BOOL)transcodeFileAtPath:(NSString *)source toPath:(NSString *)destination transferSyntax:(NSString *)transferSyntax
                    quality:(int)quality error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmDataset::chooseRepresentation", [&]() -> NSError * {
        const E_TransferSyntax target = transferSyntax.length ? DcmXfer(transferSyntax.UTF8String).getXfer() : EXS_Unknown;
        if (target == EXS_Unknown) return IsiXDCMTKErrorFromCondition(EC_UnknownTransferSyntax);
        const char *from = IsiXDCMTKFileSystemPath(source), *to = IsiXDCMTKFileSystemPath(destination);
        if (from == NULL || to == NULL) return IsiXDCMTKFailure(@"the path has no file system representation");
        DcmFileFormat file;
        OFCondition result = file.loadFile(from);
        DcmDataset *dataset = file.getDataset();
        if (result.good() && dataset->tagExists(DCM_PixelData) && !dataset->canWriteXfer(target)) {
            if (target == EXS_JPEGProcess1 || target == EXS_JPEGProcess2_4) {
                DJ_RPLossy jpeg([self jpegQualityForCompressionQuality:quality]);
                result = HorosChooseDICOMRepresentation(file, target, &jpeg, quality);
            } else
                result = HorosChooseDICOMRepresentation(file, target, NULL, quality);
        }
        if (result.good() && !dataset->canWriteXfer(target))
            result = EC_CannotChangeRepresentation;
        NSString *temporary = [self temporaryPathBeside:destination];
        if (result.good()) {
            file.loadAllDataIntoMemory();
            result = file.saveFile(IsiXDCMTKFileSystemPath(temporary), target);
        }
        if (result.good() && rename(temporary.fileSystemRepresentation, to) != 0)
            result = EC_InvalidStream;
        if (result.bad())
            [[NSFileManager defaultManager] removeItemAtPath:temporary error:NULL];
        return IsiXDCMTKErrorFromCondition(result);
    });
}

+ (NSString *)temporaryPathBeside:(NSString *)path
{
    return [path stringByAppendingFormat:@".%@.tmp", [[NSUUID UUID] UUIDString]];
}

+ (NSString *)generateUIDWithRoot:(IsiXDCMTKUIDRoot)root
{
    char buffer[100] = {0};
    const char *prefix = root == IsiXDCMTKUIDRootStudy ? SITE_STUDY_UID_ROOT
                       : (root == IsiXDCMTKUIDRootSeries ? SITE_SERIES_UID_ROOT : SITE_INSTANCE_UID_ROOT);
    IsiXDCMTKRead("dcmGenerateUniqueIdentifier", [&]() { dcmGenerateUniqueIdentifier(buffer, prefix); });
    return [NSString stringWithUTF8String:buffer];
}

- (BOOL)readFileAtPath:(NSString *)path error:(NSError **)error
{
    const char *fileSystemPath = IsiXDCMTKFileSystemPath(path);
    if (fileSystemPath == NULL) {
        if (error) *error = IsiXDCMTKFailure(@"the path has no file system representation");
        return NO;
    }
    return IsiXDCMTKGuard(error, "DcmFileFormat::loadFile", [&]() -> NSError * {
        if (!_storage) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        return IsiXDCMTKErrorFromCondition(_storage->loadFile(fileSystemPath, EXS_Unknown, EGL_noChange));
    });
}

- (void)loadAllDataIntoMemory
{
    IsiXDCMTKRead("DcmFileFormat::loadAllDataIntoMemory", [&]() {
        if (_storage) _storage->loadAllDataIntoMemory();
    });
}

- (BOOL)changeRepresentationToTransferSyntax:(NSString *)transferSyntax
{
    BOOL changed = NO;
    IsiXDCMTKRead("DcmDataset::chooseRepresentation", [&]() {
        const E_TransferSyntax target = transferSyntax.length ? DcmXfer(transferSyntax.UTF8String).getXfer() : EXS_Unknown;
        if (_storage) changed = HorosChooseDICOMRepresentation(*_storage, target).good();
    });
    return changed;
}

- (BOOL)canWriteTransferSyntax:(NSString *)transferSyntax
{
    BOOL writable = NO;
    IsiXDCMTKRead("DcmFileFormat::canWriteXfer", [&]() {
        const E_TransferSyntax target = transferSyntax.length ? DcmXfer(transferSyntax.UTF8String).getXfer() : EXS_Unknown;
        if (_storage) writable = _storage->canWriteXfer(target);
    });
    return writable;
}

+ (NSString *)currentDate
{
    NSString *date = nil;
    IsiXDCMTKRead("DcmDate::getCurrentDate", [&]() {
        OFString value;
        if (DcmDate::getCurrentDate(value).good()) date = [NSString stringWithUTF8String:value.c_str()];
    });
    return date;
}

+ (NSString *)currentTime
{
    NSString *time = nil;
    IsiXDCMTKRead("DcmTime::getCurrentTime", [&]() {
        OFString value;
        if (DcmTime::getCurrentTime(value).good()) time = [NSString stringWithUTF8String:value.c_str()];
    });
    return time;
}

- (IsiXDCMTKFileStorageType)storage
{
    return _storage;
}

@end

std::shared_ptr<DcmFileFormat> IsiXDCMTKFileStorage(IsiXDCMTKFile *file)
{
    return [file storage];
}

IsiXDCMTKFile *IsiXDCMTKFileSharing(std::shared_ptr<DcmFileFormat> storage)
{
    return [[IsiXDCMTKFile alloc] initWithStorage:std::move(storage)];
}

@implementation IsiXDCMTKItem
{
    DcmItem *_item;
    IsiXDCMTKFile *_file;
}

- (instancetype)initWithItem:(DcmItem *)item file:(IsiXDCMTKFile *)file
{
    if ((self = [super init])) {
        _item = item;
        _file = file;
    }
    return self;
}

- (IsiXDCMTKFile *)file
{
    return _file;
}

- (const char *)stringForTag:(uint32_t)tag
{
    const char *value = NULL;
    IsiXDCMTKRead("DcmItem::findAndGetString", [&]() {
        if (_item && _item->findAndGetString(IsiXDCMTKKey(tag), value, OFFalse).bad()) value = NULL;
    });
    return value;
}

- (NSData *)firstStringForTag:(uint32_t)tag
{
    NSData *value = nil;
    IsiXDCMTKRead("DcmItem::findAndGetOFString", [&]() {
        OFString text;
        if (_item && _item->findAndGetOFString(IsiXDCMTKKey(tag), text, 0, OFFalse).good()) value = IsiXDCMTKFileBytes(text);
    });
    return value;
}

- (NSData *)stringArrayForTag:(uint32_t)tag
{
    NSData *value = nil;
    IsiXDCMTKRead("DcmItem::findAndGetOFStringArray", [&]() {
        OFString text;
        if (_item && _item->findAndGetOFStringArray(IsiXDCMTKKey(tag), text, OFFalse).good()) value = IsiXDCMTKFileBytes(text);
    });
    return value;
}

- (BOOL)getUInt16:(uint16_t *)value forTag:(uint32_t)tag index:(NSUInteger)index
{
    BOOL read = NO;
    IsiXDCMTKRead("DcmItem::findAndGetUint16", [&]() {
        Uint16 number = 0;
        read = _item && _item->findAndGetUint16(IsiXDCMTKKey(tag), number, index, OFFalse).good();
        if (value) *value = number;
    });
    return read;
}

- (BOOL)getUInt32:(uint32_t *)value forTag:(uint32_t)tag index:(NSUInteger)index
{
    BOOL read = NO;
    IsiXDCMTKRead("DcmItem::findAndGetUint32", [&]() {
        Uint32 number = 0;
        read = _item && _item->findAndGetUint32(IsiXDCMTKKey(tag), number, index, OFFalse).good();
        if (value) *value = number;
    });
    return read;
}

- (BOOL)getFloat64:(double *)value forTag:(uint32_t)tag index:(NSUInteger)index
{
    BOOL read = NO;
    IsiXDCMTKRead("DcmItem::findAndGetFloat64", [&]() {
        Float64 number = 0;
        read = _item && _item->findAndGetFloat64(IsiXDCMTKKey(tag), number, index, OFFalse).good();
        if (value) *value = number;
    });
    return read;
}

- (NSUInteger)getFloat64Values:(double *)values count:(NSUInteger)count forTag:(uint32_t)tag
{
    NSUInteger read = 0;
    IsiXDCMTKRead("DcmItem::findAndGetFloat64", [&]() {
        if (_item == NULL) {
            if (count > 0) values[0] = 0;
            return;
        }
        const DcmTagKey key = IsiXDCMTKKey(tag);
        while (read < count && _item->findAndGetFloat64(key, values[read], read, OFFalse).good())
            read++;
    });
    return read;
}

- (BOOL)hasElementForTag:(uint32_t)tag length:(unsigned long *)length
{
    BOOL found = NO;
    IsiXDCMTKRead("DcmItem::findAndGetElement", [&]() {
        DcmElement *element = NULL;
        found = _item && _item->findAndGetElement(IsiXDCMTKKey(tag), element, OFFalse).good() && element;
        if (length) *length = found ? element->getLength() : 0;
    });
    return found;
}

- (NSData *)bytesForTag:(uint32_t)tag
{
    NSData *bytes = nil;
    IsiXDCMTKFile *owner = _file;
    IsiXDCMTKRead("DcmItem::findAndGetUint8Array", [&]() {
        const Uint8 *buffer = NULL;
        unsigned long length = 0;
        if (_item && _item->findAndGetUint8Array(IsiXDCMTKKey(tag), buffer, &length, OFFalse).good() && buffer)
            bytes = [[NSData alloc] initWithBytesNoCopy:(void *)buffer length:length deallocator:^(void *, NSUInteger) {
                (void)owner;
            }];
    });
    return bytes;
}

- (IsiXDCMTKItem *)itemAtIndex:(NSInteger)index ofSequence:(uint32_t)tag
{
    DcmItem *found = NULL;
    IsiXDCMTKRead("DcmItem::findAndGetSequenceItem", [&]() {
        if (_item && _item->findAndGetSequenceItem(IsiXDCMTKKey(tag), found, (signed long)index, OFFalse).bad()) found = NULL;
    });
    return found ? [[IsiXDCMTKItem alloc] initWithItem:found file:_file] : nil;
}

- (IsiXDCMTKItem *)findOrCreateItemAtIndex:(NSInteger)index ofSequence:(uint32_t)tag error:(NSError **)error
{
    DcmItem *found = NULL;
    IsiXDCMTKGuard(error, "DcmItem::findOrCreateSequenceItem", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        OFCondition condition = _item->findOrCreateSequenceItem(IsiXDCMTKKey(tag), found, (signed long)index);
        if (condition.bad() || found == NULL) { found = NULL; return IsiXDCMTKErrorFromCondition(condition.bad() ? condition : EC_IllegalCall); }
        return nil;
    });
    return found ? [[IsiXDCMTKItem alloc] initWithItem:found file:_file] : nil;
}

- (BOOL)putString:(const char *)value forTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::putAndInsertString", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        return IsiXDCMTKErrorFromCondition(_item->putAndInsertString(IsiXDCMTKKey(tag), value));
    });
}

- (BOOL)putUInt16:(uint16_t)value forTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::putAndInsertUint16", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        return IsiXDCMTKErrorFromCondition(_item->putAndInsertUint16(IsiXDCMTKKey(tag), value));
    });
}

- (BOOL)putBytes:(NSData *)data forTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::putAndInsertUint8Array", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        return IsiXDCMTKErrorFromCondition(_item->putAndInsertUint8Array(IsiXDCMTKKey(tag), (const Uint8 *)data.bytes,
                                                                         (unsigned long)data.length));
    });
}

- (BOOL)putWords:(NSData *)data forTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmElement::putUint16Array", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        const DcmTagKey key = IsiXDCMTKKey(tag);
        DcmTag dicomTag(key, EVR_OW);
        DcmElement *element = key == DCM_PixelData ? (DcmElement *)new DcmPixelData(dicomTag)
                                                   : (DcmElement *)new DcmOtherByteOtherWord(dicomTag);
        // Little-endian words, which is host order here.
        OFCondition result = element->putUint16Array((const Uint16 *)data.bytes, (unsigned long)(data.length / 2));
        if (result.good())
            result = _item->insert(element, OFTrue);
        else
            delete element;
        return IsiXDCMTKErrorFromCondition(result);
    });
}

- (BOOL)insertEmptyElementForTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::insertEmptyElement", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        return IsiXDCMTKErrorFromCondition(_item->insertEmptyElement(DcmTag(IsiXDCMTKKey(tag)), OFTrue));
    });
}

- (BOOL)putUInt16Array:(NSData *)data forTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::putAndInsertUint16Array", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        return IsiXDCMTKErrorFromCondition(_item->putAndInsertUint16Array(IsiXDCMTKKey(tag), (const Uint16 *)data.bytes,
                                                                          (unsigned long)(data.length / 2)));
    });
}

- (void)removeElementForTag:(uint32_t)tag
{
    IsiXDCMTKRead("DcmItem::remove", [&]() {
        if (_item) delete _item->remove(IsiXDCMTKKey(tag));
    });
}

- (void)removeAllElementsOfGroup:(uint16_t)group
{
    IsiXDCMTKRead("DcmItem::nextObject", [&]() {
        if (_item == NULL) return;
        DcmStack stack;
        OFCondition status = _item->nextObject(stack, OFTrue);
        while (status.good()) {
            DcmObject *object = stack.top();
            if (object->getTag().getGroup() == group) {
                stack.pop();
                delete ((DcmItem *)(stack.top()))->remove(object);
            }
            status = _item->nextObject(stack, OFTrue);
        }
    });
}

- (BOOL)insertEmptySequenceForTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::insert", [&]() -> NSError * {
        if (_item == NULL) return IsiXDCMTKErrorFromCondition(EC_IllegalCall);
        DcmSequenceOfItems *sequence = new DcmSequenceOfItems(IsiXDCMTKKey(tag));
        OFCondition result = _item->insert(sequence, OFTrue);
        if (result.bad()) delete sequence;
        return IsiXDCMTKErrorFromCondition(result);
    });
}

@end
