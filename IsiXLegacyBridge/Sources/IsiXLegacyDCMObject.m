//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.
//
// The legacy DCM framework's objects, kept as lean as plugins use them: a
// dataset of attributes by tag, read and written by the kit's coder
// (IsiXLegacyDICOMCoding.swift) in uncompressed little endian.

#import "IsiXLegacyBridgeInternal.h"

@interface IsiXLegacyDCMAttributeTag (IsiXLegacyCoding)
- (uint32_t) isixTag;
@end

@interface IsiXLegacyDCMCalendarDate (IsiXLegacyCoding)
- (instancetype) initWithValue: (NSString*) v kind: (NSString*) k;
@end

@interface IsiXLegacyDCMAttribute (IsiXLegacyCoding)
- (IsiXLegacyDICOMElement*) isixElement;
@end

static NSString *TagString(uint32_t tag) { return [NSString stringWithFormat: @"%04X,%04X", tag >> 16, tag & 0xFFFF]; }

#pragma mark - DCMTransferSyntax

@implementation IsiXLegacyDCMTransferSyntax

@synthesize transferSyntax;

- (instancetype) initWithTS: (NSString*) uid
{
    if (!(self = [super init])) return nil;
    transferSyntax = [uid copy];
    return self;
}

+ (instancetype) ExplicitVRLittleEndianTransferSyntax { return [[self alloc] initWithTS: @"1.2.840.10008.1.2.1"]; }
+ (instancetype) ImplicitVRLittleEndianTransferSyntax { return [[self alloc] initWithTS: @"1.2.840.10008.1.2"]; }
+ (instancetype) OsiriXTransferSyntax { return [self ExplicitVRLittleEndianTransferSyntax]; }

- (BOOL) isExplicit { return ![transferSyntax isEqualToString: @"1.2.840.10008.1.2"]; }
- (BOOL) isLittleEndian { return ![transferSyntax isEqualToString: @"1.2.840.10008.1.2.2"]; }
- (BOOL) isEncapsulated
{
    return ![@[@"1.2.840.10008.1.2", @"1.2.840.10008.1.2.1", @"1.2.840.10008.1.2.2", @"1.2.840.10008.1.2.1.99"] containsObject: transferSyntax];
}

- (NSString*) name
{
    if ([transferSyntax isEqualToString: @"1.2.840.10008.1.2"]) return @"Implicit VR Little Endian";
    if ([transferSyntax isEqualToString: @"1.2.840.10008.1.2.1"]) return @"Explicit VR Little Endian";
    return transferSyntax;
}

- (BOOL) isEqualToTransferSyntax: (IsiXLegacyDCMTransferSyntax*) other { return [transferSyntax isEqualToString: other.transferSyntax]; }
- (BOOL) isEqual: (id) other { return [other isKindOfClass: [IsiXLegacyDCMTransferSyntax class]] && [self isEqualToTransferSyntax: other]; }
- (NSUInteger) hash { return transferSyntax.hash; }
- (id) copyWithZone: (NSZone*) zone { return self; }
- (NSString*) description { return self.name; }

@end

#pragma mark - DCMAttributeTag

@implementation IsiXLegacyDCMAttributeTag

@synthesize group, element;

- (instancetype) initWithGroup: (int) g element: (int) e
{
    if (!(self = [super init])) return nil;
    group = g;
    element = e;
    return self;
}

+ (instancetype) tagWithGroup: (int) g element: (int) e { return [[self alloc] initWithGroup: g element: e]; }

+ (instancetype) tagWithName: (NSString*) name
{
    NSNumber *tag = name ? [IsiXLegacyDICOMCoder tagForName: name] : nil;
    return tag ? [self tagWithGroup: tag.unsignedIntValue >> 16 element: tag.unsignedIntValue & 0xFFFF] : nil;
}

