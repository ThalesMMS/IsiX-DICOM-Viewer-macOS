#!/usr/bin/env python3
"""A former plugin finds the SDK's stand-alone classes in the host, and they answer as they did.

The plugin SDK of Horos and OsiriX carried classes that depend on nothing of
the application: N2SingletonObject, N2CSV, N2Pair, N2URLParts (with the two
NSURL selectors that take it), the JSON classes SBJsonBase, SBJsonParser,
SBJsonWriter and SBJSON, and ISO8601DateFormatter. A plugin built for either
SDK, linked with -undefined dynamic_lookup, looks each of them up by name when
it loads: without _OBJC_CLASS_$_<Name> in the application the bundle does not
load at all ("symbol not found in flat namespace"). Each is declared by a
header of Nitrogen/Sources and implemented in Swift (@objc @implementation), an
Objective-C class for the runtime; N2SingletonObject alone is Objective-C
without ARC, because Swift cannot override -retain and -release.

The delivered headers and sources are compiled here into a host executable,
with the application's own definitions of the two C globals of those classes
(Nitrogen+CAPI.m). A bundle that declares the classes as the SDK's headers
did, instance variables included, is built as the former plugins were and
loaded by the host. It subclasses N2SingletonObject and SBJsonBase, with
instance variables of its own, and sends the classes their selectors; every
value it gets is compared with the table below:

- N2SingletonObject: -init runs once for an instance, _hasInited is read by
  the subclass, and -release, -retain, -autorelease and -retainCount leave the
  instance alone;
- N2CSV: +quote: and +stringFromArray:, as N2CSV.mm wrote a line;
- N2Pair and N2URLParts, -[NSURL parts] and +[NSURL URLWithParts:];
- SBJsonWriter: the default output, which is that of -JSONRepresentation,
  humanReadable and sortKeys, a fragment, and the error codes and domain;
  SBJsonParser: mutable containers, NSDecimalNumber numbers, booleans that
  round-trip, and its error codes; SBJSON: the methods that take an NSError**
  and the options it forwards; SBJsonBase: the error trace of a subclass;
- ISO8601DateFormatter: the calendar, ordinal and week formats written, with
  and without the time, in three time zones, and read back, with the time
  zone and the range the text gave; loose and strict parsing.

The host also checks, from Swift, the superclass of each class and that
LegacyISO8601DateFormatter, the Swift name of the SDK's ISO8601DateFormatter,
lives beside Foundation's type of that name.

    python3 tests/test-former-sdk-nitrogen-classes.py

Exit status: 0 every value is the expected one, 1 otherwise.
"""
from pathlib import Path
import json
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import former_sdk_objects  # noqa: E402

NITROGEN = 'Nitrogen/Sources/'

# The headers the host's Swift is given, in the order the bridging header
# imports them, and the Swift and Objective-C sources that implement them.
HEADERS = [NITROGEN + name for name in (
    'N2SingletonObject.h', 'N2CSV.h', 'N2Pair.h', 'NSURL+N2.h',
    'JSON/SBJsonBase.h', 'JSON/SBJsonParser.h', 'JSON/SBJsonWriter.h', 'JSON/SBJSON.h',
    'JSON/NSObject+SBJSON.h', 'JSON/NSString+SBJSON.h', 'ISO8601DateFormatter.h')]
SWIFT_SOURCES = [NITROGEN + name for name in (
    'N2CSV.swift', 'N2Pair.swift', 'NSURL+N2.swift',
    'JSON/SBJsonBase.swift', 'JSON/SBJsonParser.swift', 'JSON/SBJsonWriter.swift', 'JSON/SBJSON.swift',
    'JSON/NSObject+SBJSON.swift', 'JSON/NSString+SBJSON.swift', 'ISO8601DateFormatter.swift')]
OBJC_SOURCES = [NITROGEN + 'N2SingletonObject.m']

