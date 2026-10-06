#!/usr/bin/env python3
"""The GETDI reply of a database-sharing peer, read without instantiating its classes.

Before a copy between two shared databases, the browser asks the destination
for its DICOM listener with +[RemoteDicomDatabase
fetchDicomDestinationInfoForAddress:port:]. The peer answers with NSArchiver
data, which the client handed to NSUnarchiver: whatever answered on the port
chose the classes instantiated. The client now reads the reply with
HorosSharedDatabaseDestinationInfo, which accepts a dictionary of strings and
builds it without looking up any class the data names.

The probe compiles the real method (extracted from RemoteDicomDatabase.mm, or
from RemoteDicomDatabase.swift, into a Swift stand-in of the class),
the real N2Connection.mm it sends the request with, and the real
SharedDatabaseDestinationInfo.swift. A fake peer on 127.0.0.1 answers each
case: replies archived as Horos servers make them decode to the same
dictionary; archives holding a marker class, whose -initWithCoder: records that
it ran, another Foundation class, trailing or truncated bytes, or no archive at
all raise, and the marker never runs.

Optional argument: a git revision whose RemoteDicomDatabase (.mm or .swift) and
N2Connection.mm are used instead of the working tree's (a negative control:
before the fix the marker was instantiated and the other classes returned).

Exit status: 0 all cases pass, 1 a case failed, 2 the probe could not be built.
"""
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402

REMOTE_MM = 'Horos/Sources/RemoteDicomDatabase.mm'
REMOTE_SWIFT = 'Horos/Sources/RemoteDicomDatabase.swift'
CONNECTION = 'Nitrogen/Sources/N2Connection.mm'
READER = 'Horos/Sources/SharedDatabaseDestinationInfo.swift'