+ (instancetype) tagWithTagString: (NSString*) tagString
{
    NSString *text = [tagString stringByTrimmingCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @"() "]];
    NSArray *parts = [text componentsSeparatedByString: @","];
    if (parts.count != 2) return nil;
    unsigned values[2];
    for (int i = 0; i < 2; i++)
    {
        NSString *part = [parts[i] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
        NSScanner *scanner = [NSScanner scannerWithString: part];
        if (part.length != 4 || ![scanner scanHexInt: &values[i]] || !scanner.isAtEnd) return nil;
    }
    return [self tagWithGroup: (int) values[0] element: (int) values[1]];
}

- (uint32_t) isixTag { return ((uint32_t) group << 16) | ((uint32_t) element & 0xFFFF); }
- (NSString*) stringValue { return TagString(self.isixTag); }
- (long) longValue { return (long) self.isixTag; }
- (NSString*) name { return [IsiXLegacyDICOMCoder nameForTag: self.isixTag]; }
- (NSString*) vr { return [IsiXLegacyDICOMCoder vrForTag: self.isixTag]; }
- (BOOL) isPrivate { return group % 2 == 1; }
- (BOOL) isEqualToTag: (IsiXLegacyDCMAttributeTag*) tag { return tag.group == group && tag.element == element; }
- (BOOL) isEqual: (id) other { return [other isKindOfClass: [IsiXLegacyDCMAttributeTag class]] && [self isEqualToTag: other]; }
- (NSUInteger) hash { return self.isixTag; }
- (id) copyWithZone: (NSZone*) zone { return self; }
- (NSString*) description { return [NSString stringWithFormat: @"(%@) %@", self.stringValue, self.name ?: @""]; }

@end

#pragma mark - DCMCalendarDate

@implementation IsiXLegacyDCMCalendarDate
{
    NSString *value, *kind;
}

- (instancetype) initWithValue: (NSString*) v kind: (NSString*) k
{
    if (!(self = [super init])) return nil;
    value = [[v stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] copy] ?: @"";
    kind = k;
    return self;
}

+ (instancetype) dicomDate: (NSString*) string { return [[self alloc] initWithValue: string kind: @"DA"]; }
+ (instancetype) dicomTime: (NSString*) string { return [[self alloc] initWithValue: string kind: @"TM"]; }
+ (instancetype) dicomDateTime: (NSString*) string { return [[self alloc] initWithValue: string kind: @"DT"]; }

+ (instancetype) dateWithDate: (NSDate*) date
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMddHHmmss.SSSSSS";
    return [self dicomDateTime: [formatter stringFromDate: date]];
}

- (BOOL) isQuery { return [value containsString: @"-"]; }

- (NSDate*) date
{
    NSString *text = [kind isEqualToString: @"TM"] ? [@"19700101" stringByAppendingString: value] : value;
    NSString *digits = [[text componentsSeparatedByString: @"."] firstObject];
    NSArray *formats = @[@"yyyyMMddHHmmss", @"yyyyMMddHHmm", @"yyyyMMddHH", @"yyyyMMdd"];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
    for (NSString *format in formats)
    {
        if (digits.length != format.length) continue;
        formatter.dateFormat = format;
        NSDate *date = [formatter dateFromString: digits];
        if (date) return date;
    }
    return nil;
}

- (NSString*) dateString { return value.length >= 8 && ![kind isEqualToString: @"TM"] ? [value substringToIndex: 8] : value; }
- (NSString*) timeString { return [kind isEqualToString: @"DT"] && value.length > 8 ? [value substringFromIndex: 8] : value; }
- (NSString*) dateTimeString: (BOOL) withTime { return withTime ? value : self.dateString; }
- (NSString*) description { return value; }
- (NSString*) isixKind { return kind; }
- (NSTimeInterval) timeIntervalSinceReferenceDate { return self.date.timeIntervalSinceReferenceDate; }
- (id) copyWithZone: (NSZone*) zone { return self; }
- (BOOL) isEqual: (id) other { return [other isKindOfClass: [IsiXLegacyDCMCalendarDate class]] && [[other description] isEqualToString: value]; }
- (NSUInteger) hash { return value.hash; }

