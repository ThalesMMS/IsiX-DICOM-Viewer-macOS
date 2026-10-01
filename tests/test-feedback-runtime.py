#!/usr/bin/env python3
"""Actual FeedbackReporter upload contracts, using only synthetic loopback HTTP."""
from pathlib import Path
import argparse
import importlib.util
import json
import plistlib
import http.server
import socket
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from local_http import ThreadingLocalHTTPServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--uploader-source", type=Path,
                    help="production implementation or disposable negative-control revision")
arguments = parser.parse_args()

# Exercise the production resolver, including rejection before a workspace or
# product is written. Compile the implementations selected by the real build.
spec = importlib.util.spec_from_file_location('feedback_prepare', ROOT / 'Horos/Scripts/FeedbackReporter/prepare.py')
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)
with tempfile.TemporaryDirectory(prefix='horos-feedback-package-') as temporary:
    package = Path(temporary)
    workspace = selection.prepare(ROOT / 'FeedbackReporter', package / 'selected')
    manifest = json.loads((ROOT / 'Horos/Scripts/FeedbackReporter/upstream.json').read_text())
    record = json.loads((workspace / 'BuildSource.json').read_text())
    assert record['revision'] == selection.PIN and record['tree'] == manifest['tree']
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
                         str(workspace / 'FeedbackReporter.xcodeproj/project.pbxproj')]))
    objects = project['objects']
    phases = objects['8DC2EF4F0486A6940098B216']['buildPhases']
    sources = [objects[objects[item]['fileRef']]['path'] for phase in phases
               if objects[phase]['isa'] == 'PBXSourcesBuildPhase' for item in objects[phase]['files']]
    for name in selection.HOST_SOURCES:
        assert sources.count('Sources/Main/' + name) == 1
        assert (workspace / 'Sources/Main' / name).resolve() == ROOT / 'Horos/FeedbackReporter' / name
    assert not any('version="1090"' in path.read_text() for path in (workspace / 'Resources').rglob('*.xib'))
    resources = [objects[objects[item]['fileRef']].get('path') for phase in phases
                 if objects[phase]['isa'] == 'PBXResourcesBuildPhase' for item in objects[phase]['files']]
    assert resources.count('BuildSource.json') == 1
    supported = selection.PIN
    selection.PIN = '0' * 40
    try:
        selection.prepare(ROOT / 'FeedbackReporter', package / 'wrong-revision')
    except ValueError:
        assert not (package / 'wrong-revision').exists()
    else:
        raise AssertionError('accepted an unsupported revision')
    finally:
        selection.PIN = supported
    for metadata in ('file', 'directory'):
        checkout = package / ('checkout-' + metadata)
        shutil.copytree(ROOT / 'FeedbackReporter', checkout, ignore=shutil.ignore_patterns('.git'))
        git = checkout / '.git'
        if metadata == 'file':
            git.write_text('gitdir: ../.git/modules/FeedbackReporter\n')
        else:
            (git / 'objects').mkdir(parents=True)
            (git / 'HEAD').write_text('ref: refs/heads/main\n')
            (git / 'objects/local-object').write_bytes(b'local git object')
        selected = selection.prepare(checkout, package / ('selected-' + metadata))
        assert not (selected / '.git').exists()
    for mutation in ('changed', 'missing', 'mode', 'extra'):
        dirty = package / ('dirty-' + mutation)
        shutil.copytree(ROOT / 'FeedbackReporter', dirty)
        target = dirty / 'LICENSE.txt'
        original = (ROOT / 'FeedbackReporter/LICENSE.txt').read_bytes()
        target.write_bytes(original)
        target.chmod(0o644)
        if mutation == 'changed': target.write_bytes(original + b'changed')
        if mutation == 'missing': target.unlink()
        if mutation == 'mode': target.chmod(0o755)
        if mutation == 'extra': (dirty / 'untracked').write_text('extra')
        try:
            selection.prepare(dirty, package / mutation)
        except ValueError:
            assert not (package / mutation).exists()
        else:
            raise AssertionError('accepted a dirty upstream tree: ' + mutation)
    print('PASS: verified original pin with Git file/directory metadata, rejected modified/missing/extra sources, unique host source selection and copied resources')