# ---------------------------------------------------------------------------
# CLASSES OF OTHER AREAS: Interpolation3D and the waveform classes (DCMWaveform
# and the eight that go with it) depend on nothing of the application either.
# Add their headers, their Swift sources and, if any, their Objective-C sources
# to these three lists, what the SDK declared of them to PLUGIN_OTHER_AREAS
# below, the values the plugin gets to its -otherAreas:, and the expected
# values to EXPECTED_OTHER_AREAS.
OTHER_HEADERS = ['Horos/Sources/DCMWaveform.h']
OTHER_SWIFT_SOURCES = ['Horos/Sources/DCMWaveform.swift']
OTHER_OBJC_SOURCES = []
PLUGIN_OTHER_AREAS = r'''
// The waveform classes, as DCMWaveform.h of the SDK declared them.
typedef enum { DCMWaveformOriginalityOriginal, DCMWaveformOriginalityDerived } DCMWaveformOriginality;
typedef enum { DCMWaveformSampleInterpretationSB, DCMWaveformSampleInterpretationUB, DCMWaveformSampleInterpretationMB,
               DCMWaveformSampleInterpretationAB, DCMWaveformSampleInterpretationSS, DCMWaveformSampleInterpretationUS } DCMWaveformSampleInterpretation;
typedef enum { DCMWaveformChannelStatusOk, DCMWaveformChannelStatusTestData, DCMWaveformChannelStatusDisconnected,
               DCMWaveformChannelStatusQuestionable, DCMWaveformChannelStatusInvalid, DCMWaveformChannelStatusUncalibrated,
               DCMWaveformChannelStatusUnzeroed } DCMWaveformChannelStatus;
typedef enum { DCMMappingResourceDCMR, DCMMappingResourceSDM } DCMMappingResource;
typedef enum { DCMContextGroupExtensionFlagY, DCMContextGroupExtensionFlagN } DCMContextGroupExtensionFlag;
@class DCMWaveformSequence, DCMWaveformChannelDefinition, DCMWaveformChannelSource, DCMWaveformChannelSourceModifier,
       DCMWaveformSourceWaveform, DCMWaveformChannelSensitivityUnit;
@interface DCMWaveform : NSObject
- (DCMWaveformSequence*)newSequence;
- (NSArray*)sequences;
@end
@interface DCMWaveformSequence : NSObject
@property CGFloat multiplexgroupTimeOffset;
@property CGFloat triggerTimeOffset;
@property unsigned int triggerSamplePosition;
@property DCMWaveformOriginality waveformOriginality;
@property unsigned short numberOfWaveformChannels;
@property unsigned int numberOfWaveformSamples;
@property CGFloat samplingFrequency;
@property(retain) NSString* multiplexGroupLabel;
@property(retain,readonly) NSArray* channelDefinitions;
@property unsigned short waveformBitsAllocated;
@property DCMWaveformSampleInterpretation waveformSampleInterpretation;
- (void)setWaveformOriginalityCS:(char*)cs;
- (void)setWaveformSampleInterpretationCS:(char*)cs;
- (void)setWaveformPaddingValue:(void*)data length:(size_t)length;
- (void)setWaveformData:(void*)data length:(size_t)length;
- (DCMWaveformChannelDefinition*)newChannelDefinition;
- (CGFloat*)getValues:(NSUInteger*)numberOfValues;
@end
@interface DCMWaveformChannelDefinition : NSObject
@property NSInteger waveformChannelNumber;
@property(retain) NSString* channelLabel;
@property DCMWaveformChannelStatus channelStatus;
@property(retain,readonly) DCMWaveformChannelSource* channelSource;
@property(retain,readonly) NSArray* channelSourceModifiers;
@property(retain,readonly) NSArray* sourceWaveforms;
@property(retain) NSString* channelDerivationDescription;
@property CGFloat channelSensitivity;
@property(retain,readonly) DCMWaveformChannelSensitivityUnit* channelSensitivityUnit;
@property CGFloat channelSensitivityCorrectionFactor;
@property CGFloat channelBaseline;
@property CGFloat channelTimeSkew;
@property CGFloat channelSampleSkew;
@property CGFloat channelOffset;
@property unsigned short waveformBitsStored;
@property CGFloat filterLowFrequency;
@property CGFloat filterHighFrequency;
@property CGFloat notchFilterFrequency;
@property CGFloat notchFilterBandwidth;
- (void)setChannelStatusCS:(char*)cs;
- (void)setChannelMinimumValue:(void*)data length:(size_t)length;
- (void)setChannelMaximumValue:(void*)data length:(size_t)length;
- (DCMWaveformChannelSource*)newChannelSource;
- (DCMWaveformChannelSourceModifier*)newChannelSourceModifier;
- (DCMWaveformSourceWaveform*)newSourceWaveform;
- (DCMWaveformChannelSensitivityUnit*)newChannelSensitivityUnit;
- (void)getValuesMin:(CGFloat*)min max:(CGFloat*)max;
- (void)setValuesMin:(CGFloat)min max:(CGFloat)max;
@end
@interface DCMCodeSequenceMacro : NSObject
@property(retain) NSString* codeValue;
@property(retain) NSString* codingSchemeDesignator;
@property(retain) NSString* codingSchemeVersion;
@property(retain) NSString* codeMeaning;
@property(retain) NSString* contextIdentifier;
@property(retain) NSString* contextUID;
@property DCMMappingResource mappingResource;
@property(retain) NSDate* contextGroupVersion;
@property DCMContextGroupExtensionFlag contextGroupExtensionFlag;
@property(retain) NSDate* contextGroupLocalVersion;
@property(retain) NSString* contextGroupExtensionCreatorUID;
- (void)setMappingResourceCS:(char*)cs;
- (void)setContextGroupExtensionFlagCS:(char*)cs;
@end
@interface DCMSOPInstanceReferenceMacro : NSObject
@property(retain) NSString* referencedSOPClassUID;
@property(retain) NSString* referencedSOPInstanceUID;
@end
@interface DCMWaveformChannelSource : DCMCodeSequenceMacro
@end
@interface DCMWaveformChannelSourceModifier : DCMCodeSequenceMacro
@end
@interface DCMWaveformSourceWaveform : DCMSOPInstanceReferenceMacro
@property unsigned short referencedWaveformChannels;
@end
@interface DCMWaveformChannelSensitivityUnit : DCMCodeSequenceMacro
@end

static NSString *waveformNumbers(CGFloat *values, NSUInteger count)
{
    NSMutableArray *list = [NSMutableArray array];
    for (NSUInteger i = 0; values && i < count; i++) [list addObject:[NSString stringWithFormat:@"%g", (double)values[i]]];
    return values ? [list componentsJoinedByString:@" "] : @"NULL";
}

static NSString *waveformRange(DCMWaveformChannelDefinition *definition)
{
    CGFloat least = 77, greatest = 77;
    [definition getValuesMin:&least max:&greatest];
    return [NSString stringWithFormat:@"%g to %g", (double)least, (double)greatest];
}

static NSString *waveformRaises(void (^block)(void))
{
    @try { block(); } @catch (NSException *exception) { return [NSString stringWithFormat:@"%@: %@", [exception name], [exception reason]]; }
    return @"nothing raised";
}

static void otherAreas(NSMutableDictionary *results)
{
#define NOTE(key, value) [results setObject:(value) forKey:(key)]
    DCMWaveform *waveform = [[DCMWaveform alloc] init];
    DCMWaveformSequence *sequence = nil;
    DCMWaveformChannelDefinition *first = nil, *second = nil;
    DCMWaveformChannelSource *source = nil; DCMWaveformChannelSensitivityUnit *unit = nil;
    DCMWaveformChannelSourceModifier *modifier = nil; DCMWaveformSourceWaveform *reference = nil;
    NSAutoreleasePool *made = [[NSAutoreleasePool alloc] init];
    sequence = [waveform newSequence];
    first = [sequence newChannelDefinition]; second = [sequence newChannelDefinition];
    source = [first newChannelSource]; unit = [first newChannelSensitivityUnit];
    modifier = [first newChannelSourceModifier]; reference = [first newSourceWaveform];
    [made release];
    // What a -new... of the SDK answered was autoreleased and kept by its parent: nothing is owed by the caller.
    NOTE(@"waveform.retain counts of what -new... answered", ([NSString stringWithFormat:@"%lu %lu %lu %lu %lu %lu %lu",
        (unsigned long)[sequence retainCount], (unsigned long)[first retainCount], (unsigned long)[second retainCount], (unsigned long)[source retainCount],
        (unsigned long)[unit retainCount], (unsigned long)[modifier retainCount], (unsigned long)[reference retainCount]]));
    NOTE(@"waveform.superclasses", ([NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@ %@", [DCMWaveform superclass], [DCMWaveformSequence superclass],
        [DCMWaveformChannelDefinition superclass], [DCMCodeSequenceMacro superclass], [DCMSOPInstanceReferenceMacro superclass], [source superclass],
        [modifier superclass], [unit superclass], [reference superclass]]));
    NOTE(@"waveform.items", ([NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
        yes([[waveform sequences] count] == 1 && [[waveform sequences] objectAtIndex:0] == sequence),
        yes([[sequence channelDefinitions] count] == 2 && [[sequence channelDefinitions] objectAtIndex:1] == second),
        yes([first channelSource] == source), yes([first channelSensitivityUnit] == unit),
        yes([[first channelSourceModifiers] lastObject] == modifier), yes([[first sourceWaveforms] lastObject] == reference)]));
    NOTE(@"waveform.second channel source", waveformRaises(^{ [first newChannelSource]; }));
    NOTE(@"waveform.second sensitivity unit", waveformRaises(^{ [first newChannelSensitivityUnit]; }));
    NOTE(@"waveform.unknown originality", waveformRaises(^{ [sequence setWaveformOriginalityCS:"WRONG"]; }));
    NOTE(@"waveform.unknown interpretation", waveformRaises(^{ [sequence setWaveformSampleInterpretationCS:"XX"]; }));
    NOTE(@"waveform.unknown status", waveformRaises(^{ [first setChannelStatusCS:"FINE"]; }));
    NOTE(@"waveform.unknown mapping resource", waveformRaises(^{ [source setMappingResourceCS:"X"]; }));
    NOTE(@"waveform.unknown extension flag", waveformRaises(^{ [source setContextGroupExtensionFlagCS:"X"]; }));

    [sequence setWaveformOriginalityCS:"DERIVED"]; [sequence setWaveformSampleInterpretationCS:"SS"];
    [sequence setNumberOfWaveformChannels:2]; [sequence setNumberOfWaveformSamples:3]; [sequence setWaveformBitsAllocated:16];
    [sequence setMultiplexGroupLabel:@"group"]; [sequence setSamplingFrequency:500]; [sequence setTriggerSamplePosition:7];
    [sequence setMultiplexgroupTimeOffset:1.5]; [sequence setTriggerTimeOffset:2.5];
    NOTE(@"waveform.sequence values", ([NSString stringWithFormat:@"%d %d %d %u %d %@ %g %u %g %g", (int)[sequence waveformOriginality],
        (int)[sequence waveformSampleInterpretation], (int)[sequence numberOfWaveformChannels], [sequence numberOfWaveformSamples],
        (int)[sequence waveformBitsAllocated], [sequence multiplexGroupLabel], (double)[sequence samplingFrequency], [sequence triggerSamplePosition],
        (double)[sequence multiplexgroupTimeOffset], (double)[sequence triggerTimeOffset]]));
    NSUInteger count = 99;
    CGFloat *values = [sequence getValues:&count];
    NOTE(@"waveform.values without data", ([NSString stringWithFormat:@"%@ count %lu", waveformNumbers(values, count), (unsigned long)count]));
    int16_t samples[6] = {10, -100, -20, 300, 5, 200};
    [sequence setWaveformData:samples length:sizeof(samples)];
    [sequence setWaveformPaddingValue:samples length:2];
    values = [sequence getValues:&count];
    NOTE(@"waveform.16 bit signed values", ([NSString stringWithFormat:@"%@ count %lu", waveformNumbers(values, count), (unsigned long)count]));
    NOTE(@"waveform.ranges of the two channels", ([NSString stringWithFormat:@"%@, %@", waveformRange(first), waveformRange(second)]));
    NOTE(@"waveform.values are kept", yes([sequence getValues:&count] == values));

    uint8_t bytes[4] = {0x00, 0xFF, 0x80, 0x7F};
    const char *laws[5] = {"SB", "UB", "MB", "AB", "US"};
    for (int i = 0; i < 5; i++) {
        DCMWaveformSequence *eight = [waveform newSequence];
        [eight setNumberOfWaveformChannels:1]; [eight setNumberOfWaveformSamples:4]; [eight setWaveformBitsAllocated:8];
        [eight setWaveformSampleInterpretationCS:(char *)laws[i]]; [eight setWaveformData:bytes length:4];
        count = 0;
        values = [eight getValues:&count];
        NOTE(([NSString stringWithFormat:@"waveform.8 bits as %s", laws[i]]), waveformNumbers(values, count));
    }

    [first setWaveformChannelNumber:-3]; [first setChannelLabel:@"I"]; [first setChannelStatusCS:"TEST DATA"]; [first setChannelSensitivity:0.5];
    [first setChannelDerivationDescription:@"derived"]; [first setWaveformBitsStored:12]; [first setNotchFilterBandwidth:3];
    [first setChannelSensitivityCorrectionFactor:1.25]; [first setChannelBaseline:2]; [first setChannelTimeSkew:3]; [first setChannelSampleSkew:4];
    [first setChannelOffset:5]; [first setFilterLowFrequency:6]; [first setFilterHighFrequency:7]; [first setNotchFilterFrequency:8];
    [first setChannelMinimumValue:samples length:2]; [first setChannelMaximumValue:NULL length:0]; [first setValuesMin:-1 max:1];
    NOTE(@"waveform.definition values", ([NSString stringWithFormat:@"%d %@ %d %g %@ %d %g %g %g %g %g %g %g %g %g %@", (int)[first waveformChannelNumber],
        [first channelLabel], (int)[first channelStatus], (double)[first channelSensitivity], [first channelDerivationDescription],
        (int)[first waveformBitsStored], (double)[first notchFilterBandwidth], (double)[first channelSensitivityCorrectionFactor],
        (double)[first channelBaseline], (double)[first channelTimeSkew], (double)[first channelSampleSkew], (double)[first channelOffset],
        (double)[first filterLowFrequency], (double)[first filterHighFrequency], (double)[first notchFilterFrequency], waveformRange(first)]));
    [source setCodeValue:@"5.6.3-9-1"]; [source setCodingSchemeDesignator:@"SCPECG"]; [source setCodingSchemeVersion:@"1.3"];
    [source setCodeMeaning:@"Lead I"]; [source setContextIdentifier:@"3001"]; [source setContextUID:@"1.2.3"];
    [source setMappingResourceCS:"SDM"]; [source setContextGroupExtensionFlagCS:"N"];
    [source setContextGroupVersion:[NSDate dateWithTimeIntervalSince1970:86400]]; [source setContextGroupLocalVersion:[NSDate dateWithTimeIntervalSince1970:172800]];
    [source setContextGroupExtensionCreatorUID:@"1.2.3.4"];
    NOTE(@"waveform.code sequence values", ([NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %d %g %d %g %@", [source codeValue], [source codingSchemeDesignator],
        [source codingSchemeVersion], [source codeMeaning], [source contextIdentifier], [source contextUID], (int)[source mappingResource],
        [[source contextGroupVersion] timeIntervalSince1970], (int)[source contextGroupExtensionFlag],
        [[source contextGroupLocalVersion] timeIntervalSince1970], [source contextGroupExtensionCreatorUID]]));
    NOTE(@"waveform.code sequence unset", ([NSString stringWithFormat:@"%@ %d %d", [unit codeValue], (int)[unit mappingResource], (int)[unit contextGroupExtensionFlag]]));
    [reference setReferencedSOPClassUID:@"1.2"]; [reference setReferencedSOPInstanceUID:@"1.2.3"]; [reference setReferencedWaveformChannels:513];
    NOTE(@"waveform.reference values", ([NSString stringWithFormat:@"%@ %@ %d", [reference referencedSOPClassUID], [reference referencedSOPInstanceUID],
        (int)[reference referencedWaveformChannels]]));
    [waveform release];
#undef NOTE
}
'''
EXPECTED_OTHER_AREAS = {
    # The waveform classes. A parent alone keeps what its -new... answered.
    'waveform.retain counts of what -new... answered': '1 1 1 1 1 1 1',
    'waveform.superclasses': 'NSObject NSObject NSObject NSObject NSObject DCMCodeSequenceMacro DCMCodeSequenceMacro '
                             'DCMCodeSequenceMacro DCMSOPInstanceReferenceMacro',
    'waveform.items': 'YES YES YES YES YES YES',
    'waveform.second channel source':
        'NSGenericException: Waveform Channel Definition Sequence can only contain one Channel Source Sequence item',
    'waveform.second sensitivity unit':
        'NSGenericException: Waveform Channel Definition Sequence can only contain one Channel Sensitivity Units Sequence item',
    'waveform.unknown originality': 'NSGenericException: Invalid Waveform Originality value: WRONG',
    'waveform.unknown interpretation': 'NSGenericException: Invalid Waveform Sample Interpretation value: XX',
    'waveform.unknown status': 'NSGenericException: Invalid Channel Status value: FINE',
    'waveform.unknown mapping resource': 'NSGenericException: Invalid Mapping Resource value: X',
    'waveform.unknown extension flag': 'NSGenericException: Invalid Context Group Extension Flag value: X',
    'waveform.sequence values': '1 4 2 3 16 group 500 7 1.5 2.5',
    # No data yet: NULL, and the count is left as it was.
    'waveform.values without data': 'NULL count 99',
    # The samples in the order of the file, the first of each channel, then the second of each.
    'waveform.16 bit signed values': '10 -100 -20 300 5 200 count 6',
    'waveform.ranges of the two channels': '-20 to 10, -100 to 300',
    'waveform.values are kept': 'YES',
    'waveform.8 bits as SB': '0 -1 -128 127',
    'waveform.8 bits as UB': '0 255 128 127',
    # The mu-law and A-law tables of the SDK.
    'waveform.8 bits as MB': '-32124 0 32124 0',
    'waveform.8 bits as AB': '-5504 848 5504 -848',
    # A 16 bit interpretation of samples of 8 bits would read past the data.
    'waveform.8 bits as US': 'NULL',
    'waveform.definition values': '-3 I 1 0.5 derived 12 3 1.25 2 3 4 5 6 7 8 -1 to 1',
    'waveform.code sequence values': '5.6.3-9-1 SCPECG 1.3 Lead I 3001 1.2.3 1 86400 1 172800 1.2.3.4',
    'waveform.code sequence unset': '(null) 0 0',
    'waveform.reference values': '1.2 1.2.3 513',
}
# ---------------------------------------------------------------------------

