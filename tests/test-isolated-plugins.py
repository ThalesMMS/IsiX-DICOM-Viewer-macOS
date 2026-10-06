#!/usr/bin/env python3
"""An isolated development launch leaves the user's plugins alone.

The isolated launches (`tools/native_app.py`, `script/build_and_run.sh`) kept
their own database, listener and updates, and still loaded the plugins of
whoever ran them from ~/Library/Application Support/Horos/Plugins. Stopping the
development app while one loaded left the marker naming it beside that folder,
and the next launch offered, as its default button, to move the user's real
plugin to the disabled folder.

`-IsolatedPluginsFolder <folder>`, honoured only by the development bundle
identifier, stands that folder in for the user's and the computer's plugins
folders, and puts the marker there too; `--LoadPlugin <bundle>` still loads a
given plugin. Checked here with the production `+discoverPlugins`, its folder
helpers, the crash marker, the loader and `+pluginsList`, compiled from
PluginManager.swift into a probe bundle with the development identifier or the
released one, run with a temporary home that holds a synthetic plugin and a
marker left behind naming it. The probe records every folder listed and every
existence check, and refuses listings outside the temporary folder, so the real
/Library folders are never enumerated. The real home is never used.

`<git revision>` as an optional argument reads the sources from that revision:
before the fix the isolated launch lists the home's plugins folder, reads its
marker and loads the plugin there.
"""
from pathlib import Path
import json
import plistlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
DEVELOPMENT = 'thalesmms.isis.workstation.local-development'
RELEASE = 'thalesmms.isis.workstation'
failures = []


def read(path):
    """The file at `revision`, or in the working tree; Objective-C headers may be Latin-1."""
    data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']) if revision \
        else (root / path).read_bytes()
    return data.decode('latin1' if path.endswith(('.h', '.m')) else 'utf-8')


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


if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

# The launchers pass the switch, pointing inside the test root.
native_app = read('tools/native_app.py')
namespace = {'__file__': str(root / 'tools/native_app.py'), '__name__': 'native_app_under_test'}
exec(compile(native_app, 'tools/native_app.py', 'exec'), namespace)
arguments = namespace['isolation_arguments'](Path('/isolated/root'))
if '-IsolatedPluginsFolder' not in arguments:
    failures.append('tools/native_app.py: isolation_arguments does not pass -IsolatedPluginsFolder')
else:
    folder = arguments[arguments.index('-IsolatedPluginsFolder') + 1]
    if not folder.startswith('/isolated/root/'):
        failures.append(f'tools/native_app.py: the isolated plugins folder {folder} is not inside the test root')
launcher = read('script/build_and_run.sh')
launch_arguments = re.search(r'^ARGS=\((.*)\)$', launcher, re.M)
if not launch_arguments or not re.search(r'-IsolatedPluginsFolder "\$TEST_ROOT/[^"]+"', launch_arguments.group(1)):
    failures.append('script/build_and_run.sh: ARGS does not pass -IsolatedPluginsFolder inside $TEST_ROOT')

# The production code, in slices the probe can compile.
source = read('Horos/Sources/PluginManager.swift')
section = source[source.index('    // MARK: directories'):source.index('    // MARK: activation')]
methods = [swift_block(source, source.index(anchor)) for anchor in (
    '@objc public class func crashMarkerPath()',
    '@objc(startProtectForCrashWithPath:)',
    '@objc public class func endProtectForCrash()',
    '@objc(isPluginBundleSignatureValid:)',
    '@objc(loadPluginBundle:)',
    '@objc(loadHorosPluginAtPath:)',
    '@objc(loadOsiriXPluginAtPath:)',
    '@objc(loadPluginAtPath:)',
    '@objc public class func discoverPlugins()',
    '@objc(movePluginFromPath:toPath:)',
    '@objc public class func pluginsList()',
    '@objc public class func availabilities()',
)]
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
registry = swift_block(source, source.index('fileprivate enum Registry {'))
header = read('Horos/Sources/PluginManager.h')
declarations = header[header.index('@class PluginManager;') + len('@class PluginManager;'):header.index('#elif __has_include("Horos-Swift.h")')]

bridge = '''#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);
void ProbeInstall(NSArray<NSString *> *allowedRoots);
NSArray<NSString *> *ProbeListed(void);
NSArray<NSString *> *ProbeChecked(void);
NSArray<NSString *> *ProbeRefused(void);
''' + declarations

