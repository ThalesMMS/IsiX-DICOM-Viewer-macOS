#import "HorosDCMTKObject.h"
#import "DCMAttribute.h"
#import "DCMAttributeTag.h"
#import "DCMSequenceAttribute.h"
#import "DCMPixelDataAttribute.h"
#import "DCMTransferSyntax.h"
#import "DCMCharacterSet.h"
#import "DCMCalendarDate.h"
#import "HorosDICOMServices.h"

#undef verify

#include <dcmtk/config/osconfig.h>
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

typedef std::shared_ptr<DcmFileFormat> HorosDCMTKFile;

// ---- Values ---------------------------------------------------------------------
//
// Each VR becomes what DCMAttribute -valuesForVR:length:data: made of it, so the
// callers' isKindOfClass: checks and conversions keep working: text as strings
// (trimmed as a whole, then split at backslashes), DA/TM/DT as DCMCalendarDate,
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

static NSMutableArray *HorosValues(DcmElement *element, NSString *vr, DCMCharacterSet *characterSet)
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
        // DCMTK converts under the declared character set (#737); a term it
        // does not know ("WINDOWS-1251") keeps the DCM Framework's table.
        NSString *text = HorosIsPlainASCII(raw, characterSet.characterSet) ?
            [[[NSString alloc] initWithBytes: raw.c_str() length: raw.length() encoding: NSASCIIStringEncoding] autorelease] :
            [HorosDICOMCharacterSets stringWithBytes: raw.c_str() length: raw.length()
                                        characterSet: characterSet.characterSet];
        if (text == nil)
            text = [DCMCharacterSet stringWithBytes: (char *) raw.c_str() length: (unsigned) raw.length()
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
            DCMCalendarDate *date = nil;
            if ([vr isEqualToString: @"DA"]) date = [DCMCalendarDate dicomDate: component];
            else if ([vr isEqualToString: @"TM"]) date = [DCMCalendarDate dicomTime: component];
            else date = [DCMCalendarDate dicomDateTime: component];
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

@interface HorosDCMTKPixelData : DCMPixelDataAttribute
{
    HorosDCMTKFile _file;
    DcmPixelData *_pixel;
    std::mutex _decoding;
    BOOL _encapsulated;
    BOOL _detached; // converted since: the values, not the file, hold the pixels
}
- (instancetype)initWithFile:(HorosDCMTKFile)file pixel:(DcmPixelData *)pixel tag:(DCMAttributeTag *)tag
                      object:(DCMObject *)object transferSyntax:(DCMTransferSyntax *)syntax;
@end

@implementation HorosDCMTKPixelData

- (instancetype)initWithFile:(HorosDCMTKFile)file pixel:(DcmPixelData *)pixel tag:(DCMAttributeTag *)tag
                      object:(DCMObject *)object transferSyntax:(DCMTransferSyntax *)syntax
{
    if (!(self = [super init]))
        return nil;
    _file = file;
    _pixel = pixel;
    singleThread = [[NSRecursiveLock alloc] init];
    _dcmObject = object; // not retained: the object owns this attribute
    _tag = [tag retain];
    transferSyntax = [syntax retain];
    _pixelDepth = [[object attributeValueWithName: @"BitsStored"] intValue];
    _bitsAllocated = [[object attributeValueWithName: @"BitsAllocated"] intValue];
    _rows = [[object attributeValueWithName: @"Rows"] intValue];
    _columns = [[object attributeValueWithName: @"Columns"] intValue];
    _samplesPerPixel = [[object attributeValueWithName: @"SamplesperPixel"] intValue];
    _numberOfFrames = [object attributeWithName: @"NumberofFrames"] ? [[object attributeValueWithName: @"NumberofFrames"] intValue] : 1;
    _isSigned = [[object attributeValueWithName: @"PixelRepresentation"] boolValue];
    _framesCreated = NO;

    // What -values gave: the whole native value, or the offset table followed by
    // every fragment. The bytes stay in DCMTK's memory, which _file keeps alive.
    NSMutableArray *values = [NSMutableArray array];
    DcmXfer original(file->getDataset()->getOriginalXfer());
    DcmPixelSequence *sequence = NULL;
    _encapsulated = (original.usesEncapsulatedFormat() && original.isPixelDataCompressed()) &&
        pixel->getEncapsulatedRepresentation(original.getXfer(), NULL, sequence).good() && sequence;
    if (_encapsulated)
    {
        _vr = [@"OB" retain];
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
        _vr = [(_bitsAllocated <= 8 ? @"OB" : @"OW") retain];
        Uint8 *bytes = NULL;
        // DcmPolymorphOBOW hands 16-bit data out as little-endian bytes, which
        // is host order here, as the frames always were.
        if (pixel->getUint8Array(bytes).good() && bytes)
            [values addObject: [NSData dataWithBytesNoCopy: bytes length: pixel->getLength() freeWhenDone: NO]];
    }
    _values = [values retain];
    return self;
}

- (NSData *)decodeFrameAtIndex:(int)index
{
    if (_isDecoded || _detached)
        return [super decodeFrameAtIndex: index];
    if (index < 0 || index >= _numberOfFrames || _values.count == 0)
        return nil;
    NSString *colorspace = [_dcmObject attributeValueWithName: @"PhotometricInterpretation"];
    BOOL colorspaceIsConverted = NO, interleaved = NO;
    NSData *data = nil;

    if (_encapsulated == NO)
    {
        const long depth = _bitsAllocated <= 8 ? 1 : (_bitsAllocated <= 16 ? 2 : 4);
        const long frameLength = (long) _rows * _columns * _samplesPerPixel * depth;
        NSData *whole = [_values objectAtIndex: 0];
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
        // UseJPEGColorSpace is on (#1031); the stated one is back afterwards.
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
            NSMutableData *buffer = [NSMutableData dataWithLength: frameSize];
            OFCondition result = _pixel->getUncompressedFrame(dataset, index, startFragment, buffer.mutableBytes,
                                                              frameSize, model, NULL);
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
                                                      frameSize, model, NULL);
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
                if (bytes <= frameSize)
                {
                    startFragment = 0;
                    result = _pixel->getUncompressedFrame(dataset, index, startFragment, buffer.mutableBytes,
                                                          bytes, model, NULL);
                    if (result.good())
                        [buffer setLength: bytes];
                }
                dataset->putAndInsertUint16(DCM_BitsAllocated, allocated);
                dataset->putAndInsertUint16(DCM_HighBit, highBit);
            }
            if (result.good())
                data = buffer;
            else
                NSLog(@"DCMTK cannot decode frame %d (%@): %s", index, transferSyntax.transferSyntax, result.text());
        }
        if (data)
        {
            // A decoder that changed the colour model has converted it (JPEG
            // YBR to RGB, JPEG 2000 RCT/ICT), and JPEG, JPEG-LS and JPEG 2000
            // decode interleaved whatever Planar Configuration says. RLE
            // follows the attribute, as native data does.
            colorspaceIsConverted = colorspace && model.length() &&
                [colorspace isEqualToString: [NSString stringWithUTF8String: model.c_str()]] == NO;
            interleaved = DcmXfer(_file->getDataset()->getOriginalXfer()).getXfer() != EXS_RLELossless;
        }
    }
    if (data == nil)
        return nil;

    if (interleaved && [[_dcmObject attributeValueWithName: @"PlanarConfiguration"] intValue] > 0)
        [_dcmObject setAttributeValues: [NSMutableArray arrayWithObject: @0] forName: @"PlanarConfiguration"];

    if (([colorspace hasPrefix: @"YBR"] || [colorspace hasPrefix: @"PALETTE"]) && !colorspaceIsConverted)
        return [self convertDataToRGBColorSpace: data];
    int planes = [[_dcmObject attributeValueWithName: @"PlanarConfiguration"] intValue];
    if (planes > 0 && planes <= 4 && !interleaved)
        return [self interleavePlanesInData: data];
    return data;
}

