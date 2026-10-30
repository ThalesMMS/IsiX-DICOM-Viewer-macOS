#!/usr/bin/env python3
"""Reading the annotations of an SR that holds none raises nothing.

A study archives its annotations (comments, state, key images) in an SR. Before
the first archive that file does not exist: DicomStudy still opens it, to
compare what it holds with what is to be written, and -[SRAnnotation
annotations] handed the missing data to NSPropertyListSerialization, which
raises on nil. The method caught the exception and logged it with its stack
at every first key image of a study.

-[SRAnnotation annotations] is compiled here as it is written, in a class with
the one stored value it reads (SRAnnotation.swift, or the Objective-C++ of an
earlier revision):
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
SWIFT = 'Horos/Sources/SRAnnotation.swift'
swift = None
if revision:
    shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{PATH}'], capture_output=True)
    if shown.returncode:
        swift = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{SWIFT}']).decode('utf-8')
    else:
        text = shown.stdout.decode('latin1')
elif (root / SWIFT).is_file():
    swift = (root / SWIFT).read_text(encoding='utf-8')
else:
    text = (root / PATH).read_bytes().decode('latin1')

if swift is None:
    start = text.index('- (NSDictionary*) annotations\n')
    method = text[start:text.index('\n}\n', start) + 3]
else:
    start = swift.index('    func annotations() -> [AnyHashable: Any]! {')
    method = swift[start:swift.index('\n    }\n', start) + 7]

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

# The Swift method, in a class whose one stored value is the one it reads; the
# Objective-C class of the driver forwards to it.
SWIFT_CLASS = r'''
import Foundation

@_silgen_name("countLoggedException")
func countLoggedException(_ stack: Bool)

func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ function: String) { countLoggedException(stack) }

extension HorosObjCException {
    static func caught(_ body: () -> Void) -> NSException? {
        do {
            try perform(body)
            return nil
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
    }
}

@objc(SRAnnotationProbe) public final class SRAnnotationProbe: NSObject {
    @objc public var horos_dataEncapsulated: NSData?
METHOD
}
'''

SWIFT_DRIVER = r'''
#import <Foundation/Foundation.h>
#import <objc/objc-exception.h>

static int logged = 0, raised = 0;
void countLoggedException(BOOL stack) { logged++; }

@interface SRAnnotationProbe : NSObject
@property (nullable, strong) NSData *horos_dataEncapsulated;
- (nullable NSDictionary *)annotations;
@end

static id count(id exception) { raised++; return exception; }

static int failed = 0;
static void check(BOOL condition, const char *what) {
    if (!condition) { fprintf(stderr, "FAIL: %s (logged %d, raised %d)\\n", what, logged, raised); failed = 1; }
    logged = raised = 0;
}

int main(void) { @autoreleasepool {
    objc_setExceptionPreprocessor(count);
    SRAnnotationProbe *annotation = [SRAnnotationProbe new];

    NSDictionary *none = [annotation annotations];
    check(none == nil && logged == 0 && raised == 0, "an SR without data must answer nil, raising and logging nothing");

    NSDictionary *archived = @{@"comment": @"read", @"stateText": @4, @"keyImages": @[@"1.2.3"]};
    annotation.horos_dataEncapsulated = [NSPropertyListSerialization dataWithPropertyList:archived format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    check([[annotation annotations] isEqual:archived] && logged == 0 && raised == 0, "the archived annotations are not read back");

    annotation.horos_dataEncapsulated = [NSData dataWithBytes:"\\x01\\x02not a property list" length:22];
    check([annotation annotations] == nil && raised == 0, "data that is no property list must answer nil without raising");

    annotation.horos_dataEncapsulated = [NSData data];
    check([annotation annotations] == nil && raised == 0, "empty data must answer nil without raising");

    if (failed) return 1;
    puts("PASS: no data, archived annotations, data that is no property list and empty data");
    return 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-sr-annotations-') as folder:
    folder = Path(folder)
    if swift is None:
        (folder / 'main.m').write_bytes(DRIVER.replace('METHOD', method).encode('latin1'))
        subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-Wno-deprecated-declarations', str(folder / 'main.m'),
                        '-framework', 'Foundation', '-o', str(folder / 'check')], check=True)
    else:
        # The method as written, made public for the probe class.
        (folder / 'bridge.h').write_text('#import "HorosObjCException.h"\n')
        (folder / 'probe.swift').write_text(SWIFT_CLASS.replace('METHOD', method.replace(
            '    func annotations()', '    @objc public func annotations()')))
        (folder / 'main.m').write_text(SWIFT_DRIVER)
        include = '-I' + str(root / 'Horos/Sources')
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-wmo', '-module-name', 'Probe', '-import-objc-header',
                        str(folder / 'bridge.h'), '-Xcc', include, '-c', str(folder / 'probe.swift'),
                        '-o', str(folder / 'probe.o')], check=True)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', include, '-c', str(root / 'Horos/Sources/HorosObjCException.m'),
                        '-o', str(folder / 'exception.o')], check=True)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', str(folder / 'main.m'), '-o', str(folder / 'main.o')],
                       check=True)
        subprocess.run(['xcrun', 'swiftc', str(folder / 'probe.o'), str(folder / 'exception.o'), str(folder / 'main.o'),
                        '-framework', 'Foundation', '-o', str(folder / 'check')], check=True)
    ran = subprocess.run([str(folder / 'check')], capture_output=True, text=True, timeout=60)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        sys.exit(1)
    print(ran.stdout.strip())