recorder = r'''#import <Foundation/Foundation.h>
#import <objc/runtime.h>

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"%s: %@", pf, e); }

static NSMutableArray *listed, *checked, *refused;
static NSArray *allowed;
static IMP contentsIMP, existsIMP, existsDirectoryIMP;

static BOOL permitted(NSString *path) {
    for (NSString *prefix in allowed) if ([path hasPrefix:prefix]) return YES;
    return NO;
}

static NSArray *contents(id self, SEL _cmd, NSString *path, NSError **error) {
    [listed addObject:path ?: @"(nil)"];
    if (!path || !permitted(path)) {
        // Outside the temporary folder: recorded, never enumerated.
        [refused addObject:path ?: @"(nil)"];
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        return nil;
    }
    return ((NSArray *(*)(id, SEL, NSString *, NSError **))contentsIMP)(self, _cmd, path, error);
}

static BOOL exists(id self, SEL _cmd, NSString *path) {
    [checked addObject:path ?: @"(nil)"];
    return ((BOOL (*)(id, SEL, NSString *))existsIMP)(self, _cmd, path);
}

static BOOL existsDirectory(id self, SEL _cmd, NSString *path, BOOL *directory) {
    [checked addObject:path ?: @"(nil)"];
    return ((BOOL (*)(id, SEL, NSString *, BOOL *))existsDirectoryIMP)(self, _cmd, path, directory);
}

void ProbeInstall(NSArray<NSString *> *allowedRoots) {
    listed = [NSMutableArray new]; checked = [NSMutableArray new]; refused = [NSMutableArray new];
    allowed = [allowedRoots copy];
    Class manager = [NSFileManager class];
    contentsIMP = method_setImplementation(class_getInstanceMethod(manager, @selector(contentsOfDirectoryAtPath:error:)), (IMP)contents);
    existsIMP = method_setImplementation(class_getInstanceMethod(manager, @selector(fileExistsAtPath:)), (IMP)exists);
    existsDirectoryIMP = method_setImplementation(class_getInstanceMethod(manager, @selector(fileExistsAtPath:isDirectory:)), (IMP)existsDirectory);
}

NSArray<NSString *> *ProbeListed(void) { return [[listed copy] autorelease]; }
NSArray<NSString *> *ProbeChecked(void) { return [[checked copy] autorelease]; }
NSArray<NSString *> *ProbeRefused(void) { return [[refused copy] autorelease]; }
'''

