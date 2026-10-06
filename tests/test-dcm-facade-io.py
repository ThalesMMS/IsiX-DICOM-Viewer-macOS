#!/usr/bin/env python3
"""DCMObject reads and writes through the host's DCMTK, not a parser of its own.

DCM.framework keeps the class and selector names plugins compile against, and
forwards reading to HorosDCMTKObject and writing to HorosDICOMWriter. The
driver is linked like the application: DCM.framework plus those host classes
and the codecs the host registers. It exercises the DCMObject messages a plugin
sends:

- +objectWithContentsOfFile:decodingPixelData: hands out the host's object,
  with values, a sequence and the pixels of the file;
- edited attributes, a new sequence and a private element survive
  -writeToFile:withTransferSyntax:quality:AET:atomically: to JPEG 2000,
  JPEG-LS, RLE and explicit little endian, and the pixels read back identical;
- decodingPixelData:YES decodes every frame at load;
- a DCMObject built in memory converts its own pixel data to RLE and decodes
  it again through the host (-convertToTransferSyntax:quality:,
  -decodeFrameAtIndex:);
- -writeDatasetWithTransferSyntax:quality: and -initWithData:transferSyntax:
  carry a bare dataset, as the network does;
- DCMLimitedObject stops after the group it is given;
- text keeps a declared Specific Character Set that holds it and becomes
  ISO_IR 192 when it does not;
- +anonymizeContentsOfFile:tags:writingToFile: writes the anonymized file;
- truncated files and an undelimited sequence end the read.

With --python pointing at an interpreter that has pydicom and numpy, the
written files are also read by that independent implementation. The objects
here are minimal; test-dicom-writer.py checks complete ones with dciodvfy.

Usage: python test-dcm-facade-io.py [--products DIR] [--python PYTHON]
"""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT
import horos_reader

parser = argparse.ArgumentParser()
parser.add_argument('--products', default=str(ROOT / 'build/Build/Products' / BUILD.name))
parser.add_argument('--python')
args = parser.parse_args()
reason = horos_reader.missing(args.products)
if reason:
    print('skipped: %s: --products DIR' % reason, file=sys.stderr)
    raise SystemExit(2)

driver = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCM.h>
#import <DCM/DCMAbstractSyntaxUID.h>
#import "HorosDCMTKObject.h"
#import "HorosDICOMWriter.h"

extern "C" void HorosTestRegisterDecoders(void);
static int failures = 0;
#define CHECK(condition, ...) do { if (!(condition)) { failures++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const int kRows = 12, kColumns = 10, kFrames = 3;

static NSMutableData *Frames(void)
{
    NSMutableData *pixels = [NSMutableData dataWithLength: kRows * kColumns * kFrames * 2];
    short *p = (short *) pixels.mutableBytes;
    for (int i = 0; i < kRows * kColumns * kFrames; i++) p[i] = (short) ((i * 37) % 4000 - 1000);
    return pixels;
}

static NSString *Source(NSString *folder)
{
    HorosDICOMWriter *writer = [[[HorosDICOMWriter alloc] init] autorelease];
    [writer setValues: @[[DCMAbstractSyntaxUID secondaryCaptureImageStorage]] forName: @"SOPClassUID"];
    [writer setValues: @[[HorosDICOMWriter newSOPInstanceUID]] forName: @"SOPInstanceUID"];
    [writer setValues: @[[HorosDICOMWriter newStudyInstanceUID]] forName: @"StudyInstanceUID"];
    [writer setValues: @[[HorosDICOMWriter newSeriesInstanceUID]] forName: @"SeriesInstanceUID"];
    [writer setValues: @[@"FACADE^742"] forName: @"PatientsName"];
    [writer setValues: @[@"PID-742"] forName: @"PatientID"];
    for (NSString *name in @[@"PatientsBirthDate", @"PatientsSex", @"StudyID", @"AccessionNumber",
                             @"ReferringPhysiciansName", @"SeriesNumber", @"InstanceNumber", @"Laterality",
                             @"PatientOrientation", @"StudyTime"])
        [writer setValues: @[] forName: name];
    [writer setValues: @[[DCMCalendarDate dicomDate: @"20260926"]] forName: @"StudyDate"];
    [writer setValues: @[@"OT"] forName: @"Modality"];
    [writer setValues: @[@"WSD"] forName: @"ConversionType"];
    [writer setValues: @[@(kRows)] forName: @"Rows"];
    [writer setValues: @[@(kColumns)] forName: @"Columns"];
    [writer setValues: @[@(kFrames)] forName: @"NumberofFrames"];
    [writer setValues: @[@1] forName: @"SamplesperPixel"];
    [writer setValues: @[@"MONOCHROME2"] forName: @"PhotometricInterpretation"];
    [writer setValues: @[@16] forName: @"BitsAllocated"];
    [writer setValues: @[@16] forName: @"BitsStored"];
    [writer setValues: @[@15] forName: @"HighBit"];
    [writer setValues: @[@1] forName: @"PixelRepresentation"];
    [writer setData: Frames() forName: @"PixelData" vr: @"OW"];
    NSString *path = [folder stringByAppendingPathComponent: @"source.dcm"];
    CHECK([writer writeToFile: path transferSyntax: @"1.2.840.10008.1.2.1"], "source not written");
    return path;
}

