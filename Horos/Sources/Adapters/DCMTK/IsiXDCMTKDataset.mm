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

#import "IsiXDCMTKDataset.h"
#import "IsiXDCMTKInternal.hpp"

#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/ofstd/ofstream.h>
#include <memory>

#if !__has_feature(objc_arc)
#error "IsiXDCMTKDataset.mm is compiled with ARC (-fobjc-arc)"
#endif

static DcmTagKey IsiXDCMTKTagKey(uint32_t tag)
{
    return DcmTagKey((Uint16)(tag >> 16), (Uint16)(tag & 0xffff));
}

static NSData *IsiXDCMTKBytes(const OFString &value)
{
    return [NSData dataWithBytes:value.c_str() length:value.length()];
}

@interface IsiXDCMTKDataset ()
- (instancetype)initTakingOwnership:(DcmDataset *)dataset NS_DESIGNATED_INITIALIZER;
- (DcmDataset *)storage;
- (DcmDataset *)releaseStorage;
@end

@implementation IsiXDCMTKDataset
{
    std::unique_ptr<DcmDataset> _dataset;
}

- (instancetype)init
{
    if ((self = [super init])) {
        try { _dataset.reset(new DcmDataset()); }
        catch (...) { return nil; }
    }
    return self;
}

- (instancetype)initTakingOwnership:(DcmDataset *)dataset
{
    if ((self = [super init])) _dataset.reset(dataset);
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    try { return [[IsiXDCMTKDataset alloc] initTakingOwnership:new DcmDataset(*_dataset)]; }
    catch (const std::exception &exception) { IsiXDCMTKErrorFromException(exception.what(), "DcmDataset copy"); }
    catch (...) { IsiXDCMTKErrorFromException("unknown exception", "DcmDataset copy"); }
    return nil;
}

+ (instancetype)datasetOfFileAtPath:(NSString *)path transferSyntax:(NSString **)transferSyntax error:(NSError **)error
{
    IsiXDCMTKDataset *result = nil;
    NSString *syntax = nil;
    IsiXDCMTKGuard(error, "DcmFileFormat::loadFileUntilTag", [&]() -> NSError * {
        DcmFileFormat file;
        OFCondition condition = file.loadFileUntilTag(path.fileSystemRepresentation, EXS_Unknown, EGL_noChange,
                                                      DCM_MaxReadLength, ERM_autoDetect, DCM_PixelData);
        if (condition.bad()) return IsiXDCMTKErrorFromCondition(condition);
        OFString uid;
        if (file.getMetaInfo()->findAndGetOFString(DCM_TransferSyntaxUID, uid).good())
            syntax = [NSString stringWithUTF8String:uid.c_str()];
        result = [[IsiXDCMTKDataset alloc] initTakingOwnership:file.getAndRemoveDataset()];
        return nil;
    });
    if (transferSyntax) *transferSyntax = syntax;
    return result;
}

- (BOOL)insertEmptyElementWithTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::insertEmptyElement", [&]() -> NSError * {
        return IsiXDCMTKErrorFromCondition(_dataset->insertEmptyElement(IsiXDCMTKTagKey(tag), OFTrue));
    });
}

- (BOOL)putValue:(NSData *)value forTag:(uint32_t)tag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::putAndInsertString", [&]() -> NSError * {
        if (value == nil) return IsiXDCMTKErrorFromCondition(_dataset->putAndInsertString(IsiXDCMTKTagKey(tag), NULL, OFTrue));
        return IsiXDCMTKErrorFromCondition(_dataset->putAndInsertString(IsiXDCMTKTagKey(tag), (const char *)value.bytes,
                                                                        (Uint32)value.length, OFTrue));
    });
}

- (BOOL)putValue:(NSData *)value forTag:(uint32_t)tag inItemOfSequence:(uint32_t)sequenceTag error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::findOrCreateSequenceItem", [&]() -> NSError * {
        DcmItem *item = NULL;
        OFCondition condition = _dataset->findOrCreateSequenceItem(IsiXDCMTKTagKey(sequenceTag), item, 0);
        if (condition.bad() || item == NULL) return IsiXDCMTKErrorFromCondition(condition.bad() ? condition : EC_IllegalCall);
        if (value == nil) return IsiXDCMTKErrorFromCondition(item->putAndInsertString(IsiXDCMTKTagKey(tag), NULL, OFTrue));
        return IsiXDCMTKErrorFromCondition(item->putAndInsertString(IsiXDCMTKTagKey(tag), (const char *)value.bytes,
                                                                    (Uint32)value.length, OFTrue));
    });
}

- (NSData *)rawValueForTag:(uint32_t)tag
{
    NSData *result = nil;
    IsiXDCMTKGuard(NULL, "DcmItem::findAndGetString", [&]() -> NSError * {
        const char *value = NULL;
        if (_dataset->findAndGetString(IsiXDCMTKTagKey(tag), value).good() && value != NULL)
            result = [NSData dataWithBytes:value length:strlen(value)];
        return nil;
    });
    return result;
}

