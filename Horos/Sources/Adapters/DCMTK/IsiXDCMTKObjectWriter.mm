//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC. Every call into DCMTK runs inside a guard: a C++ exception
// is logged and the write fails, as a DCMTK condition does.

#import "IsiXDCMTKObjectWriter.h"
#import "HorosDICOMWriter.h"
#import "IsiXDCMTKFile.h"
#import "IsiXDCMTKInternal.hpp"
#import "HorosDCMTKObject.h"
// The DICOM value types; found in GENERATED_MODULEMAP_DIR, because the
// targets compiling this file build without clang modules.
#import "IsiXDICOMFile-Swift.h"

#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcsequen.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcostrmb.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmjpeg/djrploss.h>
#include "HorosDICOMRepresentation.h"
#include <cstdio>
#include <memory>

#if !__has_feature(objc_arc)
#error "IsiXDCMTKObjectWriter.mm is compiled with ARC (-fobjc-arc)"
#endif

// A value as the element's VR writes it.
static NSString *HorosValueText(id value, DcmEVR vr)
{
    if ([value isKindOfClass: [IsiXDICOMCalendarDate class]])
    {
        IsiXDICOMCalendarDate *date = value;
        switch (vr)
        {
            case EVR_DA: return [date dateString];
            case EVR_TM: return [date timeString];
            case EVR_DT: return [date dateTimeString: NO];
            default: return [date description];
        }
    }
    if ([value isKindOfClass: [NSNumber class]])
        return [value stringValue];
    if ([value isKindOfClass: [NSString class]])
        return value;
    return [value description];
}

// ---- DCMObject ------------------------------------------------------------------------
//
// The object becomes a DcmDataset element by element; DCMTK then changes the
// pixel encoding and writes it, so the dataset model keeps no serializer or
// codec of its own.

static BOOL HorosVRIsOneOf(NSString *vr, NSString *candidates)
{
    return vr.length == 2 && [[candidates componentsSeparatedByString: @" "] containsObject: vr];
}

// The VRs Specific Character Set applies to (PS3.5 6.1.2.3).
static BOOL HorosIsCharacterSetText(NSString *vr)
{
    return HorosVRIsOneOf(vr, @"SH LO ST LT PN UT UC");
}

static DCMAttribute *HorosAttribute(DCMObject *object, int group, int element)
{
    return [object attributeForTag: [IsiXDICOMAttributeTag tagWithGroup: group element: element]];
}

// Every text value the character set applies to, in the object and its items.
static void HorosCollectText(DCMObject *object, NSMutableArray *texts)
{
    for (DCMAttribute *attribute in object.attributes.allValues)
    {
        if ([attribute isKindOfClass: [DCMSequenceAttribute class]])
        {
            for (id item in [(DCMSequenceAttribute *) attribute sequence])
                if ([item isKindOfClass: [DCMObject class]])
                    HorosCollectText(item, texts);
        }
        else if (HorosIsCharacterSetText(attribute.vr))
        {
            for (id value in attribute.values)
                [texts addObject: [value isKindOfClass: [NSString class]] ? value : [value description]];
        }
    }
}

// The encoding the object's text is written in, and the Specific Character Set
// that says so: its own when it declares one term that can hold every value,
// UTF-8 otherwise.
static NSStringEncoding HorosTextEncoding(DCMObject *object, NSString **declared)
{
    NSArray *terms = HorosAttribute(object, 0x0008, 0x0005).values;
    NSMutableArray *texts = [NSMutableArray array];
    HorosCollectText(object, texts);
    NSString *term = terms.count == 1 ? [[terms objectAtIndex: 0] description] : nil;
    BOOL ascii = YES;
    for (NSString *text in texts)
        if ([text canBeConvertedToEncoding: NSASCIIStringEncoding] == NO) { ascii = NO; break; }

    if (ascii)
    {
        // ASCII reads the same under any declaration; keep the object's own.
        *declared = terms.count ? [terms componentsJoinedByString: @"\\"] : nil;
        return NSASCIIStringEncoding;
    }
    if (term.length && [term isEqualToString: @"ISO_IR 192"] == NO)
    {
        NSStringEncoding encoding = [IsiXDICOMCharacterSet encodingForDICOMCharacterSet: term];
        BOOL fits = YES;
        for (NSString *text in texts)
            if ([text canBeConvertedToEncoding: encoding] == NO) { fits = NO; break; }
        if (fits)
        {
            *declared = term;
            return encoding;
        }
    }
    *declared = @"ISO_IR 192";
    return NSUTF8StringEncoding;
}