# The reporter fills its window's tabs on a queue of its own and asks its
# delegate for the preferences from there. Swift ends the process when a method
# isolated to the main actor is entered from another queue, so the application's
# answers to the reporter must be declared nonisolated.
application = (ROOT / 'Horos/Sources/AppController.swift').read_text(encoding='utf-8')
for declaration in ('func feedbackDisplayName()', 'func customParametersForFeedbackReport()',
                    'func anonymizePreferencesForFeedbackReport('):
    lines = [line for line in application.splitlines() if declaration in line]
    assert len(lines) == 1 and 'nonisolated' in lines[0], declaration + ' can be asked only on the main thread'
print('PASS: the application answers the reporter from any queue')

requests = []
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        requests.append((self.path, self.headers.get('Content-Type', ''), body))
        if self.path == '/disconnect':
            self.send_response(200)
            self.send_header('Content-Length', '100')
            self.end_headers()
            self.wfile.write(b'x'); self.wfile.flush()
            self.close_connection = True
            return
        if self.path == '/slow':
            time.sleep(0.6)
        answer = 'synthetic ✓'.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(answer)))
        self.end_headers()
        try:
            self.wfile.write(answer[:4]); self.wfile.flush()
            time.sleep(0.03)
            self.wfile.write(answer[4:])
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *args):
        pass

PROGRAM = r'''
#import <Foundation/Foundation.h>
#import "FRUploader.h"
#import "FRConsoleLog.h"
#define CHECK(value) do { if (!(value)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#value); return 1; } } while(0)
@interface Observer : NSObject <FRUploaderDelegate>
@property NSUInteger started, finished, failed;
@property BOOL main;
@property NSError *error;
@end
@implementation Observer
- (instancetype)init { if ((self = [super init])) _main = YES; return self; }
- (void)uploaderStarted:(FRUploader *)uploader { (void)uploader; self.started++; self.main &= NSThread.isMainThread; }
- (void)uploaderFinished:(FRUploader *)uploader { (void)uploader; self.finished++; self.main &= NSThread.isMainThread; }
- (void)uploaderFailed:(FRUploader *)uploader withError:(NSError *)error { (void)uploader; self.failed++; self.error = error; self.main &= NSThread.isMainThread; }
@end
static void waitFor(Observer *observer, NSTimeInterval duration) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:duration];
    while (observer.finished == 0 && observer.failed == 0 && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
int main(int argc, char **argv) { @autoreleasepool {
    CHECK(argc == 3);
    NSString *base = [NSString stringWithUTF8String:argv[1]];
    NSDictionary *fields = @{@"message": @"synthetic café ✓", @"category": @"contract"};
    Observer *observer = [Observer new];
    FRUploader *sync = [[FRUploader alloc] initWithTargetURL:[NSURL URLWithString:[base stringByAppendingString:@"/sync"]] delegate:observer];
    CHECK([[sync post:fields] isEqualToString:@"synthetic ✓"]);
    CHECK(observer.started == 0 && observer.finished == 0 && observer.failed == 0);

    FRUploader *async = [[FRUploader alloc] initWithTargetURL:[NSURL URLWithString:[base stringByAppendingString:@"/async"]] delegate:observer];
    [async postAndNotify:fields]; waitFor(observer, 5);
    CHECK(observer.started == 1 && observer.finished == 1 && observer.failed == 0 && observer.main);
    CHECK([[async response] isEqualToString:@"synthetic ✓"]);
    observer.finished = 0;
    [async postAndNotify:fields]; waitFor(observer, 5);
    CHECK(observer.started == 2 && observer.finished == 1 && observer.failed == 0 && observer.main);
    CHECK([[async response] isEqualToString:@"synthetic ✓"]);

    Observer *canceled = [Observer new];
    FRUploader *slow = [[FRUploader alloc] initWithTargetURL:[NSURL URLWithString:[base stringByAppendingString:@"/slow"]] delegate:canceled];
    [slow postAndNotify:fields]; [slow cancel]; waitFor(canceled, 0.9);
    CHECK(canceled.started == 1 && canceled.finished == 0 && canceled.failed == 0 && canceled.main);

    Observer *failed = [Observer new];
    FRUploader *broken = [[FRUploader alloc] initWithTargetURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]] delegate:failed];
    [broken postAndNotify:fields]; waitFor(failed, 5);
    CHECK(failed.started == 1 && failed.failed == 1 && failed.finished == 0 && failed.error != nil && failed.main);
    CHECK([broken post:fields] == nil);

    CHECK([NSBundle.mainBundle.infoDictionary[@"FRFeedbackReporter.maxPOSTSize"] unsignedIntegerValue] == 1024);
    Observer *limited = [Observer new];
    FRUploader *oversize = [[FRUploader alloc] initWithTargetURL:[NSURL URLWithString:[base stringByAppendingString:@"/oversize"]] delegate:limited];
    [oversize postAndNotify:@{@"message": [@"synthetic" stringByPaddingToLength:2048 withString:@"x" startingAtIndex:0]}];
    waitFor(limited, 0.1);
    CHECK(limited.started == 0 && limited.finished == 0 && limited.failed == 0);

    // Query the real current-process store without system-wide access. Denied
    // access is permitted to return an empty diagnostic, never nil or a crash.
    NSString *log = [FRConsoleLog logSince:[NSDate dateWithTimeIntervalSinceNow:-30] maxSize:@128];
    CHECK(log != nil);
    NSLog(@"PASS: real unified-log query safely returned %lu characters (empty/permission limits allowed)", (unsigned long)log.length);
    puts("PASS: synchronous/async Unicode multipart, reset response, main callbacks, cancellation and transport failure");
    return 0;
}}
'''

