#!/usr/bin/env python3
"""+[DefaultsOsiriX currentHost] resolves once without holding @synchronized(NSApp).

[NSHost currentHost] can take tens of seconds; +[AppController DNSResolve:] starts
it at launch. The shipped method is compiled against a slowed NSHost: while one
thread resolves, another enters @synchronized(NSApp) (the lock N2Debug.mm takes to
log every exception) at once, a concurrent caller waits and gets the same host,
and NSHost is asked once. The former body, compiled the same way, is the negative
control: there the lock waits for the resolution.

It also reads the sources for the two other waits on name resolution: the
listener turns DCMTK's reverse lookup of the peer off before it listens, and the
browser's remote sources ask for the current host only in their background block.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/DefaultsOsiriX.m').read_text()
match = re.search(r'\+\(NSHost\*\) currentHost\n\{.*?\n\}\n', source, re.S)
if not match:
    sys.exit('FAIL: +currentHost not found in DefaultsOsiriX.m')
shipped = match.group(0)
former = '''+(NSHost*) currentHost
{
	@synchronized( NSApp)
	{
		if( currentHost == nil)
			currentHost = [[NSHost currentHost] retain];
	}
	return currentHost;
}
'''

harness = r'''
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <stdatomic.h>
static id NSApp;
static NSHost *currentHost = nil;
static atomic_int resolutions;
static IMP originalCurrentHost;
static id slowCurrentHost(id self, SEL _cmd) {
    atomic_fetch_add(&resolutions, 1);
    [NSThread sleepForTimeInterval:1.5];
    return ((id(*)(id, SEL))originalCurrentHost)(self, _cmd);
}
@interface DefaultsOsiriX : NSObject @end
@implementation DefaultsOsiriX
BODY
@end
int main(int argc, char **argv) { @autoreleasepool {
    NSApp = [NSObject new];
    Method m = class_getClassMethod([NSHost class], @selector(currentHost));
    originalCurrentHost = method_setImplementation(m, (IMP)slowCurrentHost);
    __block NSHost *first = nil, *second = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{ first = [DefaultsOsiriX currentHost]; });
    [NSThread sleepForTimeInterval:0.2];
    dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{ second = [DefaultsOsiriX currentHost]; });
    NSDate *start = [NSDate date];
    @synchronized(NSApp) {}
    double lockWait = -[start timeIntervalSinceNow];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    printf("%.2f %d %d %d\n", lockWait, atomic_load(&resolutions), first != nil && first == second,
           [DefaultsOsiriX currentHost] == first);
}}
'''

def run(body, name, work):
    path = Path(work) / (name + '.m')
    path.write_text(harness.replace('BODY', body))
    binary = Path(work) / name
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-framework', 'Foundation', str(path), '-o', str(binary)],
                   check=True, capture_output=True, text=True)
    lock_wait, resolutions, same, cached = subprocess.run([str(binary)], check=True, capture_output=True,
                                                         text=True, timeout=60).stdout.split()
    return float(lock_wait), int(resolutions), same == '1', cached == '1'

with tempfile.TemporaryDirectory() as work:
    lock_wait, resolutions, same, cached = run(shipped, 'shipped', work)
    control_wait, _, _, _ = run(former, 'former', work)

failures = []
# The listener answers no association while a reverse lookup of the peer runs
# on its thread; it turns DCMTK's lookup off before it starts listening.
listener = (root / 'Horos/Sources/DCMTKQueryRetrieveSCP.mm').read_text()
run_body = listener[listener.index('- (void)run'):]
disable = run_body.find('dcmDisableGethostbyaddr.set(OFTrue);')
if disable < 0 or disable > run_body.index('ASC_initializeNetwork('):
    failures.append('the listener does not turn off the reverse lookup of the peer before it listens')
# The browser asks for the computer's host off the main thread (-awakeFromNib
# runs before the listener starts).
sources = (root / 'Horos/Sources/BrowserController+Sources.swift').read_text()
remote = sources[sources.index('if context == RemoteBrowserSourcesContext.pointer {'):]
remote = remote[:remote.index('if context == DicomBrowserSourcesContext.pointer {')]
background = remote.find('Thread.performBlock(inBackground:')
calls = [m.start() for m in re.finditer(r'DefaultsOsiriX\.currentHost\(\)', remote)]
if background < 0 or not calls or any(c < background for c in calls):
    failures.append('the remote sources ask for the current host on the main thread')
if lock_wait > 0.3:
    failures.append('@synchronized(NSApp) waited %.2f s for the resolution' % lock_wait)
if resolutions != 1:
    failures.append('NSHost was asked %d times' % resolutions)
if not same:
    failures.append('the concurrent caller did not get the same host')
if not cached:
    failures.append('a later call did not return the resolved host')
if control_wait < 1.0:
    failures.append('negative control: the former body did not hold the lock (%.2f s)' % control_wait)
if failures:
    print('FAIL: ' + '; '.join(failures))
    sys.exit(1)
print('PASS: currentHost resolved once (%d), shared by a concurrent caller; @synchronized(NSApp) free in %.2f s '
      'during the resolution (former body: %.2f s)' % (resolutions, lock_wait, control_wait))
