#!/usr/bin/env python3
"""The Swift XML-RPC connection answers as the Objective-C one did.

N2XMLRPCConnection was Objective-C++ on top of N2Connection, a stream
connection whose streams the XML-RPC interface no longer used: its listener
hands the connection the bytes received and sends what it writes. The
connection is Swift now, and the request framing, the reading of the method
call, the dispatch rules and the XML-RPC values (N2XMLRPC) are in the
IsiXHTTPServer module.

The same Objective-C driver is built twice: against N2Connection.mm,
N2XMLRPCConnection.mm and the N2XMLRPC of the last revision that had the
Objective-C connection (read from git), and against the working tree's Swift
connection, N2XMLRPC and module. It subclasses the connection as the
interface's listener does (the bytes so far at each arrival, what is written
captured, the sending reported as done) and runs:

- requests whole, byte by byte, without Content-Length, with a short, long,
  negative or zero Content-Length, in HTTP/1.0, with a request line that has
  no version, refused before their body, and a second request on the same
  connection;
- calls of published, unpublished, inherited and missing methods; too many
  parameters, a parameter that is not a struct, a nil one, one of an unknown
  type; methods that answer a value, nothing, an application error, another
  error, raise, answer a value XML-RPC cannot carry, take two parameters, take
  no error or no parameter;
- the same calls made in process (methodCall:params:error:);
- N2XMLRPC writing and reading every kind of value, and failing on those it
  cannot convert;
- the deadline: a connection closes itself 10 seconds after it opens.

Each case's written bytes, closes, request document, result and error, and
the lines it logged, must be the same in both.

Optional argument: the revision to compare with. Exit status: 0 the same,
1 a difference, 2 the reference or a compiler is not available.
"""
from pathlib import Path
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

CONNECTION = 'Nitrogen/Sources/N2XMLRPCConnection.mm'
BEFORE_PATHS = ['Nitrogen/Sources', 'Horos/Sources/HorosObjCException.h', 'Horos/Sources/HorosObjCException.m',
                'Horos/Sources/XMLRPCRequestContract.swift']
LOG_PREFIX = re.compile(r'^\d{4}-\d\d-\d\d [\d:.]+ \S+\[\d+:\w+\] ')

PROBE_CONNECTION = r'''
import Foundation

/// The listener's side: what the connection writes is kept, its closes are
/// counted, and a request carrying X-Refuse is refused before its body, as
/// the interface refuses one without its credential.
@objc(ProbeConnection) public final class ProbeConnection: N2XMLRPCConnection {
    @objc public let written = NSMutableData()
    @objc public var closes = 0

    private func refuses(_ request: CFHTTPMessage, _ version: String) -> Bool {
        guard CFHTTPMessageCopyHeaderFieldValue(request, "X-Refuse" as CFString) != nil else { return false }
        writeStatus(401, headers: ["WWW-Authenticate": "Basic realm=\"probe\""], version: version)
        return true
    }

    public override func close() {
        closes += 1
        super.close()
    }

#if PROBE_SWIFT_CONNECTION
    public override func write(_ data: Data) {
        written.append(data)
    }

    public override func shouldHandleRequest(_ request: CFHTTPMessage, version: String) -> Bool {
        refuses(request, version) ? false : super.shouldHandleRequest(request, version: version)
    }
#else
    public override func write(_ data: Data!) {
        written.append(data)
    }

    public override func shouldHandleRequest(_ request: CFHTTPMessage!, version: String!) -> Bool {
        refuses(request, version) ? false : super.shouldHandleRequest(request, version: version)
    }
#endif
}
'''

STUBS = r'''
#import <Foundation/Foundation.h>
#import "N2Debug.h"
// The parts of N2Debug and NSException+N2 the connections log through.
@implementation N2Debug
+ (BOOL)isActive { return NO; }
+ (void)setActive:(BOOL)active {}
@end
NSString* const N2ErrorDomain = @"N2";
void N2LogStackTrace(NSString* format, ...) {}
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"exception %@: %@", e.name, e.reason); }
'''

