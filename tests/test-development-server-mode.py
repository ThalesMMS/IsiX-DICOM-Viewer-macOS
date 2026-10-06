#!/usr/bin/env python3
"""Execute the actual preference write blocks with process overrides and saved values.

AppController is Swift: its two blocks (the abort in
-killAllStoreSCU: and the crash recovery) are cut out of AppController.swift and
compiled with swiftc into functions the Objective-C driver calls, beside the
BrowserController.m block, which stays Objective-C.
"""
from pathlib import Path
import argparse
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', help='read source from this Git revision')
args = parser.parse_args()


def source(path):
    encoding = 'utf-8' if path.endswith('.swift') else 'latin1'
    if args.baseline:
        return subprocess.check_output(['git', 'show', f'{args.baseline}:{path}'],
                                       cwd=root).decode(encoding)
    return (root / path).read_bytes().decode(encoding)


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it,
    outside comments and string literals."""
    index, depth, opened = at, 0, False
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
            if index < 0:
                break
            continue
        if text.startswith('/*', index):
            index = text.index('*/', index) + 2
            continue
        if text[index] == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == '\\' else 1
        elif text[index] == '{':
            depth, opened = depth + 1, True
        elif text[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return text[at:index + 1]
        index += 1
    return ''


app = source(str(source_path('AppController').relative_to(root)))
browser = source('Horos/Sources/BrowserController.m')
category = source('Horos/Sources/NSUserDefaults+OsiriX.mm')
helper = re.search(r'-\(BOOL\)hasArgumentOverrideForKey:.*?\n\}', category, re.S)
browser_scope = browser.split('- (void)waitForRunningProcesses', 1)[1]
browser_scope = browser_scope.split('// ----------', 2)[1]
# The method's statements, from those after the wait window is shown to the
# brace that closes it.
abort = swift_block(app, app.index('@objc(killAllStoreSCU:)'))
abort = abort[abort.index('\n', abort.index('.showWindow(')):abort.rindex('}')]
abort_begin = abort.split('HorosDICOMGlobalAbortBegin()')[0]
abort_begin = abort_begin[:abort_begin.rindex('\n')]
abort_end = abort.split('HorosDICOMGlobalAbortEnd()')[1]
recovery_end = app.index('object(forKey: "copyHideListenerError")')
recovery_start = app.rfind('if ', 0, recovery_end)
recovery = swift_block(app, recovery_start)

functions = ('static void writeBlock0(NSUserDefaults *defaults) {\n'
             + browser_scope.replace('[NSUserDefaults standardUserDefaults]', 'defaults') + '\n}\n'
             'void writeBlock1(NSUserDefaults *defaults);\nvoid writeBlock2(NSUserDefaults *defaults);')
swift_functions = 'import Foundation\n' + '\n'.join(
    f'@_cdecl("writeBlock{index}") public func writeBlock{index}(_ defaults: UserDefaults) {{\n'
    + block.replace('UserDefaults.standard', 'defaults') + '\n}'
    for index, block in ((1, abort_begin + abort_end), (2, recovery)))

driver = r'''
#import <Foundation/Foundation.h>
@interface NSUserDefaults (Probe)
-(BOOL)hasArgumentOverrideForKey:(NSString*)key;
@end
@implementation NSUserDefaults (Probe)
HELPER
@end
FUNCTIONS
int main(void) { @autoreleasepool {
    NSString *domain = [@"thalesmms.isis.workstation.test-server-mode-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
    [defaults registerDefaults:@{@"hideListenerError": @NO}];
    void (*writers[])(NSUserDefaults *) = {writeBlock0, writeBlock1, writeBlock2};
    int checks = 0;
    @try {
        for (int saved = -1; saved <= 1; saved++) {
            for (int argument = 0; argument <= 1; argument++) {
                for (int stale = 0; stale <= 1; stale++) {
                    NSMutableDictionary *original = [@{@"sentinel": @"preserved"} mutableCopy];
                    if (saved >= 0) original[@"hideListenerError"] = @(saved != 0);
                    if (stale) original[@"copyHideListenerError"] = @(argument == 0);
                    [defaults setVolatileDomain:@{@"hideListenerError": argument ? @"YES" : @"NO"}
                                       forName:NSArgumentDomain];
                    for (int block = 0; block < 3; block++) {
                        [defaults setPersistentDomain:original forName:domain];
                        // Repeated writes model startup, later abort and shutdown, with no timer.
                        writers[block](defaults);
                        writers[block](defaults);
                        if (![[defaults persistentDomainForName:domain] isEqual:original]) {
                            fprintf(stderr, "FAIL: block %d changed saved mode %d with argument %d and backup %d\n",
                                    block, saved, argument, stale);
                            return 1;
                        }
                        if ([defaults boolForKey:@"hideListenerError"] != (argument != 0)) return 1;
                        checks++;
                    }
                }
            }
        }
        // Without an override, preserve existing suppression and crash recovery.
        [defaults setVolatileDomain:@{} forName:NSArgumentDomain];
        for (int saved = 0; saved <= 1; saved++) {
            for (int block = 0; block < 3; block++) {
                [defaults setPersistentDomain:@{@"hideListenerError": @(saved != 0),
                    @"copyHideListenerError": @(saved == 0)} forName:domain];
                writers[block](defaults);
                BOOL expected = block == 2 ? saved == 0 : saved != 0;
                if ([defaults boolForKey:@"hideListenerError"] != expected) return 1;
                checks++;
            }
        }
        printf("PASS: %d native preference cases; all three host write paths preserve process overrides\n", checks);
    } @finally {
        [defaults removePersistentDomainForName:domain];
        [defaults synchronize];
    }
} }
'''.replace('HELPER', helper.group() if helper else '').replace('FUNCTIONS', functions)

with tempfile.TemporaryDirectory(prefix='horos-server-mode-') as directory:
    path = Path(directory)
    (path / 'probe.m').write_text(driver)
    (path / 'blocks.swift').write_text(swift_functions)
    (path / 'bridge.h').write_text('#import <Foundation/Foundation.h>\n@interface NSUserDefaults (Probe)\n'
                                   '-(BOOL)hasArgumentOverrideForKey:(NSString*)key;\n@end\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', str(path / 'probe.m'), '-o', str(path / 'probe.o')],
                   check=True)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-import-objc-header', str(path / 'bridge.h'),
                    str(path / 'blocks.swift'), str(path / 'probe.o'), '-o', str(path / 'probe')], check=True)
    subprocess.run([str(path / 'probe')], check=True)

launcher = source('script/build_and_run.sh')
assert 'ARGS=(-hideListenerError NO ' in launcher, 'development must override saved server mode'
assert 'restore_development_server_mode' not in launcher, 'startup cannot depend on a timed restoration'