# 2009-04-11 12:34:56 UTC, a Saturday, the 101st day of 2009, in the week 15.
EXPECTED = {
    # N2SingletonObject, by a subclass of the plugin.
    'singleton.superclass': 'N2SingletonObject',
    'singleton.inits after three -init': '1',
    'singleton._hasInited read by the subclass': 'YES',
    'singleton.alive after three -release': 'YES',
    'singleton.retain and autorelease answer self': 'YES',
    'singleton.retainCount is UINT_MAX': 'YES',
    # N2CSV.
    'csv.quote plain': 'plain',
    'csv.quote comma': '"a,b"',
    'csv.quote quotes': '"say ""hi"""',
    'csv.quote leading space': '" lead"',
    'csv.quote trailing space': '"trail "',
    'csv.quote line feed': '"two\nlines"',
    'csv.quote inner space': 'in ner',
    'csv.line': 'a,"b,c",,"d ""q""",e',
    'csv.line that begins empty': 'x,,y',
    'csv.line of nothing': '',
    # N2Pair.
    'pair.first and second': 'one 2',
    'pair.set': 'three (nil)',
    # N2URLParts and NSURL (N2).
    'url.parts': 'http|host.example|8080|/path/to|x=1&y=2',
    'url.pathAndParams': '/path/tox=1&y=2',
    'url.parts without port and params': 'https|host.example|(nil)|/|(nil)',
    'url.from parts': 'http://host.example:8080/path/to?x=1&y=2',
    'url.from parts without port and params': 'ftp://host.example/a',
    # SBJsonWriter.
    'writer.default': '{"k":[1,2.5,true,false,null,"q\\"\\\\/\\n\\u0001é"]}',
    'writer.default is -JSONRepresentation': 'YES',
    'writer.sortKeys': '{"a":1,"b":{"c":[],"d":{}},"e":"z"}',
    'writer.humanReadable and sortKeys': '{\n  "a" : 1,\n  "b" : {\n    "c" : [],\n    "d" : {}\n  },\n  "e" : [\n    1,\n    [\n      2\n    ]\n  ]\n}',
    'writer.options default': 'NO NO 512',
    'writer.fragment': '"alone"',
    'writer.scalar as object': '(nil) 1 errors, code 4, domain org.brautaset.JSON.ErrorDomain: Not valid type for JSON',
    'writer.errorTrace after a success': '(nil)',
    'writer.too deep': '(nil) 1 errors, code 7, domain org.brautaset.JSON.ErrorDomain: Nested too deep',
    'writer.unsupported value': '(nil) 2 errors, code 1, domain org.brautaset.JSON.ErrorDomain: Unsupported value for key when in object',
    'writer.unsupported value underlying': 'code 1: JSON serialisation not supported for LegacyOpaque',
    'writer.key that is not a string': '(nil) 1 errors, code 1, domain org.brautaset.JSON.ErrorDomain: JSON object key must be string',
    'writer.proxyForJson': '[{"proxied":true}]',
    'writer.error domain is SBJSONErrorDomain': 'YES',
    # SBJsonParser.
    'parser.object': 'NSMutableDictionary NSMutableArray NSDecimalNumber NSDecimalNumber boolean NSNull NSMutableString',
    'parser.values': '1 2.5 1 text',
    'parser.round trip': '{"k":[1,2.5,true,null,"text"]}',
    'parser.fragment': '3',
    'parser.scalar as object': '(nil) 1 errors, code 4, domain org.brautaset.JSON.ErrorDomain: Valid fragment, but not JSON',
    'parser.broken': '(nil) 1 errors, code 3',
    'parser.nil': '(nil) 1 errors, code 12, domain org.brautaset.JSON.ErrorDomain: Input was \'nil\'',
    'parser.too deep': '(nil) 1 errors, code 7, domain org.brautaset.JSON.ErrorDomain: Nested too deep',
    'parser.as deep as allowed': '[[1]]',
    'parser.brackets in a string are not depth': '["[[[["]',
    # SBJSON.
    'facade.stringWithObject:error:': '[1,"a"] error (nil)',
    'facade.stringWithObject:error: of a scalar': '(nil) error code 4',
    'facade.stringWithFragment:error:': '"a" error (nil)',
    'facade.stringWithObject:allowScalar:error:': '7 / (nil) error code 4',
    'facade.objectWithString:error:': '[1,"a"] error (nil)',
    'facade.objectWithString:error: of a scalar': '(nil) error code 4',
    'facade.fragmentWithString:error:': 'true error (nil)',
    'facade.objectWithString:allowScalar:error:': '7 / (nil) error code 4',
    'facade.NULL error': '(nil)',
    'facade.errorTrace': '1 errors, code 4, domain org.brautaset.JSON.ErrorDomain: Valid fragment, but not JSON',
    'facade.protocol methods': '[1] [1]',
    'facade.humanReadable and sortKeys': '{\n  "a" : 1,\n  "b" : 2\n}',
    'facade.maxDepth': '512 then 1: (nil) (nil)',
    # SBJsonBase, by a subclass of the plugin with an instance variable.
    'base.subclass': 'SBJsonBase 512 (nil)',
    'base.two errors': '2 errors, code 9, domain org.brautaset.JSON.ErrorDomain: second; underlying code 3: first; added 2',
    'base.cleared': '(nil)',
    # ISO8601DateFormatter: writing.
    'iso.class': 'ISO8601DateFormatter NSFormatter',
    'iso.defaults': 'format 0 includeTime NO strict NO separator : (the default: YES) zone (nil)',
    'iso.calendar': '2009-04-11',
    'iso.calendar with time UTC': '2009-04-11T12:34:56Z',
    'iso.calendar with time +02:00': '2009-04-11T14:34:56+0200',
    'iso.calendar with time -03:30': '2009-04-11T09:04:56-0330',
    'iso.calendar the day after in +13:00': '2009-04-12',
    'iso.ordinal': '2009-101',
    'iso.ordinal with time': '2009-101T12:34:56Z',
    'iso.week': '2009-W15-06',
    'iso.week with time': '2009-W15-06T12:34:56Z',
    'iso.week of the Monday 2008-12-29': '2009-W01-01',
    'iso.week of the Sunday 2010-01-03': '2009-W53-07',
    'iso.time separator': '2009-04-11T12.34.56Z',
    'iso.defaultTimeZone': '2009-04-11T14:34:56+0200',
    'iso.stringForObjectValue:': '2009-04-11T14:34:56+0200',
    # ISO8601DateFormatter: reading.
    'iso.read calendar': '2009-04-11T12:34:56Z zone 0 range 0 19',
    'iso.read calendar +02:00': '2009-04-11T12:34:56Z zone 7200 range 0 24',
    'iso.read calendar -0330': '2009-04-11T12:34:56Z zone -12600 range 0 23',
    'iso.read basic date': '2009-04-11T00:00:00Z zone 0 range 0 11',
    'iso.read ordinal': '2009-04-11T12:34:56Z zone 0 range 0 17',
    'iso.read week': '2009-04-11T12:34:56Z zone 0 range 0 19',
    'iso.read first week': '2008-12-29T00:00:00Z zone 0 range 0 13',
    'iso.read fraction of a minute': '2009-04-11T12:30:30Z zone 0 range 0 18',
    'iso.components calendar': 'year 2009 month 4 day 11 hour 0 minute 0 second 0 zone (nil) range 3 10',
    'iso.components ordinal': 'year 2009 month - day 101 hour 0 minute 0 second 0 zone (nil) range 0 8',
    'iso.components week': 'year 2009 month - day 101 hour 0 minute 0 second 0 zone (nil) range 0 10',
    'iso.components year and month': 'year 2009 month 4 day 1 hour 0 minute 0 second 0 zone (nil) range 0 7',
    'iso.components of what is no date': 'year - month - day - hour - minute - second - zone (nil) range NSNotFound 0',
    'iso.date of what is no date': '(nil)',
    'iso.strict refuses leading space': '(nil) range NSNotFound 0',
    'iso.strict reads the date': '2009-04-11T12:34:56Z zone 0 range 0 19',
    'iso.getObjectValue:': 'YES 2009-04-11T12:34:56Z / NO',
    'iso.round trip of the three formats': 'YES YES YES',
}