DRIVER = r'''#import <Foundation/Foundation.h>
#ifndef PROBE_SWIFT_CONNECTION
#import "N2XMLRPCConnection.h"
#endif
#import "Horos-Swift.h"

@interface ProbeDelegate : NSObject <N2XMLRPCConnectionDelegate>
@end

@implementation ProbeDelegate
- (NSString*)selectorStringForXMLRPCRequestMethodName:(NSString*)name {
    NSDictionary* published = @{@"echo": @"Echo:error:", @"fail": @"Fail:error:", @"other": @"Other:error:",
                                @"raise": @"Raise:error:", @"nothing": @"Nothing:error:", @"url": @"Url:error:",
                                @"two": @"Two:b:error:", @"noerror": @"NoError:", @"void": @"Void:error:",
                                @"zero": @"Zero:error:", @"missing": @"Missing:error:"};
    return published[[name lowercaseString]];
}
- (BOOL)isSelectorAvailableToXMLRPC:(NSString*)selector { return [selector isEqualToString:@"secret:error:"]; }
- (id)Echo:(NSDictionary*)p error:(NSError**)e {
    return @{@"echo": p ?: @"(nil)", @"int": @3, @"double": @2.5, @"bool": @YES, @"data": [NSData dataWithBytes:"\x01\xff" length:2],
             @"list": @[@"a<b", @"c&d"], @"date": [NSDate dateWithTimeIntervalSince1970:1790426096]};
}
- (id)Fail:(NSDictionary*)p error:(NSError**)e {
    if (e) *e = [NSError errorWithDomain:NSCocoaErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:
        @"<?xml version=\"1.0\"?><methodResponse><params><param><value><struct><member><name>error</name><value>400</value></member></struct></value></param></params></methodResponse>"}];
    return nil;
}
- (id)Other:(NSDictionary*)p error:(NSError**)e {
    if (e) *e = [NSError errorWithDomain:NSCocoaErrorDomain code:7 userInfo:@{NSLocalizedDescriptionKey: @"boom"}];
    return nil;
}
- (id)Raise:(NSDictionary*)p error:(NSError**)e { [NSException raise:NSGenericException format:@"went <wrong> & stayed"]; return nil; }
- (id)Nothing:(NSDictionary*)p error:(NSError**)e { return nil; }
- (id)Url:(NSDictionary*)p error:(NSError**)e { return [NSURL URLWithString:@"http://127.0.0.1/"]; }
- (id)Two:(id)a b:(id)b error:(NSError**)e { return @[a ? [a description] : @"nil", b ? [b description] : @"nil"]; }
- (id)NoError:(NSDictionary*)p { return @"plain"; }
- (void)Void:(NSDictionary*)p error:(NSError**)e { }
- (id)Zero:(NSError**)e { return @"zero"; }
- (id)secret:(NSDictionary*)p error:(NSError**)e { return @"secret"; }
- (id)hidden:(NSDictionary*)p error:(NSError**)e { return @"hidden"; }
@end

// ProbeConnection, the listener's side of the connection, is Swift (a Swift
// class cannot be subclassed in Objective-C): PROBE_CONNECTION below.

static NSString* printable(NSData* data) {
    NSString* text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return text ?: [data base64EncodedStringWithOptions:0];
}

static void emit(NSDictionary* record) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    fflush(stderr);
    printf("%s\n", [[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease] UTF8String]);
    fflush(stdout);
}

static NSString* describe(id object) {
    if (!object) return @"nil";
    if ([object isKindOfClass:[NSData class]]) return [@"data:" stringByAppendingString:[object base64EncodedStringWithOptions:0]];
    if ([object isKindOfClass:[NSDate class]]) return [NSString stringWithFormat:@"date:%.0f", [object timeIntervalSince1970]];
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray* items = [NSMutableArray array];
        for (id item in object) [items addObject:describe(item)];
        return [NSString stringWithFormat:@"[%@]", [items componentsJoinedByString:@","]];
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableArray* items = [NSMutableArray array];
        for (id key in [[object allKeys] sortedArrayUsingSelector:@selector(compare:)]) [items addObject:[NSString stringWithFormat:@"%@=%@", key, describe(object[key])]];
        return [NSString stringWithFormat:@"{%@}", [items componentsJoinedByString:@","]];
    }
    if ([object isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"number:%@:%s", object, [object objCType]];
    return [NSString stringWithFormat:@"%@:%@", [object isKindOfClass:[NSString class]] ? @"string" : NSStringFromClass([object class]), object];
}

// One request, received in the chunks given, as the listener hands them over:
// all the bytes so far, each time more arrive.
static void exchange(NSString* name, NSArray* chunks) {
    fprintf(stderr, "=== %s\n", name.UTF8String);
    ProbeDelegate* delegate = [[ProbeDelegate new] autorelease];
    ProbeConnection* c = [[ProbeConnection new] autorelease];
    c.delegate = delegate;
    c.dontSpecifyStringType = [name hasPrefix:@"untyped"];
    NSMutableData* received = [NSMutableData data];
    NSMutableArray* after = [NSMutableArray array];
    for (NSString* chunk in chunks) {
        [received appendData:[chunk dataUsingEncoding:NSUTF8StringEncoding]];
        [c handleData:received];
        [after addObject:@(c.written.length)];
    }
    NSInteger closesBeforeSent = c.closes;
    if (c.written.length) [c connectionFinishedSendingData];
    emit(@{@"case": name, @"written": printable(c.written), @"writtenAfterChunk": after,
           @"closesBeforeSent": @(closesBeforeSent), @"closes": @(c.closes), @"document": @(c.requestDocument != nil)});
}

static void direct(NSString* name, NSString* method, NSArray* params) {
    fprintf(stderr, "=== %s\n", name.UTF8String);
    ProbeConnection* c = [[ProbeConnection new] autorelease];
    c.delegate = [[ProbeDelegate new] autorelease];
    NSError* error = nil;
    NSString* outcome;
    @try {
        id result = [c methodCall:method params:params error:&error];
        outcome = describe(result);
    } @catch (NSException* e) {
        outcome = [NSString stringWithFormat:@"raised %@: %@", e.name, e.reason];
    }
    emit(@{@"case": name, @"result": outcome, @"error": error ? [NSString stringWithFormat:@"%ld %@", (long)error.code, error.localizedDescription] : @"nil",
           @"written": printable(c.written)});
}

static NSArray* post(NSString* body, NSString* extraHeaders, BOOL withLength) {
    NSString* head = [NSString stringWithFormat:@"POST /RPC2 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/xml\r\n%@%@\r\n",
                      extraHeaders ?: @"", withLength ? [NSString stringWithFormat:@"Content-Length: %lu\r\n", (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding]] : @""];
    return @[head, body];
}

static NSString* methodCall(NSString* name, NSString* params) {
    return [NSString stringWithFormat:@"<?xml version=\"1.0\"?><methodCall><methodName>%@</methodName><params>%@</params></methodCall>", name, params];
}

static NSString* const STRUCT = @"<param><value><struct><member><name>k</name><value><string>v&amp;w</string></value></member></struct></value></param>";

static void coder(NSString* name, id value) {
    fprintf(stderr, "=== %s\n", name.UTF8String);
    NSMutableDictionary* record = [NSMutableDictionary dictionaryWithObject:name forKey:@"case"];
    for (NSNumber* option in @[@0, @1]) {
        @try {
            record[[NSString stringWithFormat:@"format%@", option]] = [N2XMLRPC FormatElement:value options:option.unsignedIntegerValue];
        } @catch (NSException* e) {
            record[[NSString stringWithFormat:@"format%@", option]] = [NSString stringWithFormat:@"raised %@: %@", e.name,
                [e.reason componentsSeparatedByString:@" sent to instance"][0]];
        }
    }
    @try {
        record[@"response"] = [N2XMLRPC responseWithValue:value];
        record[@"request"] = [N2XMLRPC requestWithMethodName:@"m<&>" arguments:value ? @[value] : @[]];
    } @catch (NSException* e) {
        record[@"response"] = [NSString stringWithFormat:@"raised %@: %@", e.name, [e.reason componentsSeparatedByString:@" sent to instance"][0]];
    }
    emit(record);
}

static void parse(NSString* name, NSString* xml) {
    fprintf(stderr, "=== %s\n", name.UTF8String);
    NSXMLDocument* document = [[[NSXMLDocument alloc] initWithXMLString:[NSString stringWithFormat:@"<value>%@</value>", xml] options:0 error:NULL] autorelease];
    NSString* outcome;
    @try {
        outcome = describe([N2XMLRPC ParseElement:[document rootElement]]);
    } @catch (NSException* e) {
        outcome = [NSString stringWithFormat:@"raised %@: %@", e.name, e.reason];
    }
    emit(@{@"case": name, @"parsed": outcome});
}

int main(int argc, char** argv) {
    @autoreleasepool {
        [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"America/Sao_Paulo"]];
        if (argc > 1 && !strcmp(argv[1], "--deadline")) {
            // The connection closes itself 10 seconds after it opens.
            fprintf(stderr, "=== deadline\n");
            ProbeConnection* c = [[ProbeConnection new] autorelease];
                    [c open];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:9.5]];
            NSInteger before = c.closes;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
            emit(@{@"case": @"deadline", @"closesAt9.5s": @(before), @"closesAt11s": @(c.closes)});
            return 0;
        }

        exchange(@"echo", post(methodCall(@"Echo", STRUCT), nil, YES));
        exchange(@"untyped echo", post(methodCall(@"echo", STRUCT), nil, YES));
        exchange(@"echo byte by byte", ^{
            NSMutableArray* bytes = [NSMutableArray array];
            NSString* whole = [post(methodCall(@"Echo", STRUCT), nil, YES) componentsJoinedByString:@""];
            for (NSUInteger i = 0; i < whole.length; i++) [bytes addObject:[whole substringWithRange:NSMakeRange(i, 1)]];
            return bytes;
        }());
        exchange(@"echo without parameters", post(methodCall(@"Echo", @""), nil, YES));
        exchange(@"echo without content length", post(methodCall(@"Echo", STRUCT), nil, NO));
        exchange(@"echo in HTTP/1.0", @[@"POST / HTTP/1.0\r\nContent-Length: 1000\r\n\r\n", [methodCall(@"Echo", STRUCT) stringByPaddingToLength:1000 withString:@" " startingAtIndex:0]]);
        exchange(@"body longer than content length", @[@"POST / HTTP/1.1\r\nContent-Length: 20\r\n\r\n", @"<methodCall></methodCall> trailing"]);
        exchange(@"incomplete body", @[@"POST / HTTP/1.1\r\nContent-Length: 500\r\n\r\n", methodCall(@"Echo", STRUCT)]);
        exchange(@"negative content length", @[@"POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", methodCall(@"Echo", STRUCT)]);
        exchange(@"header only", @[@"POST / HTTP/1.1\r\nHost: x\r\n\r\n"]);
        exchange(@"header only with zero length", @[@"POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n"]);
        exchange(@"incomplete header", @[@"POST / HTTP/1.1\r\nContent-Length: 4\r\n"]);
        exchange(@"not xml", post(@"not xml", nil, YES));
        exchange(@"not xml without length", post(@"not xml", nil, NO));
        exchange(@"partial xml without length", @[@"POST / HTTP/1.1\r\n\r\n<methodCall><methodName>Echo</method", @"Name></methodCall>"]);
        exchange(@"no method call", post(@"<?xml version=\"1.0\"?><methodResponse/>", nil, YES));
        exchange(@"two method names", post(@"<methodCall><methodName>a</methodName><methodName>b</methodName></methodCall>", nil, YES));
        exchange(@"nil parameter", post(methodCall(@"Echo", @"<param><value><nil/></value></param>"), nil, YES));
        exchange(@"unreadable parameter", post(methodCall(@"Echo", @"<param><value><float>1</float></value></param>"), nil, YES));
        exchange(@"unknown method", post(methodCall(@"NoSuchMethod", STRUCT), nil, YES));
        exchange(@"inherited method", post(methodCall(@"isEqualTo", STRUCT), nil, YES));
        exchange(@"unpublished method", post(methodCall(@"hidden", STRUCT), nil, YES));
        exchange(@"available method", post(methodCall(@"secret", STRUCT), nil, YES));
        exchange(@"too many parameters", post(methodCall(@"Echo", [STRUCT stringByAppendingString:STRUCT]), nil, YES));
        exchange(@"parameter not a struct", post(methodCall(@"Echo", @"<param><value>text</value></param>"), nil, YES));
        exchange(@"application error", post(methodCall(@"Fail", STRUCT), nil, YES));
        exchange(@"other error", post(methodCall(@"Other", STRUCT), nil, YES));
        exchange(@"method raises", post(methodCall(@"Raise", STRUCT), nil, YES));
        exchange(@"method answers nothing", post(methodCall(@"Nothing", STRUCT), nil, YES));
        exchange(@"void method", post(methodCall(@"Void", STRUCT), nil, YES));
        exchange(@"unsupported answer", post(methodCall(@"Url", STRUCT), nil, YES));
        exchange(@"two parameters", post(methodCall(@"Two", [STRUCT stringByAppendingString:STRUCT]), nil, YES));
        exchange(@"one of two parameters", post(methodCall(@"Two", STRUCT), nil, YES));
        exchange(@"method without error", post(methodCall(@"NoError", STRUCT), nil, YES));
        exchange(@"method without parameters", post(methodCall(@"Zero", @""), nil, YES));
        exchange(@"published but missing", post(methodCall(@"Missing", STRUCT), nil, YES));
        exchange(@"refused", post(methodCall(@"Echo", STRUCT), @"X-Refuse: yes\r\n", YES));
        exchange(@"refused before body", @[@"POST / HTTP/1.1\r\nX-Refuse: yes\r\nContent-Length: 400\r\n\r\n", @"<methodCall>"]);
        exchange(@"garbage request line", @[@"garbage\r\n\r\n", methodCall(@"Echo", STRUCT)]);
        exchange(@"second request ignored", @[[post(methodCall(@"Echo", STRUCT), nil, YES) componentsJoinedByString:@""],
                                               [post(methodCall(@"Nothing", STRUCT), nil, YES) componentsJoinedByString:@""]]);

        direct(@"direct echo", @"echo", @[@{@"k": @"v"}]);
        direct(@"direct without parameters", @"echo", @[]);
        direct(@"direct nil parameters", @"echo", nil);
        direct(@"direct unknown", @"nope", @[@{}]);
        direct(@"direct too many", @"echo", @[@{}, @{}]);
        direct(@"direct not a struct", @"echo", @[@"x"]);
        direct(@"direct error", @"fail", @[@{}]);
        direct(@"direct raises", @"raise", @[@{}]);
        direct(@"direct nothing", @"nothing", @[@{}]);
        direct(@"direct void", @"void", @[@{}]);
        direct(@"direct two", @"two", @[@{@"a": @1}, @{@"b": @2}]);

        coder(@"format nil", nil);
        coder(@"format string", @"a <b> & 'c' \"d\" é 🩻");
        coder(@"format numbers", @[@YES, @NO, @7, @(-3), @(1ll << 40), @2.5, @1.0f, @'c']);
        coder(@"format largest unsigned", @(UINT64_MAX));
        coder(@"format data", [NSData dataWithBytes:"\x00\x01\x02\xfe\xff" length:5]);
        coder(@"format empty data", [NSData data]);
        coder(@"format date", [NSDate dateWithTimeIntervalSince1970:1790426096]);
        coder(@"format struct", @{@"a&b": @[@1, @"x"], @"n": @{@"m": @"y"}});
        coder(@"format number key", @{@1: @"x"});
        coder(@"format url", [NSURL URLWithString:@"http://127.0.0.1/"]);
        coder(@"format null", [NSNull null]);
        coder(@"format array with url", @[@"a", [NSURL URLWithString:@"http://x/"]]);

        parse(@"parse string", @"<string>a &amp;amp; b</string>");
        parse(@"parse bare", @"bare text");
        parse(@"parse empty", @"");
        parse(@"parse int", @"<int> 42abc</int>");
        parse(@"parse i4", @"<i4>-7</i4>");
        parse(@"parse boolean", @"<boolean>yes</boolean>");
        parse(@"parse double", @"<double>2.5e3</double>");
        parse(@"parse base64", @"<base64> AQ\nID== </base64>");
        parse(@"parse bad base64", @"<base64>AQ!D</base64>");
        parse(@"parse short base64", @"<base64>AQIDB</base64>");
        parse(@"parse empty base64", @"<base64></base64>");
        parse(@"parse date", @"<dateTime.iso8601>20260926T12:34:56</dateTime.iso8601>");
        parse(@"parse zulu date", @"<dateTime.iso8601>2026-09-26T12:34:56.789Z</dateTime.iso8601>");
        parse(@"parse bad date", @"<dateTime.iso8601>never</dateTime.iso8601>");
        parse(@"parse array", @"<array><data><value><int>1</int></value><value>two</value></data></array>");
        parse(@"parse array with nil", @"<array><data><value><nil/></value></data></array>");
        parse(@"parse struct", @"<struct><member><name>a</name><value><string>b</string></value></member></struct>");
        parse(@"parse struct without value", @"<struct><member><name>a</name></member></struct>");
        parse(@"parse struct without name", @"<struct><member><value>b</value></member></struct>");
        parse(@"parse struct with nil", @"<struct><member><name>a</name><value><nil/></value></member></struct>");
        parse(@"parse nil", @"<nil/>");
        parse(@"parse unknown type", @"<float>1</float>");
    }
    return 0;
}
'''


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def compile_objc(source, output, include, extra=()):
    language = 'objective-c++' if source.suffix == '.mm' else 'objective-c'
    built = run(['xcrun', 'clang', '-c', '-x', language, '-fno-objc-arc', '-w', '-fblocks',
                 *(['-std=c++17'] if language == 'objective-c++' else []),
                 *sum((['-I', str(folder)] for folder in include), []), *extra, str(source), '-o', str(output)])
    if built.returncode:
        raise RuntimeError(f'{source.name} did not compile:\n{built.stderr[-3000:]}')
    return output