PROBE = r'''
#import <Foundation/Foundation.h>
#import "N2Connection.h"

extern "C" {
extern NSString* const N2ErrorDomain; NSString* const N2ErrorDomain = @"N2";
void N2LogStackTrace(NSString* format, ...) {}
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) {}
}

static BOOL markerInstantiated = NO;

// A class outside the dictionary of strings a peer may send.
@interface HorosArchiveProbeMarker : NSObject <NSCoding, NSCopying>
@end
@implementation HorosArchiveProbeMarker
- (id)copyWithZone:(NSZone*)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder*)coder {
    markerInstantiated = YES;
    int value = 0; [coder decodeValueOfObjCType:@encode(int) at:&value size:sizeof(value)];
    return [super init];
}
- (void)encodeWithCoder:(NSCoder*)coder { int value = 1; [coder encodeValueOfObjCType:@encode(int) at:&value]; }
@end

@interface HorosSharedDatabaseDestinationInfo : NSObject
+ (NSDictionary*)dictionaryFromReply:(NSData*)reply;
@end

@interface RemoteDicomDatabase : NSObject
+ (NSDictionary*)fetchDicomDestinationInfoForAddress:(NSString*)address port:(NSInteger)port;
@end
ACTUAL_IMPLEMENTATION

static NSData* archive(id object) { return [NSArchiver archivedDataWithRootObject:object]; }

static void makeArchives(NSString* directory) {
    NSMutableDictionary* archives = [NSMutableDictionary dictionary];
    // As Horos servers answer: +dictionaryWithObjectsAndKeys: of the defaults.
    archives[@"legit"] = archive([NSDictionary dictionaryWithObjectsAndKeys:@"HOROS", @"AETitle", @"11112", @"Port",
                                  [NSString stringWithFormat:@"%d", 3], @"TransferSyntax", nil]);
    NSMutableDictionary* mutableInfo = [NSMutableDictionary dictionary];
    mutableInfo[@"AETitle"] = [NSMutableString stringWithString:@"MUTABLE"];
    mutableInfo[@"Port"] = [NSMutableString stringWithString:@"104"];
    archives[@"mutable"] = archive(mutableInfo);
    NSString* same = [NSString stringWithFormat:@"%d", 4242];
    archives[@"shared"] = archive(@{@"Port": same, @"TransferSyntax": same, same: same});
    archives[@"long"] = archive(@{@"AETitle": [@"HÖRÖS ✓ " stringByPaddingToLength:300 withString:@"x" startingAtIndex:0]});
    archives[@"empty"] = archive(@{});
    HorosArchiveProbeMarker* marker = [[HorosArchiveProbeMarker new] autorelease];
    archives[@"marker"] = archive(@{@"AETitle": marker});
    archives[@"markerRoot"] = archive(marker);
    archives[@"markerNested"] = archive(@{@"AETitle": @[marker]});
    archives[@"markerKey"] = archive(@{(id)marker: @"HOROS"});
    NSMutableData* trailing = [[archives[@"legit"] mutableCopy] autorelease];
    [trailing appendData:archive(marker)];
    archives[@"markerTrailing"] = trailing;
    archives[@"url"] = archive(@{@"AETitle": [NSURL URLWithString:@"http://127.0.0.1/"]});
    archives[@"number"] = archive(@{@"Port": @11112});
    archives[@"truncated"] = [archives[@"legit"] subdataWithRange:NSMakeRange(0, [archives[@"legit"] length] - 1)];
    archives[@"keyed"] = [NSKeyedArchiver archivedDataWithRootObject:@{@"AETitle": @"HOROS"} requiringSecureCoding:YES error:NULL];
    archives[@"garbage"] = [@"not an archive" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString* name in archives)
        [archives[name] writeToFile:[directory stringByAppendingPathComponent:name] atomically:NO];
}

// Every prefix of each archive, and each byte replaced by tags and extremes:
// the reader returns nil or a dictionary of strings, never crashes, and never
// runs the marker. Prints how many variants it accepted.
static int mutate(NSString* directory) {
    const uint8_t replacements[] = {0x00, 0x01, 0x7f, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x92, 0x93, 0xff};
    NSUInteger accepted = 0, variants = 0;
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
        NSData* original = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        NSMutableArray* inputs = [NSMutableArray array];
        for (NSUInteger length = 0; length < original.length; length++)
            [inputs addObject:[original subdataWithRange:NSMakeRange(0, length)]];
        for (NSUInteger i = 0; i < original.length; i++)
            for (size_t r = 0; r < sizeof(replacements); r++) {
                NSMutableData* variant = [[original mutableCopy] autorelease];
                ((uint8_t*)variant.mutableBytes)[i] = replacements[r];
                [inputs addObject:variant];
            }
        for (NSData* input in inputs) {
            @autoreleasepool {
                variants++;
                NSDictionary* info = [HorosSharedDatabaseDestinationInfo dictionaryFromReply:input];
                if (!info) continue;
                accepted++;
                for (id key in info)
                    if (![key isKindOfClass:[NSString class]] || ![info[key] isKindOfClass:[NSString class]]) {
                        printf("MUTATE not strings: %s\n", name.UTF8String); return 1;
                    }
            }
        }
    }
    if (markerInstantiated) { printf("MUTATE marker instantiated\n"); return 1; }
    printf("MUTATE %lu variants, %lu accepted\n", (unsigned long)variants, (unsigned long)accepted);
    return 0;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--archives")) { makeArchives(@(argv[2])); return 0; }
        if (argc == 3 && !strcmp(argv[1], "--mutate")) return mutate(@(argv[2]));
        NSMutableDictionary* report = [NSMutableDictionary dictionary];
        @try {
            NSDictionary* info = [RemoteDicomDatabase fetchDicomDestinationInfoForAddress:@"127.0.0.1" port:atoi(argv[1])];
            NSMutableDictionary* result = [NSMutableDictionary dictionary];
            BOOL strings = [info isKindOfClass:[NSDictionary class]];
            if (strings)
                for (id key in info) {
                    id value = info[key];
                    if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) strings = NO;
                    result[[key description]] = [value description];
                }
            report[@"result"] = info ? result : [NSNull null];
            report[@"classes"] = strings ? @"strings" : NSStringFromClass([info class]) ?: @"nil";
        } @catch (NSException* e) {
            report[@"exception"] = e.name;
        }
        report[@"marker"] = @(markerInstantiated);
        NSData* json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        printf("REPORT %s\n", [[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease] UTF8String]);
    }
    return 0;
}
'''