host = r'''
import Foundation

var failed = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: " + what); failed += 1 }
}

// The classes, from Swift: each an Objective-C class of the SDK's name, with the SDK's superclass.
for (name, base) in [("N2SingletonObject", "NSObject"), ("N2CSV", "NSObject"), ("N2Pair", "NSObject"), ("N2URLParts", "NSObject"),
                     ("SBJsonBase", "NSObject"), ("SBJsonParser", "SBJsonBase"), ("SBJsonWriter", "SBJsonBase"), ("SBJSON", "SBJsonBase"),
                     ("ISO8601DateFormatter", "NSFormatter")] {
    let found: AnyClass? = NSClassFromString(name)
    check(found != nil && class_getSuperclass(found).map { NSStringFromClass($0) } == base, "\(name) is a class of the runtime, a \(base)")
}
// The SDK's formatter and Foundation's, side by side.
check(NSStringFromClass(LegacyISO8601DateFormatter.self) == "ISO8601DateFormatter"
      && NSStringFromClass(ISO8601DateFormatter.self) != "ISO8601DateFormatter"
      && LegacyISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)) == "1970-01-01"
      && ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z",
      "Swift names the SDK's formatter LegacyISO8601DateFormatter and still has Foundation's ISO8601DateFormatter")
// From Swift, through the headers.
check(N2CSV.string(from: ["a", "b c", "d,e"]) == "a,b c,\"d,e\"", "N2CSV from Swift")
check((SBJSON().object(with: "{\"a\":[true]}") as? NSDictionary) == ["a": [true]], "SBJSON from Swift")

let bundle = Bundle(path: CommandLine.arguments[1])!
do { try bundle.loadAndReturnError() } catch { print("FAIL: the bundle does not load: \(error)"); exit(1) }
guard let principal = bundle.principalClass as? NSObject.Type else { print("FAIL: no principal class"); exit(1) }
guard let results = principal.init().perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? [String: String] else {
    print("FAIL: the plugin answered no results"); exit(1)
}
if failed > 0 { exit(1) }
let text = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
FileHandle.standardOutput.write(text)
'''