program = r'''
import AppKit

REGISTRY

HELPERS

var alerts: [String] = []

extension NSString {
    @objc(stringByResolvingAlias) func resolvingAlias() -> String! { return self.resolvingSymlinksInPath }
    @objc(stringByResolvingSymlinksAndAliases) func resolvingSymlinksAndAliases() -> String! { return self.resolvingSymlinksInPath }
}
@objc(T2FitMapCompatibility) final class T2FitMapCompatibility: NSObject {
    @objc static func diagnostic(forBundleAtPath path: String, loadErrorDomain: String?, loadErrorCode: Int) -> String? { return nil }
}
@objc(ROIEnhancementCompatibility) final class ROIEnhancementCompatibility: NSObject {
    @objc static func diagnostic(forBundleAtPath path: String, loadErrorDomain: String?, loadErrorCode: Int) -> String? { return nil }
}
@objc(HorosArchitectureAudit) final class HorosArchitectureAudit: NSObject {
    @objc(pluginDiagnosisAtPath:) static func pluginDiagnosis(at path: String) -> String? { return nil }
}
@objc(DCMPix) final class DCMPix: NSObject {
    static var protected = false
    @objc static func isRunOsiriXInProtectedModeActivated() -> Bool { return protected }
    @objc static func setRunOsiriXInProtectedMode(_ value: Bool) { protected = value }
}
enum T2FitMapFilter { static func register(in plugins: NSMutableDictionary) {} }
enum ROIEnhancementFilter { static func register(in plugins: NSMutableDictionary) {} }
// Every panel answers its alternate button: "Continue" for the marker left
// behind, so the probe never moves a plugin even in the temporary home.
enum HorosAlertPanel {
    static let defaultResponse = 1
    static let alternateResponse = 0
    static let otherResponse = -1
    @discardableResult static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts.append(title ?? ""); return NSAlertAlternateReturn
    }
    @discardableResult static func runInformational(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts.append(title ?? ""); return NSAlertAlternateReturn
    }
    @discardableResult static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts.append(title ?? ""); return NSAlertAlternateReturn
    }
}
final class ProbeAuthentication { func executeCommand(_ command: String, withArgs arguments: [Any]?) -> Bool { return false } }

@objc(PluginManager) final class PluginManager: NSObject {
    class func authentication() -> ProbeAuthentication? { return nil }
SECTION
METHODS
}

let temporary = ProcessInfo.processInfo.environment["PROBE_ALLOWED"]!.components(separatedBy: ":")
ProbeInstall(temporary)
// The type icons the Plugins window shows come from the application's assets.
for name in ["horosplugin", "osirixplugin"] { _ = NSImage(size: NSSize(width: 1, height: 1)).setName(name) }
guard temporary.contains(where: { NSHomeDirectory().hasPrefix($0) }) else {
    print("PROBE-ABORT home is not temporary: \(NSHomeDirectory())")
    exit(3)
}
PluginManager.discoverPlugins()
let listedDuringDiscovery = ProbeListed(), checkedDuringDiscovery = ProbeChecked()
let marker = PluginManager.crashMarkerPath()!
PluginManager.startProtectForCrash(withPath: "probe")
let markerWritten = FileManager.default.fileExists(atPath: marker)
PluginManager.endProtectForCrash()
// What the loader was asked to do with the home's plugin and the given one.
let arguments = ProcessInfo.processInfo.arguments
let given = arguments.firstIndex(of: "--LoadPlugin").map { arguments[$0 + 1] } ?? ""
let homePlugin = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Horos/Plugins/QADisabled.horosplugin")
func outcome(_ path: String) -> String {
    return PluginManagerCAPILoadOutcome((path as NSString).resolvingSymlinksInPath, true)["loadState"] as? String ?? ""
}
let report: [String: Any] = [
    "home": NSHomeDirectory(),
    "protected": DCMPix.isRunOsiriXInProtectedModeActivated(),
    "outcomes": ["home": outcome(homePlugin), "given": outcome(given)],
    "bundle": Bundle.main.bundleIdentifier ?? "",
    "alerts": alerts,
    "listed": listedDuringDiscovery,
    "checked": checkedDuringDiscovery,
    "refused": ProbeRefused(),
    "loaded": (Registry.pluginsBundleDictionnary?.allKeys as? [String]) ?? [],
    "marker": marker,
    "markerWritten": markerWritten,
    "markerRemoved": !FileManager.default.fileExists(atPath: marker),
    "active": PluginManager.activeDirectories() as? [String] ?? [],
    "inactive": PluginManager.inactiveDirectories() as? [String] ?? [],
    "listedPlugins": (PluginManager.pluginsList() ?? []).compactMap { ($0 as? NSDictionary)?["name"] as? String },
]
let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print("PROBE-REPORT " + String(data: data, encoding: .utf8)!)
'''.replace('REGISTRY', registry).replace('HELPERS', helpers).replace('SECTION', section).replace('METHODS', '\n'.join(methods))


def snapshot(folder):
    """Every entry under `folder` with its size and contents, to compare before and after."""
    state = {}
    for path in sorted(folder.rglob('*')):
        key = str(path.relative_to(folder))
        state[key] = path.read_bytes() if path.is_file() and not path.is_symlink() else ('dir' if path.is_dir() else 'other')
    return state


def under(path, *prefixes):
    return any(path == prefix.rstrip('/') or path.startswith(prefix.rstrip('/') + '/') for prefix in prefixes)


