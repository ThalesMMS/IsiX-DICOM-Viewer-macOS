#!/usr/bin/env python3
"""The app's own folders resolve where they did before IsiXStorage, with one
deliberate change: the direct build's folder is Application Support/IsiX.

The plugin manager, the Web Portal, its preference pane and Horos.m (Weasis)
each spelled out their folders under Application Support. They now ask the
IsiXStorage module. Earlier versions of the direct build used
Application Support/Horos, the folder of Horos itself; that folder became
Application Support/IsiX, and nothing else about where the files are changed:
the App Store build's Horos App folder, the domains (home, root of the disk,
or the isolated folder's stand-ins), the subfolders and file names, the order
of the folders and what the App Store build lists.

Checked against the revision before the move, read from git, with every
`Application Support/Horos/` of its answers read as `Application Support/IsiX/`
(`Horos App` is not rewritten):
- the plugins folders: the directories section of PluginManager.swift and the
  folders plugin discovery lists, from that revision and from this one, are
  compiled into probes run as the released and the development bundle, with and
  without -IsolatedPluginsFolder, and in the App Store build; every answer
  must match;
- the Web Portal's accounts and custom pages, and the pane's copy: the paths
  that revision spelled out for each build, against the module's answer for
  the channel the app passes, which follows MACAPPSTORE;
- Weasis: that revision's literals (in Horos.m) against
  +[Horos WeasisCustomizationPaths], compiled from the current Horos.swift.

The four files must no longer spell the folders out themselves.

`<git revision>` as an optional argument names the earlier revision.
"""
from pathlib import Path
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from history_reference import before_text_added  # noqa: E402
from isix_modules import build_module, link_flags, module_flags  # noqa: E402

root = Path(__file__).resolve().parents[1]
CONSUMERS = ('Horos/Sources/PluginManager.swift', 'Horos/Sources/WebPortal.swift',
             'Preference Panes/OSIWebSharingPreferencePane/OSIWebSharingPreferencePanePref.swift',
             'Horos/Sources/Horos.swift')
# Where the earlier revision spelled the Weasis folders out.
EARLIER_WEASIS = 'Horos/Sources/Horos.m'
failures = []

if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

current_manager = (root / CONSUMERS[0]).read_text()
if len(sys.argv) > 1:
    previous = sys.argv[1]
elif 'StorageLocations' not in subprocess.run(['git', '-C', str(root), 'show', 'HEAD:' + CONSUMERS[0]],
                                              capture_output=True, text=True).stdout:
    previous = 'HEAD'  # the move is not committed yet
else:
    previous = before_text_added(CONSUMERS[0], 'StorageLocations')
if not previous:
    sys.stderr.write('the history does not reach the revision before IsiXStorage\n')
    sys.exit(2)


def renamed(answer):
    """An answer of the earlier revision, with the direct build's folder as it is now."""
    if isinstance(answer, str):
        return re.sub(r'Application Support/Horos(?=/|$)', 'Application Support/IsiX', answer)
    if isinstance(answer, list):
        return [renamed(item) for item in answer]
    return answer


# The rewrite touches the direct build's folder only.
assert renamed('/Library/Application Support/Horos/Plugins/') == '/Library/Application Support/IsiX/Plugins/'
assert renamed('~/Library/Application Support/Horos') == '~/Library/Application Support/IsiX'
assert renamed('/u/Library/Application Support/Horos App/Plugins') == '/u/Library/Application Support/Horos App/Plugins'