REFUSED = {'exception': 'NSInternalInconsistencyException', 'marker': False}
CASES = [
    ('a reply as Horos servers make it', 'legit',
     {'result': {'AETitle': 'HOROS', 'Port': '11112', 'TransferSyntax': '3'}, 'classes': 'strings', 'marker': False}),
    ('a mutable dictionary of mutable strings', 'mutable',
     {'result': {'AETitle': 'MUTABLE', 'Port': '104'}, 'classes': 'strings', 'marker': False}),
    ('one string archived once and referenced as key and values', 'shared',
     {'result': {'Port': '4242', 'TransferSyntax': '4242', '4242': '4242'}, 'classes': 'strings', 'marker': False}),
    ('a long UTF-8 string', 'long',
     {'result': {'AETitle': 'HÖRÖS ✓ '.ljust(300, 'x')}, 'classes': 'strings', 'marker': False}),
    ('an empty dictionary', 'empty', {'result': {}, 'classes': 'strings', 'marker': False}),
    ('another class as a value', 'marker', REFUSED),
    ('another class as the root', 'markerRoot', REFUSED),
    ('another class in a nested list', 'markerNested', REFUSED),
    ('another class as a key', 'markerKey', REFUSED),
    ('another class after a valid reply', 'markerTrailing', REFUSED),
    ('an NSURL value', 'url', REFUSED),
    ('an NSNumber value', 'number', REFUSED),
    ('a truncated reply', 'truncated', REFUSED),
    ('a keyed archive', 'keyed', REFUSED),
    ('data that is no archive', 'garbage', REFUSED),
]


