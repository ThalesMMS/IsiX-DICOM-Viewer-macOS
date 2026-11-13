#!/usr/bin/env python3
"""The hiding of the listener's errors: what the launch gave stays the launch's, and an abort stores nothing.

The development application is launched with -hideListenerError NO: no step
of the application may write that over what the user stored, nor take the
stored value for the launch's. The steps are compiled as they stand, with
swiftc, into functions the Objective-C driver calls over preferences of its
own:

  * the abort of the incoming transfers, DICOMListenerController's
    whileListenerErrorsHidden (in an older revision, a block of
    -killAllStoreSCU: itself), with the IsiXPreferences and IsiXDICOMNetwork
    modules it reads and the guards of PreferenceWorkGuards.swift. It once
    stored hideListenerError on, the user's value kept under
    copyHideListenerError for the launch after a crash; it now hides the
    errors for the process alone. While it runs every reader of the key reads
    it on and the stored preferences are as before; afterwards, and after an
    exception in the middle, everything is as before, a copy left by an
    earlier version included;
  * the launch's step of IsiXPreferences' LaunchPreferenceMigrations (in an
    older revision, a block of AppController.swift), which puts back a kept
    copy once and removes it;
  * the browser's -waitForRunningProcesses (BrowserController+Window.swift; in
    an older revision, the Objective-C of BrowserController.m), which stored
    the key on and at once put it back: it must not name the key any more. A
    revision that still has the block has it run.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR, where the probe's preferences are
from pathlib import Path
import argparse
import os
import re
import subprocess
import uuid
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path, class_text  # noqa: E402
import isix_modules  # noqa: E402
import objc_exception_guards  # noqa: E402
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', help='read source from this Git revision')
args = parser.parse_args()


def left_in_preferences():
    """The preference files a run of this test may leave in ~/Library/Preferences, whatever identifier named them."""
    return {path.name for path in (Path.home() / 'Library/Preferences').glob('*test-server-mode-*')}


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
browser = class_text('BrowserController')
category = source('Horos/Sources/NSUserDefaults+OsiriX.m')
helper = re.search(r'-\(BOOL\)hasArgumentOverrideForKey:.*?\n\}', category, re.S)
if '- (void)waitForRunningProcesses' in browser:
    browser_scope = browser.split('- (void)waitForRunningProcesses', 1)[1]
    browser_scope = browser_scope.split('// ----------', 2)[1]
    browser_swift = None
else:
    window = source('Horos/Sources/BrowserController+Window.swift')
    wait = swift_block(window, window.index('@objc(waitForRunningProcesses)'))
    if 'hideListenerError' in wait or 'HideListenerError' in wait:
        browser_swift = swift_block(wait, wait.index('if !defaults.hasArgumentOverride(forKey: "hideListenerError")'))
    else:
        # The wait writes nothing of the key: nothing of it to run.
        browser_swift = ''
# The method's statements, from those after the wait window is shown to the
# brace that closes it.
if 'HorosDICOMGlobalAbortBegin()' in swift_block(app, app.index('@objc(killAllStoreSCU:)')):
    abort = swift_block(app, app.index('@objc(killAllStoreSCU:)'))
    abort = abort[abort.index('\n', abort.index('.showWindow(')):abort.rindex('}')]
    abort_begin = abort.split('HorosDICOMGlobalAbortBegin()')[0]
    abort_begin = abort_begin[:abort_begin.rindex('\n')]
    abort_end = abort.split('HorosDICOMGlobalAbortEnd()')[1]
    abort_block, hidden, in_process = abort_begin + abort_end, '', False
else:
    # The abort runs inside the listener controller's whileListenerErrorsHidden,
    # compiled on its own and called with nothing to run while the errors are hidden.
    lifecycle = source('Horos/Sources/DICOMListenerController.swift')
    signature = re.search(r'(?:nonisolated )?static func whileListenerErrorsHidden\(', lifecycle)
    hidden = swift_block(lifecycle, signature.start())
    # For the process alone, on the main thread; a revision that stored the value ran on any thread.
    in_process = 'TemporaryPreference' in hidden
    hidden = ('@MainActor ' if in_process else '') + 'enum ListenerErrors {\n' + hidden + '\n}\n'
    abort_block = 'ListenerErrors.whileListenerErrorsHidden(in: defaults) { HarnessDuringAbort(defaults) }'
    if in_process:
        abort_block = 'MainActor.assumeIsolated { ' + abort_block + ' }'

if 'object(forKey: "copyHideListenerError")' in app:
    recovery_end = app.index('object(forKey: "copyHideListenerError")')
    recovery_start = app.rfind('if ', 0, recovery_end)
    recovery = swift_block(app, recovery_start)
else:
    # The launch's step in IsiXPreferences' LaunchPreferenceMigrations, over the
    # store it is given: here the defaults the driver hands it.
    migrations = source('Modules/IsiXPreferences/Sources/LaunchPreferenceMigrations.swift')
    recovery_end = migrations.index('object(forKey: NetworkPreferences.savedHidesListenerErrors.name)')
    recovery_start = migrations.rfind('if ', 0, recovery_end)
    recovery = swift_block(migrations, recovery_start).replace('store.', 'defaults.').replace('store[', 'defaults[')

if browser_swift is None:
    functions = ('static void writeBlock0(NSUserDefaults *defaults) {\n'
                 + browser_scope.replace('[NSUserDefaults standardUserDefaults]', 'defaults') + '\n}\n'
                 'void writeBlock1(NSUserDefaults *defaults);\nvoid writeBlock2(NSUserDefaults *defaults);')
    swift_blocks = ((1, abort_block), (2, recovery))
else:
    functions = 'void writeBlock0(NSUserDefaults *defaults);\nvoid writeBlock1(NSUserDefaults *defaults);\nvoid writeBlock2(NSUserDefaults *defaults);'
    swift_blocks = ((0, browser_swift), (1, abort_block), (2, recovery))
swift_functions = 'import Foundation\nimport IsiXPreferences\nimport IsiXDICOMNetwork\n' + hidden + '\n'.join(
    f'@_cdecl("writeBlock{index}") public func writeBlock{index}(_ defaults: UserDefaults) {{\n'
    + block.replace('UserDefaults.standard', 'defaults') + '\n}'
    for index, block in swift_blocks)

driver = r'''
#import <Foundation/Foundation.h>
@interface NSUserDefaults (Probe)
-(BOOL)hasArgumentOverrideForKey:(NSString*)key;
@end
@implementation NSUserDefaults (Probe)
HELPER
@end
FUNCTIONS

// What the abort of the incoming transfers must find while it runs.
static NSString *domainName;
static NSDictionary *storedDuringAbort;
static int hiddenDuringAbort = -1, abortsSeen = 0, raisesDuringAbort = 0, readByEveryReader = 0;
static const char *failure = NULL;
void HarnessDuringAbort(NSUserDefaults *defaults) {
    abortsSeen++;
    if (hiddenDuringAbort >= 0 && [defaults boolForKey:@"hideListenerError"] != (hiddenDuringAbort != 0))
        failure = "the errors are not hidden as expected while the transfers are aborted";
    if (readByEveryReader && hiddenDuringAbort >= 0 && [[NSUserDefaults standardUserDefaults] boolForKey:@"hideListenerError"] != (hiddenDuringAbort != 0))
        failure = "another reader of the process does not read the errors hidden while the transfers are aborted";
    if (storedDuringAbort && ![[defaults persistentDomainForName:domainName] isEqual:storedDuringAbort])
        failure = "the abort of the incoming transfers stored something";
    if (raisesDuringAbort) [NSException raise:NSGenericException format:@"in the middle"];
}

int main(int argc, char **argv) { @autoreleasepool {
    // The test names the domain, so it can remove the plist cfprefsd leaves behind.
    NSString *domain = domainName = @(argv[1]);
    // For the process alone, which another instance of the defaults reads too; or stored, in this suite.
    BOOL inProcess = atoi(argv[2]) != 0;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
    [defaults registerDefaults:@{@"hideListenerError": @NO}];
    void (*writers[])(NSUserDefaults *) = {writeBlock0, writeBlock1, writeBlock2};
    int checks = 0;
    @try {
        // Given at the launch, the key is the launch's: every step leaves what is stored alone.
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
                        storedDuringAbort = original; hiddenDuringAbort = argument;
                        // Repeated writes model startup, later abort and shutdown, with no timer.
                        writers[block](defaults);
                        writers[block](defaults);
                        if (failure || ![[defaults persistentDomainForName:domain] isEqual:original]) {
                            fprintf(stderr, "FAIL: block %d changed saved mode %d with argument %d and backup %d (%s)\n",
                                    block, saved, argument, stale, failure ?: "stored afterwards");
                            return 1;
                        }
                        if ([defaults boolForKey:@"hideListenerError"] != (argument != 0)) return 1;
                        checks++;
                    }
                }
            }
        }
        [defaults setVolatileDomain:@{} forName:NSArgumentDomain];
        readByEveryReader = inProcess;
        // Not given at the launch: stored on, stored off or only registered (off), with or without a copy
        // an earlier version left.
        for (int saved = -1; saved <= 1; saved++) {
            for (int stale = -1; stale <= 1; stale++) {
                NSMutableDictionary *original = [@{@"sentinel": @"preserved"} mutableCopy];
                if (saved >= 0) original[@"hideListenerError"] = @(saved != 0);
                if (stale >= 0) original[@"copyHideListenerError"] = @(stale != 0);

                // The abort: hidden while it runs; with the errors hidden for the process alone, nothing stored.
                for (int raises = 0; raises <= (inProcess ? 1 : 0); raises++) {
                    [defaults setPersistentDomain:original forName:domain];
                    storedDuringAbort = inProcess ? original : nil; hiddenDuringAbort = 1; raisesDuringAbort = raises;
                    int seen = abortsSeen;
                    NSString *raised = nil;
                    @try { writeBlock1(defaults); } @catch (NSException *exception) { raised = exception.reason; }
                    raisesDuringAbort = 0;
                    if (failure || abortsSeen != seen + 1 || (raises != 0) != (raised != nil)) {
                        fprintf(stderr, "FAIL: the abort with saved mode %d and backup %d, raising %d: %s\n", saved, stale, raises,
                                failure ?: "it did not run once, or its exception did not reach the caller");
                        return 1;
                    }
                    if ([defaults boolForKey:@"hideListenerError"] != (saved == 1)
                        || [[defaults volatileDomainForName:NSArgumentDomain] count] != 0) {
                        fprintf(stderr, "FAIL: after the abort (saved mode %d, backup %d, raising %d) the errors are not hidden as the user has it\n", saved, stale, raises);
                        return 1;
                    }
                    if (![[defaults persistentDomainForName:domain] isEqual:original]) {
                        fprintf(stderr, "FAIL: the abort changed what is stored (saved mode %d, backup %d, raising %d)\n", saved, stale, raises);
                        return 1;
                    }
                    checks++;
                }

                // The launch: a kept copy is put back, once, and is gone.
                [defaults setPersistentDomain:original forName:domain];
                writeBlock2(defaults);
                NSMutableDictionary *expected = [original mutableCopy];
                if (stale >= 0) { expected[@"hideListenerError"] = @(stale != 0); if (inProcess) [expected removeObjectForKey:@"copyHideListenerError"]; }
                if (![[defaults persistentDomainForName:domain] isEqual:expected]) {
                    fprintf(stderr, "FAIL: the launch with saved mode %d and backup %d left %s\n", saved, stale,
                            [[[defaults persistentDomainForName:domain] description] UTF8String]);
                    return 1;
                }
                if (inProcess && stale >= 0) {
                    // What the user chooses afterwards is theirs at the next launch.
                    [defaults setBool:stale == 0 forKey:@"hideListenerError"];
                    writeBlock2(defaults);
                    if ([defaults boolForKey:@"hideListenerError"] != (stale == 0)) {
                        fprintf(stderr, "FAIL: a second launch undid the user's choice (saved mode %d, backup %d)\n", saved, stale);
                        return 1;
                    }
                }
                checks++;
            }
        }
        printf("PASS: %d native preference cases; the abort hides the listener's errors %s, and no step writes over what the launch gave\n",
               checks, inProcess ? "for the process alone, storing nothing" : "in the preferences");
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
    (path / 'bridge.h').write_text('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n@interface NSUserDefaults (Probe)\n'
                                   '-(BOOL)hasArgumentOverrideForKey:(NSString*)key;\n@end\n'
                                   'void HarnessDuringAbort(NSUserDefaults *defaults);\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', str(path / 'probe.m'), '-o', str(path / 'probe.o')],
                   check=True)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', str(root / 'Horos/Sources/HorosObjCException.m'),
                    '-o', str(path / 'exception.o')], check=True)
    modules = isix_modules.module_flags('IsiXDICOMNetwork', path / 'modules')
    # The guards the abort runs its work in, as they stand.
    guards = []
    if in_process:
        (path / 'guards.swift').write_text(objc_exception_guards.source(log=False))
        guards = [str(path / 'guards.swift'), str(source_path('PreferenceWorkGuards'))]
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-import-objc-header', str(path / 'bridge.h'),
                    '-I', str(root / 'Horos/Sources'), *modules,
                    str(path / 'blocks.swift'), *guards, str(path / 'probe.o'), str(path / 'exception.o'), '-o', str(path / 'probe')], check=True)
    # The preferences of the probe are a file of the test's own TMPDIR (a domain named by an absolute path is
    # that file), removed with it: a domain named like a bundle identifier is a plist that cfprefsd keeps in
    # ~/Library/Preferences, and earlier revisions of this test left one there at every run.
    domain = str(Path(os.environ['TMPDIR']) / f'test-server-mode-{uuid.uuid4()}')
    left_before = left_in_preferences()
    try:
        subprocess.run([str(path / 'probe'), domain, '1' if in_process else '0'], check=True)
    finally:
        Path(domain + '.plist').unlink(missing_ok=True)
    left = left_in_preferences() - left_before
    assert not left, f'the test left preference domains behind: {sorted(left)}'

launcher = source('script/build_and_run.sh')
assert 'ARGS=(-hideListenerError NO ' in launcher, 'development must override saved server mode'
assert 'restore_development_server_mode' not in launcher, 'startup cannot depend on a timed restoration'