def old(path):
    return subprocess.run(['git', '-C', str(root), 'show', f'{previous}:{path}'],
                          capture_output=True, check=True).stdout.decode('utf-8')


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it."""
    depth, opened, index = 0, False, at
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
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


def manager_probe(source):
    """A PluginManager with the directories section of `source` and the
    folders its discovery lists, printing every answer as JSON."""
    section = source[source.index('    // MARK: directories'):source.index('    // MARK: activation')]
    discover = swift_block(source, source.index('@objc public class func discoverPlugins()'))
    start = discover.index('try HorosObjCException.perform {') + len('try HorosObjCException.perform {')
    folders = discover[start:discover.index('                let paths')]
    helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
    return '''import AppKit
import IsiXStorage

HELPERS

@objc(PluginManager) final class PluginManager: NSObject {
SECTION
    static func discoveryFolders() -> [String] {
FOLDERS
        return [userPath as String, userAppStorePath as String, sysPath as String]
    }
}

let answers: [String: Any] = [
    "active": PluginManager.activePluginsDirectoryPath() as Any,
    "inactive": PluginManager.inactivePluginsDirectoryPath() as Any,
    "userActive": PluginManager.userActivePluginsDirectoryPath() as Any,
    "userInactive": PluginManager.userInactivePluginsDirectoryPath() as Any,
    "systemActive": PluginManager.systemActivePluginsDirectoryPath() as Any,
    "systemInactive": PluginManager.systemInactivePluginsDirectoryPath() as Any,
    "isolated": PluginManager.isolatedPluginsFolder() ?? "(nil)",
    "activeDirectories": PluginManager.activeDirectories() as Any,
    "inactiveDirectories": PluginManager.inactiveDirectories() as Any,
    "discovery": PluginManager.discoveryFolders(),
    "developmentIdentifier": PluginManager.developmentBundleIdentifier,
    "argument": PluginManager.isolatedPluginsFolderArgument,
]
print(String(data: try! JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]), encoding: .utf8)!)
'''.replace('HELPERS', helpers).replace('SECTION', section).replace('FOLDERS', folders)


with tempfile.TemporaryDirectory(prefix='horos-storage-paths-') as folder:
    work = Path(folder)
    modules = work / 'modules'
    build_module('IsiXStorage', modules)
    (work / 'bridge.h').write_text('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(work / 'exception.o')], check=True)

    # The plugins folders, before and after, in each build and launch.
    results = {}
    home = work / 'home'
    home.mkdir()
    for label, source in (('before', old(CONSUMERS[0])), ('after', current_manager)):
        for store in (False, True):
            name = f'{label}-{"store" if store else "direct"}'
            (work / f'{name}.swift').write_text(manager_probe(source))
            built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Probe', '-import-objc-header', str(work / 'bridge.h'),
                                    '-Xcc', '-I' + str(root / 'Horos/Sources'), *(['-D', 'MACAPPSTORE'] if store else []),
                                    str(work / f'{name}.swift'), str(work / 'exception.o'),
                                    *module_flags('IsiXStorage', modules), '-o', str(work / name)],
                                   capture_output=True, text=True)
            if built.returncode != 0:
                print(f'FAIL: the {label} directories section does not compile')
                print(built.stderr[-3000:])
                sys.exit(1)
            for identifier in ('thalesmms.isis.workstation', 'thalesmms.isis.workstation.local-development'):
                # One bundle per identifier for both revisions: the folders
                # inside the bundle are part of the answers.
                app = work / 'apps' / f'{identifier}.app'
                (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
                shutil.copy2(work / name, app / 'Contents/MacOS/probe')
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
                    {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'probe', 'CFBundlePackageType': 'APPL'}))
                for arguments in ([], ['-IsolatedPluginsFolder', str(work / 'isolated' / '..' / 'isolated')]):
                    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
                    ran = subprocess.run([str(app / 'Contents/MacOS/probe'), *arguments], capture_output=True,
                                         text=True, env=environment, timeout=60)
                    if ran.returncode != 0:
                        print(f'FAIL: the {label} probe stopped: {ran.stderr[-1000:]}')
                        sys.exit(1)
                    results[(label, store, identifier, bool(arguments))] = json.loads(ran.stdout)
    for key, before in results.items():
        if key[0] != 'before':
            continue
        after = results[('after',) + key[1:]]
        for answer in sorted(set(before) | set(after)):
            if renamed(before.get(answer)) != after.get(answer):
                failures.append(f'{answer} ({"App Store" if key[1] else "direct"}, {key[2]}, '
                                f'{"isolated" if key[3] else "not isolated"}): {before.get(answer)!r} became {after.get(answer)!r}')

    # The Web Portal, its pane and Weasis: the paths the earlier revision spelled
    # out, against the module's answers for the channel the app passes.
    spelled = r'\("(~/Library/Application Support/[^"]+)" as NSString\)\.expandingTildeInPath'
    portal = re.findall(spelled, old(CONSUMERS[1]))
    pane = re.findall(spelled, old(CONSUMERS[2]))
    weasis = re.search(r'@\[ \[@"([^"]+)" stringByExpandingTildeInPath\], @"([^"]+)" \]', old(EARLIER_WEASIS))
    expected = {
        'store': {'accounts': portal[0], 'pages': portal[2], 'pane': pane[0]},
        'direct': {'accounts': portal[1], 'pages': portal[3], 'pane': pane[1]},
    }
    channel = (root / 'Horos/Sources/StorageLocations+Channel.swift').read_text()
    for store in (False, True):
        program = channel + '''
import Foundation
let answers = [
    "accounts": StorageLocations.webPortalAccountsPath(for: .running),
    "pages": StorageLocations.customWebPagesPath(for: .running),
    "pane": StorageLocations.customWebPagesPath(for: .running),
]
print(String(data: try! JSONSerialization.data(withJSONObject: ["answers": answers, "weasis": Horos.weasisCustomizationPaths()]), encoding: .utf8)!)
'''
        (work / 'main.swift').write_text(program)
        built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Channel', *(['-D', 'MACAPPSTORE'] if store else []),
                                str(work / 'main.swift'), str(root / CONSUMERS[3]), *module_flags('IsiXStorage', modules),
                                '-o', str(work / 'channel')], capture_output=True, text=True)
        if built.returncode != 0:
            print('FAIL: the channel probe does not compile')
            print(built.stderr[-3000:])
            sys.exit(1)
        ran = json.loads(subprocess.run([str(work / 'channel')], capture_output=True, text=True, check=True).stdout)
        build = 'store' if store else 'direct'
        for answer, literal in expected[build].items():
            if ran['answers'][answer] != os.path.expanduser(renamed(literal)):
                failures.append(f'{answer} ({build}): {literal} became {ran["answers"][answer]}')
        if ran['weasis'] != renamed([os.path.expanduser(weasis.group(1)), weasis.group(2)]):
            failures.append(f'Weasis ({build}): {weasis.groups()} became {ran["weasis"]}')

# The consumers ask the module rather than spelling the folders out.
for path in CONSUMERS:
    text = (root / path).read_text()
    if re.search(r'Application Support/Horos', text.split('*/', 1)[-1] if path.endswith('.m') else
                 '\n'.join(line for line in text.splitlines() if not line.strip().startswith('//'))):
        failures.append(f'{path} still spells out a folder under Application Support')
    if 'StorageLocations' not in text:
        failures.append(f'{path} does not use IsiXStorage')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'PASS: the plugins folders, the Web Portal accounts and pages, the pane copy and Weasis resolve as in {previous}, '
      'with Application Support/Horos now Application Support/IsiX and Horos App unchanged, in both builds, for the '
      'released and the development bundle, isolated or not, now through IsiXStorage')