static NSString *HorosObjectValueText(id value, DcmEVR vr)
{
    if ([value isKindOfClass: [IsiXDICOMCalendarDate class]] && [(IsiXDICOMCalendarDate *) value isQuery])
        return [(IsiXDICOMCalendarDate *) value queryString];
    return HorosValueText(value, vr);
}

static double HorosNumber(id value)
{
    return [value respondsToSelector: @selector(doubleValue)] ? [value doubleValue] : 0;
}

static NSData *HorosJoinedData(NSArray *values)
{
    if (values.count == 1 && [[values objectAtIndex: 0] isKindOfClass: [NSData class]])
        return [values objectAtIndex: 0];
    NSMutableData *joined = [NSMutableData data];
    for (id value in values)
        if ([value isKindOfClass: [NSData class]])
            [joined appendData: value];
    return joined;
}

// Pixel Data as the attribute holds it: native frames in host byte order, or
// the items of an encapsulated value (the offset table, then the fragments).
static OFCondition HorosInsertPixelData(DcmItem *item, DCMAttribute *attribute, const DcmTagKey &key,
                                        DCMTransferSyntax *syntax)
{
    DcmXfer source(syntax.transferSyntax.UTF8String ?: "");
    NSArray *values = attribute.values;
    if ((source.usesEncapsulatedFormat() && source.isPixelDataCompressed()))
    {
        DcmPixelData *pixel = new DcmPixelData(DcmTag(key, EVR_OB));
        DcmPixelSequence *sequence = new DcmPixelSequence(DcmTag(DCM_PixelSequenceTag, EVR_OB));
        for (NSUInteger i = 0; i < values.count; i++)
        {
            NSData *fragment = [values objectAtIndex: i];
            if ([fragment isKindOfClass: [NSData class]] == NO)
                continue;
            DcmPixelItem *pixelItem = new DcmPixelItem(DcmTag(DCM_Item, EVR_OB));
            pixelItem->putUint8Array((const Uint8 *) fragment.bytes, (unsigned long) fragment.length);
            sequence->insert(pixelItem);
        }
        pixel->putOriginalRepresentation(source.getXfer(), NULL, sequence);
        return item->insert(pixel, OFTrue);
    }

    NSData *bytes = HorosJoinedData(values);
    const BOOL words = [attribute.vr isEqualToString: @"OW"] ||
        ([attribute isKindOfClass: [DCMPixelDataAttribute class]] && [(DCMPixelDataAttribute *) attribute pixelDepth] > 8);
    DcmPixelData *pixel = new DcmPixelData(DcmTag(key, words ? EVR_OW : EVR_OB));
    OFCondition result;
    if (words)
    {
        NSMutableData *host = [NSMutableData dataWithData: bytes];
        // A value still in the big-endian syntax it was read in: DCMTK takes words in host order.
        if (source.getXfer() == EXS_BigEndianExplicit && [attribute isKindOfClass: [DCMPixelDataAttribute class]] &&
            [(DCMPixelDataAttribute *) attribute isDecoded] == NO)
        {
            Uint16 *w = (Uint16 *) host.mutableBytes;
            for (NSUInteger i = 0; i < host.length / 2; i++) w[i] = NSSwapShort(w[i]);
        }
        if (host.length % 2)
            [host increaseLengthBy: 1];
        result = pixel->putUint16Array((const Uint16 *) host.bytes, (unsigned long) (host.length / 2));
    }
    else
        result = pixel->putUint8Array((const Uint8 *) bytes.bytes, (unsigned long) bytes.length);
    if (result.good())
        return item->insert(pixel, OFTrue);
    delete pixel;
    return result;
}

static OFCondition HorosFillItem(DcmItem *item, DCMObject *object, DCMTransferSyntax *syntax,
                                 NSStringEncoding encoding);