- (NSMutableData *)createFrameAtIndex:(int)index
{
    if (_detached)
        return [super createFrameAtIndex: index];
    return [[[self decodeFrameAtIndex: index] mutableCopy] autorelease];
}

- (BOOL)convertToTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality
{
    NSArray *before = [[_values retain] autorelease];
    BOOL converted = [super convertToTransferSyntax: ts quality: quality];
    if (converted && _values != before)
    {
        _detached = YES;
        _pixel = NULL;
    }
    return converted;
}

@end

// ---- Objects ------------------------------------------------------------------------

@implementation HorosDCMTKObject
{
    HorosDCMTKFile _file;
}

+ (instancetype)objectWithContentsOfFile:(NSString *)path
{
    return [self objectWithContentsOfFile: path decodingPixelData: NO lastGroup: 0xFFFF];
}

// Reading stops at the first element of the group after `lastGroup`.
static DcmTagKey HorosStopTag(unsigned short lastGroup)
{
    return lastGroup == 0xFFFF ? DCM_UndefinedTagKey : DcmTagKey((Uint16) (lastGroup + 1), 0x0000);
}

+ (instancetype)objectWithContentsOfFile:(NSString *)path decodingPixelData:(BOOL)decodePixelData
                               lastGroup:(unsigned short)lastGroup
{
    if (path.length == 0)
        return nil;
    HorosDCMTKFile file = std::make_shared<DcmFileFormat>();
    OFCondition result = file->loadFileUntilTag(path.fileSystemRepresentation, EXS_Unknown, EGL_noChange,
                                                DCM_MaxReadLength, ERM_autoDetect, HorosStopTag(lastGroup));
    if (result.good())
        result = file->loadAllDataIntoMemory();
    if (result.bad())
    {
        NSLog(@"DCMTK cannot read %@: %s", path.lastPathComponent, result.text());
        return nil;
    }
    return [self objectWithFile: file decodingPixelData: decodePixelData];
}

