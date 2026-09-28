#import "HorosDICOMServices.h"

#undef verify

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcvrda.h>
#include <dcmtk/dcmdata/dcvrtm.h>
#include <dcmtk/dcmdata/dcvrdt.h>
#include <dcmtk/dcmdata/dcspchrs.h>
#include <cmath>

@implementation HorosDICOMTransferSyntaxes

+ (NSDictionary *)propertiesForTransferSyntax:(NSString *)uid
{
    if (uid.length == 0)
        return nil;
    DcmXfer xfer(uid.UTF8String);
    if (xfer.getXfer() == EXS_Unknown)
        return nil;
    // The names the DCM Framework gave the syntaxes it knew; they are what
    // DCMTransferSyntax -name and -description have always answered.
    static NSDictionary *formerNames;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formerNames = [@{
        @"1.2.840.10008.1.2.2": @"ExplicitVRBigEndian", @"1.2.840.10008.1.2.1": @"ExplicitVRLittleEndian",
        @"1.2.840.10008.1.2": @"ImplicitVRLittleEndian", @"1.2.840.10008.1.2.4.55": @"JPEG1012Retired",
        @"1.2.840.10008.1.2.4.56": @"JPEG1113Retired", @"1.2.840.10008.1.2.4.59": @"JPEG1618Retired",
        @"1.2.840.10008.1.2.4.60": @"JPEG1719Retired", @"1.2.840.10008.1.2.4.90": @"JPEG2000Lossless",
        @"1.2.840.10008.1.2.4.91": @"JPEG2000Lossy", @"1.2.840.10008.1.2.4.61": @"JPEG2022Retired",
        @"1.2.840.10008.1.2.4.62": @"JPEG2123Retired", @"1.2.840.10008.1.2.4.63": @"JPEG2426Retired",
        @"1.2.840.10008.1.2.4.64": @"JPEG2527Retired", @"1.2.840.10008.1.2.4.66": @"JPEG29Retired",
        @"1.2.840.10008.1.2.4.53": @"JPEG68Retired", @"1.2.840.10008.1.2.4.54": @"JPEG79Retired",
        @"1.2.840.10008.1.2.4.50": @"JPEGBaseline", @"1.2.840.10008.1.2.4.51": @"JPEGExtended",
        @"1.2.840.10008.1.2.4.52": @"JPEGExtended35Retired", @"1.2.840.10008.1.2.4.65": @"JPEGLoRetired",
        @"1.2.840.10008.1.2.4.70": @"JPEGLossless", @"1.2.840.10008.1.2.4.57": @"JPEGLossless14",
        @"1.2.840.10008.1.2.4.58": @"JPEGLossless15Retired", @"1.2.840.10008.1.2.4.80": @"JPEGLSLossless",
        @"1.2.840.10008.1.2.4.81": @"JPEGLSLossy", @"1.2.840.10008.1.2.5": @"RLELossless",
    } retain]; });
    NSString *name = formerNames[uid];
    if (name == nil)
    {
        NSMutableString *spelled = [NSMutableString string];
        for (NSString *word in [[NSString stringWithUTF8String: xfer.getXferName()]
                                   componentsSeparatedByCharactersInSet: [[NSCharacterSet alphanumericCharacterSet] invertedSet]])
            [spelled appendString: word];
        name = spelled;
    }
    return @{@"isEncapsulated": @(xfer.isEncapsulated() ? YES : NO), @"isLittleEndian": @(xfer.isLittleEndian() ? YES : NO),
             @"isExplicit": @(xfer.isExplicitVR() ? YES : NO), @"Name": name, @"TransferSyntax": uid};
}

@end

static OFString HorosTrimmed(NSString *value)
{
    NSString *trimmed = [value stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const char *text = trimmed.UTF8String;
    return OFString(text ? text : "");
}

static unsigned long HorosMicroseconds(double seconds)
{
    const double fraction = seconds - std::floor(seconds);
    const long value = std::lround(fraction * 1e6);
    return value < 0 ? 0 : (value > 999999 ? 999999 : (unsigned long) value);
}

@implementation HorosDICOMDates

+ (NSString *)canonicalDate:(NSString *)dicomDate
{
    OFDate date;
    if (dicomDate.length == 0 || DcmDate::getOFDateFromString(HorosTrimmed(dicomDate), date, OFTrue).bad())
        return nil;
    return [NSString stringWithFormat: @"%04u%02u%02u", date.getYear(), date.getMonth(), date.getDay()];
}

+ (NSString *)canonicalTime:(NSString *)dicomTime microseconds:(unsigned long *)microseconds
{
    OFTime time;
    const OFString text = HorosTrimmed(dicomTime);
    if (text.empty() || DcmTime::getOFTimeFromString(text.c_str(), text.length(), time, OFTrue).bad())
        return nil;
    if (microseconds)
        *microseconds = HorosMicroseconds(time.getSecond());
    return [NSString stringWithFormat: @"%02u%02u%02u", time.getHour(), time.getMinute(), (unsigned) std::floor(time.getSecond())];
}

+ (NSString *)canonicalDateTime:(NSString *)dicomDateTime microseconds:(unsigned long *)microseconds
                timeZoneSeconds:(NSInteger *)timeZoneSeconds hasTimeZone:(BOOL *)hasTimeZone
{
    OFDateTime value;
    const OFString text = HorosTrimmed(dicomDateTime);
    if (text.empty() || DcmDateTime::getOFDateTimeFromString(text, value).bad())
        return nil;
    const OFDate &date = value.getDate();
    const OFTime &time = value.getTime();
    if (microseconds)
        *microseconds = HorosMicroseconds(time.getSecond());
    // DCMTK reports an offset of zero when the value states none; whether one
    // is stated is in the text: &ZZXX at its end.
    const double zone = time.getTimeZone();
    const size_t sign = text.find_last_of("+-");
    const BOOL stated = sign != OFString_npos && sign > 0 && text.length() - sign == 5;
    if (hasTimeZone)
        *hasTimeZone = stated;
    if (stated && timeZoneSeconds)
        *timeZoneSeconds = (NSInteger) std::lround(zone * 3600.0);
    return [NSString stringWithFormat: @"%04u%02u%02u%02u%02u%02u", date.getYear(), date.getMonth(), date.getDay(),
            time.getHour(), time.getMinute(), (unsigned) std::floor(time.getSecond())];
}

@end

@implementation HorosDICOMCharacterSets

+ (NSString *)stringWithBytes:(const char *)bytes length:(NSUInteger)length characterSet:(NSString *)specificCharacterSet
{
    if (bytes == NULL)
        return nil;
    DcmSpecificCharacterSet converter;
    const char *code = specificCharacterSet.UTF8String;
    if (converter.selectCharacterSet(OFString(code ? code : "")).bad())
        return nil;
    OFString utf8;
    // Backslash, caret and equals delimit values, name components and name
    // groups; an ISO 2022 escape does not carry across them.
    if (converter.convertString(OFString(bytes, length), utf8, "\\^=").bad())
        return nil;
    return [[[NSString alloc] initWithBytes: utf8.c_str() length: utf8.length() encoding: NSUTF8StringEncoding] autorelease];
}

@end