def compile_swift(sources, work, bridging, include, extra=()):
    """The Swift sources as one object of module Horos, with their Objective-C interface."""
    output = work / 'swift.o'
    built = run(['xcrun', 'swiftc', '-c', '-wmo', '-parse-as-library', '-module-name', 'Horos', '-suppress-warnings',
                 '-import-objc-header', str(bridging), *sum((['-Xcc', '-I' + str(folder)] for folder in include), []),
                 *extra, '-emit-objc-header-path', str(work / 'Horos-Swift.h'),
                 *map(str, sources), '-o', str(output)], cwd=work)
    if built.returncode:
        raise RuntimeError(f'the Swift sources did not compile:\n{built.stderr[-3000:]}')
    return output


def link(objects, output, extra=()):
    built = run(['xcrun', 'swiftc', *map(str, objects), *extra, '-lc++', '-framework', 'Cocoa', '-o', str(output)])
    if built.returncode:
        raise RuntimeError(f'the probe did not link:\n{built.stderr[-3000:]}')
    return output


def build_before(revision, work):
    """The driver over the Objective-C connection of `revision`."""
    archive = subprocess.run(['git', '-C', str(ROOT), 'archive', '--format=tar', revision, '--', *BEFORE_PATHS],
                             capture_output=True)
    if archive.returncode:
        raise RuntimeError(f'git archive {revision} failed: {archive.stderr.decode()[-400:]}')
    tree = work / 'tree'
    with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
        tar.extractall(tree, filter='data')
    nitrogen, horos = tree / 'Nitrogen/Sources', tree / 'Horos/Sources'
    (work / 'stubs.m').write_text(STUBS)
    (work / 'driver.m').write_text(DRIVER)
    (work / 'ProbeConnection.swift').write_text(PROBE_CONNECTION)
    (work / 'Bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n#import "N2Debug.h"\n'
                                     '#import "N2XMLRPC.h"\n#import "NSString+N2.h"\n#import "NSData+N2.h"\n'
                                     '#import "NSMutableString+N2.h"\n#import "HorosObjCException.h"\n'
                                     '#import "N2XMLRPCConnection.h"\n')
    include = [work, nitrogen, horos]
    objects = [compile_swift([nitrogen / 'N2XMLRPC.swift', nitrogen / 'NSString+N2.swift', nitrogen / 'NSData+N2.swift',
                              nitrogen / 'NSMutableString+N2.swift', horos / 'XMLRPCRequestContract.swift',
                              work / 'ProbeConnection.swift'],
                             work, work / 'Bridging.h', include)]
    for source in (nitrogen / 'N2Connection.mm', nitrogen / 'N2XMLRPCConnection.mm', nitrogen / 'NSInvocation+N2.mm',
                   nitrogen / 'NSString+N2+CAPI.mm', nitrogen / 'NSData+N2+CAPI.mm'):
        objects.append(compile_objc(source, work / (source.name + '.o'), include, ['-DHOROS_BRIDGING_HEADER=1']))
    for source in (horos / 'HorosObjCException.m', work / 'stubs.m', work / 'driver.m'):
        objects.append(compile_objc(source, work / (source.name + '.o'), include))
    return link(objects, work / 'probe')