static OFCondition HorosInsertAttribute(DcmItem *item, DCMAttribute *attribute, DCMTransferSyntax *syntax,
                                        NSStringEncoding encoding)
{
    const DcmTagKey key((Uint16) attribute.group, (Uint16) attribute.element);
    NSString *vrName = attribute.vr;
    DcmTag tag(key);
    DcmVR stated(vrName.UTF8String ?: "");
    if (vrName.length == 2 && stated.isStandard())
        tag.setVR(stated);
    else if (tag.getEVR() == EVR_UNKNOWN || tag.getEVR() == EVR_UNKNOWN2B)
        tag.setVR(DcmVR(EVR_UN));
    const DcmEVR vr = tag.getEVR();
    NSArray *values = attribute.values;

    if ([attribute isKindOfClass: [DCMSequenceAttribute class]] || vr == EVR_SQ)
    {
        DcmSequenceOfItems *sequence = new DcmSequenceOfItems(tag);
        OFCondition result = EC_Normal;
        if ([attribute isKindOfClass: [DCMSequenceAttribute class]])
        {
            for (id object in [(DCMSequenceAttribute *) attribute sequence])
            {
                if ([object isKindOfClass: [DCMObject class]] == NO)
                    continue;
                DcmItem *child = new DcmItem();
                result = HorosFillItem(child, object, syntax, encoding);
                if (result.bad()) { delete child; break; }
                sequence->insert(child);
            }
        }
        if (result.good())
            return item->insert(sequence, OFTrue);
        delete sequence;
        return result;
    }
    if (key == DCM_PixelData)
    {
        // The object's own Pixel Data says its syntax; one in an item (an icon)
        // is encapsulated only when it holds an offset table and fragments.
        DCMTransferSyntax *pixelSyntax = [attribute isKindOfClass: [DCMPixelDataAttribute class]] ?
            [(DCMPixelDataAttribute *) attribute transferSyntax] :
            (values.count > 1 ? syntax : [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]);
        return HorosInsertPixelData(item, attribute, key, pixelSyntax ?: syntax);
    }

    DcmElement *element = NULL;
    OFCondition result = DcmItem::newDicomElementWithVR(element, tag);
    if (result.bad() || element == NULL)
        return result.bad() ? result : EC_MemoryExhausted;

    const unsigned long count = values.count;
    switch (vr)
    {
        case EVR_US: for (unsigned long i = 0; i < count && result.good(); i++) result = element->putUint16((Uint16) HorosNumber(values[i]), i); break;
        case EVR_SS: for (unsigned long i = 0; i < count && result.good(); i++) result = element->putSint16((Sint16) HorosNumber(values[i]), i); break;
        case EVR_UL: for (unsigned long i = 0; i < count && result.good(); i++) result = element->putUint32((Uint32) [values[i] unsignedLongLongValue], i); break;
        case EVR_SL: for (unsigned long i = 0; i < count && result.good(); i++) result = element->putSint32((Sint32) [values[i] longLongValue], i); break;
        case EVR_FL: for (unsigned long i = 0; i < count && result.good(); i++) result = element->putFloat32((Float32) HorosNumber(values[i]), i); break;
        case EVR_FD: for (unsigned long i = 0; i < count && result.good(); i++) result = element->putFloat64(HorosNumber(values[i]), i); break;
        case EVR_AT:
            for (unsigned long i = 0; i < count && result.good(); i++)
            {
                id value = values[i];
                // The DCM Framework held an AT as one 32-bit word: element high, group low.
                const BOOL isTag = [value isKindOfClass: [IsiXDICOMAttributeTag class]];
                const unsigned long word = isTag ?
                    ((unsigned long) [(IsiXDICOMAttributeTag *) value element] << 16 | (unsigned long) [(IsiXDICOMAttributeTag *) value group]) :
                    (unsigned long) [value unsignedLongLongValue];
                result = element->putTagVal(DcmTagKey((Uint16) (word & 0xFFFF), (Uint16) (word >> 16)), i);
            }
            break;
        case EVR_OB: case EVR_UN: case EVR_OW: case EVR_OF: case EVR_OD: case EVR_OL: case EVR_OV:
        {
            NSData *bytes = HorosJoinedData(values);
            if (vr == EVR_OW)
                result = element->putUint16Array((const Uint16 *) bytes.bytes, (unsigned long) (bytes.length / 2));
            else if (vr == EVR_OF)
                result = element->putFloat32Array((const Float32 *) bytes.bytes, (unsigned long) (bytes.length / 4));
            else if (vr == EVR_OD)
                result = element->putFloat64Array((const Float64 *) bytes.bytes, (unsigned long) (bytes.length / 8));
            else if (vr == EVR_OL)
                result = element->putUint32Array((const Uint32 *) bytes.bytes, (unsigned long) (bytes.length / 4));
            else
                result = element->putUint8Array((const Uint8 *) bytes.bytes, (unsigned long) bytes.length);
            break;
        }
        default:
        {
            NSMutableArray *texts = [NSMutableArray array];
            for (id value in values)
                [texts addObject: HorosObjectValueText(value, vr) ?: @""];
            NSString *text = [texts componentsJoinedByString: @"\\"];
            NSData *bytes = HorosIsCharacterSetText(vrName) ?
                [text dataUsingEncoding: encoding allowLossyConversion: YES] :
                [text dataUsingEncoding: NSASCIIStringEncoding allowLossyConversion: YES];
            if (bytes.length)
                result = element->putString((const char *) bytes.bytes, (Uint32) bytes.length);
            break;
        }
    }
    if (result.good())
        result = item->insert(element, OFTrue);
    else
        delete element;
    return result;
}

