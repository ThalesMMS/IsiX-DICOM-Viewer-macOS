#!/usr/bin/env python3
"""Reading the annotations of an SR that holds none raises nothing.

A study archives its annotations (comments, state, key images) in an SR. Before
the first archive that file does not exist: DicomStudy still opens it, to
compare what it holds with what is to be written, and -[SRAnnotation
annotations] handed the missing data to NSPropertyListSerialization, which
raises on nil. The method caught the exception and logged it with its stack
at every first key image of a study.

-[SRAnnotation annotations] is compiled here as it is written, in a class with
the one instance variable it reads:
- without data it answers nil, raising and logging nothing;
- with the property list an archive holds it answers the dictionary;
- with data that is no property list it answers nil, without raising.

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
PATH = 'Horos/Sources/SRAnnotation.mm'
if revision:
    text = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{PATH}']).decode('latin1')
else:
    text = (root / PATH).read_bytes().decode('latin1')

start = text.index('- (NSDictionary*) annotations\n')
method = text[start:text.index('\n}\n', start) + 3]

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang)', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
#import <Foundation/Foundation.h>
#import <objc/objc-exception.h>

static int logged = 0, raised = 0;
#define N2LogExceptionWithStackTrace(e) (logged++)

@interface SRAnnotation : NSObject { @public NSData *_dataEncapsulated; }
- (NSDictionary*) annotations;
@end
@implementation SRAnnotation
METHOD
@end

static id count(id exception) { raised++; return exception; }

static int failed = 0;
static void check(BOOL condition, const char *what) {
    if (!condition) { fprintf(stderr, "FAIL: %s (logged %d, raised %d)\n", what, logged, raised); failed = 1; }
    logged = raised = 0;
}

int main(void) { @autoreleasepool {
    objc_setExceptionPreprocessor(count);
    SRAnnotation *annotation = [[SRAnnotation new] autorelease];

    NSDictionary *none = [annotation annotations];
    check(none == nil && logged == 0 && raised == 0, "an SR without data must answer nil, raising and logging nothing");

    NSDictionary *archived = @{@"comment": @"read", @"stateText": @4, @"keyImages": @[@"1.2.3"]};
    annotation->_dataEncapsulated = [NSPropertyListSerialization dataWithPropertyList:archived format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    check([[annotation annotations] isEqual:archived] && logged == 0 && raised == 0, "the archived annotations are not read back");

    annotation->_dataEncapsulated = [NSData dataWithBytes:"\x01\x02not a property list" length:22];
    check([annotation annotations] == nil && raised == 0, "data that is no property list must answer nil without raising");

    annotation->_dataEncapsulated = [NSData data];
    check([annotation annotations] == nil && raised == 0, "empty data must answer nil without raising");

    if (failed) return 1;
    puts("PASS: no data, archived annotations, data that is no property list and empty data");
    return 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-sr-annotations-') as folder:
    folder = Path(folder)
    (folder / 'main.m').write_bytes(DRIVER.replace('METHOD', method).encode('latin1'))
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-Wno-deprecated-declarations', str(folder / 'main.m'),
                    '-framework', 'Foundation', '-o', str(folder / 'check')], check=True)
    ran = subprocess.run([str(folder / 'check')], capture_output=True, text=True, timeout=60)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        sys.exit(1)
    print(ran.stdout.strip())