with tempfile.TemporaryDirectory(prefix='horos-isolated-plugins-') as directory:
    work = Path(directory)
    real = Path(os.path.realpath(directory))
    allowed = sorted({str(work), str(real)})
    fixtures = work / 'fixtures'
    generated = subprocess.run(['python3', str(root / 'tools/generate-plugin-load-fixtures.py'), str(fixtures)],
                               capture_output=True, text=True)
    if generated.returncode != 0:
        print('FAIL: the synthetic plugins were not built')
        print(generated.stdout + generated.stderr)
        sys.exit(1)

    (work / 'bridge.h').write_text(bridge)
    (work / 'recorder.m').write_text(recorder)
    (work / 'main.swift').write_text(program)
    (work / 'PluginUpdateRecovery.swift').write_text(read('Horos/Sources/PluginUpdateRecovery.swift'))
    (work / 'PluginQuarantine.swift').write_text(read('Horos/Sources/PluginQuarantine.swift'))
    objects = []
    for name, path in (('PluginManager+CAPI', root / 'Horos/Sources/PluginManager+CAPI.m'),
                       ('HorosObjCException', root / 'Horos/Sources/HorosObjCException.m'),
                       ('recorder', work / 'recorder.m')):
        built = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                                str(path), '-o', str(work / (name + '.o'))], capture_output=True, text=True)
        if built.returncode != 0:
            print(f'FAIL: {name} did not compile')
            print(built.stderr)
            sys.exit(1)
        objects.append(str(work / (name + '.o')))
    executable = work / 'probe'
    built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'IsolatedPlugins', '-import-objc-header', str(work / 'bridge.h'),
                            '-Xcc', '-I' + str(root / 'Horos/Sources'), str(work / 'main.swift'),
                            str(work / 'PluginUpdateRecovery.swift'), str(work / 'PluginQuarantine.swift'),
                            *objects, '-framework', 'Security', '-o', str(executable)],
                           capture_output=True, text=True, cwd=directory)
    if built.returncode != 0:
        print('FAIL: the PluginManager probe did not compile')
        print(built.stderr[-4000:])
        sys.exit(1)

    def bundle(identifier):
        """The probe as an application bundle, so Bundle.main has this identifier."""
        app = work / f'{identifier}.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(executable, app / 'Contents/MacOS/probe')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'probe', 'CFBundlePackageType': 'APPL'}))
        return app / 'Contents/MacOS/probe'

    probes = {DEVELOPMENT: bundle(DEVELOPMENT), RELEASE: bundle(RELEASE)}
    load_plugin = str(fixtures / 'QAUniversal.horosplugin')

    def scenario(label, identifier, isolated):
        """Run discovery with a fresh temporary home holding QADisabled and a marker naming it."""
        case = work / label
        home = case / 'home'
        support = home / 'Library/Application Support'
        user_plugins = support / 'Horos/Plugins'
        user_plugins.mkdir(parents=True)
        (support / 'Horos App/Plugins').mkdir(parents=True)
        shutil.copytree(fixtures / 'QADisabled.horosplugin', user_plugins / 'QADisabled.horosplugin')
        (support / f'Horos/Plugin_Loading.{identifier}').write_text(str(user_plugins / 'QADisabled.horosplugin'))
        isolated_folder = case / 'test root' / 'Isolated Plugins'
        before = snapshot(support)
        command = [str(probes[identifier])]
        if isolated:
            command += ['-IsolatedPluginsFolder', str(isolated_folder)]
        command += ['--LoadPlugin', load_plugin]
        # The fixture's +load lists this folder while it loads and logs the marker it finds.
        marker_folder = (isolated_folder / 'User/Library/Application Support/Horos') if isolated and identifier == DEVELOPMENT \
            else (support / 'Horos')
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), PROBE_ALLOWED=':'.join(allowed),
                           HOROS_PLUGIN_MARKER_DIR=str(marker_folder))
        ran = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=60)
        line = next((entry for entry in ran.stdout.splitlines() if entry.startswith('PROBE-REPORT ')), None)
        if ran.returncode != 0 or line is None:
            failures.append(f'{label}: the probe did not report (exit {ran.returncode})\n{ran.stdout[-2000:]}{ran.stderr[-2000:]}')
            return None
        report = json.loads(line[len('PROBE-REPORT '):])
        report['case'], report['support'], report['isolated'] = case, support, isolated_folder
        report['unchanged'] = before == snapshot(support)
        report['during'] = [entry for entry in ran.stderr.splitlines() if 'PLUGINFIXTURE while QAUniversal loads' in entry]
        return report

    def user_folders(report):
        home = report['support']
        return [str(home / 'Horos'), str(home / 'Horos App'),
                os.path.realpath(home / 'Horos'), os.path.realpath(home / 'Horos App')]

    SYSTEM = '/Library/Application Support/Horos'

    def touched(report, folders):
        return sorted({path for path in report['listed'] + report['checked'] if under(path, *folders)})

    def loaded(report, name):
        return any(Path(path).name == name for path in report['loaded'])

    # Isolated: the development bundle with the switch.
    isolated = scenario('isolated', DEVELOPMENT, True)
    if isolated:
        iso = [str(isolated['isolated']), os.path.realpath(isolated['isolated'])]
        read_home = touched(isolated, user_folders(isolated))
        if read_home:
            failures.append('isolated: the user\'s plugins folders were read: ' + ', '.join(read_home))
        read_system = touched(isolated, [SYSTEM])
        if read_system:
            failures.append('isolated: the computer\'s plugins folders were read: ' + ', '.join(read_system))
        if isolated['alerts'] or isolated['protected']:
            failures.append(f'isolated: the marker left in the home raised {isolated["alerts"]}, '
                            f'protected mode {isolated["protected"]}')
        if isolated['outcomes'] != {'home': 'Not loaded', 'given': 'Loaded'}:
            failures.append(f'isolated: load outcomes {isolated["outcomes"]}')
        if loaded(isolated, 'QADisabled.horosplugin'):
            failures.append('isolated: the plugin in the user\'s folder was loaded')
        if not loaded(isolated, 'QAUniversal.horosplugin'):
            failures.append('isolated: --LoadPlugin did not load the given bundle')
        if not isolated['unchanged']:
            failures.append('isolated: something under the home\'s Application Support changed (plugin moved or marker written or removed)')
        if not under(isolated['marker'], *iso):
            failures.append(f'isolated: the crash marker is {isolated["marker"]}, outside the isolated folder')
        if not (isolated['markerWritten'] and isolated['markerRemoved']):
            failures.append('isolated: the crash marker was not written and removed in the isolated folder')
        if not any(f'names {load_plugin}' in entry for entry in isolated['during']):
            failures.append('isolated: while the given bundle loaded, its marker was not in the isolated folder')
        bundle_plugins = str(probes[DEVELOPMENT].parents[1] / 'PlugIns')
        outside = [path for path in isolated['active'] + isolated['inactive']
                   if not under(path, *iso) and not path.startswith(bundle_plugins)]
        if outside:
            failures.append('isolated: Plugin Manager\'s folders include ' + ', '.join(outside))
        if isolated['listedPlugins']:
            failures.append(f'isolated: the Plugins window would list {isolated["listedPlugins"]}')
        # Beside the isolated folder, only the bundle's own PlugIns and the folder
        # of the --LoadPlugin bundle, where a loaded plugin's previous copy is discarded.
        strays = [path for path in isolated['listed'] if not (
            under(path, *iso) or path.startswith(bundle_plugins) or under(path, str(fixtures), os.path.realpath(fixtures)))]
        if not isolated['listed'] or strays:
            failures.append('isolated: listed outside the isolated folder: ' + ', '.join(strays))

    # Normal launches still read the user's folder, so the probe can see a read:
    # the development bundle without the switch, and a release bundle given it.
    for label, identifier, switch in (('development without the switch', DEVELOPMENT, False),
                                      ('release given the switch', RELEASE, True)):
        report = scenario(label.replace(' ', '-'), identifier, switch)
        if not report:
            continue
        if not touched(report, user_folders(report)):
            failures.append(f'{label}: the user\'s plugins folder was not read, so the probe cannot see a read')
        if SYSTEM + '/Plugins' not in report['listed'] and SYSTEM + '/Plugins/' not in report['listed']:
            failures.append(f'{label}: the computer\'s plugins folder was not listed')
        # The marker left in the home is read: the recovery alert, then no plugin
        # code in this run, the home's plugin included.
        if 'IsiX DICOM Viewer crashed' not in report['alerts']:
            failures.append(f'{label}: the marker left in the home did not raise the recovery alert')
        if not report['protected'] or report['outcomes'] != {'home': 'Blocked', 'given': 'Blocked'}:
            failures.append(f'{label}: expected the marker to block the home\'s plugin and the given one, '
                            f'got protected={report["protected"]} {report["outcomes"]}')
        if not under(report['marker'], str(report['support'] / 'Horos'), os.path.realpath(report['support'] / 'Horos')) \
                or not report['markerWritten']:
            failures.append(f'{label}: the crash marker {report["marker"]} is not written beside the user\'s plugins')
        if 'QADisabled' not in report['listedPlugins']:
            failures.append(f'{label}: the Plugins window would not list the user\'s plugin')
        if report['refused'] and not all(under(path, SYSTEM) for path in report['refused']):
            failures.append(f'{label}: refused listings outside the system folder: {report["refused"]}')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: an isolated development launch lists no user or system plugins folder, raises no alert for the '
      'marker in the home, changes nothing there, keeps its marker in the isolated folder and still loads '
      '--LoadPlugin; without the switch, or in a release bundle given it, the home\'s folder is listed, its '
      'marker raises the recovery alert and a new marker is written beside it')