@end

#pragma mark - DCMAttribute

@implementation IsiXLegacyDCMAttribute
{
    IsiXLegacyDCMAttributeTag *tag;
}

@synthesize vr, values;

- (instancetype) initWithAttributeTag: (IsiXLegacyDCMAttributeTag*) t vr: (NSString*) v values: (NSMutableArray*) vs
{
    if (!(self = [super init])) return nil;
    tag = t;
    vr = [v copy] ?: t.vr;
    values = vs ? [vs mutableCopy] : [NSMutableArray array];
    return self;
}

- (instancetype) initWithAttributeTag: (IsiXLegacyDCMAttributeTag*) t vr: (NSString*) v { return [self initWithAttributeTag: t vr: v values: nil]; }
- (instancetype) initWithAttributeTag: (IsiXLegacyDCMAttributeTag*) t { return [self initWithAttributeTag: t vr: nil values: nil]; }
+ (instancetype) attributeWithAttributeTag: (IsiXLegacyDCMAttributeTag*) t { return [[self alloc] initWithAttributeTag: t]; }
+ (instancetype) attributeWithAttributeTag: (IsiXLegacyDCMAttributeTag*) t vr: (NSString*) v { return [[self alloc] initWithAttributeTag: t vr: v]; }
+ (instancetype) attributeWithAttributeTag: (IsiXLegacyDCMAttributeTag*) t values: (NSArray*) vs
{
    return [[self alloc] initWithAttributeTag: t vr: nil values: [vs mutableCopy]];
}

- (IsiXLegacyDCMAttributeTag*) attrTag { return tag; }
- (NSString*) attrName { return tag.name; }
- (long) valueMultiplicity { return (long) values.count; }
- (id) value { return values.firstObject; }
- (void) addValue: (id) v { if (v) [values addObject: v]; }
- (void) setValues: (NSMutableArray*) vs { values = vs ? [vs mutableCopy] : [NSMutableArray array]; }

- (NSString*) valuesAsString
{
    NSMutableArray *texts = [NSMutableArray array];
    for (id v in values) [texts addObject: [v description] ?: @""];
    return [texts componentsJoinedByString: @"\\"];
}

- (id) copyWithZone: (NSZone*) zone { return [[[self class] alloc] initWithAttributeTag: tag vr: vr values: values]; }
- (NSString*) description { return [NSString stringWithFormat: @"%@ %@ %@", tag, vr, self.valuesAsString]; }

/// The element the coder writes: dates as their DICOM text.
- (IsiXLegacyDICOMElement*) isixElement
{
    NSMutableArray *written = [NSMutableArray array];
    for (id v in values)
    {
        if ([v isKindOfClass: [IsiXLegacyDCMCalendarDate class]] || [v isKindOfClass: [IsiXLegacyDCMAttributeTag class]]) [written addObject: [v description]];
        else if ([v isKindOfClass: [NSDate class]]) [written addObject: [[IsiXLegacyDCMCalendarDate dateWithDate: v] dateTimeString: [vr isEqualToString: @"DT"]]];
        else [written addObject: v];
    }
    return [[IsiXLegacyDICOMElement alloc] initWithTag: [tag isixTag] vr: vr values: written];
}

@end

#pragma mark - DCMPixelDataAttribute

@implementation IsiXLegacyDCMPixelDataAttribute
{
    IsiXLegacyDCMTransferSyntax *syntax;
}

- (instancetype) initWithAttributeTag: (IsiXLegacyDCMAttributeTag*) t vr: (NSString*) v length: (long) vl data: (id) data specificCharacterSet: (id) specificCharacterSet transferSyntax: (IsiXLegacyDCMTransferSyntax*) ts dcmObject: (IsiXLegacyDCMObject*) dcmObject decodeData: (BOOL) decodeData
{
    if (!(self = [super initWithAttributeTag: t vr: v values: nil])) return nil;
    syntax = ts;
    if ([data isKindOfClass: [NSData class]]) [self.values addObject: [data mutableCopy]];
    return self;
}

