#!/usr/bin/env python3
"""The web portal starts one server, opens its own database and ends cleanly (#771).

- -initWithDatabaseAtPath:dicomDatabase: opened the default WebUsers database
  whatever path it was given. It opens the one at the path.
- -startAcceptingConnections waited for isAcceptingConnections, which the
  connection threads set only once they run: a second start before that made
  a second server, which replaced the arrays of the first and could not bind
  its port. A start is now pending until a thread marks the portal; a start
  after -stopAcceptingConnections still makes a server, as before.
- Each connection thread kept its run loop running with a timer that targets
  -ignore:, which nothing implements. The timer has no target now, and the run
  loop still waits instead of spinning.
- +finalizeWebPortalClass released the default portal once more than anything
  retained it: once its timers stopped, the portal was deallocated while the
  class still referenced it. It now stops the portal's timers and keeps it.
- +initialize (WebPortal+CAPI.m) ran again for the subclass KVO makes when a
  portal is first observed, observing the defaults a second time. It runs for
  WebPortal only.

The instance section, the notifications section, +defaultWebPortal and
+finalizeWebPortalClass are taken as they are from WebPortal.swift and compiled
with stubs for the server and the application around them; the portal's lock
helper is replaced by one that holds the connection threads until the test lets
them go, so the window between a start and the threads is deterministic.
Timer scheduling is intercepted to check each timer's selector against its
target. The server never binds a socket and no mail code is compiled in.
WebPortal+CAPI.m is compiled as it is against a stand-in WebPortal class.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text()


def between(text, start, end, name, keep_end=False):
    at = text.find(start)
    stop = text.find(end, at + len(start)) if at >= 0 else -1
    if at < 0 or stop < 0:
        print(f'FAIL: {name} is not where the test expects it')
        sys.exit(1)
    return text[at:stop + (len(end) if keep_end else 0)]


portal = read('Horos/Sources/WebPortal.swift')
capi = read('Horos/Sources/WebPortal+CAPI.m')
caught = between(portal, 'fileprivate func webPortalCaught(', '\n}\n', 'webPortalCaught', True)
# The statics are behind a lock since #1005; an earlier revision starts at the first one.
statics_start = ('    /// Guards the three statics below' if '    /// Guards the three statics below' in portal
                 else '    private static var defaultWebPortalDatabasePath')
statics = between(portal, statics_start,
                  '\n\n', 'the class properties')
finalize = between(portal, '    @objc(finalizeWebPortalClass)', '\n    }\n', 'finalizeWebPortalClass', True)
default = between(portal, '    @objc(defaultWebPortal)', '\n    }\n', 'defaultWebPortal', True)
instance = between(portal, '    // MARK: Instance', '    // MARK: Sessions', 'the instance section')
notifications = between(portal, '    // MARK: Notifications', '\n}\n', 'the notifications section')

MAIN = r'''
import Foundation
import ObjectiveC

let THREAD_POOL_SIZE: Int32 = 4

/// The connection threads wait here until the test opens the gate.
let gate = NSCondition()
var gateOpen = false
fileprivate func webPortalSynchronized(_ object: AnyObject?, _ body: () -> Void) {
    gate.lock()
    while !gateOpen { gate.wait() }
    gate.unlock()
    if let object { objc_sync_enter(object) }
    body()
    if let object { objc_sync_exit(object) }
}
CAUGHT

func _N2LogExceptionImpl(_ e: NSException, _ log: Bool, _ where_: String) {}
final class AsyncSocket: NSObject { class func lastBindErrno() -> Int32 { 48 } }
final class AppController: NSObject {
    static let instance = AppController()
    class func shared() -> AppController? { instance }
    func reportListenBindFailure(forService service: String, port: Int, errnoCode: Int32) {}
}
extension NSString {
    func resolvingSymlinksAndAliases() -> String? { self as String }
    func stringByComposingPath(with rel: NSString) -> String { rel as String }
    func n2Contains(_ s: String) -> Bool { range(of: s).location != NSNotFound }
}
final class WebPortalDatabase: NSObject {
    let path: String?
    init(path: String?) { self.path = path }
    var mainDatabase: Any? { nil }
    func privateQueueIndependentDatabase() -> Any? { nil }
}
final class DicomDatabase: NSObject {
    class func `default`() -> DicomDatabase! { DicomDatabase() }
    var mainDatabase: Any? { nil }
    func privateQueueIndependentDatabase() -> Any? { nil }
}
/// The keys of the request databases (#966); no connection runs here.
final class WebPortalConnection: NSObject {
    static let threadDicomDatabaseKey = "WebPortalConnectionDicomDatabase"
    static let threadWebDatabaseKey = "WebPortalConnectionWebPortalDatabase"
}

/// The HTTP server, which binds nothing: its start fails as a port in use does.
var servers = 0
final class WebPortalServer: NSObject {
    weak var portal: WebPortal!
    override init() { servers += 1 }
    func setConnectionClass(_ c: AnyClass?) {}
    func setType(_ t: String) {}
    func setTXTRecord(_ r: [String: String]) {}
    func setPort(_ p: UInt16) {}
    func setDocumentRoot(_ u: URL) {}
    func start() throws { throw NSError(domain: NSPOSIXErrorDomain, code: 48) }
    func stop() -> Bool { true }
}

final class WebPortal: NSObject {
STATICS
FINALIZE
DEFAULT
INSTANCE
NOTIFICATIONS
}

/// What WebPortal+Email+Log gives the class; the mail is not compiled in.
extension WebPortal {
    @objc(deleteTemporaryUsers:) func deleteTemporaryUsers(_ timer: Timer!) {}
    @objc func emailNotifications() {}
    static func setDefaultPath(_ path: String) { defaultWebPortalDatabasePath = path }
    static var defaultInstance: WebPortal? { defaultWebPortalInstance }
    var timers: [Timer] { [temporaryUsersTimer, notificationsTimer].compactMap { $0 } }
    /// Stops the timers, as -stopAcceptingConnections or a deallocation would.
    func stopTimersForTest() {
        temporaryUsersTimer?.invalidate(); temporaryUsersTimer = nil
        notificationsTimer?.invalidate(); notificationsTimer = nil
    }
}

/// The selectors of the timers scheduled for a target that does not implement
/// them (the targets themselves are not kept: that would retain them).
var unimplemented: [String] = []
typealias Scheduler = @convention(c) (AnyClass, Selector, TimeInterval, AnyObject, Selector, AnyObject?, Bool) -> Timer
let scheduleSelector = NSSelectorFromString("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:")
let scheduleMethod = class_getClassMethod(Timer.self, scheduleSelector)!
let originalSchedule = unsafeBitCast(method_getImplementation(scheduleMethod), to: Scheduler.self)
let recordingSchedule: @convention(block) (AnyClass, TimeInterval, AnyObject, Selector, AnyObject?, Bool) -> Timer = {
    cls, interval, target, selector, info, repeats in
    if !target.responds(to: selector) {
        objc_sync_enter(gate); unimplemented.append(NSStringFromSelector(selector)); objc_sync_exit(gate)
    }
    return originalSchedule(cls, scheduleSelector, interval, target, selector, info, repeats)
}
method_setImplementation(scheduleMethod, imp_implementationWithBlock(recordingSchedule))

func waitUntil(_ condition: () -> Bool) -> Bool {
    for _ in 0..<500 { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return condition()
}

// The database at the path given.
WebPortal.setDefaultPath("/nonexistent/default/WebUsers.sql")
let portal = WebPortal(databaseAtPath: "/nonexistent/other/WebUsers.sql", dicomDatabase: nil)
print("database: \(portal.database.path ?? "nil")")

// Two starts before a connection thread runs, then the threads.
portal.startAcceptingConnections()
portal.startAcceptingConnections()
print("servers made by two starts before the threads: \(servers)")
gate.lock(); gateOpen = true; gate.broadcast(); gate.unlock()
print("accepting: \(waitUntil { portal.isAcceptingConnections })")
var made = servers
portal.startAcceptingConnections()
print("servers made by a start while accepting: \(servers - made)")
portal.stopAcceptingConnections()
made = servers
portal.startAcceptingConnections()
print("servers made by a start after a stop: \(servers - made)")
_ = waitUntil { portal.isAcceptingConnections }

// The connection threads wait on their run loops; they do not spin.
let cpu = clock()
Thread.sleep(forTimeInterval: 0.5)
print("connection threads cpu: \(Double(clock() - cpu) / Double(CLOCKS_PER_SEC))")

// The default portal outlives its finalization, and its timers stop.
final class Sentinel: NSObject {
    static var deallocated = false
    deinit { Sentinel.deallocated = true }
}
var sentinelKey = 0
var timers: [Timer] = []
autoreleasepool {
    let p = WebPortal.default()!
    objc_setAssociatedObject(p, &sentinelKey, Sentinel(), .OBJC_ASSOCIATION_RETAIN)
    timers = p.timers
}
WebPortal.finalizeWebPortalClass()
print("timers running after finalize: \(timers.filter { $0.isValid }.count)")
timers = []
autoreleasepool { WebPortal.defaultInstance?.stopTimersForTest() }
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
print("default portal deallocated while referenced: \(Sentinel.deallocated)")

objc_sync_enter(gate)
for selector in unimplemented {
    print("timer selector not implemented: \(selector)")
}
objc_sync_exit(gate)
print("done")
exit(0)
'''
MAIN = (MAIN.replace('CAUGHT', caught).replace('STATICS', statics).replace('FINALIZE', finalize)
        .replace('DEFAULT', default).replace('INSTANCE', instance).replace('NOTIFICATIONS', notifications))

HEADER = '''#import <Foundation/Foundation.h>
// A stand-in for the Swift class, whose +horosInitializeWebPortalClass counts.
@interface WebPortal : NSObject
+ (void)horosInitializeWebPortalClass;
@property (nonatomic) int port;
@end
'''
OBJC_MAIN = r'''#import "WebPortal.h"
#import <objc/runtime.h>
#include <stdio.h>

static int initialized = 0;

@implementation WebPortal
+ (void)horosInitializeWebPortalClass { initialized++; }
@end

@interface Observer : NSObject
@end
@implementation Observer
- (void)observeValueForKeyPath:(NSString*)k ofObject:(id)o change:(NSDictionary*)c context:(void*)x {}
@end

int main(void) {
    @autoreleasepool {
        WebPortal* portal = [WebPortal new];
        Observer* observer = [Observer new];
        [portal addObserver:observer forKeyPath:@"port" options:0 context:NULL];
        portal.port = 8080;
        printf("observed class: %s\n", object_getClassName(portal));
        [portal removeObserver:observer forKeyPath:@"port"];
        printf("initialized: %d\n", initialized);
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-portal-lifecycle-') as tmp:
    p = Path(tmp)
    (p / 'bridging.h').write_text('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n'
                                  '#import "HorosWebPathSafety.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'HorosObjCException.o')], check=True)
    (p / 'main.swift').write_text(MAIN)
    build = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(p / 'bridging.h'),
                            '-Xcc', '-I' + str(root / 'Horos/Sources'), str(p / 'main.swift'),
                            str(p / 'HorosObjCException.o'), '-o', str(p / 'lifecycle')], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        print('FAIL: the portal harness did not compile')
        sys.exit(1)
    run = subprocess.run([str(p / 'lifecycle')], capture_output=True, text=True, timeout=120)
    print(run.stdout.strip())

    (p / 'objc').mkdir()
    (p / 'objc' / 'WebPortal.h').write_text(HEADER)
    (p / 'objc' / 'WebPortal+CAPI.m').write_text(capi)
    (p / 'objc' / 'main.m').write_text(OBJC_MAIN)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', str(p / 'objc' / 'WebPortal+CAPI.m'),
                    str(p / 'objc' / 'main.m'), '-o', str(p / 'initialize')], check=True)
    objc_run = subprocess.run([str(p / 'initialize')], capture_output=True, text=True, timeout=60)
    print(objc_run.stdout.strip())

failures = []
if run.returncode != 0 or 'done' not in run.stdout:
    failures.append(f'the portal harness ended with {run.returncode}: {run.stderr[-500:]}')


def value(output, key):
    found = re.search(rf'^{re.escape(key)}: (.*)$', output, re.M)
    return found.group(1) if found else None


checks = [
    ('database', '/nonexistent/other/WebUsers.sql', 'the portal opened another database than the one at its path'),
    ('servers made by two starts before the threads', '1',
     'a second start before the connection threads ran made another server'),
    ('accepting', 'true', 'the connection threads never marked the portal as accepting'),
    ('servers made by a start while accepting', '0', 'a start while accepting made another server'),
    ('servers made by a start after a stop', '1', 'a start after a stop no longer makes a server'),
    ('timers running after finalize', '0', '+finalizeWebPortalClass left the portal\'s timers running'),
    ('default portal deallocated while referenced', 'false',
     '+finalizeWebPortalClass over-released the default portal: it was deallocated while the class referenced it'),
]
for key, expected, message in checks:
    found = value(run.stdout, key)
    if found != expected:
        failures.append(f'{message} ({key}: {found})')
cpu = value(run.stdout, 'connection threads cpu')
if cpu is None or float(cpu) > 0.2:
    failures.append(f'the connection threads spin instead of waiting on their run loops (cpu: {cpu} s in 0.5 s)')
for selector in sorted(set(re.findall(r'^timer selector not implemented: (.*)$', run.stdout, re.M))):
    failures.append(f'a timer targets -{selector}, which nothing implements')
if value(objc_run.stdout, 'observed class') != 'NSKVONotifying_WebPortal':
    failures.append(f'observing a portal did not make the KVO subclass ({value(objc_run.stdout, "observed class")})')
if value(objc_run.stdout, 'initialized') != '1':
    failures.append(f'+initialize ran the class initialization {value(objc_run.stdout, "initialized")} times, '
                    'once more for the KVO subclass')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: one server per start, the database at its path, no timer without a method, a finalization that '
      'keeps the portal, and +initialize once')
