#!/usr/bin/env python3
"""Run the portal's actual HTTP policy overrides against the HTTP base class.

Only the identity lookup and socket I/O are stand-ins: this checks synchronous
TLS dispatch to the owning portal thread, its settings, reset, bounded uploads,
response framing, keepalive, deadline callbacks, and SDK status compatibility. Native TLS/key ownership is exercised by
test-asyncsocket-native-tls.py. No app, real Keychain or external peer is used.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import sys
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
from dcmtk_build import BUILD
OPENSSL = BUILD / 'OpenSSL.build/Install'
if not (OPENSSL / 'lib/libssl.a').is_file():
    print('SKIP: compile OpenSSL dependency first')
    raise SystemExit(2)

source = (ROOT / 'Horos/Sources/WebPortalConnection.swift').read_text()
manifest = json.loads((ROOT / 'cocoahttpserver/UPSTREAM.json').read_text())
for name, record in manifest['coreFiles'].items():
    original = ROOT / 'cocoahttpserver/upstream' / name
    assert hashlib.sha256(original.read_bytes()).hexdigest() == record['upstreamSHA256'], name
for name in ('DDData', 'DDNumber', 'DDRange', 'HTTPAuthenticationRequest', 'HTTPConnection', 'HTTPServer'):
    wrapper = (ROOT / 'cocoahttpserver' / (name + '.m')).read_text()
    assert wrapper[wrapper.rfind('*/') + 2:].strip().splitlines()[-1] == '#include "upstream/' + name + '.m"'


def method(name):
    match = re.search(r'    (?:@objc )?public (?:override )?func ' + re.escape(name), source)
    assert match, name
    start = match.start()
    previous = source.rfind('\n', 0, start - 1) + 1
    if source[previous:start].strip().startswith('@objc('):
        start = previous
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


methods = '\n'.join(method(name) for name in (
    'realm()', 'requestBodyChunkSize()', 'responseHeaderTimeout()',
    'errorResponseTimeout()', 'onSocket(', 'onSocketWillConnect(', 'startTLSThread()', 'preprocessResponse('))

HEADER = r'''
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import "HTTPConnection.h"
#import "HTTPServer.h"
#import "HTTPResponse.h"
#import "AsyncSocket.h"
#import "HorosObjCException.h"
#import "HTTPAsyncFileResponse.h"
BOOL HTTPResponseDeclaresStatusCode(void);
BOOL HTTPResponseMissingInitializersReturnNil(void);
@interface AsyncSocket (PolicyDeadlineTest)
-(BOOL)exerciseDeadlineExtensionWithTag:(long)tag;
@end
@interface HTTPConnection (Private)
-(BOOL)onSocketWillConnect:(AsyncSocket *)sock;
-(void)replyToHTTPRequest;
-(void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag;
-(void)onSocket:(AsyncSocket *)sock didWriteDataWithTag:(long)tag;
-(UInt64)webPortalConnectionRemainingBodyBytes;
-(void)webPortalConnectionValidateResponse:(CFHTTPMessageRef)message;
-(CFHTTPMessageRef)prepareUniRangeResponse:(UInt64)length;
@end
@interface HTTPServer (WebPortalListener)
-(void)webPortalServerInstallListener:(AsyncSocket *)listener;
-(AsyncSocket *)webPortalServerListener;
@end
@interface PolicySocket : AsyncSocket
@property(retain) NSRunLoop *ownedLoop;
@property(retain) NSThread *tlsThread;
@property(retain) NSDictionary *settings;
@property(retain) NSMutableArray *bodyReads;
@property(retain) NSMutableArray *writeTimeouts;
@property(retain) NSMutableArray *writtenData;
@property(retain) NSMutableArray *writeTags;
@property NSUInteger nextWriteAck;
- (void)feedHeaders:(NSString *)headers toConnection:(HTTPConnection *)connection;
- (void)feedBody:(NSData *)data toConnection:(HTTPConnection *)connection;
- (void)finishResponseForConnection:(HTTPConnection *)connection;
- (void)drainResponseForConnection:(HTTPConnection *)connection;
@end
'''
OBJC = r'''
#import "fixture.h"
#import <objc/runtime.h>
void N2LogStackTrace(NSString *format, ...) {}
BOOL HTTPResponseDeclaresStatusCode(void) {
    return protocol_getMethodDescription(objc_getProtocol("HTTPResponse"), sel_registerName("statusCode"), NO, YES).name != NULL;
}
BOOL HTTPResponseMissingInitializersReturnNil(void) {
    NSString *missing = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    id file = [[HTTPFileResponse alloc] initWithFilePath:missing];
    id async = [[HTTPAsyncFileResponse alloc] initWithFilePath:missing forConnection:nil runLoopModes:nil];
    BOOL result = file == nil && async == nil;
    [file release]; [async release];
    return result;
}
@interface AsyncSocket (PolicyDeadlinePrivate)
-(void)doWriteTimeout:(NSTimer *)timer;
@end
@implementation AsyncSocket (PolicyDeadlineTest)
-(BOOL)exerciseDeadlineExtensionWithTag:(long)tag {
    [self moveToRunLoop:[NSRunLoop currentRunLoop]];
    [self writeData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] withTimeout:30 tag:tag];
    if (theWriteQueue.count != 1) return NO;
    theCurrentWrite = [[theWriteQueue objectAtIndex:0] retain];
    [theWriteQueue removeObjectAtIndex:0];
    // Execute the real timeout handler with a real queued write packet. Its
    // elapsed argument is cumulative timeout, so no wall-clock wait is needed.
    [self doWriteTimeout:nil];
    BOOL extended = [[(id)theCurrentWrite valueForKey:@"timeout"] doubleValue] == 240;
    [self doWriteTimeout:nil];
    return extended && theCurrentWrite == nil;
}
@end
@implementation PolicySocket
- (id)initWithDelegate:(id)delegate {
    if ((self = [super initWithDelegate:delegate])) {
        self.bodyReads = [NSMutableArray array];
        self.writeTimeouts = [NSMutableArray array];
        self.writtenData = [NSMutableArray array];
        self.writeTags = [NSMutableArray array];
    }
    return self;
}
- (CFRunLoopRef)runLoopRef { return [self.ownedLoop getCFRunLoop]; }
- (void)startTLS:(NSDictionary *)settings {
    self.settings = settings; self.tlsThread = [NSThread currentThread];
}
- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout maxLength:(NSUInteger)length tag:(long)tag {}
- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    [self.bodyReads addObject:@(length)];
}
- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    [self.writeTimeouts addObject:@(timeout)];
    [self.writtenData addObject:data];
    [self.writeTags addObject:@(tag)];
}
- (void)feedHeaders:(NSString *)headers toConnection:(HTTPConnection *)connection {
    NSArray *lines = [headers componentsSeparatedByString:@"\r\n"];
    for (NSUInteger i = 0; i + 1 < lines.count; ++i) {
        NSData *data = [[lines[i] stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding];
        [connection onSocket:self didReadData:data withTag:15];
    }
}
- (void)feedBody:(NSData *)data toConnection:(HTTPConnection *)connection {
    [connection onSocket:self didReadData:data withTag:16];
}
- (void)finishResponseForConnection:(HTTPConnection *)connection {
    self.nextWriteAck = self.writeTags.count;
    [connection onSocket:self didWriteDataWithTag:30];
}
- (void)drainResponseForConnection:(HTTPConnection *)connection {
    NSUInteger iterations = 0;
    while (self.nextWriteAck < self.writeTags.count) {
        if (++iterations > 1000) abort();
        long tag = [self.writeTags[self.nextWriteAck] longValue];
        self.nextWriteAck++;
        [connection onSocket:self didWriteDataWithTag:tag];
    }
}
- (void)dealloc {
    [_ownedLoop release]; [_tlsThread release]; [_settings release];
    [_bodyReads release]; [_writeTimeouts release];
    [_writtenData release]; [_writeTags release];
    [super dealloc];
}
@end
'''
SWIFT = r'''
import Foundation
import CFNetwork

final class OwningPortal: NSObject {
    var thread: Thread?
    var loop: RunLoop?
    func thread(forRunLoopRef ref: CFRunLoop!) -> Thread! {
        guard let loop, loop.getCFRunLoop() === ref else { return nil }
        return thread
    }
}
final class WebPortalConnection: HTTPConnection {
    var portal: OwningPortal?
    var asyncSocket: PolicySocket?
    var secure = false
    var resets = 0
    var identity: [Any] = [NSObject()]
    var nilRangeResponse = false
    var errors = 0
    var payload = Data([1, 2, 3])
    var chunked = false
    override func prepareUniRangeResponse(_ length: UInt64) -> Unmanaged<CFHTTPMessage>! {
        nilRangeResponse ? nil : super.prepareUniRangeResponse(length)
    }
    override func replyToHTTPRequest() {
        do { try HorosObjCException.perform { self.replyOriginal() } }
        catch { errors += 1 }
    }
    private func replyOriginal() { super.replyToHTTPRequest() }
    func resetPOST() { resets += 1 }
    override func isSecureServer() -> Bool { secure }
    override func sslIdentityAndCertificates() -> [Any]! { identity }
    override func supportsMethod(_ method: String!, atPath path: String!) -> Bool { true }
    override func httpResponse(forMethod method: String!, uri path: String!) -> (NSObjectProtocol & HTTPResponse)! {
        chunked ? ChunkedResponse(data: payload) : HTTPDataResponse(data: payload)
    }
METHODS
}
final class ChunkedResponse: HTTPDataResponse {
    override func isChunked() -> Bool { true }
}

PORTAL_SOCKET
final class WebPortalServer: HTTPServer {
SERVER_INIT
}
precondition(HTTPResponseDeclaresStatusCode() == EXPECT_STATUS)
precondition(HTTPResponseMissingInitializersReturnNil())
let factory = WebPortalServer()
precondition(factory.webPortalServerListener() is HorosPortalSocket)
precondition(factory.domain() == "local." && factory.name() == "")
precondition(factory.conforms(to: NSProtocolFromString("NSNetServiceDelegate")!))
let socket = HorosPortalSocket(delegate: nil)!
let host = WebPortalConnection(asyncSocket: socket, for: nil)!
host.asyncSocket = socket
let base = HTTPConnection(asyncSocket: nil, for: nil)!
precondition(base.realm() == "defaultRealm@host.com")
precondition(host.realm() == "Enter your username and password.")
precondition(host.requestBodyChunkSize() == 2 * 1024 * 1024)
precondition(host.responseHeaderTimeout() == 240 && host.errorResponseTimeout() == 240)
precondition(host.onSocketWillConnect(socket) && host.resets == 1 && socket.settings == nil)
host.secure = true
precondition(!host.onSocketWillConnect(socket) && host.resets == 2)

let portal = OwningPortal()
portal.thread = Thread.current
portal.loop = RunLoop.current
socket.ownedLoop = portal.loop
host.portal = portal
precondition(host.onSocketWillConnect(socket) && host.resets == 3)
precondition(socket.tlsThread === Thread.current)
precondition(socket.settings[kCFStreamSSLIsServer] as? Bool == true)
precondition(socket.settings[kCFStreamSSLValidatesCertificateChain] as? Bool == true)
precondition((socket.settings[kCFStreamSSLCertificates] as? [Any])?.count == 1)
precondition(socket.settings[kCFStreamSSLLevel] as? String == kCFStreamSocketSecurityLevelNegotiatedSSL as String)
socket.settings = nil
host.identity = []
precondition(host.onSocketWillConnect(socket) && socket.settings == nil)
host.identity = [NSObject()]

let condition = NSCondition()
var ready = false
var stop = false
let worker = Thread {
    autoreleasepool {
        let loop = RunLoop.current
        let timer = Timer(timeInterval: 60, repeats: true) { _ in }
        loop.add(timer, forMode: .default)
        condition.lock()
        portal.loop = loop
        portal.thread = Thread.current
        ready = true
        condition.signal()
        condition.unlock()
        while true {
            condition.lock(); let done = stop; condition.unlock()
            if done { break }
            loop.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        timer.invalidate()
    }
}
worker.start()
condition.lock()
while !ready { condition.wait() }
condition.unlock()
socket.ownedLoop = portal.loop
precondition(host.onSocketWillConnect(socket))
precondition(socket.tlsThread === worker && socket.settings != nil)
condition.lock(); stop = true; condition.unlock()

// Feed the actual parser so the budgets must be used at both upload read sites
// and by response/error writes, rather than merely returned by their getters.
socket.feedHeaders("POST /upload HTTP/1.1\r\nContent-Length: 2097153\r\n\r\n", to: host)
precondition((socket.bodyReads as? [Int]) == [2097152])
socket.feedBody(Data(count: 2097152), to: host)
precondition((socket.bodyReads as? [Int]) == [2097152, 1])
socket.feedBody(Data(count: 1), to: host)
precondition((socket.writeTimeouts as? [Int]) == [30, -1])
socket.writeTimeouts.removeAllObjects()
host.handleResourceNotFound()
host.handleAuthenticationFailed()
host.handleUnknownMethod("INVALID")
host.handleInvalidRequest(nil)
host.handleVersionNotSupported("HTTP/1.0")
precondition((socket.writeTimeouts as? [Int]) == [30, 30, 30, 30, 30])
for tag in [25, 30, 45] {
    precondition(host.onSocket(socket, shouldTimeoutWriteWithTag: tag, elapsed: 30, bytesDone: 0) == 210)
    precondition(host.onSocket(socket, shouldTimeoutWriteWithTag: tag, elapsed: 240, bytesDone: 1) == 0)
}
precondition(host.onSocket(socket, shouldTimeoutWriteWithTag: 26, elapsed: 30, bytesDone: 0) == 0)
for tag in [25, 30, 45] {
    let transport = AsyncSocket(delegate: host)!
    precondition(transport.exerciseDeadlineExtension(withTag: tag))
}
socket.finishResponse(for: host)
host.nilRangeResponse = true
socket.feedHeaders("GET / HTTP/1.1\r\nRange: bytes=0-1\r\n\r\n", to: host)
precondition(host.errors == 1)

// Use the same parser, response generator and write-completion callbacks for
// the protocol matrix. No separate HTTP parser or network stack is supplied.
let payload = Data((0..<64).map { UInt8(65 + $0 % 26) })
func request(_ method: String, range: String? = nil, chunked: Bool = false) -> (CFHTTPMessage, Data) {
    let socket = HorosPortalSocket(delegate: nil)!
    let connection = WebPortalConnection(asyncSocket: socket, for: nil)!
    connection.asyncSocket = socket
    connection.payload = payload
    connection.chunked = chunked
    let rangeLine = range.map { "Range: \($0)\r\n" } ?? ""
    socket.feedHeaders("\(method) / HTTP/1.1\r\n\(rangeLine)\r\n", to: connection)
    socket.drainResponse(for: connection)
    let wire = (socket.writtenData as! [Data]).reduce(Data(), +)
    let message = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
    precondition(wire.withUnsafeBytes { CFHTTPMessageAppendBytes(message, $0.bindMemory(to: UInt8.self).baseAddress!, wire.count) })
    precondition(CFHTTPMessageIsHeaderComplete(message))
    let body = CFHTTPMessageCopyBody(message)?.takeRetainedValue() as Data? ?? Data()
    return (message, body)
}
let get = request("GET")
precondition(CFHTTPMessageGetResponseStatusCode(get.0) == 200 && get.1 == payload)
let head = request("HEAD")
precondition(head.1.isEmpty)
precondition(CFHTTPMessageCopyHeaderFieldValue(head.0, "Content-Length" as CFString)!.takeRetainedValue() as String == "64")
let single = request("GET", range: "bytes=5-9")
precondition(CFHTTPMessageGetResponseStatusCode(single.0) == 206 && single.1 == payload.subdata(in: 5..<10))
let multiple = request("GET", range: "bytes=0-1,4-5")
precondition(CFHTTPMessageGetResponseStatusCode(multiple.0) == 206)
let multiText = String(decoding: multiple.1, as: UTF8.self)
precondition(multiText.contains("Content-Range: bytes 0-1/64") && multiText.contains("Content-Range: bytes 4-5/64"))
precondition(CFHTTPMessageCopyHeaderFieldValue(multiple.0, "Content-Length" as CFString)!.takeRetainedValue() as String == String(multiple.1.count))
let chunks = request("GET", range: "bytes=0-1", chunked: true)
precondition(CFHTTPMessageGetResponseStatusCode(chunks.0) == 200)
precondition(chunks.1 == Data("40\r\n".utf8) + payload + Data("\r\n0\r\n\r\n".utf8))
precondition(request("HEAD", chunked: true).1.isEmpty)
let keepSocket = HorosPortalSocket(delegate: nil)!
let keep = WebPortalConnection(asyncSocket: keepSocket, for: nil)!
keep.asyncSocket = keepSocket
for _ in 0..<2 {
    keepSocket.feedHeaders("GET / HTTP/1.1\r\n\r\n", to: keep)
    keepSocket.drainResponse(for: keep)
}
precondition(keep.errors == 0 && keepSocket.writtenData.count == 4)
print("PASS: original HTTP/parser + host socket/factory/TLS/null-response/deadline policies; parser upload reads and response/error writes; TLS settings and owning-thread dispatch")
'''.replace('METHODS', methods)
portal_socket = (ROOT / 'Horos/Sources/HorosPortalSocket.swift').read_text()
portal_socket = portal_socket[portal_socket.index('@objc(HorosPortalSocket)'):].replace(': AsyncSocket {', ': PolicySocket {')
server_source = (ROOT / 'Horos/Sources/WebPortal.swift').read_text()
server_at = server_source.index('    public override init()', server_source.index('public final class WebPortalServer'))
server_end = server_source.index('\n    }', server_at) + len('\n    }')
SWIFT = SWIFT.replace('PORTAL_SOCKET', portal_socket).replace('SERVER_INIT', server_source[server_at:server_end]).replace('EXPECT_STATUS', 'false' if '--original-core' in sys.argv else 'true')

with tempfile.TemporaryDirectory(prefix='horos-http-policy-') as directory:
    work = Path(directory)
    (work / 'fixture.h').write_text(HEADER)
    (work / 'fixture.m').write_text(OBJC)
    (work / 'main.swift').write_text(SWIFT)
    objects = []
    for path in [work / 'fixture.m', ROOT / 'Horos/Sources/WebPortalConnection+CAPI.m', ROOT / 'Horos/Sources/HorosObjCException.m'] + [ROOT / 'cocoahttpserver' / (name + '.m') for name in (
            'HTTPConnection', 'HTTPServer', 'HTTPResponse', 'HTTPAsyncFileResponse',
            'HTTPAuthenticationRequest', 'DDData', 'DDNumber', 'DDRange', 'AsyncSocket', 'SSCrypto')]:
        if '--original-core' in sys.argv and path.name in ('HTTPResponse.m', 'HTTPAsyncFileResponse.m'):
            path = ROOT / 'cocoahttpserver/upstream' / path.name
        obj = work / (path.stem + '.o')
        command = ['xcrun', 'clang', '-fno-objc-arc', '-include', 'CFNetwork/CFNetwork.h',
                   '-I', str(ROOT / 'cocoahttpserver'), '-I', str(ROOT / 'Horos/Sources'),
                   '-I', str(ROOT / 'Nitrogen/Sources'), '-I', str(OPENSSL / 'include'),
                   '-c', str(path), '-o', str(obj)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        objects.append(str(obj))
    command = ['xcrun', 'swiftc', '-import-objc-header', str(work / 'fixture.h'),
               '-Xcc', '-I' + str(ROOT / 'cocoahttpserver'), '-Xcc', '-I' + str(ROOT / 'Horos/Sources'), str(work / 'main.swift'), *objects,
               str(OPENSSL / 'lib/libssl.a'), str(OPENSSL / 'lib/libcrypto.a'),
               '-framework', 'CFNetwork', '-framework', 'CoreServices', '-framework', 'Security',
               '-o', str(work / 'policy')]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    subprocess.run([str(work / 'policy')], check=True, timeout=20)

    sdk_caller = 'int status(id<HTTPResponse> response) { return [response statusCode]; }\n'
    for header, accepted in ((ROOT / 'cocoahttpserver/HTTPResponse.h', True),
                             (ROOT / 'cocoahttpserver/upstream/HTTPResponse.h', False)):
        caller = work / 'status-caller.m'
        caller.write_text('#import "' + str(header) + '"\n' + sdk_caller)
        result = subprocess.run(['xcrun', 'clang', '-fsyntax-only', '-Werror', str(caller)],
                                capture_output=True, text=True, timeout=60)
        assert (result.returncode == 0) == accepted, result.stderr

    legacy = work / 'legacy-status.m'
    legacy.write_text('#import "' + str(ROOT / 'cocoahttpserver/HTTPResponse.h') + '"\n' +
                      sdk_caller.replace('int status(', 'int legacyStatus('))
    legacy_object = work / 'legacy-status.o'
    result = subprocess.run(['xcrun', 'clang', '-Werror', '-c', str(legacy), '-o', str(legacy_object)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr

    # The alternative is a separately named host protocol and class facade.
    # It does not rename or add declarations to the original HTTPResponse.
    derived_header = work / 'derived.h'
    derived_header.write_text('#import "' + str(ROOT / 'cocoahttpserver/upstream/HTTPResponse.h') + '"\n' + '''
@protocol HorosHTTPResponse <HTTPResponse>
@optional
- (int)statusCode;
@end
@interface HTTPDataResponse (HostStatus)
- (int)statusCode;
@end
BOOL originalStatusMetadataPresent(void);
BOOL hostStatusMetadataPresent(void);
int status(id<HorosHTTPResponse> response);
int legacyStatus(id<HTTPResponse> response);
''')
    caller = work / 'derived.m'
    caller.write_text('#import "derived.h"\n#import <objc/runtime.h>\n' + '''
BOOL originalStatusMetadataPresent(void) {
    return protocol_getMethodDescription(@protocol(HTTPResponse), @selector(statusCode), NO, YES).name != NULL;
}
BOOL hostStatusMetadataPresent(void) {
    return protocol_getMethodDescription(@protocol(HorosHTTPResponse), @selector(statusCode), NO, YES).name != NULL;
}
int status(id<HorosHTTPResponse> response) { return [response statusCode]; }
''')
    derived_object = work / 'derived.o'
    result = subprocess.run(['xcrun', 'clang', '-Werror', '-c', str(caller), '-o', str(derived_object)],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    derived_swift = work / 'derived.swift'
    response_source = (ROOT / 'Horos/Sources/WebPortalResponse.swift').read_text()
    status_method = re.search(r'    @objc public override func statusCode\(\) -> Int32 \{.*?\n    \}', response_source, re.S).group()
    derived_swift.write_text('import Foundation\n' + '''
final class HostResponse: HTTPDataResponse, HorosHTTPResponse {
    private var statusCodeValue: Int32 = 418
''' + status_method + '''
}
let response = HostResponse(data: Data())!
precondition(response.statusCode() == 418 && status(response) == 418 && legacyStatus(response) == 418)
precondition(!originalStatusMetadataPresent() && hostStatusMetadataPresent())
print("PASS: SDK caller requires derived host type; actual Swift override and old compiled int-selector caller preserved; original protocol metadata absent, host metadata present")
''')
    # Use ONLY the original response implementation in this isolated alternative.
    original_object = work / 'original-response.o'
    result = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-c', str(ROOT / 'cocoahttpserver/upstream/HTTPResponse.m'), '-o', str(original_object)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    result = subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(derived_header), str(derived_swift), str(derived_object), str(original_object), str(legacy_object), '-o', str(work / 'derived')], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    subprocess.run([str(work / 'derived')], check=True, timeout=20)