- (NSData *)stringValueForTag:(uint32_t)tag
{
    NSData *result = nil;
    IsiXDCMTKGuard(NULL, "DcmItem::findAndGetOFString", [&]() -> NSError * {
        OFString value;
        if (_dataset->findAndGetOFString(IsiXDCMTKTagKey(tag), value).good()) result = IsiXDCMTKBytes(value);
        return nil;
    });
    return result;
}

- (NSData *)stringArrayValueForTag:(uint32_t)tag
{
    NSData *result = nil;
    IsiXDCMTKGuard(NULL, "DcmItem::findAndGetOFStringArray", [&]() -> NSError * {
        OFString value;
        if (_dataset->findAndGetOFStringArray(IsiXDCMTKTagKey(tag), value).good()) result = IsiXDCMTKBytes(value);
        return nil;
    });
    return result;
}

- (NSArray<NSData *> *)stringValuesForTag:(uint32_t)tag inItemsOfSequence:(uint32_t)sequenceTag
{
    NSMutableArray<NSData *> *values = [NSMutableArray array];
    IsiXDCMTKGuard(NULL, "DcmItem::findAndGetSequenceItem", [&]() -> NSError * {
        DcmItem *item = NULL;
        for (signed long i = 0; _dataset->findAndGetSequenceItem(IsiXDCMTKTagKey(sequenceTag), item, i).good() && item; i++) {
            OFString value;
            if (item->findAndGetOFString(IsiXDCMTKTagKey(tag), value).good()) [values addObject:IsiXDCMTKBytes(value)];
        }
        return nil;
    });
    return values;
}

- (BOOL)enumerateElementsUsingBlock:(void (NS_NOESCAPE ^)(uint32_t, NSData *))block error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmItem::getElement", [&]() -> NSError * {
        for (unsigned long i = 0; i < _dataset->card(); ++i) {
            DcmElement *element = _dataset->getElement(i);
            if (!element) continue;
            OFString value;
            NSData *bytes = element->getOFStringArray(value).good() ? IsiXDCMTKBytes(value) : nil;
            block(((uint32_t)element->getGTag() << 16) | element->getETag(), bytes);
        }
        return nil;
    });
}

- (BOOL)enumerateRawElementsUsingBlock:(void (NS_NOESCAPE ^)(uint32_t, NSData *, NSUInteger, NSString *))block
                                 error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmElement::getString", [&]() -> NSError * {
        for (unsigned long i = 0; i < _dataset->card(); ++i) {
            DcmElement *element = _dataset->getElement(i);
            if (!element) continue;
            char *value = NULL;
            NSData *bytes = element->getString(value).good() && value != NULL
                ? [NSData dataWithBytes:value length:strlen(value)] : nil;
            DcmTag tag = element->getTag();
            block(((uint32_t)element->getGTag() << 16) | element->getETag(), bytes, (NSUInteger)element->getLength(),
                  [NSString stringWithUTF8String:tag.getTagName() ?: ""] ?: @"");
        }
        return nil;
    });
}

- (NSString *)dump
{
    NSString *text = @"";
    IsiXDCMTKGuard(NULL, "DcmDataset::print", [&]() -> NSError * {
        OFOStringStream stream;
        _dataset->print(stream);
        OFSTRINGSTREAM_GETSTR(stream, printed)
        text = [NSString stringWithUTF8String:printed] ?: [NSString stringWithCString:printed encoding:NSISOLatin1StringEncoding] ?: @"";
        OFSTRINGSTREAM_FREESTR(printed)
        return nil;
    });
    return text;
}

- (void)printToStandardOutput
{
    IsiXDCMTKGuard(NULL, "DcmDataset::print", [&]() -> NSError * {
        _dataset->print(COUT);
        return nil;
    });
}

+ (BOOL)isLossyTransferSyntax:(NSString *)uid
{
    BOOL lossy = NO;
    IsiXDCMTKGuard(NULL, "DcmXfer::isPixelDataLossyCompressed", [&]() -> NSError * {
        lossy = DcmXfer(uid.UTF8String ?: "").isPixelDataLossyCompressed() ? YES : NO;
        return nil;
    });
    return lossy;
}

- (DcmDataset *)storage
{
    return _dataset.get();
}

- (DcmDataset *)releaseStorage
{
    return _dataset.release();
}

@end

DcmDataset *IsiXDCMTKDatasetReleaseStorage(IsiXDCMTKDataset *dataset)
{
    return [dataset releaseStorage];
}

DcmDataset *IsiXDCMTKDatasetStorage(IsiXDCMTKDataset *dataset)
{
    return [dataset storage];
}

IsiXDCMTKDataset *IsiXDCMTKDatasetTakingOwnership(DcmDataset *storage)
{
    return [[IsiXDCMTKDataset alloc] initTakingOwnership:storage];
}