def build_after(work):
    """The driver over the working tree's Swift connection and IsiXHTTPServer."""
    nitrogen, horos = ROOT / 'Nitrogen/Sources', ROOT / 'Horos/Sources'
    modules = work / 'modules'
    # IsiXLogging: the app's NSLog, which the connection's DLog calls, writes through it.
    flags = isix_modules.module_flags('IsiXHTTPServer', modules) + isix_modules.module_flags('IsiXLogging', modules)
    (work / 'stubs.m').write_text(STUBS)
    (work / 'driver.m').write_text(DRIVER)
    (work / 'ProbeConnection.swift').write_text(PROBE_CONNECTION)
    (work / 'Bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n#import "N2Debug.h"\n'
                                     '#import "HorosObjCException.h"\n')
    include = [work, nitrogen, horos]
    objects = [compile_swift([nitrogen / 'N2XMLRPCConnection.swift', nitrogen / 'N2XMLRPC.swift',
                              horos / 'XMLRPCRequestContract.swift', work / 'ProbeConnection.swift',
                              # The module's NSLog and unifiedLogv, which the connection's DLog calls.
                              *([horos / 'UnifiedLogNSLog.swift']
                                if 'unifiedLogv' in (nitrogen / 'N2XMLRPCConnection.swift').read_text() else [])],
                             work, work / 'Bridging.h', include, [*flags, '-D', 'PROBE_SWIFT_CONNECTION'])]
    for source in (horos / 'HorosObjCException.m', work / 'stubs.m'):
        objects.append(compile_objc(source, work / (source.name + '.o'), include))
    objects.append(compile_objc(work / 'driver.m', work / 'driver.m.o', include,
                                ['-DPROBE_SWIFT_CONNECTION', *isix_modules.clang_module_flags('IsiXHTTPServer', modules)]))
    return link(objects, work / 'probe', isix_modules.link_flags('IsiXHTTPServer', modules)
                + isix_modules.link_flags('IsiXLogging', modules))