static BOOL SameFrames(DCMObject *object, NSData *expected, const char *what)
{
    DCMPixelDataAttribute *pixels = (DCMPixelDataAttribute *) [object attributeWithName: @"PixelData"];
    if ([pixels isKindOfClass: [DCMPixelDataAttribute class]] == NO) { CHECK(NO, "%s: no pixel data", what); return NO; }
    const NSUInteger frameLength = kRows * kColumns * 2;
    for (int f = 0; f < kFrames; f++)
    {
        NSData *frame = [pixels decodeFrameAtIndex: f];
        NSData *want = [expected subdataWithRange: NSMakeRange(f * frameLength, frameLength)];
        if ([frame isEqualToData: want] == NO)
        {
            CHECK(NO, "%s: frame %d differs (%lu bytes)", what, f, (unsigned long) frame.length);
            return NO;
        }
    }
    return YES;
}

int main(int argc, char **argv) { @autoreleasepool {
    HorosTestRegisterDecoders();
    NSString *folder = @(argv[1]);
    NSData *expected = Frames();
    NSString *source = Source(folder);

    // Reading: the host's object answers the DCMObject messages.
    DCMObject *object = [DCMObject objectWithContentsOfFile: source decodingPixelData: NO];
    CHECK([object isKindOfClass: NSClassFromString(@"HorosDCMTKObject")], "DCMObject read is %s", object ? object_getClassName(object) : "nil");
    CHECK([[object attributeValueWithName: @"PatientsName"] isEqualToString: @"FACADE^742"], "PatientsName %s", [[object attributeValueWithName: @"PatientsName"] description].UTF8String);
    CHECK([[object attributeValueWithName: @"Rows"] intValue] == kRows, "Rows");
    CHECK([[object attributeValueWithName: @"StudyDate"] isKindOfClass: [DCMCalendarDate class]], "StudyDate is not a DCMCalendarDate");
    SameFrames(object, expected, "read");
    DCMObject *viaInit = [[[DCMObject alloc] initWithContentsOfFile: source decodingPixelData: NO] autorelease];
    CHECK([[viaInit attributeValueWithName: @"PatientID"] isEqualToString: @"PID-742"], "-initWithContentsOfFile:");
    CHECK([DCMObject objectWithContentsOfFile: [folder stringByAppendingPathComponent: @"absent.dcm"] decodingPixelData: NO] == nil, "an absent file read as an object");

    // Editing and writing through the facade, in each syntax the host encodes.
    // The source says ISO_IR 192; Latin-1 holds the new name, so it is kept.
    CHECK([[object attributeValueWithName: @"SpecificCharacterSet"] isEqualToString: @"ISO_IR 192"], "source character set");
    [object setAttributeValues: [NSMutableArray arrayWithObject: @"ISO_IR 100"] forName: @"SpecificCharacterSet"];
    [object setAttributeValues: [NSMutableArray arrayWithObject: @"Müller^José"] forName: @"PatientsName"];
    DCMSequenceAttribute *codes = [DCMSequenceAttribute sequenceAttributeWithName: @"ConceptNameCodeSequence"];
    [codes addItem: [DCMObject objectWithCodeValue: @"18748-4" codingSchemeDesignator: @"LN" codeMeaning: @"Diagnostic imaging report"]];
    [object setAttribute: codes];
    DCMAttributeTag *privateTag = [DCMAttributeTag tagWithGroup: 0x0009 element: 0x1001];
    privateTag.vr = @"LO";
    [object setAttribute: [DCMAttribute attributeWithAttributeTag: [DCMAttributeTag tagWithGroup: 0x0009 element: 0x0010] vr: @"LO" values: [NSMutableArray arrayWithObject: @"HOROS 742"]]];
    [object setAttribute: [DCMAttribute attributeWithAttributeTag: privateTag vr: @"LO" values: [NSMutableArray arrayWithObject: @"private value"]]];
    NSDictionary *syntaxes = @{@"j2k.dcm": [DCMTransferSyntax JPEG2000LosslessTransferSyntax],
                               @"jls.dcm": [DCMTransferSyntax JPEGLSLosslessTransferSyntax],
                               @"rle.dcm": [DCMTransferSyntax RLELosslessTransferSyntax],
                               @"explicit.dcm": [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]};
    for (NSString *name in syntaxes)
    {
        DCMTransferSyntax *syntax = syntaxes[name];
        NSString *path = [folder stringByAppendingPathComponent: name];
        CHECK([object writeToFile: path withTransferSyntax: syntax quality: DCMLosslessQuality AET: @"FACADE742" atomically: YES], "%s not written", name.UTF8String);
        DCMObject *back = [DCMObject objectWithContentsOfFile: path decodingPixelData: NO];
        CHECK([[back transferSyntax] isEqualToTransferSyntax: syntax], "%s: syntax %s", name.UTF8String, [[back transferSyntax] transferSyntax].UTF8String);
        CHECK([[back attributeValueWithName: @"PatientsName"] isEqualToString: @"Müller^José"], "%s: PatientsName %s", name.UTF8String, [[back attributeValueWithName: @"PatientsName"] description].UTF8String);
        CHECK([[back attributeValueWithName: @"SpecificCharacterSet"] isEqualToString: @"ISO_IR 100"], "%s: character set %s", name.UTF8String, [[back attributeValueWithName: @"SpecificCharacterSet"] description].UTF8String);
        NSArray *items = [(DCMSequenceAttribute *) [back attributeWithName: @"ConceptNameCodeSequence"] sequence];
        CHECK(items.count == 1 && [[items[0] attributeValueWithName: @"CodeValue"] isEqualToString: @"18748-4"], "%s: sequence item", name.UTF8String);
        CHECK([[[back attributeForTag: privateTag] value] isEqualToString: @"private value"], "%s: private element", name.UTF8String);
        SameFrames(back, expected, name.UTF8String);
    }

    // Decoding at load.
    DCMObject *decoded = [DCMObject objectWithContentsOfFile: [folder stringByAppendingPathComponent: @"j2k.dcm"] decodingPixelData: YES];
    CHECK(decoded.pixelDataIsDecoded, "decodingPixelData:YES left the pixels encoded");
    DCMPixelDataAttribute *decodedPixels = (DCMPixelDataAttribute *) [decoded attributeWithName: @"PixelData"];
    CHECK(decodedPixels.values.count == kFrames && decodedPixels.transferSyntax.isEncapsulated == NO, "decoded values: %lu", (unsigned long) decodedPixels.values.count);
    SameFrames(decoded, expected, "decodingPixelData:YES");

    // A DCMObject made in memory converts and decodes its own pixel data through the host.
    DCMObject *made = [DCMObject secondaryCaptureObjectWithBitDepth: 16 samplesPerPixel: 1 numberOfFrames: kFrames];
    for (NSString *name in @[@"Rows", @"Columns", @"NumberofFrames", @"SamplesperPixel", @"BitsAllocated", @"BitsStored", @"HighBit", @"PixelRepresentation"])
    {
        NSDictionary *value = @{@"Rows": @(kRows), @"Columns": @(kColumns), @"NumberofFrames": @(kFrames), @"SamplesperPixel": @1,
                                @"BitsAllocated": @16, @"BitsStored": @16, @"HighBit": @15, @"PixelRepresentation": @1};
        [made setAttributeValues: [NSMutableArray arrayWithObject: value[name]] forName: name];
    }
    [made setAttributeValues: [NSMutableArray arrayWithObject: @"MONOCHROME2"] forName: @"PhotometricInterpretation"];
    DCMPixelDataAttribute *pixels = [[[DCMPixelDataAttribute alloc] initWithAttributeTag: [DCMAttributeTag tagWithName: @"PixelData"]] autorelease];
    pixels.rows = kRows; pixels.columns = kColumns; pixels.numberOfFrames = kFrames; pixels.samplesPerPixel = 1;
    pixels.pixelDepth = 16; pixels.transferSyntax = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
    [pixels setValue: made forKey: @"_dcmObject"];
    [pixels setValue: @16 forKey: @"_bitsAllocated"];
    [pixels addFrame: [[expected mutableCopy] autorelease]];
    [made setAttribute: pixels];
    CHECK([pixels convertToTransferSyntax: [DCMTransferSyntax RLELosslessTransferSyntax] quality: DCMLosslessQuality], "RLE conversion refused");
    CHECK(pixels.transferSyntax.isEncapsulated && pixels.values.count == kFrames + 1, "RLE: %lu items", (unsigned long) pixels.values.count);
    SameFrames(made, expected, "in-memory RLE");
    CHECK([made writeToFile: [folder stringByAppendingPathComponent: @"made.dcm"] withTransferSyntax: [DCMTransferSyntax JPEG2000LosslessTransferSyntax] quality: DCMLosslessQuality AET: @"FACADE742" atomically: YES], "in-memory object not written");

    // A bare dataset, as it travels over the network.
    NSData *dataset = [object writeDatasetWithTransferSyntax: [DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] quality: DCMLosslessQuality];
    CHECK(dataset.length > kRows * kColumns * kFrames * 2, "dataset: %lu bytes", (unsigned long) dataset.length);
    CHECK(dataset.length < 132 || memcmp((const char *) dataset.bytes + 128, "DICM", 4) != 0, "the dataset carries a preamble");
    DCMObject *fromDataset = [[[DCMObject alloc] initWithData: dataset transferSyntax: [DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax]] autorelease];
    CHECK([[fromDataset attributeValueWithName: @"PatientID"] isEqualToString: @"PID-742"], "-initWithData:transferSyntax:");
    SameFrames(fromDataset, expected, "dataset");
    DCMObject *fromFile = [DCMObject objectWithData: [NSData dataWithContentsOfFile: source] decodingPixelData: NO];
    CHECK([[fromFile attributeValueWithName: @"PatientID"] isEqualToString: @"PID-742"], "+objectWithData:decodingPixelData:");

    // DCMLimitedObject reads up to the group it is given.
    DCMObject *limited = [DCMLimitedObject objectWithContentsOfFile: source lastGroup: 0x0010];
    CHECK([[limited attributeValueWithName: @"PatientID"] isEqualToString: @"PID-742"], "limited: PatientID");
    CHECK([limited attributeWithName: @"Rows"] == nil && [limited attributeWithName: @"PixelData"] == nil, "limited: read past group 0010");

    // Text the declared character set cannot hold is written as UTF-8.
    [object setAttributeValues: [NSMutableArray arrayWithObject: @"Σωκράτης"] forName: @"PatientsName"];
    NSString *greek = [folder stringByAppendingPathComponent: @"greek.dcm"];
    CHECK([object writeToFile: greek withTransferSyntax: nil quality: DCMLosslessQuality AET: @"FACADE742" atomically: YES], "greek not written");
    DCMObject *greekBack = [DCMObject objectWithContentsOfFile: greek decodingPixelData: NO];
    CHECK([[greekBack attributeValueWithName: @"SpecificCharacterSet"] isEqualToString: @"ISO_IR 192"], "greek: character set %s", [[greekBack attributeValueWithName: @"SpecificCharacterSet"] description].UTF8String);
    CHECK([[greekBack attributeValueWithName: @"PatientsName"] isEqualToString: @"Σωκράτης"], "greek: PatientsName");

    // Anonymization writes through the host as well.
    NSString *anonymous = [folder stringByAppendingPathComponent: @"anonymous.dcm"];
    NSArray *tags = @[@[[DCMAttributeTag tagWithName: @"PatientsName"], @"ANON^742"], @[[DCMAttributeTag tagWithName: @"PatientID"], @"ANON-742"]];
    CHECK([DCMObject anonymizeContentsOfFile: source tags: tags writingToFile: anonymous], "anonymization not written");
    DCMObject *anonymized = [DCMObject objectWithContentsOfFile: anonymous decodingPixelData: NO];
    CHECK([[anonymized attributeValueWithName: @"PatientsName"] isEqualToString: @"ANON^742"], "anonymized name %s", [[anonymized attributeValueWithName: @"PatientsName"] description].UTF8String);
    SameFrames(anonymized, expected, "anonymized");

    // Malformed input ends the read, as the DCM parser's sequence loop had to be
    // made to (the facade retired that loop and its test with it).
    NSData *whole = [NSData dataWithContentsOfFile: source];
    for (NSNumber *cut in @[@60, @200, @(whole.length / 2), @(whole.length - 3)])
        [DCMObject objectWithData: [whole subdataWithRange: NSMakeRange(0, cut.unsignedIntegerValue)] decodingPixelData: NO];
    const unsigned char undelimited[] = {0x08,0x00,0x40,0x11,'S','Q',0,0,0xFF,0xFF,0xFF,0xFF,
                                         0xFE,0xFF,0x00,0xE0,0xFF,0xFF,0xFF,0xFF,
                                         0x08,0x00,0x50,0x11,'U','I',4,0,'1','.','2',0};
    [[[DCMObject alloc] initWithData: [NSData dataWithBytes: undelimited length: sizeof(undelimited)]
                      transferSyntax: [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]] autorelease];

    printf("%s\n", failures ? "facade checks failed" : "DCMObject read, wrote, converted and decoded through the host");
    return failures ? 1 : 0;
}}
'''

check = r'''
import sys, numpy as np, pydicom
folder = sys.argv[1]
expected = ((np.arange(12 * 10 * 3) * 37) % 4000 - 1000).astype(np.int16).reshape(3, 12, 10)
for name, uid in (('j2k.dcm', '1.2.840.10008.1.2.4.90'), ('jls.dcm', '1.2.840.10008.1.2.4.80'),
                  ('rle.dcm', '1.2.840.10008.1.2.5'), ('explicit.dcm', '1.2.840.10008.1.2.1')):
    d = pydicom.dcmread(folder + '/' + name)
    assert str(d.file_meta.TransferSyntaxUID) == uid, (name, d.file_meta.TransferSyntaxUID)
    assert str(d.PatientName) == 'Müller^José' and d.SpecificCharacterSet == 'ISO_IR 100', (name, d.PatientName)
    assert d.ConceptNameCodeSequence[0].CodeValue == '18748-4', name
    assert d[0x0009, 0x1001].value == 'private value', name
    assert d.file_meta.SourceApplicationEntityTitle == 'FACADE742', name
    if name != 'j2k.dcm':  # pydicom needs pylibjpeg-openjpeg for JPEG 2000
        assert np.array_equal(d.pixel_array, expected), name
g = pydicom.dcmread(folder + '/greek.dcm')
assert g.SpecificCharacterSet == 'ISO_IR 192' and str(g.PatientName) == 'Σωκράτης', g.PatientName
print('pydicom: syntaxes, text, sequence, private element and pixels read back')
'''

failures = 0
with tempfile.TemporaryDirectory(prefix='horos-facade-') as work:
    work = Path(work)
    (work / 'bin').mkdir()
    (work / 'Frameworks').symlink_to(Path(args.products).resolve())
    (work / 'driver.mm').write_text(driver)
    horos_reader.compile_reader(args.products, work / 'driver.mm', work / 'bin/driver', work)
    out = work / 'out'
    out.mkdir()
    try:
        result = subprocess.run([str(work / 'bin/driver'), str(out)], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        print('FAIL: the driver did not finish; a malformed input may keep the reader going')
        sys.exit(1)
    print(result.stdout.strip())
    if result.returncode != 0:
        print(result.stderr.strip()[-2000:])
        failures += 1
    if args.python and result.returncode == 0:
        failures += subprocess.run([args.python, '-c', check, str(out)]).returncode != 0
sys.exit(1 if failures else 0)