static OFCondition HorosFillItem(DcmItem *item, DCMObject *object, DCMTransferSyntax *syntax,
                                 NSStringEncoding encoding)
{
    for (DCMAttribute *attribute in object.attributes.allValues)
    {
        if ([attribute isKindOfClass: [DCMAttribute class]] == NO)
            continue;
        const int group = attribute.group, element = attribute.element;
        // The meta header is DCMTK's to write, group lengths are recomputed,
        // and Specific Character Set is the one the text is written in.
        if (group == 0x0002 || element == 0x0000 || group == 0xFFFE || (group == 0x0008 && element == 0x0005))
            continue;
        OFCondition result = HorosInsertAttribute(item, attribute, syntax, encoding);
        if (result.bad())
        {
            NSLog(@"HorosDICOMWriter: (%04X,%04X) %@ not written: %s", group, element, attribute.vr, result.text());
            return result;
        }
    }
    return EC_Normal;
}

static E_TransferSyntax HorosXferOf(NSString *uid, E_TransferSyntax fallback)
{
    if (uid.length == 0)
        return fallback;
    const E_TransferSyntax xfer = DcmXfer(uid.UTF8String).getXfer();
    return xfer == EXS_Unknown ? fallback : xfer;
}

// The object as a DcmFileFormat, its pixel data in `target`.
static std::shared_ptr<DcmFileFormat> HorosFileOfObject(DCMObject *object, NSString *targetUID, int quality,
                                                        E_TransferSyntax *target)
{
    DCMTransferSyntax *syntax = object.transferSyntax ?: [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
    DCMAttribute *pixels = [object attributeWithName: @"PixelData"];
    DCMTransferSyntax *pixelSyntax = [pixels isKindOfClass: [DCMPixelDataAttribute class]] ?
        [(DCMPixelDataAttribute *) pixels transferSyntax] : nil;
    const E_TransferSyntax source = HorosXferOf((pixelSyntax ?: syntax).transferSyntax, EXS_LittleEndianExplicit);
    *target = HorosXferOf(targetUID, source);

    NSString *declared = nil;
    const NSStringEncoding encoding = HorosTextEncoding(object, &declared);
    std::shared_ptr<DcmFileFormat> file = std::make_shared<DcmFileFormat>();
    DcmDataset *dataset = file->getDataset();
    if (declared.length)
        dataset->putAndInsertString(DCM_SpecificCharacterSet, declared.UTF8String);
    if (HorosFillItem(dataset, object, syntax, encoding).bad())
        return nullptr;

    OFCondition result = EC_Normal;
    if (dataset->tagExists(DCM_PixelData))
    {
        const DcmXfer to(*target);
        const int lossy = to.isPixelDataLossyCompressed() ? quality : 0;
        if (*target == EXS_JPEGProcess1 || *target == EXS_JPEGProcess2_4)
        {
            // What -[DCMPixelDataAttribute convertToTransferSyntax:quality:] never did: JPEG was refused.
            DJ_RPLossy jpeg([IsiXDCMTKFile jpegQualityForCompressionQuality:quality]);
            result = HorosChooseDICOMRepresentation(*file, *target, &jpeg, lossy);
        }
        else
            result = HorosChooseDICOMRepresentation(*file, *target, NULL, lossy);
        if (result.good())
        {
            dataset->removeAllButCurrentRepresentations();
            dataset->updateOriginalXfer();
        }
    }
    else
        dataset->updateOriginalXfer();
    if (result.bad())
    {
        NSLog(@"HorosDICOMWriter: pixel data cannot become %s: %s", DcmXfer(*target).getXferName(), result.text());
        return nullptr;
    }
    return file;
}

// The dataset model finds the writer by name and writes through this protocol.
@interface IsiXDCMTKObjectWriter () <IsiXDCMWriting>
@end

@implementation IsiXDCMTKObjectWriter

+ (BOOL)writeObject:(DCMObject *)object toFile:(NSString *)path transferSyntax:(NSString *)transferSyntaxUID
            quality:(int)quality AET:(NSString *)aet
{
    if (object == nil || path.length == 0)
        return NO;
    BOOL written = NO;
    IsiXDCMTKGuard(NULL, "DcmFileFormat::saveFile", [&]() -> NSError * {
        written = [self writingObject: object toFile: path transferSyntax: transferSyntaxUID quality: quality AET: aet];
        return nil;
    });
    return written;
}

+ (BOOL)writingObject:(DCMObject *)object toFile:(NSString *)path transferSyntax:(NSString *)transferSyntaxUID
              quality:(int)quality AET:(NSString *)aet
{
    E_TransferSyntax target = EXS_Unknown;
    std::shared_ptr<DcmFileFormat> file = HorosFileOfObject(object, transferSyntaxUID, quality, &target);
    if (file == nullptr)
        return NO;
    if (aet.length)
        file->getMetaInfo()->putAndInsertString(DCM_SourceApplicationEntityTitle, aet.UTF8String);
    NSString *temporary = [IsiXDCMTKFile temporaryPathBeside: path];
    const char *temporaryPath = IsiXDCMTKFileSystemPath(temporary), *finalPath = IsiXDCMTKFileSystemPath(path);
    OFCondition result = temporaryPath && finalPath ? file->saveFile(temporaryPath, target, EET_ExplicitLength, EGL_withoutGL,
                                                                     EPD_withoutPadding, 0, 0, EWM_fileformat)
                                                    : OFCondition(EC_InvalidStream);
    if (result.bad() || rename(temporaryPath, finalPath) != 0)
    {
        NSLog(@"HorosDICOMWriter: %@ not written: %s", path.lastPathComponent, result.bad() ? result.text() : strerror(errno));
        [[NSFileManager defaultManager] removeItemAtPath: temporary error: NULL];
        return NO;
    }
    return YES;
}

+ (NSData *)datasetOfObject:(DCMObject *)object transferSyntax:(NSString *)transferSyntaxUID quality:(int)quality
{
    if (object == nil)
        return nil;
    NSData *dataset = nil;
    IsiXDCMTKGuard(NULL, "DcmDataset::write", [&]() -> NSError * {
        dataset = [self encodingObject: object transferSyntax: transferSyntaxUID quality: quality];
        return nil;
    });
    return dataset;
}

+ (NSData *)encodingObject:(DCMObject *)object transferSyntax:(NSString *)transferSyntaxUID quality:(int)quality
{
    E_TransferSyntax target = EXS_Unknown;
    std::shared_ptr<DcmFileFormat> file = HorosFileOfObject(object, transferSyntaxUID, quality, &target);
    if (file == nullptr)
        return nil;
    DcmDataset *dataset = file->getDataset();
    const Uint32 length = dataset->calcElementLength(target, EET_ExplicitLength);
    NSMutableData *bytes = [NSMutableData dataWithLength: length + 256];
    DcmOutputBufferStream stream(bytes.mutableBytes, (offile_off_t) bytes.length);
    dataset->transferInit();
    OFCondition result = dataset->write(stream, target, EET_ExplicitLength, NULL, EGL_withoutGL, EPD_withoutPadding);
    dataset->transferEnd();
    void *written = NULL;
    offile_off_t writtenLength = 0;
    stream.flushBuffer(written, writtenLength);
    if (result.bad())
    {
        NSLog(@"HorosDICOMWriter: dataset not written: %s", result.text());
        return nil;
    }
    [bytes setLength: (NSUInteger) writtenLength];
    return bytes;
}

+ (DCMObject *)objectByConvertingObject:(DCMObject *)object toTransferSyntax:(NSString *)transferSyntaxUID quality:(int)quality
{
    if (object == nil || transferSyntaxUID.length == 0)
        return nil;
    DCMObject *converted = nil;
    IsiXDCMTKGuard(NULL, "DcmDataset::chooseRepresentation", [&]() -> NSError * {
        E_TransferSyntax target = EXS_Unknown;
        std::shared_ptr<DcmFileFormat> file = HorosFileOfObject(object, transferSyntaxUID, quality, &target);
        converted = file == nullptr ? nil : [HorosDCMTKObject objectWithFile: IsiXDCMTKFileSharing(file)];
        return nil;
    });
    return converted;
}

@end

// The UID factories of HorosDICOMWriter. Their selectors are of the new family
// and their declarations say NS_RETURNS_NOT_RETAINED, which ARC honours here
// (an autoreleased string); a Swift implementation would return +1.
@implementation HorosDICOMWriter (Identifiers)

+ (NSString *)newStudyInstanceUID
{
    return [IsiXDCMTKFile generateUIDWithRoot:IsiXDCMTKUIDRootStudy];
}

+ (NSString *)newSeriesInstanceUID
{
    return [IsiXDCMTKFile generateUIDWithRoot:IsiXDCMTKUIDRootSeries];
}

+ (NSString *)newSOPInstanceUID
{
    return [IsiXDCMTKFile generateUIDWithRoot:IsiXDCMTKUIDRootInstance];
}

@end
