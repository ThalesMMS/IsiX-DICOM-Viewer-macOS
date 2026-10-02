#!/usr/bin/env python3
"""An interrupted or incompatible plugin update keeps a usable copy, and a
failed start does not take the database with it.

Issue #159: Horos Cloud (and any other plugin) can be updated in place. The
atomic swap already publishes a complete bundle, but it then deleted the
previous copy, so a candidate that passed preflight and then broke startup left
nothing to go back to. The bundled Cloud unzip wrote into the live plugins
folder and treated a disabled copy as missing, so safe deactivation did not
stick. A leftover Loading file still offered to rebuild the database even when
the crash note already named the plugin.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []


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



install = (root / 'Horos/Sources/HorosPluginInstall.h').read_text()
# PluginManager is Swift since #720; the checks below read its Swift spelling.
manager = source_text('PluginManager')
capi = (root / 'Horos/Sources/PluginManager+CAPI.m').read_bytes().decode('latin1')
# AppController is Swift since #830.
app = source_text('AppController')
swift = root / 'Horos/Sources/PluginUpdateRecovery.swift'

if not swift.exists():
    failures.append('PluginUpdateRecovery.swift is gone; the update recovery policy has no home')

# --- previous copy survives a successful publication --------------------------
if 'HorosPluginPreviousPath' not in install:
    failures.append('the installer has no stable place for the previous working plugin')
if install.count('removeItemAtPath:staging') and '.horos-plugin-previous' not in install:
    failures.append('successful publication still deletes the previous plugin with the staging directory')

# --- no plugin is installed from inside the application bundle ----------------
# The bundled copy of a third-party plugin used to be unzipped into the user's
# plugins folder at startup. Nothing is bundled now, and nothing is deployed.
for name, text in (('PluginManager.swift', manager), ('PluginUpdateRecovery.swift', source_text('PluginUpdateRecovery'))):
    for gone in ('deployHorosCloudPlugin', 'shouldDeployBundledCloud', 'prepareBundledCloud', 'HOROSCLOUD_PLUGIN_DEPLOYED'):
        if gone in text:
            failures.append('%s still carries %s: a plugin would be installed without being asked for' % (name, gone))

main = r'''import Foundation

let destination = "/Users/somebody/Library/Application Support/Horos/Plugins/HorosCloud.horosplugin"
let previous = PluginUpdateRecovery.previousPath(forDestination: destination)
assert(previous.hasSuffix("/.horos-plugin-previous/HorosCloud.horosplugin"), previous)
assert((previous as NSString).deletingLastPathComponent.hasSuffix("/Plugins/.horos-plugin-previous"), previous)

assert(PluginUpdateRecovery.shouldEnterPluginLessMode(markerExists: true))
assert(!PluginUpdateRecovery.shouldEnterPluginLessMode(markerExists: false))

assert(PluginUpdateRecovery.shouldOfferDatabaseRebuild(loadingFileExists: true, pluginMarkerExists: false))
assert(!PluginUpdateRecovery.shouldOfferDatabaseRebuild(loadingFileExists: true, pluginMarkerExists: true))
assert(!PluginUpdateRecovery.shouldOfferDatabaseRebuild(loadingFileExists: false, pluginMarkerExists: true))
assert(!PluginUpdateRecovery.shouldOfferDatabaseRebuild(loadingFileExists: false, pluginMarkerExists: false))

let restore = PluginUpdateRecovery.explanation(pluginNamed: "HorosCloud.horosplugin", canRestore: true, canDisable: true)
assert(restore.contains("HorosCloud.horosplugin"), restore)
assert(restore.lowercased().contains("previous") || restore.lowercased().contains("restore"), restore)
assert(restore.lowercased().contains("disabl"), restore)
assert(!restore.lowercased().contains("delete"), restore)
assert(!restore.lowercased().contains("database"), restore)
assert(!restore.lowercased().contains("rebuild"), restore)
let disableOnly = PluginUpdateRecovery.explanation(pluginNamed: "HorosCloud.horosplugin", canRestore: false, canDisable: true)
assert(disableOnly.contains("HorosCloud.horosplugin"), disableOnly)
assert(disableOnly.lowercased().contains("disabl"), disableOnly)
assert(!disableOnly.lowercased().contains("delete"), disableOnly)

print("PASS: previous path, plugin-less mode, no database rebuild, Cloud deploy policy, and a sentence that names the plugin")
'''

program = r'''
#import <Foundation/Foundation.h>
#import "HorosPluginInstall.h"
int main(int argc, char **argv) { @autoreleasepool {
 NSString *root = [NSString stringWithUTF8String:argv[1]];
 NSString *source = [root stringByAppendingPathComponent:@"new/QAUniversal.horosplugin"];
 NSString *destination = [root stringByAppendingPathComponent:@"installed/QAUniversal.horosplugin"];
 NSString *payload = @"Contents/Resources/seal.txt";
 NSData *old = [NSData dataWithContentsOfFile:[destination stringByAppendingPathComponent:payload]];
 NSData *updated = [NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:payload]];
 NSCAssert(old && updated && ![old isEqual:updated], @"fixture versions must differ");
 NSError *error = nil;
 NSCAssert(HorosInstallPlugin(source, destination, &error), @"valid update must publish: %@", error);
 NSCAssert([[NSData dataWithContentsOfFile:[destination stringByAppendingPathComponent:payload]] isEqual:updated], @"published version must be the new one");
 NSString *previous = HorosPluginPreviousPath(destination);
 NSCAssert([[NSData dataWithContentsOfFile:[previous stringByAppendingPathComponent:payload]] isEqual:old], @"successful update must keep the previous working plugin");
 for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:destination.stringByDeletingLastPathComponent error:NULL])
  NSCAssert(![entry hasPrefix:@".horos-plugin-update-"], @"normal completion must clean staging");
 NSCAssert(HorosRestorePreviousPlugin(destination, &error), @"restore must put the previous plugin back: %@", error);
 NSCAssert([[NSData dataWithContentsOfFile:[destination stringByAppendingPathComponent:payload]] isEqual:old], @"restore must publish the previous working plugin");
 puts("PASS: published update keeps the previous plugin and restore puts it back");
} }
'''

with tempfile.TemporaryDirectory(prefix='horos-plugin-update-recovery-') as directory:
    p = Path(directory)
    if swift.exists():
        (p / 'main.swift').write_text(main)
        compiled = subprocess.run(
            ['swiftc', str(swift), str(p / 'main.swift'), '-o', str(p / 'policy')],
            capture_output=True, text=True)
        if compiled.returncode != 0:
            print('FAIL: PluginUpdateRecovery.swift did not compile')
            print(compiled.stderr)
            failures.append('PluginUpdateRecovery.swift did not compile')
        else:
            ran = subprocess.run([str(p / 'policy')], capture_output=True, text=True)
            sys.stdout.write(ran.stdout)
            sys.stderr.write(ran.stderr)
            if ran.returncode != 0:
                failures.append('PluginUpdateRecovery policy assertions failed')

    subprocess.run(['python3', str(root / 'tools/generate-plugin-load-fixtures.py'),
                    str(p / 'fixtures')], check=True)
    data = p / 'fs'
    for parent in ('new', 'installed'):
        shutil.copytree(p / 'fixtures/QAUniversal.horosplugin',
                        data / parent / 'QAUniversal.horosplugin')
    (data / 'new/QAUniversal.horosplugin/Contents/Resources/seal.txt').write_text(
        'Updated synthetic resource')
    subprocess.run(['codesign', '--force', '--sign', '-',
                    str(data / 'new/QAUniversal.horosplugin')],
                   check=True, capture_output=True)
    (p / 'retain.m').write_text(program)
    compiled = subprocess.run(
        ['xcrun', 'clang', '-framework', 'Foundation', '-framework', 'Security',
         '-fsanitize=address', '-I', str(root / 'Horos/Sources'),
         str(p / 'retain.m'), '-o', str(p / 'retain')],
        capture_output=True, text=True)
    if compiled.returncode != 0:
        print('FAIL: previous-version installer harness did not compile')
        print(compiled.stderr)
        failures.append('previous-version installer harness did not compile')
    else:
        ran = subprocess.run([str(p / 'retain'), str(data)], capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        if ran.returncode != 0:
            failures.append('previous-version installer harness failed')

    leftover = p / 'leftover'
    installed = leftover / 'QAUniversal.horosplugin'
    shutil.copytree(p / 'fixtures/QAUniversal.horosplugin', installed)
    staging = leftover / '.horos-plugin-update-deadbeef' / 'QAUniversal.horosplugin'
    shutil.copytree(p / 'fixtures/QAUniversal.horosplugin', staging)
    (staging / 'Contents/Resources/seal.txt').write_text('Previous working copy')
    if swift.exists() and (p / 'policy').exists():
        adopt = r'''import Foundation
let root = CommandLine.arguments[1]
let adopted = PluginUpdateRecovery.adoptLeftoverStaging(inDirectory: root)
assert(adopted != nil, "leftover staging after a published swap must become the previous copy")
let previous = PluginUpdateRecovery.previousPath(forDestination: root + "/QAUniversal.horosplugin")
assert(adopted == previous, adopted ?? "nil")
assert((try? String(contentsOfFile: previous + "/Contents/Resources/seal.txt")) == "Previous working copy")
assert(!FileManager.default.fileExists(atPath: root + "/.horos-plugin-update-deadbeef"))
PluginUpdateRecovery.discardPrevious(forDestination: root + "/QAUniversal.horosplugin")
assert(!FileManager.default.fileExists(atPath: previous))
print("PASS: leftover staging is adopted as the previous plugin and can be discarded")
'''
        adopt_dir = p / 'adopt-main'
        adopt_dir.mkdir()
        (adopt_dir / 'main.swift').write_text(adopt)
        compiled = subprocess.run(
            ['swiftc', str(swift), str(adopt_dir / 'main.swift'), '-o', str(p / 'adopt')],
            capture_output=True, text=True)
        if compiled.returncode != 0:
            print('FAIL: leftover-staging harness did not compile')
            print(compiled.stderr)
            failures.append('leftover-staging harness did not compile')
        else:
            ran = subprocess.run([str(p / 'adopt'), str(leftover)], capture_output=True, text=True)
            sys.stdout.write(ran.stdout)
            sys.stderr.write(ran.stderr)
            if ran.returncode != 0:
                failures.append('leftover-staging harness failed')

if failures:
    for failure in failures:
        print('FAIL: %s' % failure)
    sys.exit(1)
print('ok: previous plugin kept, no plugin is installed from the application bundle, plugin-less start leaves the database alone')
