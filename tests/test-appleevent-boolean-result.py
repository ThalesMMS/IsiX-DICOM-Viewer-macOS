#!/usr/bin/env python3
"""Exercise real AppleScript boolean replies through Nitrogen's converter.

The converter is Swift since #710 (NSAppleEventDescriptor+N2.swift): by default
the program links a library compiled from it with the Objective-C it calls
(HorosObjCException). --source compiles an Objective-C NSAppleEventDescriptor+N2.mm
instead, which applies to the converter before #710 (e.g. from `git show REV:...`).
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
import object_probe  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path,
                    help='an Objective-C NSAppleEventDescriptor+N2.mm (the converter before #710)')
args = parser.parse_args()
program = r'''
#import <Cocoa/Cocoa.h>
#import "NSAppleEventDescriptor+N2.h"
int main() { @autoreleasepool {
    NSArray *sources = @[@"return true", @"return false", @"return {true, false, 2 > 1}"];
    NSArray *expected = @[@YES, @NO, (@[@YES, @NO, @YES])];
    for (NSUInteger i=0; i<sources.count; ++i) {
        NSAppleScript *script=[[[NSAppleScript alloc] initWithSource:sources[i]] autorelease];
        NSDictionary *error=nil;
        NSAppleEventDescriptor *result=[script executeAndReturnError:&error];
        if (error || !result) return 1;
        @try { if (![[result object] isEqual:expected[i]]) return 1; }
        @catch (NSException *exception) { fprintf(stderr,"%s\n",exception.reason.UTF8String); return 1; }
    }
    for (NSNumber *value in @[@YES, @NO]) {
        NSAppleEventDescriptor *descriptor=[NSAppleEventDescriptor descriptorWithBoolean:value.boolValue];
        if (![[descriptor object] isEqual:value]) return 1;
    }
    // Exercise the ObjC keyed fallback, both new API writes and released payloads.
    for (id value in @[[NSData dataWithBytes:"abc" length:3], [NSDate dateWithTimeIntervalSince1970:12345]]) {
        NSAppleEventDescriptor *current=[NSAppleEventDescriptor descriptorWithObject:value];
        if (![[current object] isEqual:value]) return 1;
        NSData *legacy=[NSKeyedArchiver archivedDataWithRootObject:value];
        NSAppleEventDescriptor *old=[NSAppleEventDescriptor descriptorWithDescriptorType:'ObjC' data:legacy];
        if (![[old object] isEqual:value]) return 1;
        NSAppleEventDescriptor *truncated=[NSAppleEventDescriptor descriptorWithDescriptorType:'ObjC'
            data:[legacy subdataWithRange:NSMakeRange(0,legacy.length/2)]];
        BOOL refused=NO;
        @try { (void)[truncated object]; } @catch (NSException *exception) { refused=YES; }
        if (!refused) return 1;
    }
    NSData *unexpected=[NSKeyedArchiver archivedDataWithRootObject:[NSSet setWithObject:@"x"]];
    BOOL refused=NO;
    @try { (void)[[NSAppleEventDescriptor descriptorWithDescriptorType:'ObjC' data:unexpected] object]; }
    @catch (NSException *exception) { refused=YES; }
    if (!refused) return 1;
    puts("PASS: real AppleScript true/false and nested boolean replies; ordinary boolean descriptors preserved");
} }
'''
with tempfile.TemporaryDirectory(prefix='horos-appleevent-bool-') as temp:
    directory = Path(temp)
    source = directory / 'main.mm'
    source.write_text(program)
    binary = directory / 'test'
    if args.source:
        implementation = [str(args.source)]
    else:
        helper = object_probe.first_app_object('HorosObjCException')
        if helper is None:
            print('needs a built HorosObjCException.o: script/build_and_run.sh', file=sys.stderr)
            raise SystemExit(2)
        bridging = directory / 'bridging.h'
        bridging.write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                            '#import "NSAppleEventDescriptor+N2.h"\n#import "HorosObjCException.h"\n')
        library = object_probe.swift_dylib([root / 'Nitrogen/Sources/NSAppleEventDescriptor+N2.swift'], [helper],
                                           directory / 'libNSAppleEventDescriptorN2.dylib', bridging_header=bridging,
                                           include_dirs=(root / 'Nitrogen/Sources', root / 'Horos/Sources'),
                                           frameworks=('Cocoa',))
        implementation = [str(library), '-Wl,-rpath,' + str(directory)]
    subprocess.run(['xcrun', 'clang++', '-fno-objc-arc', '-Wno-deprecated-declarations',
                    '-I', str(root / 'Nitrogen/Sources'), *implementation, str(source),
                    '-framework', 'Cocoa', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