def outcomes(probe, *arguments):
    """{case: (record, log lines)} of one run of the probe."""
    ran = run([str(probe), *arguments], timeout=60)
    if ran.returncode:
        raise RuntimeError(f'{probe} {" ".join(arguments)} ended with status {ran.returncode}: {ran.stderr[-1500:]}')
    logs, case = {}, None
    for line in ran.stderr.splitlines():
        if line.startswith('=== '):
            case = line[4:]
            logs[case] = []
        elif case is not None:
            logs[case].append(LOG_PREFIX.sub('', line))
    records = {}
    for line in ran.stdout.splitlines():
        record = json.loads(line)
        records[record['case']] = (record, logs.get(record['case'], []))
    return records


def main():
    revision = sys.argv[1] if len(sys.argv) > 1 else history_reference.before_removal(CONNECTION)
    if revision is None and run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{CONNECTION}']).returncode == 0:
        # The removal is not committed yet: the reference is the last commit.
        revision = 'HEAD'
    if revision is None:
        print(f'skipped: no revision of this history has {CONNECTION}', file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='horos-xmlrpc-connection-') as temporary:
        work = Path(temporary)
        (work / 'before').mkdir()
        (work / 'after').mkdir()
        try:
            before = build_before(revision, work / 'before')
            after = build_after(work / 'after')
        except RuntimeError as error:
            print(error, file=sys.stderr)
            print('skipped: the probes could not be built', file=sys.stderr)
            return 2
        old, new = outcomes(before), outcomes(after)
        old.update(outcomes(before, '--deadline'))
        new.update(outcomes(after, '--deadline'))

    failures = []
    if set(old) != set(new):
        failures.append(f'cases differ: only before {sorted(set(old) - set(new))}, only after {sorted(set(new) - set(old))}')
    for case in sorted(set(old) & set(new)):
        (old_record, old_log), (new_record, new_log) = old[case], new[case]
        if old_record != new_record:
            for key in sorted(set(old_record) | set(new_record)):
                if old_record.get(key) != new_record.get(key):
                    failures.append(f'{case}: {key}\n  before: {old_record.get(key)!r}\n  after:  {new_record.get(key)!r}')
        if old_log != new_log:
            failures.append(f'{case}: log\n  before: {old_log!r}\n  after:  {new_log!r}')
    deadline = new.get('deadline', ({}, []))[0]
    if deadline.get('closesAt9.5s') != 0 or deadline.get('closesAt11s') != 1:
        failures.append(f'the deadline does not close the connection after 10 seconds: {deadline}')
    answered = sum(1 for record, _ in new.values() if record.get('written'))
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        return 1
    print(f'PASS: {len(new)} cases against {revision}, {answered} with an answer on the wire: '
          'the same bytes, closes, results, errors and log lines')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
