#!/usr/bin/env python3
"""A custom annotation reads the element it names, private ones included.

Compiles the production field lookup (DCMPix+Annotations.swift, with the
IsiXImaging rules it uses) against the dataset model and DCMTK of the Debug build and runs it on a
synthetic file. Needs that build, which this repository does not carry; the
file comes from tools/generate-private-annotation-fixture.py.

Usage: python test-private-annotation-field.py PRODUCTS_DIR PRIVATE_FIXTURE
       PRODUCTS_DIR is build/Build/Products/Debug, of a build that left its DCMTK
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from horos_reader import ADAPTERS, compile_reader
import isix_modules

if len(sys.argv) < 3:
    print('skipped: needs the dataset model and DCMTK of the Debug build and a private-block fixture: '
          'PRODUCTS_DIR PRIVATE_FIXTURE', file=sys.stderr)
    raise SystemExit(2)

root = Path(__file__).resolve().parents[1]
products = Path(sys.argv[1]).resolve()
fixture = Path(sys.argv[2]).resolve()

source = (root / 'Horos/Sources/DCMPix+Annotations.swift').read_text()
start = source.index('    @objc(getDICOMFieldValueForGroup:element:DCMLink:)\n')
lookup = source[start:source.index('\n    }\n', start) + len('\n    }\n')]

# The lookup in a class of its own, with the two formatters it reaches for dates and times.
probe = r'''
import Foundation
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXImaging

final class BrowserController {
    static func time(withSecondsFormat date: Date) -> String { date.description }
    static func dateTime(withSecondsFormat date: Date) -> String { date.description }
}

extension UserDefaults {
    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter
    }
}

@objc(PixProbe) public final class PixProbe: NSObject {
LOOKUP}
'''.replace('LOOKUP', lookup)

program = r'''
#import <Foundation/Foundation.h>
#import "DCMModel.h"
#import "HorosDCMTKObject.h"
extern "C" void HorosTestRegisterDecoders(void);

@interface PixProbe : NSObject
- (NSString*) getDICOMFieldValueForGroup:(int) group element:(int) element DCMLink:(DCMObject*) dcmObject;
@end

static int failures = 0;
#define check(...) do{ if(!(__VA_ARGS__)){ NSLog(@"FAIL: %s", #__VA_ARGS__); failures++; } }while(0)

int main(int argc, char **argv) { @autoreleasepool {
    HorosTestRegisterDecoders();
    DCMObject *object = [HorosDCMTKObject objectWithContentsOfFile: [NSString stringWithUTF8String: argv[1]]];
    check(object != nil);

    PixProbe *probe = [PixProbe new];

    // The tag from the report, under its private creator.
    NSString *privateValue = [probe getDICOMFieldValueForGroup: 0x0011 element: 0x1005 DCMLink: object];
    check([privateValue isEqualToString: @"private annotation"]);

    // The same element under a different private group is a different value:
    // a lookup that ignores the group would return one for the other.
    NSString *other = [probe getDICOMFieldValueForGroup: 0x0013 element: 0x1005 DCMLink: object];
    check([other isEqualToString: @"other block"]);

    // A neighbouring element of the same block, to catch an off-by-one.
    NSString *number = [probe getDICOMFieldValueForGroup: 0x0011 element: 0x1006 DCMLink: object];
    check([number isEqualToString: @"42.5"]);

    // The private creator itself is readable, which is what names the block.
    NSString *creator = [probe getDICOMFieldValueForGroup: 0x0011 element: 0x0010 DCMLink: object];
    check([creator isEqualToString: @"HOROS PRIVATE TEST"]);

    // The patient name is the patient's name, not the word "PatientName".
    NSString *name = [probe getDICOMFieldValueForGroup: 0x0010 element: 0x0010 DCMLink: object];
    check(name != nil && [name rangeOfString: @"PRIVATE"].location != NSNotFound);
    check([name isEqualToString: @"PatientName"] == NO);

    // An element the file does not carry is absent, not another field's value.
    check([probe getDICOMFieldValueForGroup: 0x0011 element: 0x10ff DCMLink: object] == nil);
    check([probe getDICOMFieldValueForGroup: 0x0099 element: 0x0099 DCMLink: object] == nil);

    // No dictionary describes these tags, and asking for them does not raise.
    @try {
        for (int element = 0x1000; element < 0x1010; element++)
            [probe getDICOMFieldValueForGroup: 0x0011 element: element DCMLink: object];
    } @catch (NSException *e) {
        NSLog(@"FAIL: raised for a private tag: %@", e);
        failures++;
    }

    NSLog(@"%@", failures ? @"FAILURES" : @"lookup correct");
    return failures ? 1 : 0;
}}
'''

# The placeholder that showed the word instead of the name, in both places.
assert '"PatientName"' not in source, 'a custom annotation on the patient name still shows the literal word'

with tempfile.TemporaryDirectory(prefix='horos-private-annotation-') as tmp:
    p = Path(tmp)
    (p / 'bin').mkdir()
    (p / 'test.m').write_text(program)
    # The Swift lookup, with the modules it imports (IsiXDICOMDataset, the
    # dataset model, over IsiXDICOMFile and IsiXImaging), built where
    # compile_reader builds them, p / 'modules'.
    modules = p / 'modules'
    isix_modules.build_module('IsiXDICOMDataset', modules, ['-target', 'arm64-apple-macos15.0'])
    (p / 'probe.swift').write_text(probe)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-c', '-module-name', 'PrivateAnnotationProbe',
                    '-target', 'arm64-apple-macos15.0',
                    '-Xcc', '-I' + str(ADAPTERS), '-Xcc', '-I' + str(modules), '-I', str(modules),
                    str(p / 'probe.swift'), '-o', str(p / 'probe.o')], check=True, cwd=p)
    compile_reader(products, p / 'test.m', p / 'bin/test', p, extra=[str(p / 'probe.o')])
    subprocess.run([str(p / 'bin/test'), str(fixture)], check=True)

print('PASS: private elements read under their own group, the private creator reads, '
      'absent tags are absent, and the patient name is the name')
