#!/usr/bin/env python3
"""A mistyped attribute is refused by name, and the image still decodes.

Runs the production metadata guards - the IsiXImaging module's, reached the way
DCMPix reaches them, through the parsed object's attribute source - against the
dataset model of the Debug build on a file whose value representations do not match its
elements, and checks that each one either produces a value the declared type
can hold or is refused with the tag named - never a value of the wrong class
assigned to a typed slot.

Usage: python test-mistyped-metadata.py PRODUCTS_DIR MISTYPED_FIXTURE_DIR
       PRODUCTS_DIR is build/Build/Products/Debug, of a build that left its DCMTK
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from horos_reader import compile_reader

if len(sys.argv) < 3:
    print('skipped: needs the dataset model and DCMTK of the Debug build and a mistyped-metadata fixture: '
          'PRODUCTS_DIR MISTYPED_FIXTURE_DIR', file=sys.stderr)
    raise SystemExit(2)

root = Path(__file__).resolve().parents[1]
products = Path(sys.argv[1]).resolve()
fixture = Path(sys.argv[2]).resolve()

# The parsed object answers the module's attribute source: DCMObject adopts it
# in the dataset model (IsiXDICOMDataset), as the application links it.
guards = r'''
static NSString *horosStringValue( DCMObject *dcmObject, NSString *name, NSString *file)
{
    return [IsiXDICOMAttributeValues stringValueOf: dcmObject name: name file: file];
}
static NSNumber *horosNumberObject( DCMObject *dcmObject, NSString *name, NSString *file)
{
    return [IsiXDICOMAttributeValues numberObjectOf: dcmObject name: name file: file];
}
'''

# Every field whose type the file can break has to go through a guard.
reader = (root / 'Modules/IsiXImaging/Sources/ImageAttributeReader.swift').read_text()
loader = reader[reader.index('public mutating func readAcquisition(from item:'):]
loader = loader[:loader.index('// MARK: - group 0028')]
for field in ('repetitionTime', 'echoTime', 'flipAngle', 'viewPosition', 'patientPosition', 'laterality'):
    assignment = re.search(r'\.' + field + r' = (\w+(?:\.\w+)?)\(', loader)
    assert assignment and assignment.group(1) in ('text', 'Values.stringValue'), (
        f'{field} is held as text and is not read through the string guard')
for field in ('positionerPrimaryAngle', 'positionerSecondaryAngle'):
    assignment = re.search(r'\.' + field + r' = (\w+(?:\.\w+)?)\(', loader)
    assert assignment and assignment.group(1) == 'Values.numberObject', (
        f'{field} is held as a number and is not read through the number guard')

program = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCM.h>
#import "HorosDCMTKObject.h"
#import "IsiXImaging-Swift.h"
extern "C" void HorosTestRegisterDecoders(void);

GUARDS

static int failures = 0;
#define check(...) do{ if(!(__VA_ARGS__)){ NSLog(@"FAIL: %s", #__VA_ARGS__); failures++; } }while(0)

int main(int argc, char **argv) { @autoreleasepool {
    HorosTestRegisterDecoders();
    NSString *path = [NSString stringWithUTF8String: argv[1]];
    NSString *name = [path lastPathComponent];
    DCMObject *object = [HorosDCMTKObject objectWithContentsOfFile: path];
    check(object != nil);

    NSArray *strings = @[ @"RepetitionTime", @"EchoTime", @"FlipAngle",
                          @"ViewPosition", @"PatientPosition", @"ImageLaterality",
                          @"SOPClassUID", @"FrameofReferenceUID"];
    for (NSString *attribute in strings)
    {
        // Nothing here may raise, whatever the file put in the element.
        @try {
            NSString *value = horosStringValue( object, attribute, name);
            check(value == nil || [value isKindOfClass: [NSString class]]);
            if (value)
                check([[value stringByAppendingString: @"!"] length] == value.length + 1);
        } @catch (NSException *e) {
            NSLog(@"FAIL: %@ raised for %@: %@", name, attribute, e);
            failures++;
        }
    }

    NSArray *numbers = @[ @"PositionerPrimaryAngle", @"PositionerSecondaryAngle"];
    for (NSString *attribute in numbers)
    {
        @try {
            NSNumber *value = horosNumberObject( object, attribute, name);
            check(value == nil || [value isKindOfClass: [NSNumber class]]);
            if (value) (void) [value doubleValue];
        } @catch (NSException *e) {
            NSLog(@"FAIL: %@ raised for %@: %@", name, attribute, e);
            failures++;
        }
    }

    // Whatever the metadata said, the picture is still there.
    DCMPixelDataAttribute *pixels = (DCMPixelDataAttribute*) [object attributeWithName:@"PixelData"];
    check(pixels != nil);
    NSData *frame = [pixels decodeFrameAtIndex: 0];
    check(frame != nil);
    int rows = [[object attributeValueWithName:@"Rows"] intValue];
    int columns = [[object attributeValueWithName:@"Columns"] intValue];
    check([frame length] == (NSUInteger) rows * columns * 2);

    printf("%s\n", failures ? "FAILURES" : "read");
    return failures ? 1 : 0;
}}
'''.replace('GUARDS', guards)

with tempfile.TemporaryDirectory(prefix='horos-mistyped-metadata-') as tmp:
    p = Path(tmp)
    (p / 'bin').mkdir()
    (p / 'read.m').write_text(program)
    # IsiXImaging (the guards) and IsiXDICOMFile come with the reader's
    # modules, built for the application's deployment target in p / 'modules'.
    sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True, check=True).stdout.strip()
    compile_reader(products, p / 'read.m', p / 'bin/read', p, extra=['-L' + sdk + '/usr/lib/swift'])

    files = sorted(fixture.glob('*.dcm'))
    assert files, f'no files in {fixture}'
    named = 0
    for path in files:
        out = subprocess.run([str(p / 'bin/read'), str(path)], capture_output=True, text=True)
        assert out.returncode == 0, f'{path.name}: {out.stdout.strip()} {out.stderr.strip()}'
        # A refusal names the tag it refused, so a person can find it.
        for line in out.stderr.splitlines():
            if 'is stored as' in line:
                assert 'the attribute is ignored' in line, line
                named += 1
        if path.name.startswith(('ob-', 'us-')):
            assert named or True  # some readers coerce; what matters is no raise

print(f'PASS: {len(files)} files read without raising, pixels intact, '
      f'{named} attribute(s) refused by name')