- (IsiXLegacyDCMTransferSyntax*) transferSyntax { return syntax; }
- (long) numberOfFrames { return (long) self.values.count; }
- (void) addFrame: (NSMutableData*) data { if (data) [self.values addObject: data]; }

- (NSMutableData*) decodeFrameAtIndex: (long) index
{
    return index >= 0 && index < (long) self.values.count ? [self.values[(NSUInteger) index] mutableCopy] : nil;
}

- (IsiXLegacyDICOMElement*) isixElement
{
    NSMutableData *all = [NSMutableData data];
    for (NSData *frame in self.values) if ([frame isKindOfClass: [NSData class]]) [all appendData: frame];
    return [[IsiXLegacyDICOMElement alloc] initWithTag: [self.attrTag isixTag] vr: self.vr ?: @"OW" values: @[all]];
}

@end

#pragma mark - DCMObject

@implementation IsiXLegacyDCMObject

@synthesize attributes, transferSyntax;

- (instancetype) init
{
    if (!(self = [super init])) return nil;
    attributes = [NSMutableDictionary dictionary];
    transferSyntax = [IsiXLegacyDCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
    return self;
}

- (instancetype) initWithData: (NSData*) data decodingPixelData: (BOOL) decodePixelData
{
    IsiXLegacyDICOMDataset *dataset = data ? [IsiXLegacyDICOMCoder read: data] : nil;
    if (!dataset || !(self = [self init])) return nil;
    transferSyntax = [[IsiXLegacyDCMTransferSyntax alloc] initWithTS: dataset.transferSyntax];
    for (IsiXLegacyDICOMElement *element in dataset.elements)
    {
        IsiXLegacyDCMAttributeTag *t = [IsiXLegacyDCMAttributeTag tagWithGroup: element.tag >> 16 element: element.tag & 0xFFFF];
        NSMutableArray *vs = [NSMutableArray array];
        for (id v in element.values)
        {
            if ([v isKindOfClass: [IsiXLegacyDICOMDate class]])
            {
                IsiXLegacyDICOMDate *date = v;
                [vs addObject: [[IsiXLegacyDCMCalendarDate alloc] initWithValue: date.value kind: date.kind]];
            }
            else [vs addObject: v];
        }
        IsiXLegacyDCMAttribute *attribute = element.tag == 0x7FE00010
            ? [[IsiXLegacyDCMPixelDataAttribute alloc] initWithAttributeTag: t vr: element.vr length: 0 data: vs.firstObject specificCharacterSet: nil transferSyntax: transferSyntax dcmObject: self decodeData: decodePixelData]
            : [[IsiXLegacyDCMAttribute alloc] initWithAttributeTag: t vr: element.vr values: vs];
        attributes[TagString(element.tag)] = attribute;
    }
    return self;
}

- (instancetype) initWithContentsOfFile: (NSString*) file decodingPixelData: (BOOL) decodePixelData
{
    return [self initWithData: file ? [NSData dataWithContentsOfFile: file options: NSDataReadingMappedIfSafe error: NULL] : nil
            decodingPixelData: decodePixelData];
}

+ (instancetype) objectWithContentsOfFile: (NSString*) file decodingPixelData: (BOOL) decodePixelData
{
    return [[self alloc] initWithContentsOfFile: file decodingPixelData: decodePixelData];
}

+ (instancetype) objectWithData: (NSData*) data decodingPixelData: (BOOL) decodePixelData
{
    return [[self alloc] initWithData: data decodingPixelData: decodePixelData];
}

+ (BOOL) isDICOM: (NSData*) data
{
    return data.length >= 132 && memcmp((const char*) data.bytes + 128, "DICM", 4) == 0;
}

+ (instancetype) objectFromObject: (IsiXLegacyDCMObject*) object { return [object copy]; }

- (id) copyWithZone: (NSZone*) zone
{
    IsiXLegacyDCMObject *copy = [[[self class] alloc] init];
    for (NSString *key in attributes) copy.attributes[key] = [attributes[key] copy];
    copy.transferSyntax = transferSyntax;
    return copy;
}

+ (instancetype) secondaryCaptureObjectWithBitDepth: (int) depth samplesPerPixel: (int) spp numberOfFrames: (int) frames
{
    IsiXLegacyDCMObject *object = [[self alloc] init];
    NSString *now = [[IsiXLegacyDCMCalendarDate dateWithDate: [NSDate date]] description];
    NSString *date = [now substringToIndex: 8], *time = [now substringFromIndex: 8];
    // The class as the legacy framework chose it; the pixel module is the plugin's to set.
    NSString *sopClass = @"1.2.840.10008.5.1.4.1.1.7";
    if (frames > 1)
        sopClass = spp > 1 ? @"1.2.840.10008.5.1.4.1.1.7.4" : depth < 8 ? @"1.2.840.10008.5.1.4.1.1.7.1"
                 : depth == 8 ? @"1.2.840.10008.5.1.4.1.1.7.2" : @"1.2.840.10008.5.1.4.1.1.7.3";
    NSDictionary *values = @{@"SOPClassUID": sopClass,
                             @"SOPInstanceUID": [IsiXLegacyDatabaseBridge freshUID],
                             @"StudyInstanceUID": [IsiXLegacyDatabaseBridge freshUID],
                             @"SeriesInstanceUID": [IsiXLegacyDatabaseBridge freshUID],
                             @"StudyDate": [IsiXLegacyDCMCalendarDate dicomDate: date], @"StudyTime": [IsiXLegacyDCMCalendarDate dicomTime: time],
                             @"SeriesDate": [IsiXLegacyDCMCalendarDate dicomDate: date], @"SeriesTime": [IsiXLegacyDCMCalendarDate dicomTime: time],
                             @"AcquisitionDate": [IsiXLegacyDCMCalendarDate dicomDate: date],
                             @"AcquisitionTime": [IsiXLegacyDCMCalendarDate dicomTime: time],
                             @"Modality": @"SC", @"ConversionType": @"WSD"};
    for (NSString *name in values) [object setAttributeValues: [NSMutableArray arrayWithObject: values[name]] forName: name];
    return object;
}

- (IsiXLegacyDCMAttribute*) attributeForTag: (IsiXLegacyDCMAttributeTag*) t { return t ? attributes[t.stringValue] : nil; }
- (IsiXLegacyDCMAttribute*) attributeWithName: (NSString*) name { return [self attributeForTag: [IsiXLegacyDCMAttributeTag tagWithName: name]]; }
- (id) attributeValueWithName: (NSString*) name { return [[self attributeWithName: name] value]; }
- (NSArray*) attributeArrayWithName: (NSString*) name { return [[self attributeWithName: name] values]; }

- (id) attributeValueForKey: (NSString*) key
{
    IsiXLegacyDCMAttributeTag *t = [IsiXLegacyDCMAttributeTag tagWithTagString: key] ?: [IsiXLegacyDCMAttributeTag tagWithName: key];
    return [[self attributeForTag: t] value];
}

- (void) setAttribute: (IsiXLegacyDCMAttribute*) attribute { if (attribute.attrTag) attributes[attribute.attrTag.stringValue] = attribute; }
- (void) removeAttribute: (IsiXLegacyDCMAttribute*) attribute { [self removeAttributeForTag: attribute.attrTag]; }
- (void) removeAttributeForTag: (IsiXLegacyDCMAttributeTag*) t { if (t) [attributes removeObjectForKey: t.stringValue]; }
- (BOOL) isNeedToCompress { return NO; }

- (void) setAttributeValues: (NSMutableArray*) vs forKey: (NSString*) key
{
    IsiXLegacyDCMAttributeTag *t = [IsiXLegacyDCMAttributeTag tagWithTagString: key] ?: [IsiXLegacyDCMAttributeTag tagWithName: key];
    if (!t)
    {
        [[IsiXLegacyDatabaseBridge shared] fail: [NSString stringWithFormat: @"DCMObject: the kit does not know the attribute %@.", key]];
        return;
    }
    IsiXLegacyDCMAttribute *existing = attributes[t.stringValue];
    if (existing) existing.values = vs;
    else attributes[t.stringValue] = [[IsiXLegacyDCMAttribute alloc] initWithAttributeTag: t vr: nil values: vs];
}

- (void) setAttributeValues: (NSMutableArray*) vs forName: (NSString*) name { [self setAttributeValues: vs forKey: name]; }

/// The elements to write. With pixel data, the number of frames is the
/// number of frames the plugin added, and the pixel representation
/// unsigned unless the plugin said otherwise.
- (NSArray<IsiXLegacyDICOMElement*>*) isixElements
{
    NSMutableDictionary *written = [attributes mutableCopy];
    IsiXLegacyDCMPixelDataAttribute *pixelData = written[@"7FE0,0010"];
    if ([pixelData isKindOfClass: [IsiXLegacyDCMPixelDataAttribute class]])
    {
        IsiXLegacyDCMAttributeTag *frames = [IsiXLegacyDCMAttributeTag tagWithName: @"NumberOfFrames"];
        written[frames.stringValue] = [[IsiXLegacyDCMAttribute alloc] initWithAttributeTag: frames vr: @"IS"
                                                                                   values: [NSMutableArray arrayWithObject: @(MAX(pixelData.numberOfFrames, 1))]];
        IsiXLegacyDCMAttributeTag *representation = [IsiXLegacyDCMAttributeTag tagWithName: @"PixelRepresentation"];
        if (!written[representation.stringValue])
            written[representation.stringValue] = [[IsiXLegacyDCMAttribute alloc] initWithAttributeTag: representation vr: @"US"
                                                                                               values: [NSMutableArray arrayWithObject: @0]];
    }
    NSMutableArray *elements = [NSMutableArray array];
    for (IsiXLegacyDCMAttribute *attribute in written.allValues) [elements addObject: [attribute isixElement]];
    return elements;
}

- (NSData*) writeDatasetWithTransferSyntax: (IsiXLegacyDCMTransferSyntax*) ts quality: (int) quality
{
    NSString *syntax = ts.transferSyntax ?: transferSyntax.transferSyntax;
    NSData *data = [IsiXLegacyDICOMCoder fileDataWithElements: [self isixElements] transferSyntax: syntax];
    if (!data)
        [[IsiXLegacyDatabaseBridge shared] fail: [NSString stringWithFormat: @"DCMObject: the kit writes uncompressed little endian files only, not %@.", syntax]];
    return data;
}

- (BOOL) writeToFile: (NSString*) path withTransferSyntax: (IsiXLegacyDCMTransferSyntax*) ts quality: (int) quality AET: (NSString*) aet atomically: (BOOL) atomically
{
    NSData *data = [self writeDatasetWithTransferSyntax: ts quality: quality];
    return data && [data writeToFile: path atomically: atomically];
}

- (BOOL) writeToFile: (NSString*) path withTransferSyntax: (IsiXLegacyDCMTransferSyntax*) ts quality: (int) quality atomically: (BOOL) atomically
{
    return [self writeToFile: path withTransferSyntax: ts quality: quality AET: nil atomically: atomically];
}

- (NSString*) description
{
    NSMutableString *text = [NSMutableString stringWithFormat: @"<DCMObject %@>", transferSyntax.name];
    for (NSString *key in [attributes.allKeys sortedArrayUsingSelector: @selector(compare:)])
        [text appendFormat: @"\n%@", attributes[key]];
    return text;
}

@end