+ (instancetype)objectWithData:(NSData *)data transferSyntax:(NSString *)transferSyntax
             decodingPixelData:(BOOL)decodePixelData lastGroup:(unsigned short)lastGroup
{
    if (data.length == 0)
        return nil;
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

+ (instancetype)objectWithDCMTKFile:(HorosDCMTKFile)file
{
    return [self objectWithFile: file decodingPixelData: NO];
}

+ (instancetype)objectWithFile:(HorosDCMTKFile)file decodingPixelData:(BOOL)decodePixelData
{
    HorosDCMTKObject *object = [[[self alloc] initWithFile: file item: file->getDataset() characterSet: nil
                                            transferSyntax: nil] autorelease];
    if (decodePixelData)
    {
        DCMPixelDataAttribute *pixels = (DCMPixelDataAttribute *) [object attributeWithName: @"PixelData"];
        if ([pixels isKindOfClass: [DCMPixelDataAttribute class]])
        {
            [pixels decodeData];
            object->_decodePixelData = pixels.isDecoded;
        }
    }
    return object;
}

- (instancetype)initWithFile:(HorosDCMTKFile)file item:(DcmItem *)item characterSet:(DCMCharacterSet *)inherited
              transferSyntax:(DCMTransferSyntax *)inheritedSyntax
{
    if (!(self = [super init]))
        return nil;
    const BOOL topLevel = inherited == nil;
    _decodePixelData = NO;
    if (topLevel)
    {
        _file = file;
        transferSyntax = [[DCMTransferSyntax alloc] initWithTS:
            [NSString stringWithUTF8String: DcmXfer(file->getDataset()->getOriginalXfer()).getXferID()]];
    }
    else
    {
        isSequence = YES;
        transferSyntax = [inheritedSyntax retain];
    }

    // An item may state its own Specific Character Set; otherwise it inherits
    // the one of what contains it, and a file that states none is ISO_IR 100.
    OFString code;
    if (item->findAndGetOFStringArray(DCM_SpecificCharacterSet, code).good() && code.length())
        specificCharacterSet = [[DCMCharacterSet alloc] initWithCode: HorosLatin1Text(code)];
    else
        specificCharacterSet = inherited ? [inherited retain] : [[DCMCharacterSet alloc] initWithCode: @"ISO_IR 100"];

    if (topLevel)
        [self addElementsOf: file->getMetaInfo() file: file];
    [self addElementsOf: item file: file];
    return self;
}

- (void)addElementsOf:(DcmItem *)item file:(HorosDCMTKFile)file
{
    for (unsigned long i = 0; i < item->card(); i++)
    {
        DcmElement *element = item->getElement(i);
        if (element == NULL)
            continue;
        const DcmTag &key = element->getTag();
        DCMAttributeTag *tag = [DCMAttributeTag tagWithGroup: key.getGTag() element: key.getETag()];
        NSString *vr = [NSString stringWithUTF8String: DcmVR(element->getVR()).getValidVRName()];
        tag.vr = vr;
        DCMAttribute *attribute = nil;
        if (element->ident() == EVR_SQ)
        {
            DcmSequenceOfItems *sequence = static_cast<DcmSequenceOfItems *>(element);
            DCMSequenceAttribute *sequenceAttribute = [[[DCMSequenceAttribute alloc] initWithAttributeTag: tag] autorelease];
            for (unsigned long j = 0; j < sequence->card(); j++)
            {
                HorosDCMTKObject *object = [[HorosDCMTKObject alloc] initWithFile: file item: sequence->getItem(j)
                                                                      characterSet: specificCharacterSet
                                                                    transferSyntax: transferSyntax];
                [sequenceAttribute addItem: object];
                [object release];
            }
            attribute = sequenceAttribute;
        }
        else if (element->ident() == EVR_PixelData && isSequence == NO && key == DCM_PixelData)
        {
            attribute = [[[HorosDCMTKPixelData alloc] initWithFile: file pixel: static_cast<DcmPixelData *>(element)
                                                               tag: tag object: self
                                                    transferSyntax: transferSyntax] autorelease];
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
        [attributes setObject: attribute forKey: tag.stringValue];
    }
}

@end