plugin = r'''
#import <Foundation/Foundation.h>

// What the former SDK declared of the classes, instance variables included;
// the classes themselves are the host's.
@interface N2SingletonObject : NSObject {
	@protected
	BOOL _hasInited;
}
@end

@interface N2CSV : NSObject {
}
+(NSString*)quote:(NSString*)str;
+(NSString*)stringFromArray:(NSArray*)array;
@end

@interface N2Pair : NSObject {
	id _first, _second;
}
@property(retain) id first, second;
-(id)initWith:(id)first and:(id)second;
@end

@interface N2URLParts : NSObject {
	NSString *_protocol, *_address, *_port, *_path, *_params;
}
@property(retain) NSString *protocol, *address, *port, *path, *params;
@property(readonly) NSString* pathAndParams;
@end

@interface NSURL (N2)
-(N2URLParts*)parts;
+(NSURL*)URLWithParts:(N2URLParts*)parts;
@end

extern NSString * SBJSONErrorDomain;
enum {
    EUNSUPPORTED = 1, EPARSENUM, EPARSE, EFRAGMENT, ECTRL, EUNICODE, EDEPTH, EESCAPE, ETRAILCOMMA, ETRAILGARBAGE, EEOF, EINPUT
};

@interface SBJsonBase : NSObject {
    NSMutableArray *errorTrace;
@protected
    NSUInteger depth, maxDepth;
}
@property NSUInteger maxDepth;
@property(copy,readonly) NSArray* errorTrace;
- (void)addErrorWithCode:(NSUInteger)code description:(NSString*)str;
- (void)clearErrorTrace;
@end

@protocol SBJsonParser
- (id)objectWithString:(NSString *)repr;
@end
@interface SBJsonParser : SBJsonBase <SBJsonParser> {
@private
    const char *c;
}
@end
@interface SBJsonParser (Private)
- (id)fragmentWithString:(id)repr;
@end

@protocol SBJsonWriter
@property BOOL humanReadable;
@property BOOL sortKeys;
- (NSString*)stringWithObject:(id)value;
@end
@interface SBJsonWriter : SBJsonBase <SBJsonWriter> {
@private
    BOOL sortKeys, humanReadable;
}
@end
@interface SBJsonWriter (Private)
- (NSString*)stringWithFragment:(id)value;
@end

@interface SBJSON : SBJsonBase <SBJsonParser, SBJsonWriter> {
@private
    SBJsonParser *jsonParser;
    SBJsonWriter *jsonWriter;
}
- (id)fragmentWithString:(NSString*)jsonrep error:(NSError**)error;
- (id)objectWithString:(NSString*)jsonrep error:(NSError**)error;
- (id)objectWithString:(id)value allowScalar:(BOOL)x error:(NSError**)error;
- (NSString*)stringWithObject:(id)value error:(NSError**)error;
- (NSString*)stringWithFragment:(id)value error:(NSError**)error;
- (NSString*)stringWithObject:(id)value allowScalar:(BOOL)x error:(NSError**)error;
@end

@interface NSObject (NSObject_SBJSON)
- (NSString *)JSONRepresentation;
@end

enum {
	ISO8601DateFormatCalendar,
	ISO8601DateFormatOrdinal,
	ISO8601DateFormatWeek,
};
typedef NSUInteger ISO8601DateFormat;
extern unichar ISO8601DefaultTimeSeparatorCharacter;

@interface ISO8601DateFormatter: NSFormatter
{
	NSTimeZone *defaultTimeZone;
	ISO8601DateFormat format;
	unichar timeSeparator;
	BOOL includeTime;
	BOOL parsesStrictly;
}
@property(retain) NSTimeZone *defaultTimeZone;
@property BOOL parsesStrictly;
- (NSDateComponents *) dateComponentsFromString:(NSString *)string;
- (NSDateComponents *) dateComponentsFromString:(NSString *)string timeZone:(out NSTimeZone **)outTimeZone;
- (NSDateComponents *) dateComponentsFromString:(NSString *)string timeZone:(out NSTimeZone **)outTimeZone range:(out NSRange *)outRange;
- (NSDate *) dateFromString:(NSString *)string;
- (NSDate *) dateFromString:(NSString *)string timeZone:(out NSTimeZone **)outTimeZone;
- (NSDate *) dateFromString:(NSString *)string timeZone:(out NSTimeZone **)outTimeZone range:(out NSRange *)outRange;
@property ISO8601DateFormat format;
@property BOOL includeTime;
@property unichar timeSeparator;
- (NSString *) stringFromDate:(NSDate *)date;
- (NSString *) stringFromDate:(NSDate *)date timeZone:(NSTimeZone *)timeZone;
@end

// The plugin's own classes.

@interface LegacySingleton : N2SingletonObject {
    int inits;
}
@end
@implementation LegacySingleton
- (id)init
{
    BOOL first = !_hasInited;
    if ((self = [super init]) && first)
        inits++;
    return self;
}
- (int)inits { return inits; }
- (BOOL)hasInited { return _hasInited; }
@end

@interface LegacyJsonBase : SBJsonBase {
    int added;
}
@end
@implementation LegacyJsonBase
- (void)addErrorWithCode:(NSUInteger)code description:(NSString*)str
{
    added++;
    [super addErrorWithCode:code description:str];
}
- (int)added { return added; }
@end

@interface LegacyOpaque : NSObject
@end
@implementation LegacyOpaque
@end

@interface LegacyProxied : NSObject
@end
@implementation LegacyProxied
- (id)proxyForJson { return [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"proxied"]; }
@end

static NSString *text(id value) { return value ? [value description] : @"(nil)"; }
static NSString *yes(BOOL value) { return value ? @"YES" : @"NO"; }

static NSString *trace(SBJsonBase *json)
{
    NSArray *errors = [json errorTrace];
    if (!errors) return @"(nil)";
    NSError *last = [errors lastObject];
    return [NSString stringWithFormat:@"%d errors, code %d, domain %@: %@", (int)[errors count], (int)[last code], [last domain], [last localizedDescription]];
}

static NSString *failure(NSError *error) { return error ? [NSString stringWithFormat:@"code %d", (int)[error code]] : @"(nil)"; }

static NSDate *utc(int year, int month, int day, int hour, int minute, int second)
{
    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    [calendar setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
    [components setYear:year]; [components setMonth:month]; [components setDay:day];
    [components setHour:hour]; [components setMinute:minute]; [components setSecond:second];
    return [calendar dateFromComponents:components];
}

// A date as its UTC text, by Foundation.
static NSString *instant(NSDate *date)
{
    if (!date) return @"(nil)";
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    [formatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    [formatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
    return [formatter stringFromDate:date];
}

static NSString *range(NSRange r)
{
    return r.location == NSNotFound ? [NSString stringWithFormat:@"NSNotFound %d", (int)r.length]
                                    : [NSString stringWithFormat:@"%d %d", (int)r.location, (int)r.length];
}

static NSString *zone(NSTimeZone *z) { return z ? [NSString stringWithFormat:@"%d", (int)[z secondsFromGMT]] : @"(nil)"; }

static NSString *readDate(ISO8601DateFormatter *formatter, NSString *string)
{
    NSTimeZone *z = (NSTimeZone *)0x1;
    NSRange r = NSMakeRange(77, 77);
    NSDate *date = [formatter dateFromString:string timeZone:&z range:&r];
    return [NSString stringWithFormat:@"%@ zone %@ range %@", instant(date), zone(z), range(r)];
}

static NSString *field(NSInteger value) { return value == NSDateComponentUndefined ? @"-" : [NSString stringWithFormat:@"%d", (int)value]; }

static NSString *readComponents(ISO8601DateFormatter *formatter, NSString *string)
{
    NSTimeZone *z = (NSTimeZone *)0x1;
    NSRange r = NSMakeRange(77, 77);
    NSDateComponents *c = [formatter dateComponentsFromString:string timeZone:&z range:&r];
    return [NSString stringWithFormat:@"year %@ month %@ day %@ hour %@ minute %@ second %@ zone %@ range %@",
            field([c year]), field([c month]), field([c day]), field([c hour]), field([c minute]), field([c second]), zone(z), range(r)];
}

''' + '%OTHER_AREAS%' + r'''

@interface LegacyNitrogen : NSObject
@end

@implementation LegacyNitrogen

- (NSDictionary *)results
{
    NSMutableDictionary *results = [NSMutableDictionary dictionary];
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#define PUT(key, ...) [results setObject:text(__VA_ARGS__) forKey:key]

    // N2SingletonObject
    PUT(@"singleton.superclass", NSStringFromClass([LegacySingleton superclass]));
    LegacySingleton *singleton = [[LegacySingleton alloc] init];
    [singleton init];
    [singleton init];
    PUT(@"singleton.inits after three -init", [NSNumber numberWithInt:[singleton inits]]);
    PUT(@"singleton._hasInited read by the subclass", yes([singleton hasInited]));
    [singleton release]; [singleton release]; [singleton release];
    PUT(@"singleton.alive after three -release", yes([singleton isKindOfClass:[N2SingletonObject class]] && [singleton inits] == 1));
    PUT(@"singleton.retain and autorelease answer self", yes([singleton retain] == singleton && [singleton autorelease] == singleton));
    PUT(@"singleton.retainCount is UINT_MAX", yes([singleton retainCount] == UINT_MAX));

    // N2CSV
    PUT(@"csv.quote plain", [N2CSV quote:@"plain"]);
    PUT(@"csv.quote comma", [N2CSV quote:@"a,b"]);
    PUT(@"csv.quote quotes", [N2CSV quote:@"say \"hi\""]);
    PUT(@"csv.quote leading space", [N2CSV quote:@" lead"]);
    PUT(@"csv.quote trailing space", [N2CSV quote:@"trail "]);
    PUT(@"csv.quote line feed", [N2CSV quote:@"two\nlines"]);
    PUT(@"csv.quote inner space", [N2CSV quote:@"in ner"]);
    PUT(@"csv.line", [N2CSV stringFromArray:[NSArray arrayWithObjects:@"a", @"b,c", @"", @"d \"q\"", @"e", nil]]);
    PUT(@"csv.line that begins empty", [N2CSV stringFromArray:[NSArray arrayWithObjects:@"", @"", @"x", @"", @"y", nil]]);
    PUT(@"csv.line of nothing", [N2CSV stringFromArray:[NSArray array]]);

    // N2Pair
    N2Pair *pair = [[[N2Pair alloc] initWith:@"one" and:[NSNumber numberWithInt:2]] autorelease];
    PUT(@"pair.first and second", ([NSString stringWithFormat:@"%@ %@", [pair first], [pair second]]));
    [pair setFirst:@"three"];
    [pair setSecond:nil];
    PUT(@"pair.set", ([NSString stringWithFormat:@"%@ %@", [pair first], text([pair second])]));

    // N2URLParts and NSURL (N2)
    N2URLParts *parts = [[NSURL URLWithString:@"http://host.example:8080/path/to?x=1&y=2"] parts];
    PUT(@"url.parts", ([NSString stringWithFormat:@"%@|%@|%@|%@|%@", text([parts protocol]), text([parts address]), text([parts port]), text([parts path]), text([parts params])]));
    PUT(@"url.pathAndParams", [parts pathAndParams]);
    PUT(@"url.from parts", [[NSURL URLWithParts:parts] absoluteString]);
    N2URLParts *bare = [[NSURL URLWithString:@"https://host.example/"] parts];
    PUT(@"url.parts without port and params", ([NSString stringWithFormat:@"%@|%@|%@|%@|%@", text([bare protocol]), text([bare address]), text([bare port]), text([bare path]), text([bare params])]));
    N2URLParts *made = [[[N2URLParts alloc] init] autorelease];
    [made setProtocol:@"ftp"];
    [made setAddress:@"host.example"];
    [made setPath:@"/a"];
    PUT(@"url.from parts without port and params", [[NSURL URLWithParts:made] absoluteString]);

    // SBJsonWriter
    SBJsonWriter *writer = [[[SBJsonWriter alloc] init] autorelease];
    PUT(@"writer.options default", ([NSString stringWithFormat:@"%@ %@ %d", yes([writer humanReadable]), yes([writer sortKeys]), (int)[writer maxDepth]]));
    NSArray *values = [NSArray arrayWithObjects:[NSNumber numberWithInt:1], [NSNumber numberWithDouble:2.5], [NSNumber numberWithBool:YES],
                       [NSNumber numberWithBool:NO], [NSNull null], @"q\"\\/\n\x01é", nil];
    NSDictionary *one = [NSDictionary dictionaryWithObject:values forKey:@"k"];
    PUT(@"writer.default", [writer stringWithObject:one]);
    PUT(@"writer.default is -JSONRepresentation", yes([[writer stringWithObject:one] isEqualToString:[one JSONRepresentation]]));
    PUT(@"writer.errorTrace after a success", trace(writer));
    NSDictionary *nested = [NSDictionary dictionaryWithObjectsAndKeys:@"z", @"e", [NSNumber numberWithInt:1], @"a",
                            [NSDictionary dictionaryWithObjectsAndKeys:[NSDictionary dictionary], @"d", [NSArray array], @"c", nil], @"b", nil];
    [writer setSortKeys:YES];
    PUT(@"writer.sortKeys", [writer stringWithObject:nested]);
    [writer setHumanReadable:YES];
    NSDictionary *shown = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:1], @"a",
                           [NSDictionary dictionaryWithObjectsAndKeys:[NSDictionary dictionary], @"d", [NSArray array], @"c", nil], @"b",
                           [NSArray arrayWithObjects:[NSNumber numberWithInt:1], [NSArray arrayWithObject:[NSNumber numberWithInt:2]], nil], @"e", nil];
    PUT(@"writer.humanReadable and sortKeys", [writer stringWithObject:shown]);
    [writer setHumanReadable:NO];
    PUT(@"writer.fragment", [writer stringWithFragment:@"alone"]);
    PUT(@"writer.scalar as object", ([NSString stringWithFormat:@"%@ %@", text([writer stringWithObject:@"alone"]), trace(writer)]));
    PUT(@"writer.error domain is SBJSONErrorDomain", yes([[[[writer errorTrace] lastObject] domain] isEqualToString:SBJSONErrorDomain]));
    [writer setMaxDepth:1];
    PUT(@"writer.too deep", ([NSString stringWithFormat:@"%@ %@", text([writer stringWithObject:[NSArray arrayWithObject:[NSArray array]]]), trace(writer)]));
    [writer setMaxDepth:512];
    NSDictionary *opaque = [NSDictionary dictionaryWithObject:[[[LegacyOpaque alloc] init] autorelease] forKey:@"when"];
    PUT(@"writer.unsupported value", ([NSString stringWithFormat:@"%@ %@", text([writer stringWithObject:opaque]), trace(writer)]));
    NSError *underlying = [[[[writer errorTrace] lastObject] userInfo] objectForKey:NSUnderlyingErrorKey];
    PUT(@"writer.unsupported value underlying", ([NSString stringWithFormat:@"code %d: %@", (int)[underlying code], [underlying localizedDescription]]));
    NSDictionary *numbered = [NSDictionary dictionaryWithObject:@"v" forKey:[NSNumber numberWithInt:1]];
    PUT(@"writer.key that is not a string", ([NSString stringWithFormat:@"%@ %@", text([writer stringWithObject:numbered]), trace(writer)]));
    PUT(@"writer.proxyForJson", [writer stringWithObject:[NSArray arrayWithObject:[[[LegacyProxied alloc] init] autorelease]]]);

    // SBJsonParser
    SBJsonParser *parser = [[[SBJsonParser alloc] init] autorelease];
    NSString *source = @"{\"k\":[1,2.5,true,null,\"text\"]}";
    id parsed = [parser objectWithString:source];
    NSArray *items = [parsed objectForKey:@"k"];
    PUT(@"parser.object", ([NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@",
        [parsed isKindOfClass:[NSMutableDictionary class]] ? @"NSMutableDictionary" : NSStringFromClass([parsed class]),
        [items isKindOfClass:[NSMutableArray class]] ? @"NSMutableArray" : NSStringFromClass([items class]),
        [[items objectAtIndex:0] isKindOfClass:[NSDecimalNumber class]] ? @"NSDecimalNumber" : NSStringFromClass([[items objectAtIndex:0] class]),
        [[items objectAtIndex:1] isKindOfClass:[NSDecimalNumber class]] ? @"NSDecimalNumber" : NSStringFromClass([[items objectAtIndex:1] class]),
        (*[[items objectAtIndex:2] objCType] == 'c' && ![[items objectAtIndex:2] isKindOfClass:[NSDecimalNumber class]]) ? @"boolean" : NSStringFromClass([[items objectAtIndex:2] class]),
        [[items objectAtIndex:3] isKindOfClass:[NSNull class]] ? @"NSNull" : NSStringFromClass([[items objectAtIndex:3] class]),
        [[items objectAtIndex:4] isKindOfClass:[NSMutableString class]] ? @"NSMutableString" : NSStringFromClass([[items objectAtIndex:4] class])]));
    PUT(@"parser.values", ([NSString stringWithFormat:@"%@ %@ %@ %@", [items objectAtIndex:0], [items objectAtIndex:1], [items objectAtIndex:2], [items objectAtIndex:4]]));
    [writer setSortKeys:NO];
    PUT(@"parser.round trip", [writer stringWithObject:parsed]);
    PUT(@"parser.fragment", [parser fragmentWithString:@"3"]);
    PUT(@"parser.scalar as object", ([NSString stringWithFormat:@"%@ %@", text([parser objectWithString:@"3"]), trace(parser)]));
    id broken = [parser objectWithString:@"[1,"];
    PUT(@"parser.broken", ([NSString stringWithFormat:@"%@ %d errors, code %d", text(broken), (int)[[parser errorTrace] count], (int)[[[parser errorTrace] lastObject] code]]));
    PUT(@"parser.nil", ([NSString stringWithFormat:@"%@ %@", text([parser objectWithString:nil]), trace(parser)]));
    [parser setMaxDepth:2];
    PUT(@"parser.too deep", ([NSString stringWithFormat:@"%@ %@", text([parser objectWithString:@"[[[1]]]"]), trace(parser)]));
    PUT(@"parser.as deep as allowed", [writer stringWithObject:[parser objectWithString:@"[[1]]"]]);
    PUT(@"parser.brackets in a string are not depth", [writer stringWithObject:[parser objectWithString:@"[\"[[[[\"]"]]);

    // SBJSON
    SBJSON *json = [[[SBJSON alloc] init] autorelease];
    NSArray *list = [NSArray arrayWithObjects:[NSNumber numberWithInt:1], @"a", nil];
    NSError *error = (NSError *)0x1;
    error = nil;
    NSString *written = [json stringWithObject:list error:&error];
    PUT(@"facade.stringWithObject:error:", ([NSString stringWithFormat:@"%@ error %@", text(written), failure(error)]));
    error = nil;
    written = [json stringWithObject:@"a" error:&error];
    PUT(@"facade.stringWithObject:error: of a scalar", ([NSString stringWithFormat:@"%@ error %@", text(written), failure(error)]));
    error = nil;
    written = [json stringWithFragment:@"a" error:&error];
    PUT(@"facade.stringWithFragment:error:", ([NSString stringWithFormat:@"%@ error %@", text(written), failure(error)]));
    error = nil;
    written = [json stringWithObject:[NSNumber numberWithInt:7] allowScalar:YES error:NULL];
    NSString *refused = [json stringWithObject:[NSNumber numberWithInt:7] allowScalar:NO error:&error];
    PUT(@"facade.stringWithObject:allowScalar:error:", ([NSString stringWithFormat:@"%@ / %@ error %@", text(written), text(refused), failure(error)]));
    error = nil;
    id read = [json objectWithString:@"[1,\"a\"]" error:&error];
    PUT(@"facade.objectWithString:error:", ([NSString stringWithFormat:@"%@ error %@", text([json stringWithObject:read]), failure(error)]));
    error = nil;
    read = [json objectWithString:@"7" error:&error];
    PUT(@"facade.objectWithString:error: of a scalar", ([NSString stringWithFormat:@"%@ error %@", text(read), failure(error)]));
    PUT(@"facade.errorTrace", trace(json));
    error = nil;
    read = [json fragmentWithString:@"true" error:&error];
    PUT(@"facade.fragmentWithString:error:", ([NSString stringWithFormat:@"%@ error %@", text([json stringWithFragment:read error:NULL]), failure(error)]));
    error = nil;
    read = [json objectWithString:@"7" allowScalar:YES error:NULL];
    id unread = [json objectWithString:@"7" allowScalar:NO error:&error];
    PUT(@"facade.objectWithString:allowScalar:error:", ([NSString stringWithFormat:@"%@ / %@ error %@", text(read), text(unread), failure(error)]));
    PUT(@"facade.NULL error", [json objectWithString:@"7" error:NULL]);
    PUT(@"facade.protocol methods", ([NSString stringWithFormat:@"%@ %@", [json stringWithObject:[NSArray arrayWithObject:[NSNumber numberWithInt:1]]],
                                     [json stringWithObject:[json objectWithString:@"[1]"]]]));
    [json setHumanReadable:YES];
    [json setSortKeys:YES];
    PUT(@"facade.humanReadable and sortKeys", [json stringWithObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:2], @"b", [NSNumber numberWithInt:1], @"a", nil]]);
    int before = (int)[json maxDepth];
    [json setMaxDepth:1];
    PUT(@"facade.maxDepth", ([NSString stringWithFormat:@"%d then %d: %@ %@", before, (int)[json maxDepth],
                             text([json stringWithObject:[NSArray arrayWithObject:[NSArray array]]]), text([json objectWithString:@"[[]]"])]));

    // SBJsonBase, subclassed
    LegacyJsonBase *base = [[[LegacyJsonBase alloc] init] autorelease];
    PUT(@"base.subclass", ([NSString stringWithFormat:@"%@ %d %@", NSStringFromClass([LegacyJsonBase superclass]), (int)[base maxDepth], text([base errorTrace])]));
    [base addErrorWithCode:EPARSE description:@"first"];
    [base addErrorWithCode:ETRAILCOMMA description:@"second"];
    NSError *first = [[[[base errorTrace] lastObject] userInfo] objectForKey:NSUnderlyingErrorKey];
    PUT(@"base.two errors", ([NSString stringWithFormat:@"%@; underlying code %d: %@; added %d", trace(base), (int)[first code], [first localizedDescription], [base added]]));
    [base clearErrorTrace];
    PUT(@"base.cleared", [base errorTrace]);

    // ISO8601DateFormatter
    NSDate *date = utc(2009, 4, 11, 12, 34, 56);
    NSTimeZone *z0 = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSTimeZone *east = [NSTimeZone timeZoneForSecondsFromGMT:7200];
    NSTimeZone *west = [NSTimeZone timeZoneForSecondsFromGMT:-12600];
    ISO8601DateFormatter *formatter = [[[ISO8601DateFormatter alloc] init] autorelease];
    PUT(@"iso.class", ([NSString stringWithFormat:@"%@ %@", NSStringFromClass([formatter class]), NSStringFromClass([[formatter class] superclass])]));
    unichar separator = [formatter timeSeparator];
    PUT(@"iso.defaults", ([NSString stringWithFormat:@"format %d includeTime %@ strict %@ separator %@ (the default: %@) zone %@", (int)[formatter format],
                          yes([formatter includeTime]), yes([formatter parsesStrictly]), [NSString stringWithCharacters:&separator length:1],
                          yes(separator == ISO8601DefaultTimeSeparatorCharacter), text([formatter defaultTimeZone])]));
    PUT(@"iso.calendar", [formatter stringFromDate:date timeZone:z0]);
    PUT(@"iso.calendar the day after in +13:00", [formatter stringFromDate:date timeZone:[NSTimeZone timeZoneForSecondsFromGMT:13 * 3600]]);
    [formatter setIncludeTime:YES];
    PUT(@"iso.calendar with time UTC", [formatter stringFromDate:date timeZone:z0]);
    PUT(@"iso.calendar with time +02:00", [formatter stringFromDate:date timeZone:east]);
    PUT(@"iso.calendar with time -03:30", [formatter stringFromDate:date timeZone:west]);
    [formatter setTimeSeparator:'.'];
    PUT(@"iso.time separator", [formatter stringFromDate:date timeZone:z0]);
    [formatter setTimeSeparator:ISO8601DefaultTimeSeparatorCharacter];
    [formatter setDefaultTimeZone:east];
    PUT(@"iso.defaultTimeZone", [formatter stringFromDate:date]);
    PUT(@"iso.stringForObjectValue:", [formatter stringForObjectValue:date]);
    [formatter setFormat:ISO8601DateFormatOrdinal];
    PUT(@"iso.ordinal with time", [formatter stringFromDate:date timeZone:z0]);
    [formatter setIncludeTime:NO];
    PUT(@"iso.ordinal", [formatter stringFromDate:date timeZone:z0]);
    [formatter setFormat:ISO8601DateFormatWeek];
    PUT(@"iso.week", [formatter stringFromDate:date timeZone:z0]);
    PUT(@"iso.week of the Monday 2008-12-29", [formatter stringFromDate:utc(2008, 12, 29, 12, 0, 0) timeZone:z0]);
    PUT(@"iso.week of the Sunday 2010-01-03", [formatter stringFromDate:utc(2010, 1, 3, 12, 0, 0) timeZone:z0]);
    [formatter setIncludeTime:YES];
    PUT(@"iso.week with time", [formatter stringFromDate:date timeZone:z0]);

    PUT(@"iso.read calendar", readDate(formatter, @"2009-04-11T12:34:56Z"));
    PUT(@"iso.read calendar +02:00", readDate(formatter, @"2009-04-11T14:34:56+02:00"));
    PUT(@"iso.read calendar -0330", readDate(formatter, @"2009-04-11T09:04:56-0330"));
    PUT(@"iso.read basic date", readDate(formatter, @"20090411T00Z"));
    PUT(@"iso.read ordinal", readDate(formatter, @"2009-101T12:34:56Z"));
    PUT(@"iso.read week", readDate(formatter, @"2009-W15-6T12:34:56Z"));
    PUT(@"iso.read first week", readDate(formatter, @"2009-W01-1T00Z"));
    PUT(@"iso.read fraction of a minute", readDate(formatter, @"2009-04-11T12:30.5Z"));
    PUT(@"iso.components calendar", readComponents(formatter, @" \t 2009-04-11!!!"));
    PUT(@"iso.components ordinal", readComponents(formatter, @"2009-101"));
    PUT(@"iso.components week", readComponents(formatter, @"2009-W15-6"));
    PUT(@"iso.components year and month", readComponents(formatter, @"2009-04"));
    PUT(@"iso.components of what is no date", readComponents(formatter, @"no date"));
    PUT(@"iso.date of what is no date", [formatter dateFromString:@"no date"]);
    [formatter setParsesStrictly:YES];
    NSRange strictRange = NSMakeRange(77, 77);
    NSDate *strictDate = [formatter dateFromString:@" 2009-04-11" timeZone:NULL range:&strictRange];
    PUT(@"iso.strict refuses leading space", ([NSString stringWithFormat:@"%@ range %@", text(strictDate), range(strictRange)]));
    PUT(@"iso.strict reads the date", readDate(formatter, @"2009-04-11T12:34:56Z"));
    [formatter setParsesStrictly:NO];
    id value = nil;
    BOOL got = [formatter getObjectValue:&value forString:@"2009-04-11T12:34:56Z" errorDescription:NULL];
    id none = nil;
    BOOL gotNone = [formatter getObjectValue:&none forString:@"no date" errorDescription:NULL];
    PUT(@"iso.getObjectValue:", ([NSString stringWithFormat:@"%@ %@ / %@", yes(got), instant(value), yes(gotNone || none != nil)]));
    // Each format, written with its time and read back, is the same instant.
    NSMutableArray *trips = [NSMutableArray array];
    ISO8601DateFormat formats[3] = { ISO8601DateFormatCalendar, ISO8601DateFormatOrdinal, ISO8601DateFormatWeek };
    for (int i = 0; i < 3; i++) {
        [formatter setFormat:formats[i]];
        [trips addObject:yes([[formatter dateFromString:[formatter stringFromDate:date timeZone:west]] isEqualToDate:date])];
    }
    PUT(@"iso.round trip of the three formats", [trips componentsJoinedByString:@" "]);

    otherAreas(results);
#undef PUT
    [pool release];
    return results;
}

@end
'''