server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
with socket.socket() as refusal:
    refusal.bind(('127.0.0.1', 0))
    try:
        with tempfile.TemporaryDirectory(prefix='horos-feedback-runtime-') as folder:
            folder = Path(folder)
            source = folder / 'main.m'; source.write_text(PROGRAM)
            selected = selection.prepare(ROOT / 'FeedbackReporter', folder / 'selected')
            main = selected / 'Sources/Main'
            contents = folder / 'Synthetic.app/Contents'
            executable = contents / 'MacOS/probe'
            executable.parent.mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'probe', 'CFBundleIdentifier': 'org.horos.synthetic.feedback',
                'FRFeedbackReporter.maxPOSTSize': 1024,
            }))
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                            '-mmacosx-version-min=26.0', '-I', str(main),
                            str(source), str(arguments.uploader_source or main / 'FRUploader.m'), str(main / 'FRConsoleLog.m'),
                            '-framework', 'Foundation', '-framework', 'OSLog', '-o', str(executable)], check=True)
            subprocess.run([str(executable), f'http://127.0.0.1:{server.server_port}',
                            f'http://127.0.0.1:{server.server_port}/disconnect'], check=True, timeout=60)
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=3)
assert sum(path == '/sync' for path, _, _ in requests) == 1
assert sum(path == '/async' for path, _, _ in requests) == 2
assert not any(path == '/oversize' for path, _, _ in requests)
for _, content_type, body in requests:
    assert content_type.startswith('multipart/form-data; boundary=')
    boundary = content_type.split('boundary=', 1)[1].encode()
    assert body.endswith(b'--' + boundary + b'--\r\n')
    assert 'synthetic café ✓'.encode() in body
    assert b'Content-Disposition: form-data; name="category"' in body
print('PASS: captured only synthetic loopback multipart requests')

# Reuse the installation boundary's native synchronous Trash contract on one
# uniquely named disposable file; no application, Dock or authentication UI.
subprocess.run([sys.executable, str(ROOT / 'tests/test-application-installation.py'),
                '--trash-only'], check=True)
