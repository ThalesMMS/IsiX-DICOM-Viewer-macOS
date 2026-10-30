// Compiled under manual retain and release, in the application and in the
// Decompress service.

#import "HorosDCMTKObject.h"
#import "IsiXDCMTKFile.h"
#import "IsiXDCMTKInternal.hpp"
#import "HorosDICOMServices.h"

#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcsequen.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcistrmb.h>
#include <memory>
#include <mutex>
#include "HorosJPEGColourModel.h"

#if __has_feature(objc_arc)
#error "HorosDCMTKObject.mm is compiled under manual retain and release"
#endif

typedef std::shared_ptr<DcmFileFormat> HorosDCMTKFile;

// ---- Values ---------------------------------------------------------------------
//
// Each VR becomes what DCMAttribute -valuesForVR:length:data: made of it, so the
// callers' isKindOfClass: checks and conversions keep working: text as strings
// (trimmed as a whole, then split at backslashes), DA/TM/DT as IsiXDICOMCalendarDate,
// binary numbers as NSNumber and everything else as the raw bytes.

static NSString *HorosLatin1Text(const OFString &raw)
{
    NSString *text = [[[NSString alloc] initWithBytes: raw.c_str() length: raw.length()
                                             encoding: NSISOLatin1StringEncoding] autorelease];
    text = [text stringByTrimmingCharactersInSet: [NSCharacterSet controlCharacterSet]];
    return [text stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Text in ASCII, with no escape, reads the same under every character set but
// JIS X 0201 (ISO_IR 13), where 5C and 7E are the yen sign and the overline.
// It needs no converter: each one opens an iconv descriptor, and opening and
// closing them take a global lock that the viewer's loading threads queue on.
static BOOL HorosIsPlainASCII(const OFString &raw, NSString *characterSet)
{
    for (size_t i = 0; i < raw.length(); i++)
    {
        const unsigned char c = (unsigned char) raw[i];
        if (c >= 0x80 || c == 0x1B)
            return NO;
    }
    for (NSString *term in [characterSet componentsSeparatedByString: @"\\"])
    {
        NSString *trimmed = [term stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed isEqualToString: @"ISO_IR 13"] || [trimmed isEqualToString: @"ISO 2022 IR 13"])
            return NO;
    }
    return YES;
}

static BOOL HorosVRIs(NSString *vr, NSString *candidates)
{
    return vr.length == 2 && [[candidates componentsSeparatedByString: @" "] containsObject: vr];
}

static NSMutableArray *HorosValues(DcmElement *element, NSString *vr, IsiXDICOMCharacterSet *characterSet)
{
    NSMutableArray *values = [NSMutableArray array];
    const Uint32 length = element->getLength();
    if (length == 0)
        return values;
    const unsigned long count = element->getVM();

    if (HorosVRIs(vr, @"LO LT PN SH ST UT"))
    {
        OFString raw;
        if (element->getOFStringArray(raw, OFFalse).bad())
            return values;
        // DCMTK converts under the declared character set; a term it
        // does not know ("WINDOWS-1251") keeps the DCM Framework's table.
        NSString *text = HorosIsPlainASCII(raw, characterSet.characterSet) ?
            [[[NSString alloc] initWithBytes: raw.c_str() length: raw.length() encoding: NSASCIIStringEncoding] autorelease] :
            [HorosDICOMCharacterSets stringWithBytes: raw.c_str() length: raw.length()
                                        characterSet: characterSet.characterSet];
        if (text == nil)
            text = [IsiXDICOMCharacterSet stringWithBytes: (char *) raw.c_str() length: (unsigned) raw.length()
                                          encodings: [characterSet encodings]];
        text = [text stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        text = [text stringByTrimmingCharactersInSet: [NSCharacterSet controlCharacterSet]];
        if (text)
            [values addObjectsFromArray: [text componentsSeparatedByString: @"\\"]];
    }
    else if (HorosVRIs(vr, @"AE AS CS DS IS UI QQ"))
    {
        OFString raw;
        if (element->getOFStringArray(raw, OFFalse).good())
            [values addObjectsFromArray: [HorosLatin1Text(raw) componentsSeparatedByString: @"\\"]];
    }
    else if (HorosVRIs(vr, @"DA TM DT"))
    {
        OFString raw;
        if (element->getOFStringArray(raw, OFFalse).bad())
            return values;
        NSString *text = HorosLatin1Text(raw);
        // Dates and times that read as zero are no date, as before; date-times
        // are parsed whatever they start with.
        if ([vr isEqualToString: @"DT"] == NO && [text intValue] == 0)
            return values;
        for (NSString *component in [text componentsSeparatedByString: @"\\"])
        {
            IsiXDICOMCalendarDate *date = nil;
            if ([vr isEqualToString: @"DA"]) date = [IsiXDICOMCalendarDate dicomDate: component];
            else if ([vr isEqualToString: @"TM"]) date = [IsiXDICOMCalendarDate dicomTime: component];
            else date = [IsiXDICOMCalendarDate dicomDateTime: component];
            if (date)
                [values addObject: date];
        }
    }
    else if ([vr isEqualToString: @"US"])
    {
        for (unsigned long i = 0; i < count; i++) { Uint16 v = 0; if (element->getUint16(v, i).good()) [values addObject: @(int(v))]; }
    }
    else if ([vr isEqualToString: @"SS"])
    {
        for (unsigned long i = 0; i < count; i++) { Sint16 v = 0; if (element->getSint16(v, i).good()) [values addObject: @(int(v))]; }
    }
    else if ([vr isEqualToString: @"UL"])
    {
        for (unsigned long i = 0; i < count; i++) { Uint32 v = 0; if (element->getUint32(v, i).good()) [values addObject: [NSNumber numberWithUnsignedLong: v]]; }
    }
    else if ([vr isEqualToString: @"SL"])
    {
        for (unsigned long i = 0; i < count; i++) { Sint32 v = 0; if (element->getSint32(v, i).good()) [values addObject: [NSNumber numberWithLong: v]]; }
    }
    else if ([vr isEqualToString: @"FL"])
    {
        for (unsigned long i = 0; i < count; i++) { Float32 v = 0; if (element->getFloat32(v, i).good()) [values addObject: [NSNumber numberWithFloat: v]]; }
    }
    else if ([vr isEqualToString: @"FD"])
    {
        for (unsigned long i = 0; i < count; i++) { Float64 v = 0; if (element->getFloat64(v, i).good()) [values addObject: [NSNumber numberWithDouble: v]]; }
    }
    else if ([vr isEqualToString: @"AT"])
    {
        // The DCM Framework read an AT value as one little-endian 32-bit word:
        // the element number in the high half, the group in the low one.
        for (unsigned long i = 0; i < count; i++)
        {
            DcmTagKey key;
            if (element->getTagVal(key, i).good())
                [values addObject: [NSNumber numberWithUnsignedLong: (unsigned long) key.getElement() << 16 | key.getGroup()]];
        }
    }
    else
    {
        NSMutableData *bytes = [NSMutableData dataWithLength: length];
        if (element->getPartialValue(bytes.mutableBytes, 0, length).good())
            [values addObject: bytes];
    }
    return values;
}

// ---- Pixel Data -----------------------------------------------------------------
//
// The frames of the top-level Pixel Data, decoded from the parsed file, which
// the source keeps alive: the attribute's stored values point into it.

@interface HorosDCMTKFrameSource : NSObject <IsiXDCMPixelFrameSource>
{
    HorosDCMTKFile _file;
    DcmPixelData *_pixel;
    std::mutex _decoding;
    BOOL _encapsulated;
}
@end

@implementation HorosDCMTKFrameSource

// The source and the Pixel Data attribute of `object`, whose values are what
// -values gave: the whole native value, or the offset table followed by every
// fragment. The bytes stay in DCMTK's memory, which the source keeps alive.
+ (DCMPixelDataAttribute *)attributeWithFile:(HorosDCMTKFile)file pixel:(DcmPixelData *)pixel tag:(IsiXDICOMAttributeTag *)tag
                                      object:(DCMObject *)object transferSyntax:(DCMTransferSyntax *)syntax
{
    HorosDCMTKFrameSource *source = [[[HorosDCMTKFrameSource alloc] init] autorelease];
    source->_file = file;
    source->_pixel = pixel;
    const int bitsAllocated = [[object attributeValueWithName: @"BitsAllocated"] intValue];
    NSString *vr = nil;
    NSMutableArray *values = [NSMutableArray array];
    DcmXfer original(file->getDataset()->getOriginalXfer());
    DcmPixelSequence *sequence = NULL;
    source->_encapsulated = (original.usesEncapsulatedFormat() && original.isPixelDataCompressed()) &&
        pixel->getEncapsulatedRepresentation(original.getXfer(), NULL, sequence).good() && sequence;
    if (source->_encapsulated)
    {
        vr = @"OB";
        for (unsigned long i = 0; i < sequence->card(); i++)
        {
            DcmPixelItem *item = NULL;
            Uint8 *bytes = NULL;
            if (sequence->getItem(item, i).good() && item && item->getUint8Array(bytes).good() && bytes)
                [values addObject: [NSData dataWithBytesNoCopy: bytes length: item->getLength() freeWhenDone: NO]];
            else
                [values addObject: [NSData data]];
        }
    }
    else
    {
        vr = bitsAllocated <= 8 ? @"OB" : @"OW";
        Uint8 *bytes = NULL;
        // DcmPolymorphOBOW hands 16-bit data out as little-endian bytes, which
        // is host order here, as the frames always were.
        if (pixel->getUint8Array(bytes).good() && bytes)
            [values addObject: [NSData dataWithBytesNoCopy: bytes length: pixel->getLength() freeWhenDone: NO]];
    }
    return [[[DCMPixelDataAttribute alloc] initWithAttributeTag: tag vr: vr values: values object: object
                                                 transferSyntax: syntax frameSource: source] autorelease];
}

- (NSData *)frameAtIndex:(int)index ofAttribute:(DCMPixelDataAttribute *)attribute
             colourModel:(NSString **)colourModel interleaved:(BOOL *)interleaved
{
    NSData *frame = nil;
    IsiXDCMTKGuard(NULL, "DcmPixelData::getUncompressedFrame", [&]() -> NSError * {
        frame = [self decodeFrameThroughDCMTKAtIndex: index ofAttribute: attribute colourModel: colourModel
                                          interleaved: interleaved];
        return nil;
    });
    return frame;
}

- (NSData *)decodeFrameThroughDCMTKAtIndex:(int)index ofAttribute:(DCMPixelDataAttribute *)attribute
                               colourModel:(NSString **)colourModel interleaved:(BOOL *)interleaved
{
    const int _rows = attribute.rows, _columns = attribute.columns, _samplesPerPixel = attribute.samplesPerPixel;
    const int _bitsAllocated = attribute.bitsAllocated, _numberOfFrames = attribute.numberOfFrames;
    NSData *data = nil;
    *colourModel = @"";
    *interleaved = NO;

    if (_encapsulated == NO)
    {
        const long depth = _bitsAllocated <= 8 ? 1 : (_bitsAllocated <= 16 ? 2 : 4);
        const long frameLength = (long) _rows * _columns * _samplesPerPixel * depth;
        NSData *whole = [attribute.values objectAtIndex: 0];
        if (_numberOfFrames <= 1)
            data = [NSData dataWithData: whole]; // a short frame is kept, and reported by the loader
        else if (frameLength > 0 && (long) whole.length >= (index + 1) * frameLength)
            data = [whole subdataWithRange: NSMakeRange(index * frameLength, frameLength)];
    }
    else
    {
        DcmDataset *dataset = _file->getDataset();
        OFString model;
        Uint32 frameSize = 0, startFragment = 0;
        std::lock_guard<std::mutex> guard(_decoding); // DcmItem lookups are not thread-safe
        // A lossy JPEG stream whose JFIF or Adobe marker contradicts the
        // Photometric Interpretation decodes by the marker while
        // UseJPEGColorSpace is on; the stated one is back afterwards.
        const E_TransferSyntax syntax = DcmXfer(dataset->getOriginalXfer()).getXfer();
        DcmPixelSequence *sequence = NULL;
        if (syntax >= EXS_JPEGProcess1 && syntax <= EXS_JPEGProcess14SV1 && _samplesPerPixel == 3)
            _pixel->getEncapsulatedRepresentation(syntax, NULL, sequence);
        HorosJPEGDecodingColour colour(dataset, syntax, sequence);
        // DCMTK refuses to size a frame whose header contradicts itself (RGB
        // with one sample per pixel); the codecs decode it from the attributes.
        if (_pixel->getUncompressedFrameSize(dataset, frameSize, OFFalse).bad() || frameSize == 0)
            frameSize = (Uint32) ((long) _rows * _columns * MAX(_samplesPerPixel, 1) *
                                  (_bitsAllocated <= 8 ? 1 : (_bitsAllocated <= 16 ? 2 : 4)));
        if (frameSize)
        {
            // DCMTK decodes a frame only into a buffer of an even number of
            // bytes: one more than the frame when the frame is odd, as an
            // eight-bit image of odd width and height is. Given the frame's
            // own size it refused every such frame (EC_IllegalCall), whatever
            // the codec, and the image was shown empty.
            Uint32 decoded = frameSize;
            const Uint32 capacity = frameSize + (frameSize & 1);
            NSMutableData *buffer = [NSMutableData dataWithLength: capacity];
            OFCondition result = _pixel->getUncompressedFrame(dataset, index, startFragment, buffer.mutableBytes,
                                                              capacity, model, NULL);
            OFString stated;
            if (result.bad() && _samplesPerPixel == 1 &&
                dataset->findAndGetOFString(DCM_PhotometricInterpretation, stated).good() &&
                (stated.compare(0, 3, "RGB") == 0 || stated.compare(0, 3, "YBR") == 0))
            {
                // A grey picture whose header says colour: DCMTK will not size
                // it. Decode the one sample it has, as the DCM Framework did;
                // the loader reads such a frame as grey.
                dataset->putAndInsertString(DCM_PhotometricInterpretation, "MONOCHROME2");
                startFragment = 0;
                result = _pixel->getUncompressedFrame(dataset, index, startFragment, buffer.mutableBytes,
                                                      capacity, model, NULL);
                dataset->putAndInsertString(DCM_PhotometricInterpretation, stated.c_str());
                model = stated;
            }
            Uint16 allocated = 0, stored = 0, highBit = 0;
            if (result.bad() && dataset->findAndGetUint16(DCM_BitsAllocated, allocated).good() &&
                dataset->findAndGetUint16(DCM_BitsStored, stored).good() && stored <= 8 && allocated > 8)
            {
                // Eight stored bits in sixteen allocated: the codecs decode
                // bytes, and DCMTK sizes the frame in words. Decode it as the
                // eight-bit image it is; the loader reads three bytes per pixel.
                dataset->findAndGetUint16(DCM_HighBit, highBit);
                dataset->putAndInsertUint16(DCM_BitsAllocated, 8);
                dataset->putAndInsertUint16(DCM_HighBit, stored - 1);
                const Uint32 bytes = (Uint32) ((long) _rows * _columns * MAX(_samplesPerPixel, 1));
                if (bytes + (bytes & 1) <= capacity)
                {
                    startFragment = 0;
                    result = _pixel->getUncompressedFrame(dataset, index, startFragment, buffer.mutableBytes,
                                                          bytes + (bytes & 1), model, NULL);
                    if (result.good())
                        decoded = bytes;
                }
                dataset->putAndInsertUint16(DCM_BitsAllocated, allocated);
                dataset->putAndInsertUint16(DCM_HighBit, highBit);
            }
            if (result.good())
            {
                // The frame, without the byte that evened the buffer.
                [buffer setLength: decoded];
                data = buffer;
            }
            else
                NSLog(@"DCMTK cannot decode frame %d (%@): %s", index, attribute.transferSyntax.transferSyntax, result.text());
        }
        if (data)
        {
            // The colour model the codec decoded into, which the attribute
            // compares with the stated one; JPEG, JPEG-LS and JPEG 2000
            // decode interleaved, RLE follows Planar Configuration.
            if (model.length())
                *colourModel = [NSString stringWithUTF8String: model.c_str()];
            *interleaved = DcmXfer(_file->getDataset()->getOriginalXfer()).getXfer() != EXS_RLELossless;
        }
    }
    return data;
}

@end

// ---- Objects ------------------------------------------------------------------------

// The dataset model finds the reader by name and reads through this protocol.
@interface HorosDCMTKObject () <IsiXDCMReading>
@end

@implementation HorosDCMTKObject

+ (DCMObject *)objectWithContentsOfFile:(NSString *)path
{
    return [self objectWithContentsOfFile: path decodingPixelData: NO lastGroup: 0xFFFF];
}

// Reading stops at the first element of the group after `lastGroup`.
static DcmTagKey HorosStopTag(unsigned short lastGroup)
{
    return lastGroup == 0xFFFF ? DCM_UndefinedTagKey : DcmTagKey((Uint16) (lastGroup + 1), 0x0000);
}

+ (DCMObject *)objectWithContentsOfFile:(NSString *)path decodingPixelData:(BOOL)decodePixelData
                              lastGroup:(unsigned short)lastGroup
{
    const char *fileSystemPath = IsiXDCMTKFileSystemPath(path);
    if (fileSystemPath == NULL)
        return nil;
    DCMObject *object = nil;
    IsiXDCMTKGuard(NULL, "DcmFileFormat::loadFileUntilTag", [&]() -> NSError * {
        HorosDCMTKFile file = std::make_shared<DcmFileFormat>();
        OFCondition result = file->loadFileUntilTag(fileSystemPath, EXS_Unknown, EGL_noChange,
                                                    DCM_MaxReadLength, ERM_autoDetect, HorosStopTag(lastGroup));
        if (result.good())
            result = file->loadAllDataIntoMemory();
        if (result.bad())
        {
            NSLog(@"DCMTK cannot read %@: %s", path.lastPathComponent, result.text());
            return nil;
        }
        object = [self objectWithFile: file decodingPixelData: decodePixelData];
        return nil;
    });
    return object;
}

+ (DCMObject *)objectWithData:(NSData *)data transferSyntax:(NSString *)transferSyntax
            decodingPixelData:(BOOL)decodePixelData lastGroup:(unsigned short)lastGroup
{
    if (data.length == 0)
        return nil;
    DCMObject *object = nil;
    IsiXDCMTKGuard(NULL, "DcmFileFormat::readUntilTag", [&]() -> NSError * {
        object = [self objectReadingData: data transferSyntax: transferSyntax decodingPixelData: decodePixelData
                               lastGroup: lastGroup];
        return nil;
    });
    return object;
}

+ (DCMObject *)objectReadingData:(NSData *)data transferSyntax:(NSString *)transferSyntax
               decodingPixelData:(BOOL)decodePixelData lastGroup:(unsigned short)lastGroup
{
    HorosDCMTKFile file = std::make_shared<DcmFileFormat>();
    DcmInputBufferStream stream;
    stream.setBuffer(data.bytes, (offile_off_t) data.length);
    stream.setEos();
    OFCondition result;
    if (transferSyntax.length)
    {
        // A bare dataset, as a network peer sends it: no preamble, no meta header.
        const E_TransferSyntax syntax = DcmXfer(transferSyntax.UTF8String).getXfer();
        if (syntax == EXS_Unknown)
            return nil;
        DcmDataset *dataset = file->getDataset();
        dataset->transferInit();
        result = dataset->readUntilTag(stream, syntax, EGL_noChange, DCM_MaxReadLength, HorosStopTag(lastGroup));
        dataset->transferEnd();
    }
    else
    {
        file->transferInit();
        result = file->readUntilTag(stream, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, HorosStopTag(lastGroup));
        file->transferEnd();
    }
    // A stream stopped at `lastGroup` ends in the middle, which is not an error here.
    if (result == EC_StreamNotifyClient && lastGroup != 0xFFFF)
        result = EC_Normal;
    if (result.bad())
    {
        NSLog(@"DCMTK cannot read %lu bytes of DICOM: %s", (unsigned long) data.length, result.text());
        return nil;
    }
    return [self objectWithFile: file decodingPixelData: decodePixelData];
}

+ (DCMObject *)objectWithFile:(IsiXDCMTKFile *)file
{
    HorosDCMTKFile storage = IsiXDCMTKFileStorage(file);
    if (storage == nullptr)
        return nil;
    DCMObject *object = nil;
    IsiXDCMTKGuard(NULL, "DcmItem::getElement", [&]() -> NSError * {
        object = [self objectWithFile: storage decodingPixelData: NO];
        return nil;
    });
    return object;
}

// Called inside a guard: an exception thrown while the elements are read
// releases the half-made object on its way out.
+ (DCMObject *)objectWithFile:(HorosDCMTKFile)file decodingPixelData:(BOOL)decodePixelData
{
    DCMObject *object = nil;
    try
    {
        object = [self newObjectWithFile: file item: file->getDataset() characterSet: nil transferSyntax: nil];
    }
    catch (...)
    {
        [object release];
        throw;
    }
    [object autorelease];
    if (decodePixelData)
        [object decodePixelDataAttribute];
    return object;
}

// An object (+1) for `item`: the top-level dataset with the meta header, or an
// item of a sequence, which inherits the character set and transfer syntax.
+ (DCMObject *)newObjectWithFile:(HorosDCMTKFile)file item:(DcmItem *)item
                    characterSet:(IsiXDICOMCharacterSet *)inherited transferSyntax:(DCMTransferSyntax *)inheritedSyntax
{
    const BOOL topLevel = inherited == nil;
    DCMTransferSyntax *syntax = topLevel ?
        [[[DCMTransferSyntax alloc] initWithTS: [NSString stringWithUTF8String:
            DcmXfer(file->getDataset()->getOriginalXfer()).getXferID()]] autorelease] : inheritedSyntax;

    // An item may state its own Specific Character Set; otherwise it inherits
    // the one of what contains it, and a file that states none is ISO_IR 100.
    OFString code;
    IsiXDICOMCharacterSet *characterSet = nil;
    if (item->findAndGetOFStringArray(DCM_SpecificCharacterSet, code).good() && code.length())
        characterSet = [[[IsiXDICOMCharacterSet alloc] initWithCode: HorosLatin1Text(code)] autorelease];
    else
        characterSet = inherited ? inherited : [[[IsiXDICOMCharacterSet alloc] initWithCode: @"ISO_IR 100"] autorelease];

    DCMObject *object = [[DCMObject alloc] initWithTransferSyntax: syntax characterSet: characterSet
                                                       isSequence: !topLevel];
    try
    {
        if (topLevel)
            [self addElementsOf: file->getMetaInfo() file: file to: object];
        [self addElementsOf: item file: file to: object];
    }
    catch (...)
    {
        [object release];
        throw;
    }
    return object;
}

+ (void)addElementsOf:(DcmItem *)item file:(HorosDCMTKFile)file to:(DCMObject *)object
{
    IsiXDICOMCharacterSet *specificCharacterSet = object.specificCharacterSet;
    DCMTransferSyntax *transferSyntax = object.transferSyntax;
    for (unsigned long i = 0; i < item->card(); i++)
    {
        DcmElement *element = item->getElement(i);
        if (element == NULL)
            continue;
        const DcmTag &key = element->getTag();
        IsiXDICOMAttributeTag *tag = [IsiXDICOMAttributeTag tagWithGroup: key.getGTag() element: key.getETag()];
        NSString *vr = [NSString stringWithUTF8String: DcmVR(element->getVR()).getValidVRName()];
        tag.vr = vr;
        DCMAttribute *attribute = nil;
        if (element->ident() == EVR_SQ)
        {
            DcmSequenceOfItems *sequence = static_cast<DcmSequenceOfItems *>(element);
            DCMSequenceAttribute *sequenceAttribute = [[[DCMSequenceAttribute alloc] initWithAttributeTag: tag] autorelease];
            for (unsigned long j = 0; j < sequence->card(); j++)
            {
                DCMObject *itemObject = [self newObjectWithFile: file item: sequence->getItem(j)
                                                   characterSet: specificCharacterSet transferSyntax: transferSyntax];
                [sequenceAttribute addItem: itemObject];
                [itemObject release];
            }
            attribute = sequenceAttribute;
        }
        else if (element->ident() == EVR_PixelData && object.isSequence == NO && key == DCM_PixelData)
        {
            attribute = [HorosDCMTKFrameSource attributeWithFile: file pixel: static_cast<DcmPixelData *>(element)
                                                             tag: tag object: object transferSyntax: transferSyntax];
        }
        else if (element->ident() == EVR_PixelData)
        {
            // Pixel Data inside an item (an icon image): the raw value, or the
            // fragments of an encapsulated one, as bytes.
            DcmXfer original(file->getDataset()->getOriginalXfer());
            DcmPixelSequence *fragments = NULL;
            NSMutableArray *values = [NSMutableArray array];
            if ((original.usesEncapsulatedFormat() && original.isPixelDataCompressed()) &&
                static_cast<DcmPixelData *>(element)->getEncapsulatedRepresentation(original.getXfer(), NULL, fragments).good() && fragments)
            {
                for (unsigned long j = 0; j < fragments->card(); j++)
                {
                    DcmPixelItem *fragment = NULL;
                    Uint8 *bytes = NULL;
                    if (fragments->getItem(fragment, j).good() && fragment && fragment->getUint8Array(bytes).good() && bytes)
                        [values addObject: [NSData dataWithBytes: bytes length: fragment->getLength()]];
                }
            }
            else
                values = HorosValues(element, vr, specificCharacterSet);
            attribute = [[[DCMAttribute alloc] initWithAttributeTag: tag vr: vr values: values] autorelease];
        }
        else
            attribute = [[[DCMAttribute alloc] initWithAttributeTag: tag vr: vr
                                                             values: HorosValues(element, vr, specificCharacterSet)] autorelease];
        [object setAttribute: attribute];
    }
}

@end