def run(command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


def fail(message):
    print('FAIL: ' + message)
    raise SystemExit(1)


with tempfile.TemporaryDirectory(prefix='horos-former-sdk-nitrogen-') as temporary:
    work = Path(temporary)
    headers = HEADERS + OTHER_HEADERS
    for path in headers:
        (work / Path(path).name).write_bytes((ROOT / path).read_bytes())
    # As the application's bridging header: Swift is compiling the classes itself.
    (work / 'Host.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                 + ''.join(f'#import "{Path(path).name}"\n' for path in headers))
    (work / 'main.swift').write_text(host)
    (work / 'Legacy.m').write_text(plugin.replace('%OTHER_AREAS%', PLUGIN_OTHER_AREAS))
    legacy = work / 'Legacy.bundle'
    (legacy / 'Contents/MacOS').mkdir(parents=True)
    (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Legacy', 'CFBundleIdentifier': 'org.example.legacy-nitrogen', 'CFBundlePackageType': 'BNDL',
        'NSPrincipalClass': 'LegacyNitrogen'}))

    objects = []
    for path in OBJC_SOURCES + OTHER_OBJC_SOURCES:
        # As the application compiles them: without ARC.
        built = run(['xcrun', 'clang', *former_sdk_objects.TARGET, '-c', '-fno-objc-arc', '-I', str(work), str(ROOT / path),
                     '-o', str(work / (Path(path).name + '.o'))])
        if built.returncode != 0:
            fail(f'{path} does not compile: ' + built.stderr[-3000:])
        objects.append(str(work / (Path(path).name + '.o')))
    try:
        # SBJSONErrorDomain and ISO8601DefaultTimeSeparatorCharacter, as the application defines them.
        objects += [former_sdk_objects.nitrogen(work), former_sdk_objects.bezier_stubs(work)]
    except RuntimeError as error:
        fail(str(error))

    built = run(['xcrun', 'swiftc', *former_sdk_objects.TARGET, '-swift-version', '6', '-module-name', 'Host',
                 '-import-objc-header', str(work / 'Host.h'),
                 '-Xcc', '-I' + str(work), *(str(ROOT / path) for path in SWIFT_SOURCES + OTHER_SWIFT_SOURCES),
                 str(work / 'main.swift'), *objects, '-o', str(work / 'host')])
    if built.returncode == 0:
        # As the former plugins were built: Objective-C without ARC, the host's classes found at run time.
        built = run(['xcrun', 'clang', *former_sdk_objects.TARGET, '-bundle', '-fno-objc-arc', '-framework', 'Foundation',
                     '-undefined', 'dynamic_lookup',
                     str(work / 'Legacy.m'), '-o', str(legacy / 'Contents/MacOS/Legacy')])
    if built.returncode != 0:
        fail('the host or the plugin does not build: ' + built.stderr[-4000:])
    probe = run([str(work / 'host'), str(legacy)], timeout=120)
    if probe.returncode != 0:
        died = f' (signal {-probe.returncode})' if probe.returncode < 0 else ''
        print((probe.stdout + probe.stderr).strip()[-4000:])
        fail(f'the host ended with status {probe.returncode}{died}')
    try:
        results = json.loads(probe.stdout)
    except ValueError:
        print(probe.stdout[-2000:])
        fail('the host did not print the plugin\'s results')

expected = {**EXPECTED, **EXPECTED_OTHER_AREAS}
wrong = 0
for key in sorted(set(expected) | set(results)):
    if key not in results:
        print(f'FAIL: {key}: the plugin gave no value, expected {expected[key]!r}')
    elif key not in expected:
        print(f'FAIL: {key}: {results[key]!r} is not in the table of expected values')
    elif results[key] != expected[key]:
        print(f'FAIL: {key}: {results[key]!r}, expected {expected[key]!r}')
    else:
        continue
    wrong += 1
if wrong:
    raise SystemExit(1)
print(f'PASS: a former plugin loads against the stand-alone classes of the SDK, subclasses N2SingletonObject and SBJsonBase, '
      f'and gets the {len(expected)} expected values from N2CSV, N2Pair, N2URLParts, the JSON classes and ISO8601DateFormatter')
