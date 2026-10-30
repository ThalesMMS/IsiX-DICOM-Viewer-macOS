#!/usr/bin/env python3
"""The DICOM value types of IsiXDICOMFile answer what DCM.framework's did.

Dates (DA, TM, DT, query ranges, the fixed formats), SOP classes, Specific
Character Sets and attribute tags moved from DCM.framework (DCMCalendarDate,
DCMAbstractSyntaxUID, DCMCharacterSet, DCMAttributeTag and its dictionaries)
to Swift types of the IsiXDICOMFile module. This compiles the framework's
Objective-C of the last revision that has it (`git show`, or `--reference`),
and the module with swiftc, into one driver, and asks both the same synthetic
questions:

* dates: every factory on valid, partial, padded, fractional, zoned and invalid
  values; every string, component and number they give; calendar arithmetic
  across daylight saving time; the fixed-format strings the app writes
  (`HorosDateString` of the former Horos.m); copies; keyed archives, which
  must be the same bytes, under the same class name;
* SOP classes: every predicate on every UID the former table named, on prefixes,
  nil and empty values; every list; with and without the preferences that add
  and hide displayed classes;
* character sets: the encoding of every term in its spellings, of unknown and
  multiple values, with and without DefaultCharacterSetWhenAbsent; the
  encodings of a value; text decoded through ISO 2022 escapes and person name
  delimiters;
* tags: every tag of the dictionary by group and element, every name (and its
  other 2011 spelling) of the dictionary, tag strings in their forms, private
  tags, comparison and equality.

Both sides run with the host's DCMTK services (`HorosDICOMDates`,
`HorosDICOMDictionaries`, compiled from Horos/Sources/Adapters/DCMTK against the
Debug build's DCMTK) and, in a second driver, without them, where both fall back
to their own text parsing and empty dictionaries. Exit 2 when the build or the
history is missing.
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORK = 'DCM Framework'
OLD_FILES = ['DCMCalendarDate', 'DCMAbstractSyntaxUID', 'DCMCharacterSet', 'DCMAttributeTag', 'DCMTagDictionary',
             'DCMTagForNameDictionary', 'DCMTagNameAlias']

parser = argparse.ArgumentParser()
parser.add_argument('--reference', help='revision of the former Objective-C (default: the last that has it)')
args = parser.parse_args()


def git(*command):
    return subprocess.run(['git', '-C', str(ROOT), *command], capture_output=True)


reference = args.reference
if reference is None:
    probe = FRAMEWORK + '/DCMCalendarDate.m'
    reference = 'HEAD' if git('cat-file', '-e', 'HEAD:' + probe).returncode == 0 else history_reference.before_removal(probe)
if reference is None:
    print('skipped: needs the history that has DCM.framework')
    sys.exit(2)


def old(path):
    shown = git('show', '%s:%s' % (reference, path))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (path, reference))
    return shown.stdout


horos_m = old('Horos/Sources/Horos.m') if git('cat-file', '-e', '%s:Horos/Sources/Horos.m' % reference).returncode == 0 \
    else history_reference.show(history_reference.before_removal('Horos/Sources/Horos.m'), 'Horos/Sources/Horos.m')
horos_m = horos_m.decode('latin1')
at = horos_m.index('NSString *HorosDateString(id date, NSString *format) {')
date_string = horos_m[at:horos_m.index('\n}\n', at) + 3].replace('HorosDateString(', 'OldHorosDateString(')

old_uids = sorted(set(re.findall(r'@"([0-9][0-9.]+)"', old(FRAMEWORK + '/DCMAbstractSyntaxUID.m').decode('latin1'))))

DATE_VALUES = ['20240229', '2024.02.29', '20240230', '202402', '2024', '19000101', '00000000', '2024022', ' 20240229',
               '20240229 ', 'invalid', '', '20240101-20240229', '-20240229', '20240229-', '20241302', '18991231',
               '20991231', '2024022a']
TIME_VALUES = ['101112', '101112.5', '101112.123456', '101112.1234567', '1011', '10', '10:11:12', '10:11:12.25',
               '246000', '235960', '000000', '000000.000001', '9', '1011121', 'invalid', '', '1010-1020', ' 101112',
               '101112 ', '101112.', '12:3:45']
DATETIME_VALUES = ['20240229101112', '20240229101112.25', '20240229101112.25+0130', '20240229101112-0500',
                   '20240229101112.123456-0030', '202402291011', '2024022910', '20240229', '202402', '2024',
                   '20241102013000', '20240310023000', '19991231235959.999999+0000', '20240229101112.1.2',
                   '2024022910111', 'invalid', '', '20240229101112+1400', '20240229101112+2500']
DATE_TIME_PAIRS = [('20261004', '103015'), ('20261004', '103015.5'), ('20261004', '10:30:15.25'), ('2026.10.04', '10'),
                   ('20261004', None), ('20261004', ''), ('20261004', '103075'), ('2022XX03', '103015'),
                   ('20261004', '1030151'), (' 20261004 ', ' 1030 '), ('20261004', '103015.1234567'), (None, '103015')]
STRING_FORMATS = [('20261004103015', '%Y%m%d%H%M%S'), ('20261004103015.123', '%Y%m%d%H%M%S'), ('2026100410301', '%Y%m%d%H%M%S'),
                  ('20261004256015', '%Y%m%d%H%M%S'), ('2026-10-04 10:30:15 +0200', '%Y-%m-%d %H:%M:%S %z'),
                  ('20261004', '%Y%m%d'), ("04 Oct 2026", '%d %b %Y'), ('10:30', '%H:%M'), ('', '%Y'), (None, '%Y')]
OUTPUT_FORMATS = ['%Y%m%d', '%H%M%S', '%Y%m%d%H%M%S', '%Y-%m-%d %H:%M:%S %z', '%Y:%m:%d %H:%M:%S', '%Y%m%d.%H%M%S',
                  '%d/%m/%Y', '%a %A %b %B %I %p %j %e %y %Z', '%H%M%S.%F', "%Y'%m'%d", '%Y%%m', '%Q']
INSTANTS = [796_552_200.0, 796_514_400.0, 793_800_000.5, 815_011_200.0, 0.25, -1_000_000_000.123456, 762_469_200.999999]
TERMS = ['ISO_IR 100', 'ISO 2022 IR 100', 'iso_ir 100', 'ISO-IR-100', 'ISO_IR 101', 'ISO_IR 109', 'ISO_IR 110',
         'ISO_IR 144', 'ISO_IR 127', 'ISO_IR 126', 'ISO_IR 138', 'ISO_IR 148', 'ISO_IR 166', 'ISO_IR 13', 'ISO 2022 IR 13',
         'ISO 2022 IR 87', 'ISO 2022 IR 159', 'ISO 2022 IR 149', 'ISO 2022 IR 58', 'ISO_IR 192', 'GB18030', 'GBK',
         'ISO_IR 6', 'ISO 2022 IR 6', 'UTF-8', 'utf_8', 'WINDOWS-1251', 'windows_1250', 'CP1252', 'cp1253', 'WINDOWS 1254',
         'CP1255', 'CP1256', 'WINDOWS-1257', 'CP1258', 'KOI8-R', '', 'ISO_IR 100\\ISO_IR 144', '\\ISO 2022 IR 87',
         'ISO 2022 IR 6\\ISO 2022 IR 87', 'X' * 60 + '\\ISO_IR 100']
CODES = ['ISO_IR 100', 'ISO 2022 IR 6\\ISO 2022 IR 87', '\\ISO 2022 IR 149', 'ISO_IR 192', '',
         'A\\B\\C\\D\\E\\F\\G\\H\\I\\J\\K\\L', 'ISO 2022 IR 6\\ISO 2022 IR 13\\ISO 2022 IR 87']
# Text bytes, as hex, with the character set value they are read in.
TEXTS = [('ISO_IR 100', 'Jos\\xe9^Mar\\xeda'),
         ('ISO 2022 IR 6\\ISO 2022 IR 87', 'Yamada^Tarou=\\x1b$B;3ED\\x1b(B^\\x1b$BB@O:\\x1b(B=\\x1b$B$d$^$@\\x1b(B^\\x1b$B$?$m$&\\x1b(B'),
         ('\\ISO 2022 IR 149', 'Hong^Gildong=\\x1b$)C\\xfb\\xf3^\\x1b$)C\\xd1\\xce\\xd4\\xd7'),
         ('ISO 2022 IR 6\\ISO 2022 IR 13', '\\x1b)I\\xd4\\xcf\\xc0\\xde^\\x1b(B\\xc0\\xdb\\xb3'),
         ('ISO 2022 IR 6\\ISO 2022 IR 144', 'abc\\x1b-L\\xbb\\xee\\xdace\\rdef\\nghi'),
         ('ISO_IR 100', 'trailing\\x1b'), ('ISO_IR 100', 'esc\\x1b$('), ('ISO_IR 100', 'esc\\x1b$(D'),
         ('ISO_IR 100', 'unknown\\x1b%Gx'), ('ISO_IR 100', '')]
TAG_STRINGS = ['0010,0010', '(0010,0010)', '0008,103E', '0008,103e', '0008, 103E', '7FE0,0010', '0029,1010', 'FFFE,E000',
               'nonsense', '', '0x0010,0x0020', '10,10', '00100010']
NAMES_EXTRA = ['PatientsName', 'PatientName', 'ReferringPhysiciansName', 'ReferringPhysicianName', 'PatientsBirthDate',
               'PatientsSex', 'PerformingPhysiciansName', 'PatientsAddress', 'NotAName', '', 'PatientsAge',
               'PatientsSize', 'PhysiciansOfRecord', 'SamplesperPixel', 'SamplesPerPixel', 'NumberofFrames']


def objc_string(value):
    if value is None:
        return 'nil'
    return '@"%s"' % value.replace('\\', '\\\\').replace('"', '\\"')


def objc_array(values):
    return '@[%s]' % ', '.join(objc_string(v) for v in values)


def c_bytes(text):
    """A C string literal of the bytes `text` spells with \\xHH escapes, every byte octal."""
    data = text.encode('latin1').decode('unicode_escape').encode('latin1')
    return '"%s"' % ''.join('\\%03o' % byte for byte in data)


DRIVER = r'''
#import <Foundation/Foundation.h>
#import "DCMCalendarDate.h"
#import "DCMAbstractSyntaxUID.h"
#import "DCMCharacterSet.h"
#import "DCMAttributeTag.h"
#import "DCMTagDictionary.h"
#import "DCMTagForNameDictionary.h"
#import "DCMTagNameAlias.h"
#import "IsiXDICOMFile-Swift.h"

NSString *OldHorosDateString(id date, NSString *format);
static const char *field(id value)
{
    NSString *text = [value description];
    if (text == nil) return "(null)";
    text = [[text stringByReplacingOccurrencesOfString: @"\n" withString: @"\\n"] stringByReplacingOccurrencesOfString: @"\t" withString: @"\\t"];
    text = [text stringByReplacingOccurrencesOfString: @"\r" withString: @"\\r"];
    return text.UTF8String;
}
static void out(NSString *kind, id input, id left, id right)
{
    printf("%s\t%s\t%s\t%s\n", kind.UTF8String, field(input), field(left), field(right));
}
static NSString *num(double v) { return [NSString stringWithFormat:@"%.6f", v]; }

// Everything a date answers, as one line.
static NSString *dateSummary(id d)
{
    if (d == nil) return @"nil";
    // A query date is made now: only what it says of its text is compared.
    if ([d isQuery])
        return [NSString stringWithFormat: @"query %@ | %@ | %@ | %@ | %@ | %@ | %@ | %@ | %@ | %@", [d queryString], [d calendarFormat],
                [d description], [d dateString], [d timeString], [d timeStringWithMilliseconds], [d dateTimeString: YES],
                [d dateAsNumber], [d timeAsNumber], [[d copy] autorelease] ? [[[d copy] autorelease] dateString] : @"-"];
    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject: num([d timeIntervalSinceReferenceDate])];
    [parts addObject: [d isQuery] ? @"query" : @"value"];
    [parts addObject: [d queryString] ?: @"-"];
    [parts addObject: [d calendarFormat] ?: @"-"];
    [parts addObject: [NSString stringWithFormat:@"%ld", (long)[[d timeZone] secondsFromGMT]]];
    [parts addObject: [d description] ?: @"-"];
    [parts addObject: [d descriptionWithLocale: nil] ?: @"-"];
    [parts addObject: [d dateString] ?: @"-"];
    [parts addObject: [d timeString] ?: @"-"];
    [parts addObject: [d timeStringWithMilliseconds] ?: @"-"];
    [parts addObject: [d dateTimeString: NO] ?: @"-"];
    [parts addObject: [d dateTimeString: YES] ?: @"-"];
    [parts addObject: [[d dateAsNumber] description]];
    [parts addObject: [[d timeAsNumber] description]];
    [parts addObject: [NSString stringWithFormat:@"%ld-%ld-%ld %ld:%ld:%ld w%ld y%ld", (long)[d yearOfCommonEra], (long)[d monthOfYear],
                       (long)[d dayOfMonth], (long)[d hourOfDay], (long)[d minuteOfHour], (long)[d secondOfMinute],
                       (long)[d dayOfWeek], (long)[d dayOfYear]]];
    for (NSString *format in @@FORMATS@@)
        [parts addObject: [d descriptionWithCalendarFormat: format] ?: @"-"];
    id copy = [d copy];
    [parts addObject: [NSString stringWithFormat:@"copy %@ %@ %@", num([copy timeIntervalSinceReferenceDate]), [copy dateTimeString: YES], [copy description]]];
    [copy release];
    id later = [d dateByAddingYears: 0 months: 1 days: 1 hours: 25 minutes: 61 seconds: 61];
    [parts addObject: [NSString stringWithFormat:@"add %@ %@ %@", num([later timeIntervalSinceReferenceDate]), [later dateTimeString: YES], [later calendarFormat]]];
    NSInteger y = -1, m = -1, dd = -1, h = -1, mi = -1, s = -1;
    [d years: &y months: &m days: &dd hours: &h minutes: &mi seconds: &s sinceDate: [NSDate dateWithTimeIntervalSinceReferenceDate: 0]];
    [parts addObject: [NSString stringWithFormat:@"since %ld %ld %ld %ld %ld %ld", (long)y, (long)m, (long)dd, (long)h, (long)mi, (long)s]];
    NSInteger only = -1;
    [d years: NULL months: NULL days: &only hours: NULL minutes: NULL seconds: NULL sinceDate: [NSDate dateWithTimeIntervalSinceReferenceDate: 0]];
    [parts addObject: [NSString stringWithFormat:@"days %ld", (long)only]];
    return [parts componentsJoinedByString: @" | "];
}

static NSString *archive(id d)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject: d requiringSecureCoding: YES error: NULL];
    NSPropertyListFormat format;
    id plist = [NSPropertyListSerialization propertyListWithData: data options: 0 format: &format error: NULL];
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList: plist format: NSPropertyListXMLFormat_v1_0 options: 0 error: NULL];
    return [[[NSString alloc] initWithData: xml encoding: NSUTF8StringEncoding] autorelease];
}

static NSString *encodings(NSStringEncoding *e)
{
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < 10; i++) [a addObject: @(e[i])];
    return [a componentsJoinedByString: @","];
}

static NSString *tagSummary(id t)
{
    if (t == nil) return @"nil";
    return [NSString stringWithFormat: @"%d %d %@ %@ %@ %@ %d %@", [t group], [t element], [t name], [t vr], [t stringValue],
            [t description], [t isPrivate], [t readableDescription]];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        [IsiXDICOMCalendarDate registerArchiveName];
        // Dates.
        for (NSString *v in @@DATES@@) out(@"dicomDate", v, dateSummary([DCMCalendarDate dicomDate: v]), dateSummary([IsiXDICOMCalendarDate dicomDate: v]));
        for (NSString *v in @@TIMES@@) out(@"dicomTime", v, dateSummary([DCMCalendarDate dicomTime: v]), dateSummary([IsiXDICOMCalendarDate dicomTime: v]));
        for (NSString *v in @@DATETIMES@@) out(@"dicomDateTime", v, dateSummary([DCMCalendarDate dicomDateTime: v]), dateSummary([IsiXDICOMCalendarDate dicomDateTime: v]));
        for (NSString *v in @@DATES@@) out(@"queryDate", v, dateSummary([DCMCalendarDate queryDate: v]), dateSummary([IsiXDICOMCalendarDate queryDate: v]));
        out(@"nil", @"", dateSummary([DCMCalendarDate dicomDate: nil]), dateSummary([IsiXDICOMCalendarDate dicomDate: nil]));
        out(@"nil", @"", dateSummary([DCMCalendarDate dicomTime: nil]), dateSummary([IsiXDICOMCalendarDate dicomTime: nil]));
        out(@"nil", @"", dateSummary([DCMCalendarDate dicomDateTime: nil]), dateSummary([IsiXDICOMCalendarDate dicomDateTime: nil]));
        @@PAIRS@@
        @@STRINGS@@
        for (NSNumber *t in @@INSTANTS@@) {
            NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate: t.doubleValue];
            out(@"dicomDateWithDate", t, dateSummary([DCMCalendarDate dicomDateWithDate: date]), dateSummary([IsiXDICOMCalendarDate dicomDateWithDate: date]));
            out(@"dicomTimeWithDate", t, dateSummary([DCMCalendarDate dicomTimeWithDate: date]), dateSummary([IsiXDICOMCalendarDate dicomTimeWithDate: date]));
            out(@"interval", t, dateSummary([DCMCalendarDate dateWithTimeIntervalSinceReferenceDate: t.doubleValue]),
                dateSummary([IsiXDICOMCalendarDate dateWithTimeIntervalSinceReferenceDate: t.doubleValue]));
            for (NSString *format in @@FORMATS@@) {
                out(@"HorosDateString", [NSString stringWithFormat:@"%@ %@", t, format], OldHorosDateString(date, format),
                    [IsiXDICOMCalendarDate stringFromDate: date calendarFormat: format]);
                DCMCalendarDate *zoned = [DCMCalendarDate dicomDateTime: @"20240229101112.25+0130"];
                IsiXDICOMCalendarDate *zonedNew = [IsiXDICOMCalendarDate dicomDateTime: @"20240229101112.25+0130"];
                out(@"HorosDateString zoned", format, OldHorosDateString(zoned, format), [IsiXDICOMCalendarDate stringFromDate: zonedNew calendarFormat: format]);
            }
        }
        out(@"HorosDateString", @"not a date", OldHorosDateString(@"x", @"%Y"), [IsiXDICOMCalendarDate stringFromDate: @"x" calendarFormat: @"%Y"]);
        out(@"dateWithYear", @"2024-02-29", dateSummary([DCMCalendarDate dateWithYear: 2024 month: 2 day: 29 hour: 10 minute: 11 second: 12 timeZone: nil]),
            dateSummary([IsiXDICOMCalendarDate dateWithYear: 2024 month: 2 day: 29 hour: 10 minute: 11 second: 12 timeZone: nil]));
        NSTimeZone *india = [NSTimeZone timeZoneWithName: @"Asia/Kolkata"];
        out(@"dateWithYear zone", @"1901-01-01", dateSummary([DCMCalendarDate dateWithYear: 1901 month: 1 day: 1 hour: 0 minute: 0 second: 0 timeZone: india]),
            dateSummary([IsiXDICOMCalendarDate dateWithYear: 1901 month: 1 day: 1 hour: 0 minute: 0 second: 0 timeZone: india]));
        out(@"dateWithYear invalid", @"2024-13-40", dateSummary([DCMCalendarDate dateWithYear: 2024 month: 13 day: 40 hour: 25 minute: 61 second: 61 timeZone: nil]),
            dateSummary([IsiXDICOMCalendarDate dateWithYear: 2024 month: 13 day: 40 hour: 25 minute: 61 second: 61 timeZone: nil]));
        DCMCalendarDate *od = [DCMCalendarDate dicomDate: @"20240229"], *ot = [DCMCalendarDate dicomTime: @"101112.5"];
        IsiXDICOMCalendarDate *nd = [IsiXDICOMCalendarDate dicomDate: @"20240229"], *nt = [IsiXDICOMCalendarDate dicomTime: @"101112.5"];
        out(@"dicomDateTimeWithDicomDate", @"", dateSummary([DCMCalendarDate dicomDateTimeWithDicomDate: od dicomTime: ot]),
            dateSummary([IsiXDICOMCalendarDate dicomDateTimeWithDicomDate: nd dicomTime: nt]));
        out(@"dicomDateTimeWithDicomDate nil", @"", dateSummary([DCMCalendarDate dicomDateTimeWithDicomDate: od dicomTime: nil]),
            dateSummary([IsiXDICOMCalendarDate dicomDateTimeWithDicomDate: nd dicomTime: nil]));
        out(@"now", @"", @(fabs([[DCMCalendarDate date] timeIntervalSinceNow]) < 2), @(fabs([[IsiXDICOMCalendarDate date] timeIntervalSinceNow]) < 2));
        out(@"calendarDate", @"", @(fabs([[DCMCalendarDate calendarDate] timeIntervalSinceNow]) < 2), @(fabs([[IsiXDICOMCalendarDate calendarDate] timeIntervalSinceNow]) < 2));
        for (NSString *v in @@DATETIMES@@) {
            id a = [DCMCalendarDate dicomDateTime: v], b = [IsiXDICOMCalendarDate dicomDateTime: v];
            if (a && b) out(@"archive", v, archive(a), [archive(b) stringByReplacingOccurrencesOfString: @"IsiXDICOMCalendarDate" withString: @"DCMCalendarDate"]);
            if (b) {
                NSData *data = [NSKeyedArchiver archivedDataWithRootObject: b requiringSecureCoding: YES error: NULL];
                id back = [NSKeyedUnarchiver unarchivedObjectOfClass: [IsiXDICOMCalendarDate class] fromData: data error: NULL];
                out(@"archive round trip", v, dateSummary(b), dateSummary(back));
            }
        }
        for (NSString *v in @@DATES@@) {
            id a = [DCMCalendarDate queryDate: v], b = [IsiXDICOMCalendarDate queryDate: v];
            out(@"archive query", v, [[archive(a) componentsSeparatedByString: @"<real>"] firstObject],
                [[[archive(b) stringByReplacingOccurrencesOfString: @"IsiXDICOMCalendarDate" withString: @"DCMCalendarDate"] componentsSeparatedByString: @"<real>"] firstObject]);
        }

        // SOP classes.
        for (NSString *uid in @@UIDS@@) {
            NSString *o = [NSString stringWithFormat: @"%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d",
                [DCMAbstractSyntaxUID isImageStorage: uid], [DCMAbstractSyntaxUID isHiddenImageStorage: uid], [DCMAbstractSyntaxUID isMultiframe: uid],
                [DCMAbstractSyntaxUID isDirectory: uid], [DCMAbstractSyntaxUID isKeyObjectDocument: uid], [DCMAbstractSyntaxUID isStructuredReport: uid],
                [DCMAbstractSyntaxUID isPresentationState: uid], [DCMAbstractSyntaxUID isSupportedPrivateClasses: uid], [DCMAbstractSyntaxUID isWaveform: uid],
                [DCMAbstractSyntaxUID isStandalone: uid], [DCMAbstractSyntaxUID isRadiotherapy: uid], [DCMAbstractSyntaxUID isSpectroscopy: uid],
                [DCMAbstractSyntaxUID isRawData: uid], [DCMAbstractSyntaxUID isNonImageStorage: uid], [DCMAbstractSyntaxUID isQuery: uid],
                [DCMAbstractSyntaxUID isPDF: uid], [DCMAbstractSyntaxUID isVerification: uid]];
            NSString *n = [NSString stringWithFormat: @"%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d",
                [IsiXDICOMSOPClass isImageStorage: uid], [IsiXDICOMSOPClass isHiddenImageStorage: uid], [IsiXDICOMSOPClass isMultiframe: uid],
                [IsiXDICOMSOPClass isDirectory: uid], [IsiXDICOMSOPClass isKeyObjectDocument: uid], [IsiXDICOMSOPClass isStructuredReport: uid],
                [IsiXDICOMSOPClass isPresentationState: uid], [IsiXDICOMSOPClass isSupportedPrivateClasses: uid], [IsiXDICOMSOPClass isWaveform: uid],
                [IsiXDICOMSOPClass isStandalone: uid], [IsiXDICOMSOPClass isRadiotherapy: uid], [IsiXDICOMSOPClass isSpectroscopy: uid],
                [IsiXDICOMSOPClass isRawData: uid], [IsiXDICOMSOPClass isNonImageStorage: uid], [IsiXDICOMSOPClass isQuery: uid],
                [IsiXDICOMSOPClass isPDF: uid], [IsiXDICOMSOPClass isVerification: uid]];
            out(@"sop", uid, o, n);
        }
        out(@"sop nil", @"", @([DCMAbstractSyntaxUID isImageStorage: nil] + [DCMAbstractSyntaxUID isNonImageStorage: nil] + [DCMAbstractSyntaxUID isPDF: nil] + [DCMAbstractSyntaxUID isSupportedPrivateClasses: nil] + [DCMAbstractSyntaxUID isMultiframe: nil]),
            @([IsiXDICOMSOPClass isImageStorage: nil] + [IsiXDICOMSOPClass isNonImageStorage: nil] + [IsiXDICOMSOPClass isPDF: nil] + [IsiXDICOMSOPClass isSupportedPrivateClasses: nil] + [IsiXDICOMSOPClass isMultiframe: nil]));
        out(@"imageSyntaxes", @"", [DCMAbstractSyntaxUID imageSyntaxes], [IsiXDICOMSOPClass imageSyntaxes]);
        out(@"hiddenImageSyntaxes", @"", [DCMAbstractSyntaxUID hiddenImageSyntaxes], [IsiXDICOMSOPClass hiddenImageSyntaxes]);
        out(@"allSupportedSyntaxes", @"", [DCMAbstractSyntaxUID allSupportedSyntaxes], [IsiXDICOMSOPClass allSupportedSyntaxes]);
        out(@"structuredReportSyntaxes", @"", [DCMAbstractSyntaxUID structuredReportSyntaxes], [IsiXDICOMSOPClass structuredReportSyntaxes]);
        out(@"presentationStateSyntaxes", @"", [DCMAbstractSyntaxUID presentationStateSyntaxes], [IsiXDICOMSOPClass presentationStateSyntaxes]);
        out(@"supportedPrivateClasses", @"", [DCMAbstractSyntaxUID supportedPrivateClasses], [IsiXDICOMSOPClass supportedPrivateClasses]);
        out(@"waveformSyntaxes", @"", [DCMAbstractSyntaxUID waveformSyntaxes], [IsiXDICOMSOPClass waveformSyntaxes]);
        out(@"radiotherapySyntaxes", @"", [DCMAbstractSyntaxUID radiotherapySyntaxes], [IsiXDICOMSOPClass radiotherapySyntaxes]);
        out(@"constants", @"", [@[[DCMAbstractSyntaxUID pdfStorageClassUID], [DCMAbstractSyntaxUID EncapsulatedCDAStorage],
                                  [DCMAbstractSyntaxUID secondaryCaptureImageStorage], [DCMAbstractSyntaxUID RTStructureSetStorage],
                                  [DCMAbstractSyntaxUID keyObjectSelectionDocumentStorage], [DCMAbstractSyntaxUID enhancedMRImageStorage],
                                  [DCMAbstractSyntaxUID studyRootQueryRetrieveInformationModelFind]] componentsJoinedByString: @" "],
            [@[[IsiXDICOMSOPClass pdfStorageClassUID], [IsiXDICOMSOPClass EncapsulatedCDAStorage],
               [IsiXDICOMSOPClass secondaryCaptureImageStorage], [IsiXDICOMSOPClass RTStructureSetStorage],
               [IsiXDICOMSOPClass keyObjectSelectionDocumentStorage], [IsiXDICOMSOPClass enhancedMRImageStorage],
               [IsiXDICOMSOPClass studyRootQueryRetrieveInformationModelFind]] componentsJoinedByString: @" "]);

        // Character sets.
        for (NSString *term in @@TERMS@@)
            out(@"encoding", term, @([DCMCharacterSet encodingForDICOMCharacterSet: term]), @([IsiXDICOMCharacterSet encodingForDICOMCharacterSet: term]));
        out(@"encoding", @"nil", @([DCMCharacterSet encodingForDICOMCharacterSet: nil]), @([IsiXDICOMCharacterSet encodingForDICOMCharacterSet: nil]));
        out(@"characterSetWhenAbsent", @"", [DCMCharacterSet characterSetWhenAbsent], [IsiXDICOMCharacterSet characterSetWhenAbsent]);
        for (NSString *code in @@CODES@@) {
            DCMCharacterSet *o = [[[DCMCharacterSet alloc] initWithCode: code] autorelease];
            IsiXDICOMCharacterSet *n = [[[IsiXDICOMCharacterSet alloc] initWithCode: code] autorelease];
            out(@"code", code, [NSString stringWithFormat: @"%lu %@ %@", (unsigned long)o.encoding, encodings(o.encodings), o.description],
                [NSString stringWithFormat: @"%lu %@ %@", (unsigned long)n.encoding, encodings(n.encodings), n.description]);
        }
        @@TEXTS@@

        // Tags.
        NSDictionary *tags = [DCMTagDictionary sharedTagDictionary];
        out(@"tag dictionary", @"", @(tags.count), @([[IsiXDICOMTagDictionary sharedTagDictionary] count]));
        out(@"name dictionary", @"", @([[DCMTagForNameDictionary sharedTagForNameDictionary] count]), @([[IsiXDICOMTagDictionary sharedTagForNameDictionary] count]));
        NSMutableArray *keys = [NSMutableArray arrayWithArray: [[tags allKeys] sortedArrayUsingSelector: @selector(compare:)]];
        [keys addObjectsFromArray: @@TAGSTRINGS@@];
        for (NSString *key in keys) {
            unsigned g = 0, e = 0;
            NSScanner *s = [NSScanner scannerWithString: key];
            [s scanHexInt: &g]; [s scanString: @"," intoString: NULL]; [s scanHexInt: &e];
            out(@"tagWithGroup", key, tagSummary([DCMAttributeTag tagWithGroup: g element: e]), tagSummary([IsiXDICOMAttributeTag tagWithGroup: g element: e]));
            out(@"tagWithTagString", key, tagSummary([DCMAttributeTag tagWithTagString: key]), tagSummary([IsiXDICOMAttributeTag tagWithTagString: key]));
        }
        NSMutableArray *names = [NSMutableArray arrayWithArray: [[[DCMTagForNameDictionary sharedTagForNameDictionary] allKeys] sortedArrayUsingSelector: @selector(compare:)]];
        [names addObjectsFromArray: @@NAMESEXTRA@@];
        for (NSString *name in names) {
            out(@"tagWithName", name, tagSummary([DCMAttributeTag tagWithName: name]), tagSummary([IsiXDICOMAttributeTag tagWithName: name]));
            out(@"otherSpelling", name, DCMTagNameOtherSpelling(name), [IsiXDICOMTagDictionary otherSpellingOfName: name]);
        }
        DCMAttributeTag *a = [DCMAttributeTag tagWithGroup: 0x10 element: 0x10], *b = [DCMAttributeTag tagWithTagString: @"0010,0020"];
        IsiXDICOMAttributeTag *na = [IsiXDICOMAttributeTag tagWithGroup: 0x10 element: 0x10], *nb = [IsiXDICOMAttributeTag tagWithTagString: @"0010,0020"];
        out(@"compare", @"", @[@([a compare: b]), @([b compare: a]), @([a compare: [DCMAttributeTag tagWithTag: a]]), @([a isEqual: [[a copy] autorelease]]),
                               @([a isEqual: b]), @([a isEquaToTag: [DCMAttributeTag tagWithName: @"PatientName"]]), @([a isEqual: @"0010,0010"])],
            @[@([na compare: nb]), @([nb compare: na]), @([na compare: [IsiXDICOMAttributeTag tagWithTag: na]]), @([na isEqual: [[na copy] autorelease]]),
              @([na isEqual: nb]), @([na isEquaToTag: [IsiXDICOMAttributeTag tagWithName: @"PatientName"]]), @([na isEqual: @"0010,0010"])]);
        a.vr = @"XX"; na.vr = @"XX";
        out(@"vr", @"", tagSummary(a), tagSummary(na));
    }
    return 0;
}
'''


def driver_text():
    pairs = '\n'.join(
        '        out(@"dicomDate:time:", @"%s %s", dateSummary([DCMCalendarDate dicomDate: %s time: %s]), '
        'dateSummary([IsiXDICOMCalendarDate dicomDate: %s time: %s]));' % (d, t, objc_string(d), objc_string(t), objc_string(d), objc_string(t))
        for d, t in DATE_TIME_PAIRS)
    strings = '\n'.join(
        '        out(@"dateWithString", @"%s %s", dateSummary([DCMCalendarDate dateWithString: %s calendarFormat: %s]), '
        'dateSummary([IsiXDICOMCalendarDate dateWithString: %s calendarFormat: %s]));\n'
        '        out(@"initWithString microseconds", @"%s %s", dateSummary([[[DCMCalendarDate alloc] initWithString: %s calendarFormat: %s microseconds: 1500000] autorelease]), '
        'dateSummary([[[IsiXDICOMCalendarDate alloc] initWithString: %s calendarFormat: %s microseconds: 1500000] autorelease]));'
        % (v, f, objc_string(v), objc_string(f), objc_string(v), objc_string(f),
           v, f, objc_string(v), objc_string(f), objc_string(v), objc_string(f))
        for v, f in STRING_FORMATS)
    texts = '\n'.join(
        '        { DCMCharacterSet *o = [[[DCMCharacterSet alloc] initWithCode: %s] autorelease];\n'
        '          IsiXDICOMCharacterSet *n = [[[IsiXDICOMCharacterSet alloc] initWithCode: %s] autorelease];\n'
        '          char bytes[] = %s; unsigned length = (unsigned) (sizeof(bytes) - 1);\n'
        '          out(@"text", @"%d", [DCMCharacterSet stringWithBytes: bytes length: length encodings: o.encodings],\n'
        '              [IsiXDICOMCharacterSet stringWithBytes: bytes length: length encodings: n.encodings]); }'
        % (objc_string(code), objc_string(code), c_bytes(text), index)
        for index, (code, text) in enumerate(TEXTS))
    instants = '@[%s]' % ', '.join('@(%r)' % t for t in INSTANTS)
    text = DRIVER
    for key, value in [('PAIRS', pairs), ('STRINGS', strings), ('TEXTS', texts),
                       ('DATETIMES', objc_array(DATETIME_VALUES)), ('DATES', objc_array(DATE_VALUES)),
                       ('TIMES', objc_array(TIME_VALUES)), ('INSTANTS', instants), ('FORMATS', objc_array(OUTPUT_FORMATS)),
                       ('UIDS', objc_array(old_uids + ['1.3.46.670589.99.1', '1.3.12.2.1107.5.9.1.1',
                                                       '1.2.840.10008.5.1.4.1.1.2.', '', ' 1.2.840.10008.5.1.4.1.1.2', '1.2.3'])),
                       ('TERMS', objc_array(TERMS)), ('CODES', objc_array(CODES)),
                       ('TAGSTRINGS', objc_array(TAG_STRINGS)), ('NAMESEXTRA', objc_array(NAMES_EXTRA))]:
        text = text.replace('@@%s@@' % key, value)
    return text


def compile_and_run(work, host):
    """Builds the driver, with the host's DCMTK services or without, and runs it
    in the launch settings given: the lines each run printed."""
    modules = work / 'modules'
    build_module('IsiXImaging', modules)
    build_module('IsiXDICOMFile', modules, ['-I', str(modules)])
    framework = work / 'framework'
    framework.mkdir(exist_ok=True)
    for name in OLD_FILES:
        for extension in ('.h', '.m'):
            (framework / (name + extension)).write_bytes(old(FRAMEWORK + '/' + name + extension))
    # -[DCMAttributeTag initWithTagString:] read its group and element from
    # uninitialized variables when the text does not scan (an empty string,
    # "0010" alone): whatever the stack held. The former is given 0 there, the
    # value the module answers, so that the comparison is not left to chance.
    tag = framework / 'DCMAttributeTag.m'
    text = tag.read_bytes()
    assert text.count(b'unsigned int uGroup, uElement;') == 1, 'the former tag parser changed'
    tag.write_bytes(text.replace(b'unsigned int uGroup, uElement;', b'unsigned int uGroup = 0, uElement = 0;'))
    (framework / 'DCM.h').write_text('#import <Foundation/Foundation.h>\n#define DCMDEBUG 0\n' +
                                     ''.join('#import "%s.h"\n' % n for n in OLD_FILES))
    (work / 'horos-date-string.m').write_text('#import "DCMCalendarDate.h"\n' + date_string)
    (work / 'driver.m').write_text(driver_text())
    objects = []
    for source in [*(framework / (n + '.m') for n in OLD_FILES), work / 'horos-date-string.m']:
        obj = work / (source.stem + '.o')
        subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-w', '-mmacosx-version-min=15.0', '-I', str(framework),
                        '-c', str(source), '-o', str(obj)], check=True)
        objects.append(str(obj))
    link = []
    if host:
        from dcmtk_build import dcmtk_flags
        flags = dcmtk_flags('dcmnet')
        adapters = ROOT / 'Horos/Sources/Adapters/DCMTK'
        for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKDictionary.mm', 'HorosDICOMServices.mm'):
            obj = work / (name + '.o')
            subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-fmodules', '-fcxx-modules', '-w',
                            '-mmacosx-version-min=15.0', '-I', str(adapters), '-I', str(modules), *flags[:2],
                            '-c', str(adapters / name), '-o', str(obj)], check=True)
            objects.append(str(obj))
        link = [*flags[2:], '-lc++']
    executable = work / ('driver-host' if host else 'driver-alone')
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fmodules', '-w', '-mmacosx-version-min=15.0',
                    '-I', str(framework), '-I', str(modules), str(work / 'driver.m'), *objects,
                    str(modules / 'libIsiXDICOMFile.a'), str(modules / 'libIsiXImaging.a'), '-L/usr/lib/swift',
                    '-framework', 'Foundation', *link, '-o', str(executable)], check=True)
    runs = {}
    for name, settings in [('plain', []),
                           ('preferences', ['-additionalDisplayedStorageSOPClassUIDArray', '(1.2.3.4, "1.2.840.10008.5.1.4.1.1.88.11")',
                                            '-hiddenDisplayedStorageSOPClassUIDArray', '("1.2.840.10008.5.1.4.1.1.2", 1.2.3.4)',
                                            '-DefaultCharacterSetWhenAbsent', 'WINDOWS-1251']),
                           ('zone', [])]:
        env = {'TZ': 'America/Sao_Paulo' if name == 'zone' else 'Europe/Paris', 'PATH': '/usr/bin:/bin'}
        result = subprocess.run([str(executable), *settings], capture_output=True, env=env, timeout=120)
        if result.returncode:
            # The log lines both sides print for refused values are noise here.
            errors = [line for line in result.stderr.decode('utf-8', 'replace').splitlines()
                      if not re.search(r'DICOM DateTime invalid|encoding not found|multiple encoding|dictionary in this process', line)]
            sys.exit('FAIL: the %s driver (%s) stopped with %d after %d lines: %s' % (
                'host' if host else 'alone', name, result.returncode, len(result.stdout.splitlines()),
                '\n'.join(errors[-30:] + result.stdout.decode('utf-8', 'replace').splitlines()[-2:])))
        runs[name] = result.stdout.decode('utf-8', 'replace').rstrip('\n').split('\n')
    return runs


def main():
    from dcmtk_build import INSTALL
    if not (INSTALL / 'include/dcmtk/config/osconfig.h').is_file():
        print('skipped: needs a current build from script/build_and_run.sh --verify')
        sys.exit(2)
    failures = []
    counts = {}
    with tempfile.TemporaryDirectory(prefix='horos-value-types-') as folder:
        work = Path(folder)
        for host in (True, False):
            for name, lines in compile_and_run(work, host).items():
                label = '%s/%s' % ('host' if host else 'alone', name)
                counts[label] = len(lines)
                for line in lines:
                    kind, value, left, right = (line.split('\t') + ['', '', ''])[:4]
                    # Only the class name an archive records may differ, and it does not: both archive as DCMCalendarDate.
                    if kind == 'archive query':
                        # A query date is made now: its instant and fraction are not compared.
                        left, right = (re.sub(r'((?:NS\.time|DCM\.microseconds)</key>(?:\\[nt])*<(?:real|integer)>)[^<]*', r'\1', side)
                                       for side in (left, right))
                    if left != right:
                        failures.append('%s %s %r:\n  former  %s\n  current %s' % (label, kind, value, left[:600], right[:600]))
                if not any(line.startswith('archive\t') for line in lines):
                    failures.append('%s: no archive was compared' % label)
    if failures:
        for failure in failures[:40]:
            print('FAIL:', failure)
        print('%d differences' % len(failures))
        sys.exit(1)
    print('ok: the DICOM value types of IsiXDICOMFile answer as DCM.framework of %s did: %s' %
          (reference, ', '.join('%s %d' % item for item in sorted(counts.items()))))


main()