def method(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return source[start:end + 1]
    raise ValueError(signature)


def serve(reply: bytes, requests: list) -> int:
    """A peer on 127.0.0.1 that answers one connection with `reply` and closes."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(30)

    def run():
        try:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(10)
                request = b''
                while len(request) < 6:
                    chunk = connection.recv(6 - len(request))
                    if not chunk:
                        break
                    request += chunk
                requests.append(request)
                connection.sendall(reply)
        except OSError as error:
            requests.append(repr(error).encode())
        finally:
            listener.close()

    threading.Thread(target=run, daemon=True).start()
    return listener.getsockname()[1]


def main() -> int:
    revision = sys.argv[1] if len(sys.argv) > 1 else None
    with tempfile.TemporaryDirectory(prefix='horos-remote-destination-info-') as temp:
        directory = Path(temp)
        def read(relative):
            if revision:
                shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{relative}'], capture_output=True)
                return shown.stdout if shown.returncode == 0 else None
            return (root / relative).read_bytes() if (root / relative).is_file() else None

        # The class is RemoteDicomDatabase.mm before its move to Swift and RemoteDicomDatabase.swift after.
        if revision:
            remote = REMOTE_MM if read(REMOTE_MM) is not None else REMOTE_SWIFT
        else:
            remote = str(source_path('RemoteDicomDatabase').relative_to(root))
        swift = remote.endswith('.swift')
        connection = read(CONNECTION)
        (directory / 'N2Connection.mm').write_bytes(connection)
        if swift:
            # The Swift method in a Swift stand-in of the class, which the probe calls
            # by its Objective-C name.
            actual = method(read(remote).decode('utf-8'), '@objc(fetchDicomDestinationInfoForAddress:port:)')
            (directory / 'remote.swift').write_text(
                'import Foundation\n\n@objc(RemoteDicomDatabase) public final class RemoteDicomDatabase: NSObject {\n    '
                + actual + '\n}\n')
            (directory / 'bridge.h').write_text('#import "N2Connection.h"\n')
            (directory / 'probe.mm').write_bytes(PROBE.encode().replace(b'ACTUAL_IMPLEMENTATION', b''))
        else:
            actual = method(read(remote).decode('latin1'), '+(NSDictionary*)fetchDicomDestinationInfoForAddress:')
            (directory / 'probe.mm').write_bytes(PROBE.encode().replace(
                b'ACTUAL_IMPLEMENTATION', b'@implementation RemoteDicomDatabase\n' + actual.encode('latin1') + b'\n@end'))

        objects = []
        for name in ('probe.mm', 'N2Connection.mm'):
            output = directory / (name + '.o')
            build = subprocess.run(['xcrun', 'clang++', '-c', '-x', 'objective-c++', '-fno-objc-arc', '-w',
                                    '-I', str(root / 'Nitrogen/Sources'), str(directory / name), '-o', str(output)],
                                   capture_output=True, text=True)
            if build.returncode:
                print(build.stderr[-2000:], file=sys.stderr)
                print(f'SKIP: {name} did not compile')
                return 2
            objects.append(str(output))
        binary = directory / 'probe'
        remote_swift = ['-import-objc-header', str(directory / 'bridge.h'), '-Xcc', '-I' + str(root / 'Nitrogen/Sources'),
                        str(directory / 'remote.swift')] if swift else []
        build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', '-module-name', 'Probe',
                                *remote_swift, str(root / READER), *objects, '-lc++', '-framework', 'Cocoa', '-o', str(binary)],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-2000:], file=sys.stderr)
            print('SKIP: the probe did not link')
            return 2

        archives = directory / 'archives'
        archives.mkdir()
        made = subprocess.run([str(binary), '--archives', str(archives)], capture_output=True, text=True, timeout=60)
        if made.returncode:
            print(f'FAIL: the probe made no archives: {made.stderr.strip()[-400:]}')
            return 1

        failures = 0
        # The references case is one only if the string was archived once.
        if (archives / 'shared').read_bytes().count(b'4242') != 1:
            print('FAIL: the shared archive does not reference its one string')
            failures += 1
        for description, name, expected in CASES:
            requests = []
            port = serve((archives / name).read_bytes(), requests)
            run = subprocess.run([str(binary), str(port)], capture_output=True, text=True, timeout=90)
            lines = [line for line in run.stdout.splitlines() if line.startswith('REPORT ')]
            if run.returncode or not lines:
                tail = run.stderr.strip().splitlines()[-1] if run.stderr.strip() else 'no output'
                print(f'FAIL: {description}: the probe ended with status {run.returncode} ({tail})')
                failures += 1
                continue
            report = json.loads(lines[-1][len('REPORT '):])
            if requests != [b'GETDI\0']:
                print(f'FAIL: {description}: the peer received {requests}, not one GETDI request')
                failures += 1
            elif report != expected:
                print(f'FAIL: {description}: {report} (expected {expected})')
                failures += 1
            else:
                print(f'PASS: {description}')

        # The reader itself, on damaged replies (only where the method uses it;
        # Swift names it SharedDatabaseDestinationInfo).
        if ('SharedDatabaseDestinationInfo.dictionary(fromReply:' if swift else 'HorosSharedDatabaseDestinationInfo') in actual:
            run = subprocess.run([str(binary), '--mutate', str(archives)], capture_output=True, text=True, timeout=300)
            summary = [line for line in run.stdout.splitlines() if line.startswith('MUTATE ')]
            if run.returncode or not summary:
                print(f'FAIL: damaged replies: status {run.returncode} {summary or run.stderr.strip()[-400:]}')
                failures += 1
            else:
                print(f'PASS: damaged replies ({summary[-1][len("MUTATE "):]}), none crashed or ran the marker')
        return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
