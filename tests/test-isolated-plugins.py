#!/usr/bin/env python3
"""An isolated development launch leaves the user's plugins alone.

The isolated launches (`tools/native_app.py`, `script/build_and_run.sh`) kept
their own database, listener and updates, and still loaded the plugins of
whoever ran them from the user's plugins folder in Application Support. Stopping
the development app while one loaded left the marker naming it beside that folder,
and the next launch offered, as its default button, to move the user's real
plugin to the disabled folder.

`-IsolatedPluginsFolder <folder>`, honoured only by the development bundle
identifier, stands that folder in for the user's and the computer's plugins
folders, and puts the marker there too; `--LoadPlugin <bundle>` still loads a
given plugin, version 1 or made for Horos or OsiriX. Checked here with the
production `+discoverPlugins`, its folder helpers, the crash marker, the loader
entry, the version 1 and the former loaders and `+pluginsList`, compiled from
PluginManager.swift and PluginManager+IsiXPlugins.swift into a probe bundle
with the development identifier or the released one; only IsiXPluginHost, which runs a version 1
plugin, is a stand-in that records what it is asked to load and the marker at
that moment. The probe runs with a temporary home that holds, in
Application Support/IsiX/Plugins, one plugin of each supported format, with
a marker left behind naming the version 1 one in the recovery scenarios.
Application Support/Horos and Application Support/Horos App hold other plugins.
Only plugins in IsiX are discovered and listed. The probe records every folder
listed and every existence check, and refuses listings outside the temporary folder, so the real /Library
folders are never enumerated. The real home is never used.

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
sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags  # noqa: E402
import process_graph_stand_in  # noqa: E402

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
startup = read('Horos/Sources/ApplicationLifecycle.swift')
if 'LegacySupportImportPrompt.offerPluginsIfNeeded()' not in startup[:startup.index('Once.pluginManager = PluginManager()')]:
    failures.append('startup does not offer the copy before plugin discovery')
section = source[source.index('    // MARK: directories'):source.index('    // MARK: activation')]
methods = [swift_block(source, source.index(anchor)) for anchor in (
    '@objc public class func crashMarkerPath()',
    '@objc(startProtectForCrashWithPath:)',
    '    private class func writeCrashMarker(forPluginAt',
    '@objc public class func endProtectForCrash()',
    '@objc(isPluginBundleSignatureValid:)',
    '@objc(loadPluginBundle:)',
    '    private class func registerFormerPlugin(',
    '@objc(loadHorosPluginAtPath:)',
    '@objc(loadOsiriXPluginAtPath:)',
    '@objc(loadPluginAtPath:)',
    '    private class func takePluginsOutOfApplication()',
    '    private class func reportDuplicate(atPath',
    '    private class func folderRank(of folder',
    '@objc public class func discoverPlugins()',
    '    class func replaceInstalledPlugin(at installed',
    '@objc(movePluginFromPath:toPath:)',
    '@objc public class func pluginsList()',
    '@objc public class func availabilities()',
    '    public class func offeredAvailabilities()',
)]
v1 = read('Horos/Sources/PluginManager+IsiXPlugins.swift')
methods += [swift_block(v1, v1.index(anchor)) for anchor in (
    '@objc(loadIsiXPluginAtPath:)', '    class func isIsiXPluginCompatible(atPath')]
helpers = swift_block(source, source.index('fileprivate enum ObjC {'))
registry = swift_block(source, source.index('fileprivate enum Registry {'))
header = read('Horos/Sources/PluginManager.h')
declarations = header[header.index('@class PluginManager;') + len('@class PluginManager;'):header.index('#elif __has_include("Horos-Swift.h")')]

# IsiXStorage, compiled from the working tree, now resolves aliases itself
# (the former NSString category's selectors); a stand-in is needed only with
# an IsiXStorage that does not.
storage = '\n'.join(p.read_text(encoding='utf-8') for p in sorted((root / 'Modules/IsiXStorage/Sources').rglob('*.swift')))
aliases = '' if '@objc(stringByResolvingAlias)' in storage else '''extension NSString {
    @objc(stringByResolvingAlias) func resolvingAlias() -> String! { return self.resolvingSymlinksInPath }
    @objc(stringByResolvingSymlinksAndAliases) func resolvingSymlinksAndAliases() -> String! { return self.resolvingSymlinksInPath }
}'''

bridge = '''#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
#import "IsiXPluginExceptionGuard.h"
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
import IsiXPluginLoading
import IsiXPreferences
import IsiXStorage

REGISTRY

HELPERS

var alerts: [String] = []
var alertButtons: [[String]] = []

ALIASES
// What the host says of an exception that escaped a plugin; the real one
// (IsiXPluginCommandGuard.swift) needs the plugin kit.
struct IsiXPluginException: CustomStringConvertible {
    let description: String
    init(_ error: NSError) { description = error.localizedDescription }
}
func onMainActorSync<Result>(_ body: @MainActor @Sendable () throws -> Result) rethrows -> Result {
    try MainActor.assumeIsolated { try body() }
}
// The import command shows its second sheet from the main run loop; the probe opens no window.
func onMainRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {}
// The host that runs version 1 plugins: it records each bundle it is asked to
// load, and what the crash marker says at that moment, and loads nothing.
@MainActor final class IsiXPluginHost {
    static let shared = IsiXPluginHost()
    nonisolated(unsafe) static var requested: [String] = []
    nonisolated(unsafe) static var markerDuring: [String] = []
    struct Outcome {
        enum State { case loaded, incompatible, failed }
        var state: State
        var reason: String
    }
    func loadPlugin(at url: URL) -> Outcome {
        Self.requested.append(url.lastPathComponent)
        Self.markerDuring.append((try? String(contentsOfFile: PluginManager.crashMarkerPath(), encoding: .utf8)) ?? "")
        return Outcome(state: .loaded, reason: "")
    }
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
final class T1FitMapFilter: NSObject { static let menuTitle = "T1 Fit Map" }
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
        alerts.append(title ?? "")
        alertButtons.append([defaultButton, alternateButton, otherButton].compactMap { $0 })
        // The default button also for the note of a plugin that was running a
        // command: there it keeps the plugin, and the alternate one disables it.
        return title == "Copy plugins to IsiX?" || title == "IsiX DICOM Viewer did not quit normally" ? defaultResponse : alternateResponse
    }
    @discardableResult static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts.append(title ?? ""); return NSAlertAlternateReturn
    }
}
final class ProbeAuthentication {
    func authenticate(_ forCommands: [Any]?) -> Bool { return false }
    func executeCommand(_ command: String, withArgs arguments: [Any]?) -> Bool { return false }
}

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
// The plugin manager's Import Plugins from Horos or OsiriX command, without its
// window: the survey with the loader's own rules, the lines the sheet shows, and
// the copy, a newer version going through the installer that updates a plugin.
var importLines: [String: [String]] = [:]
if ProcessInfo.processInfo.arguments.contains("--ProbeImportAgain") {
    let again = LegacyPluginImport(userDomain: StorageLocations.runningUserDomain, systemDomain: StorageLocations.runningSystemDomain)
    let survey = again.survey(rules: LegacySupportImportPrompt.pluginRules)
    let lines = LegacySupportImportPrompt.lines(of: survey)
    importLines["additions"] = lines.additions
    importLines["leftOut"] = lines.leftOut
    let failed = try! again.add(survey.additions, rules: LegacySupportImportPrompt.pluginRules) { source, installed in
        try PluginManager.replaceInstalledPlugin(at: installed, with: source)
    }
    importLines["failed"] = LegacySupportImportPrompt.lines(of: LegacyPluginImport.Survey(skipped: failed)).leftOut
    let afterwards = again.survey(rules: LegacySupportImportPrompt.pluginRules)
    importLines["additionsAfterwards"] = LegacySupportImportPrompt.lines(of: afterwards).additions
}
if ProcessInfo.processInfo.arguments.contains("--ProbeCopyLegacyPlugins") {
    MainActor.assumeIsolated {
        LegacySupportImportPrompt.offerPluginsIfNeeded()
        LegacySupportImportPrompt.offerPluginsIfNeeded()
    }
}
PluginManager.discoverPlugins()
let rows = (PluginManager.pluginsList() ?? []).compactMap { $0 as? NSDictionary }
let listedPlugins = rows.compactMap { $0["name"] as? String }
let listedFolders = ProbeListed(), checkedPaths = ProbeChecked()
let marker = PluginManager.crashMarkerPath()!
PluginManager.startProtectForCrash(withPath: "probe")
let markerWritten = FileManager.default.fileExists(atPath: marker)
PluginManager.endProtectForCrash()
// What the loader was asked to do with the home's plugin and the given one.
let arguments = ProcessInfo.processInfo.arguments
let givenPaths = arguments.indices.filter { arguments[$0] == "--LoadPlugin" }.map { arguments[$0 + 1] }
let given = givenPaths.first { $0.hasSuffix(".isixplugin") } ?? ""
let support = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support")
let homePlugin = support + "/IsiX/Plugins/QAVersion1.isixplugin"
let givenFormer = givenPaths.first { $0.hasSuffix(".horosplugin") } ?? ""
func outcome(_ path: String) -> String {
    return PluginManagerCAPILoadOutcome((path as NSString).resolvingSymlinksInPath, true)["loadState"] as? String ?? ""
}
let report: [String: Any] = [
    "home": NSHomeDirectory(),
    "protected": DCMPix.isRunOsiriXInProtectedModeActivated(),
    "outcomes": ["home": outcome(homePlugin), "given": outcome(given), "givenFormer": outcome(givenFormer)],
    "bundle": Bundle.main.bundleIdentifier ?? "",
    "alerts": alerts,
    "alertButtons": alertButtons,
    "protectedModeAlert": ProtectedMode.alertMessage,
    "listed": listedFolders,
    "checked": checkedPaths,
    "refused": ProbeRefused(),
    "loaded": IsiXPluginHost.requested,
    "markerDuring": IsiXPluginHost.markerDuring,
    "marker": marker,
    "markerWritten": markerWritten,
    "markerRemoved": !FileManager.default.fileExists(atPath: marker),
    "active": PluginManager.activeDirectories() as? [String] ?? [],
    "inactive": PluginManager.inactiveDirectories() as? [String] ?? [],
    "listedPlugins": listedPlugins,
    "importLines": importLines,
    "loadOf": Dictionary(rows.compactMap { row in
        (row["path"] as? String).map { (($0 as NSString).lastPathComponent, "\(row["version"] ?? "") \(row["loadState"] ?? ""): \(row["loadReason"] ?? "")") }
    }, uniquingKeysWith: { first, _ in first }),
    "availabilityOf": Dictionary(rows.compactMap { row in (row["name"] as? String).map { ($0, row["availability"] as? String ?? "") } }, uniquingKeysWith: { first, _ in first }),
    "offeredAvailabilities": PluginManager.offeredAvailabilities().compactMap { $0 as? String },
    "allAvailabilities": (PluginManager.availabilities() ?? []).compactMap { $0 as? String },
    "loadedPlugins": rows.filter { ($0["loadState"] as? String) == "Loaded" }.compactMap { $0["name"] as? String },
    "installedOutcomes": [
        "Horos": outcome(support + "/IsiX/Plugins/QADisabled.horosplugin"),
        "OsiriX": outcome(support + "/IsiX/Plugins/QAOsiriX.osirixplugin"),
    ],
]
let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print("PROBE-REPORT " + String(data: data, encoding: .utf8)!)
'''.replace('REGISTRY', registry).replace('ALIASES', aliases).replace('HELPERS', helpers).replace('SECTION', section).replace('METHODS', '\n'.join(methods))


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
    (work / 'ProtectedMode.swift').write_text(read('Horos/Sources/ProtectedMode.swift'))
    (work / 'LegacySupportImportPrompt.swift').write_text(read('Horos/Sources/LegacySupportImportPrompt.swift'))
    objects = []
    for name, path in (('PluginManager+CAPI', root / 'Horos/Sources/PluginManager+CAPI.m'),
                       ('HorosObjCException', root / 'Horos/Sources/HorosObjCException.m'),
                       ('IsiXPluginExceptionGuard', root / 'Horos/Sources/IsiXPluginExceptionGuard.mm'),
                       ('recorder', work / 'recorder.m')):
        built = subprocess.run(['xcrun', 'clang++' if path.suffix == '.mm' else 'clang', '-c', '-fno-objc-arc',
                                '-I', str(root / 'Horos/Sources'),
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
                            str(work / 'ProtectedMode.swift'),
                            str(work / 'LegacySupportImportPrompt.swift'),
                            *objects, *module_flags('IsiXStorage', work / 'modules'),
                            *module_flags('IsiXPluginLoading', work / 'modules'),
                            # PluginManager reads its preferences through PreferencesSource.
                            *process_graph_stand_in.swift_flags(work / 'modules'),
                            # IsiXStorage's NSString path methods are an Objective-C
                            # category called by selector: no symbol pulls their
                            # object file out of the static library unless it is
                            # loaded whole. Only that library: each module library
                            # carries IsiXLogging, and -ObjC would load it twice.
                            '-Xlinker', '-force_load', '-Xlinker', str(work / 'modules' / 'libIsiXStorage.a'), '-lc++', '-framework', 'Security', '-o', str(executable)],
                           capture_output=True, text=True, cwd=directory)
    if built.returncode != 0:
        print('FAIL: the PluginManager probe did not compile')
        print(built.stderr[-4000:])
        sys.exit(1)

    def bundle(identifier, folder=None):
        """The probe as an application bundle, so Bundle.main has this identifier."""
        app = work / f'{folder or identifier}.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(executable, app / 'Contents/MacOS/probe')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'probe', 'CFBundlePackageType': 'APPL'}))
        return app / 'Contents/MacOS/probe'

    probes = {DEVELOPMENT: bundle(DEVELOPMENT), RELEASE: bundle(RELEASE)}
    # Given on the command line: a version 1 plugin and a former one.
    shutil.copytree(fixtures / 'QAVersion1.isixplugin', fixtures / 'QAGiven.isixplugin', symlinks=True)
    load_isix = str(fixtures / 'QAGiven.isixplugin')
    load_former = str(fixtures / 'QAUniversal.horosplugin')

    def scenario(label, identifier, isolated, recovery=True, copy_legacy=False, running=False, probe=None, prepare=None, extra=()):
        """Run discovery and listing in a fresh temporary home."""
        case = work / label
        home = case / 'home'
        support = home / 'Library/Application Support'
        user_plugins = support / 'IsiX/Plugins'
        user_plugins.mkdir(parents=True)
        store_plugins = support / 'Horos App/Plugins'
        store_plugins.mkdir(parents=True)
        shutil.copytree(fixtures / 'QAOsiriX.osirixplugin', store_plugins / 'QAStore.osirixplugin')
        shutil.copytree(fixtures / 'QADisabled.horosplugin', user_plugins / 'QADisabled.horosplugin')
        shutil.copytree(fixtures / 'QAOsiriX.osirixplugin', user_plugins / 'QAOsiriX.osirixplugin')
        shutil.copytree(fixtures / 'QAVersion1.isixplugin', user_plugins / 'QAVersion1.isixplugin', symlinks=True)
        if recovery:
            # The note of a plugin that was loading is its path; one that was
            # running a command says so on a second line.
            (support / f'IsiX/Plugin_Loading.{identifier}').write_text(
                str(user_plugins / 'QAVersion1.isixplugin') + ('\nrunning' if running else ''))
        own_former_before = snapshot(user_plugins / 'QADisabled.horosplugin')
        # The folder earlier versions used: a legacy plugin and an old marker naming it.
        legacy_plugins = support / 'Horos/Plugins'
        legacy_plugins.mkdir(parents=True)
        shutil.copytree(fixtures / 'QADisabled.horosplugin', legacy_plugins / 'QALegacy.horosplugin')
        (support / f'Horos/Plugin_Loading.{identifier}').write_text(str(legacy_plugins / 'QALegacy.horosplugin'))
        legacy_before = snapshot(support / 'Horos')
        isolated_folder = case / 'test root' / 'Isolated Plugins'
        if prepare:
            prepare(support)
        before = snapshot(support)
        command = [str(probe or probes[identifier])]
        if isolated:
            command += ['-IsolatedPluginsFolder', str(isolated_folder)]
        if copy_legacy:
            isolated_support = isolated_folder / 'User/Library/Application Support'
            shutil.copytree(fixtures / 'QAUniversal.horosplugin', isolated_support / 'Horos/Plugins/QAUniversal.horosplugin')
            shutil.copytree(fixtures / 'QAOsiriX.osirixplugin', isolated_support / 'OsiriX/Plugins Disabled/QAOsiriX.osirixplugin')
            command += ['--ProbeCopyLegacyPlugins']
        else:
            command += ['--LoadPlugin', load_former, '--LoadPlugin', load_isix]
        command += list(extra)
        # The fixtures' +load would leave a file here if any of their code ran.
        ran_folder = case / 'ran'
        ran_folder.mkdir()
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), PROBE_ALLOWED=':'.join(allowed),
                           HOROS_PLUGIN_MARKER_DIR=str(ran_folder))
        ran = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=60)
        line = next((entry for entry in ran.stdout.splitlines() if entry.startswith('PROBE-REPORT ')), None)
        if ran.returncode != 0 or line is None:
            failures.append(f'{label}: the probe did not report (exit {ran.returncode})\n{ran.stdout[-2000:]}{ran.stderr[-2000:]}')
            return None
        report = json.loads(line[len('PROBE-REPORT '):])
        report['case'], report['support'], report['isolated'] = case, support, isolated_folder
        report['unchanged'] = before == snapshot(support)
        report['legacyUnchanged'] = legacy_before == snapshot(support / 'Horos')
        report['ownFormerUnchanged'] = own_former_before == snapshot(user_plugins / 'QADisabled.horosplugin')
        report['ran'] = sorted(path.name for path in ran_folder.iterdir()) + \
            [entry for entry in ran.stderr.splitlines() if 'PLUGINFIXTURE' in entry]
        return report

    def user_folders(report, *names):
        home = report['support']
        return [str(home / name) for name in names] + [os.path.realpath(home / name) for name in names]

    SYSTEM = '/Library/Application Support/IsiX'
    LEGACY_SYSTEM = '/Library/Application Support/Horos'

    def touched(report, folders):
        return sorted({path for path in report['listed'] + report['checked'] if under(path, *folders)})

    # Isolated: the development bundle with the switch.
    isolated = scenario('isolated', DEVELOPMENT, True)
    if isolated:
        iso = [str(isolated['isolated']), os.path.realpath(isolated['isolated'])]
        read_home = touched(isolated, user_folders(isolated, 'IsiX', 'Horos App', 'Horos'))
        if read_home:
            failures.append('isolated: the user\'s plugins folders were read: ' + ', '.join(read_home))
        read_system = touched(isolated, [SYSTEM, LEGACY_SYSTEM])
        if read_system:
            failures.append('isolated: the computer\'s plugins folders were read: ' + ', '.join(read_system))
        if isolated['alerts'] or isolated['protected']:
            failures.append(f'isolated: the marker left in the home raised {isolated["alerts"]}, '
                            f'protected mode {isolated["protected"]}')
        if isolated['outcomes'] != {'home': 'Not loaded', 'given': 'Loaded', 'givenFormer': 'Loaded'}:
            failures.append(f'isolated: load outcomes {isolated["outcomes"]}')
        if isolated['loaded'] != ['QAGiven.isixplugin']:
            failures.append(f'isolated: the host was asked to load {isolated["loaded"]}, not only the given version 1 plugin')
        if not isolated['unchanged']:
            failures.append('isolated: something under the home\'s Application Support changed (plugin moved or marker written or removed)')
        if not under(isolated['marker'], *iso):
            failures.append(f'isolated: the crash marker is {isolated["marker"]}, outside the isolated folder')
        if not (isolated['markerWritten'] and isolated['markerRemoved']):
            failures.append('isolated: the crash marker was not written and removed in the isolated folder')
        if not (under(isolated['marker'], *iso) and len(isolated['markerDuring']) == 1
                and os.path.realpath(isolated['markerDuring'][0]) == os.path.realpath(load_isix)):
            failures.append(f'isolated: while the given bundle loaded, the marker in the isolated folder said {isolated["markerDuring"]}')
        bundle_plugins = str(probes[DEVELOPMENT].parents[1] / 'PlugIns')
        outside = [path for path in isolated['active'] + isolated['inactive']
                   if not under(path, *iso) and not path.startswith(bundle_plugins)]
        if outside:
            failures.append('isolated: Plugin Manager\'s folders include ' + ', '.join(outside))
        if isolated['listedPlugins']:
            failures.append(f'isolated: the Plugins window would list {isolated["listedPlugins"]}')
        if not isolated['legacyUnchanged']:
            failures.append('isolated: the folder earlier versions used changed')
        if isolated['ran']:
            failures.append(f'isolated: plugin code ran: {isolated["ran"]}')
        # Beside the isolated folder, only the bundle's own PlugIns, the folder
        # of the --LoadPlugin bundle, where a loaded plugin's previous copy is
        # discarded, and the folder the given former plugin's +load looks into.
        ran_folder = isolated['case'] / 'ran'
        strays = [path for path in isolated['listed'] if not (
            under(path, *iso) or path.startswith(bundle_plugins) or under(path, str(fixtures), os.path.realpath(fixtures))
            or under(path, str(ran_folder), os.path.realpath(ran_folder)))]
        if not isolated['listed'] or strays:
            failures.append('isolated: listed outside the isolated folder: ' + ', '.join(strays))

    # Normal launches still read the user's folder, so the probe can see a read:
    # the development bundle without the switch, and a release bundle given it.
    for label, identifier, switch in (('development without the switch', DEVELOPMENT, False),
                                      ('release given the switch', RELEASE, True)):
        report = scenario(label.replace(' ', '-'), identifier, switch)
        if not report:
            continue
        if not touched(report, user_folders(report, 'IsiX')):
            failures.append(f'{label}: the user\'s plugins folder was not read, so the probe cannot see a read')
        if SYSTEM + '/Plugins' not in report['listed'] and SYSTEM + '/Plugins/' not in report['listed']:
            failures.append(f'{label}: the computer\'s plugins folder was not listed')
        # The marker left in the home is read: the recovery alert, then no plugin
        # code in this run, the home's plugin included.
        if 'IsiX DICOM Viewer crashed' not in report['alerts']:
            failures.append(f'{label}: the marker left in the home did not raise the recovery alert')
        if not report['protected'] or report['outcomes'] != {'home': 'Blocked', 'given': 'Blocked', 'givenFormer': 'Blocked'}:
            failures.append(f'{label}: expected the marker to block the home\'s plugin and the given ones, '
                            f'got protected={report["protected"]} {report["outcomes"]}')
        if not under(report['marker'], str(report['support'] / 'IsiX'), os.path.realpath(report['support'] / 'IsiX')) \
                or not report['markerWritten']:
            failures.append(f'{label}: the crash marker {report["marker"]} is not written beside the user\'s plugins')
        if report['loaded'] or report['ran']:
            failures.append(f'{label}: protected mode let the host load {report["loaded"]}, or plugin code ran: {report["ran"]}')
        if set(report['listedPlugins']) != {'QAVersion1', 'QADisabled', 'QAOsiriX'}:
            failures.append(f'{label}: the Plugins window listed {report["listedPlugins"]}')
        old_paths = touched(report, user_folders(report, 'Horos App', 'Horos') + [LEGACY_SYSTEM])
        if old_paths:
            failures.append(f'{label}: discovery or listing accessed {old_paths}')
        if not report['ownFormerUnchanged']:
            failures.append(f'{label}: the former plugin in the app\'s own folder changed')
        if not report['legacyUnchanged']:
            failures.append(f'{label}: the folder earlier versions used changed')
        if report['alerts'].count('IsiX DICOM Viewer crashed') != 1:
            failures.append(f'{label}: expected one recovery alert, for the IsiX marker only: {report["alerts"]}')
        # The plugin stopped while loading: switching it off is the default answer,
        # and the Protected Mode that follows says why, not which keys to release.
        if report['alertButtons'][:1] != [['Disable Plugin', 'Continue']]:
            failures.append(f'{label}: the recovery alert offers {report["alertButtons"][:1]}')
        if 'stopped while loading a plugin' not in report['protectedModeAlert'] or 'Shift' in report['protectedModeAlert']:
            failures.append(f'{label}: Protected Mode after a plugin note says: {report["protectedModeAlert"]}')
        if report['refused'] and not all(under(path, SYSTEM) for path in report['refused']):
            failures.append(f'{label}: refused listings outside the system folder: {report["refused"]}')

    # The note of a plugin that had loaded and was running a command when the
    # run ended: the alert does not say it crashed the application, keeping the
    # plugin is the default answer, and the session opens with its plugins.
    ran = scenario('release-with-the-note-of-a-running-plugin', RELEASE, False, running=True)
    if ran:
        if ran['alerts'] != ['IsiX DICOM Viewer did not quit normally']:
            failures.append(f'running note: alerts {ran["alerts"]}')
        if ran['alertButtons'] != [['Continue', 'Disable Plugin']]:
            failures.append(f'running note: the alert offers {ran["alertButtons"]}, not keeping the plugin by default')
        if ran['protected'] or ran['outcomes']['home'] != 'Loaded':
            failures.append(f'running note: protected={ran["protected"]}, outcomes {ran["outcomes"]}: the session must open with its plugins')
        if 'Shift and Option' not in ran['protectedModeAlert']:
            failures.append('running note: the Protected Mode asked for with the keys lost its sentence about them')
        if not (ran['support'] / 'IsiX/Plugins/QAVersion1.isixplugin').is_dir() or (ran['support'] / 'IsiX/Plugins Disabled').exists():
            failures.append('running note: the plugin was moved')

    normal = scenario('release-without-crash-marker', RELEASE, False, recovery=False)
    if normal:
        if normal['outcomes']['home'] != 'Loaded' or normal['installedOutcomes'] != {'Horos': 'Loaded', 'OsiriX': 'Loaded'}:
            failures.append(f'release: IsiX plugins did not load: {normal["outcomes"]}, {normal["installedOutcomes"]}')
        if set(normal['listedPlugins']) != {'QAVersion1', 'QADisabled', 'QAOsiriX'}:
            failures.append(f'release: the Plugins window listed {normal["listedPlugins"]}')
        old_paths = touched(normal, user_folders(normal, 'Horos App', 'Horos') + [LEGACY_SYSTEM])
        if old_paths:
            failures.append(f'release: discovery or listing accessed {old_paths}')

    # Plugins that an earlier version installed inside the application, with the
    # "IsiX DICOM Viewer bundle" availability: the launch moves them to the user's
    # folders, active and disabled, and loads the active one from there. What
    # the application itself keeps in that folder stays, and the application is
    # no longer offered as a place to put a plugin.
    inside_probe = bundle(RELEASE, 'release-with-plugins-inside')
    inside_app = inside_probe.parents[1]
    # A plugin no other part of the scenario loads: two bundles cannot both own one class.
    shutil.copytree(fixtures / 'QAModalDialog.horosplugin', inside_app / 'PlugIns/QAModalDialog.horosplugin')
    shutil.copytree(fixtures / 'QADisabled.horosplugin', inside_app / 'PlugIns Disabled/QAInsideOff.horosplugin')
    (inside_app / 'PlugIns/Preview.appex/Contents').mkdir(parents=True)
    (inside_app / 'PlugIns/Preview.appex/Contents/Info.plist').write_text('the application\'s own extension')
    inside = scenario('release-with-plugins-inside-the-application', RELEASE, False, recovery=False, probe=inside_probe)
    if inside:
        user = inside['support'] / 'IsiX'
        if not (user / 'Plugins/QAModalDialog.horosplugin/Contents/MacOS/QAModalDialog').is_file() \
                or not (user / 'Plugins Disabled/QAInsideOff.horosplugin/Contents/MacOS/QADisabled').is_file():
            failures.append('inside the application: the plugins were not moved to the user\'s folders')
        if sorted(entry.name for entry in (inside_app / 'PlugIns').iterdir()) != ['Preview.appex'] or (inside_app / 'PlugIns Disabled').exists():
            failures.append('inside the application: the application still holds what was installed in it, or lost something of its own: '
                            + ', '.join(sorted(str(entry.relative_to(inside_app)) for entry in inside_app.rglob('*.horosplugin'))))
        if 'QAModalDialog' not in inside['loadedPlugins'] or 'QAInsideOff' in inside['loadedPlugins']:
            failures.append(f'inside the application: loaded {inside["loadedPlugins"]}')
        if inside['availabilityOf'].get('QAModalDialog') != 'Current user' or inside['availabilityOf'].get('QAInsideOff') != 'Current user':
            failures.append(f'inside the application: the moved plugins are listed as {inside["availabilityOf"]}')
        if inside['alerts']:
            failures.append(f'inside the application: the move raised {inside["alerts"]}')
        if inside['offeredAvailabilities'] != ['Current user', 'All users']:
            failures.append(f'the plugin manager offers {inside["offeredAvailabilities"]}')
        # The selector of the former SDK still answers the three names.
        if inside['allAvailabilities'] != ['Current user', 'All users', 'IsiX DICOM Viewer bundle']:
            failures.append(f'+availabilities answers {inside["allAvailabilities"]}')

    # One plugin under two bundles in the plugins folder, as two installers of one
    # author leave it: QA.horosplugin 1.0 and QA.osirixplugin 2.0. The higher
    # version loads; the other is listed as blocked, with both versions.
    def both(support):
        for name in ('QA.horosplugin', 'QA.osirixplugin'):
            shutil.copytree(fixtures / name, support / 'IsiX/Plugins' / name)
    twice = scenario('release-with-one-plugin-twice', RELEASE, False, recovery=False, prepare=both)
    if twice:
        loaded, blocked = twice['loadOf'].get('QA.osirixplugin', ''), twice['loadOf'].get('QA.horosplugin', '')
        if not loaded.startswith('2.0 Loaded'):
            failures.append(f'one plugin twice: QA.osirixplugin 2.0 is {loaded!r}')
        if not blocked.startswith('1.0 Blocked') or 'QA.osirixplugin (2.0)' not in blocked or '(1.0)' not in blocked:
            failures.append(f'one plugin twice: QA.horosplugin 1.0 is {blocked!r}, not blocked with both versions')
        if twice['alerts'] != ['Plugins']:
            failures.append(f'one plugin twice: alerts {twice["alerts"]}')

    # The Import Plugins from Horos or OsiriX command: IsiX has QA 1.0 and QAUniversal;
    # the Horos folder got QA 2.0 under the other extension, a plugin IsiX does not
    # have, the same QAUniversal, and a link.
    def later(support):
        shutil.copytree(fixtures / 'QA.horosplugin', support / 'IsiX/Plugins/QA.horosplugin')
        shutil.copytree(fixtures / 'QAUniversal.horosplugin', support / 'IsiX/Plugins/QAUniversal.horosplugin')
        (support / 'IsiX/.ImportLegacyPlugins.json').write_text('[]')
        horos = support / 'Horos/Plugins'
        shutil.copytree(fixtures / 'QA.osirixplugin', horos / 'QA.osirixplugin')
        shutil.copytree(fixtures / 'QAModalDialog.horosplugin', horos / 'QAModalDialog.horosplugin')
        shutil.copytree(fixtures / 'QAUniversal.horosplugin', horos / 'QAUniversal.horosplugin')
        (horos / 'QALinked.horosplugin').symlink_to(fixtures / 'QAIntel.horosplugin')
    again = scenario('release-import-again', RELEASE, False, recovery=False, prepare=later, extra=['--ProbeImportAgain'])
    if again:
        lines = again['importLines']
        # QALegacy and QAStore are what every scenario leaves in the Horos and Horos App folders.
        if lines.get('additions') != ['QA.osirixplugin (2.0) replaces QA.horosplugin (1.0)', 'QALegacy.horosplugin (1.0)',
                                      'QAModalDialog.horosplugin (1.0)', 'QAStore.osirixplugin (1.0)']:
            failures.append(f'import again: would copy {lines.get("additions")}')
        if lines.get('leftOut') != ['QALinked.horosplugin: it is a symbolic link, not a plugin.']:
            failures.append(f'import again: left out {lines.get("leftOut")}')
        if lines.get('failed') or lines.get('additionsAfterwards'):
            failures.append(f'import again: failed {lines.get("failed")}, still to copy afterwards {lines.get("additionsAfterwards")}')
        isix = again['support'] / 'IsiX/Plugins'
        # The newer build took the place of the old one, under the name it was installed with.
        info = plistlib.loads((isix / 'QA.horosplugin/Contents/Info.plist').read_bytes()) if (isix / 'QA.horosplugin').is_dir() else {}
        if info.get('CFBundleVersion') != '2.0' or (isix / 'QA.osirixplugin').exists():
            failures.append(f'import again: IsiX has QA at {info.get("CFBundleVersion")}, and QA.osirixplugin beside it: {(isix / "QA.osirixplugin").exists()}')
        if not again['loadOf'].get('QA.horosplugin', '').startswith('2.0 Loaded') \
                or not again['loadOf'].get('QAModalDialog.horosplugin', '').startswith('1.0 Loaded'):
            failures.append(f'import again: after the import the plugins are {again["loadOf"]}')
        if snapshot(fixtures / 'QA.osirixplugin') != snapshot(again['support'] / 'Horos/Plugins/QA.osirixplugin'):
            failures.append('import again: the source folder changed')
        if again['alerts']:
            failures.append(f'import again: alerts {again["alerts"]}')

    copied = scenario('copy-legacy-plugins', DEVELOPMENT, True, recovery=False, copy_legacy=True)
    if copied:
        if copied['alerts'] != ['Copy plugins to IsiX?']:
            failures.append(f'import: expected a single prompt, got {copied["alerts"]}')
        if set(copied['listedPlugins']) != {'QAUniversal', 'QAOsiriX'} or copied['loadedPlugins'] != ['QAUniversal']:
            failures.append(f'import: listed {copied["listedPlugins"]}, loaded {copied["loadedPlugins"]}')
        support = copied['isolated'] / 'User/Library/Application Support'
        for product, plugin in (('Horos', 'Plugins/QAUniversal.horosplugin'),
                                ('OsiriX', 'Plugins Disabled/QAOsiriX.osirixplugin')):
            source = support / product / plugin
            destination = support / 'IsiX' / plugin
            if not source.is_dir() or not destination.is_dir() or snapshot(source) != snapshot(destination):
                failures.append(f'import: source and copied plugin differ for {plugin}')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: discovery and listing use only the IsiX folders; the release probe loads .isixplugin, .horosplugin '
      'and .osirixplugin from IsiX. Crash recovery, isolated development, and the one-time copy prompt pass.')
