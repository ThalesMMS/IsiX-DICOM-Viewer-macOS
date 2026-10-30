#!/usr/bin/env python3
"""tools/port-legacy-plugin.py: a Horos/OsiriX plugin's source converted into a
project of the IsiX plugin API 1 that builds with the porting kit.

    python3 tests/test-port-legacy-plugin.py [HOROSPLUGINS_DIR] [--xcodebuild]

Without arguments, on synthetic input only:

- each rewrite on a sample of the legacy call (alerts, sheets, panels, nib
  loading, file paths, NSCalendarDate, garbage collection), the forms it must
  leave alone (strings, comments, #import lines, another receiver, a handler
  that is not nil, ARC) and the report of what is left, with its line;
- tests/fixtures/port-legacy-plugin/LegacySample, a legacy plugin with its
  Xcode project: the files its target compiled and copied, each file's memory
  management and language (Objective-C++ in a .cxx file), the prefix header, the Info.plist in a subfolder, a localized
  resource, a xib, the former SDK, QTKit, a library of its own, garbage
  collection and former architectures. The converted project is checked file
  by file (Info.plist, Config/port.json, xcconfig, project.pbxproj, the
  originals, the diff, the report), then built with
  tools/build-isix-legacy-plugin.py: no warning in the kit or in the plugin,
  where the original source has deprecation warnings;
- two synthetic plugins converted with --shared-kit ../IsiXLegacyBridge next
  to one copy of the kit: no copy of the kit in either project, the manifest,
  header search, Xcode group and report pointing at the shared one, and both
  built, each with the kit's classes under its own runtime names;
- the kit's replacements themselves (tests/fixtures/port-legacy-plugin/
  PortSupportProbe.m): the legacy return codes of the alerts, a sheet ended by
  -[NSApplication endSheet:returnCode:], the delegate callbacks, the nib's
  top-level objects, NSCalendarDate's components, formats and arithmetic.

With HOROSPLUGINS_DIR (a checkout of horosproject/horosplugins, external input
not part of this repository), the converter runs over every plugin of the
collection without failing, and the rewrites of the kit's proofs are checked.
--xcodebuild also builds the synthetic project with xcodebuild (Release,
arm64), with its own copy of the kit and on a shared one; run it under the
machine's build lock.

Exits with 2 without the Xcode command line tools, or when HOROSPLUGINS_DIR is
given and is not a horosplugins checkout.
"""
from pathlib import Path
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'port-legacy-plugin'
SAMPLE = FIXTURES / 'LegacySample'
KIT = ROOT / 'IsiXLegacyBridge'
PROOFS = ['Cardiac Tagging MRI', 'ROIRotation', 'ROICorrectDisplayTextualData', 'Vertebra']
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


arguments = [a for a in sys.argv[1:] if not a.startswith('--')]
xcodebuild = '--xcodebuild' in sys.argv[1:]
if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
collection = Path(arguments[0]) if arguments else None
if collection and not all((collection / p / 'Info.plist').is_file() for p in PROOFS):
    sys.stderr.write('SKIP: HOROSPLUGINS_DIR is not a horosplugins checkout\n')
    sys.exit(2)
converter = load_tool('port_legacy_plugin', 'port-legacy-plugin.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')

# ---------------------------------------------------------------- rewrites, one sample each
# (name, ARC, legacy source, converted source, rules applied)
REWRITES = [
    ('alert panels and their codes', False,
     'if (NSRunAlertPanel(@"T", @"Delete %@?", @"OK", @"Cancel", nil, name) == NSAlertDefaultReturn) go();\n'
     'NSRunCriticalAlertPanel(@"T", @"m", nil, nil, nil);\n'
     'switch (NSRunInformationalAlertPanel(@"T", @"m", @"A", @"B", @"C")) { case NSAlertAlternateReturn: case NSAlertOtherReturn: break; }\n',
     'if (IsiXLegacyRunAlertPanel(@"T", @"Delete %@?", @"OK", @"Cancel", nil, name) == IsiXLegacyAlertDefaultReturn) go();\n'
     'IsiXLegacyRunCriticalAlertPanel(@"T", @"m", nil, nil, nil);\n'
     'switch (IsiXLegacyRunInformationalAlertPanel(@"T", @"m", @"A", @"B", @"C")) { case IsiXLegacyAlertAlternateReturn: case IsiXLegacyAlertOtherReturn: break; }\n',
     ['alert-return', 'alert-panel', 'alert-panel', 'alert-panel', 'alert-return', 'alert-return']),
    ('strings, comments and imports stay', False,
     '// NSRunAlertPanel(a) and [NSBundle loadNibNamed:@"X" owner:self]\n'
     'NSString *s = @"NSRunAlertPanel( NSCalendarDate";\n'
     '#import <Foundation/NSCalendarDate.h>\n'
     '/* [NSApp beginSheet:w modalForWindow:p modalDelegate:self didEndSelector:nil contextInfo:nil] */\n',
     None, []),
    ('alert sheets', False,
     'NSBeginAlertSheet(@"T", nil, nil, nil, w, self, @selector(end:returnCode:contextInfo:), nil, nil, @"%d", 3);\n'
     'NSBeginCriticalAlertSheet(@"T", nil, nil, nil, w, nil, nil, nil, nil, @"m");\n'
     'NSBeginInformationalAlertSheet(@"T", nil, nil, nil, nil, nil, nil, nil, nil, @"m");\n',
     'IsiXLegacyBeginAlertSheet(@"T", nil, nil, nil, w, self, @selector(end:returnCode:contextInfo:), nil, nil, @"%d", 3);\n'
     'IsiXLegacyBeginCriticalAlertSheet(@"T", nil, nil, nil, w, nil, nil, nil, nil, @"m");\n'
     'IsiXLegacyBeginInformationalAlertSheet(@"T", nil, nil, nil, nil, nil, nil, nil, nil, @"m");\n',
     ['alert-sheet', 'alert-sheet', 'alert-sheet']),
    ('legacy NSAlert and its sheet, nested, over several lines', False,
     '[[NSAlert alertWithMessageText: @"T" defaultButton: @"OK" alternateButton: nil otherButton: nil\n'
     '     informativeTextWithFormat: @"%@", x] beginSheetModalForWindow: [self window]\n'
     '                                 modalDelegate: self\n'
     '                                didEndSelector: @selector(end:returnCode:contextInfo:)\n'
     '                                   contextInfo: NULL];\n'
     'if ([[NSAlert alertWithMessageText:@"T" defaultButton:nil alternateButton:@"No" otherButton:nil informativeTextWithFormat:@""] runModal] == NSAlertAlternateReturn) stop();\n',
     'IsiXLegacyAlertBeginSheet(IsiXLegacyAlertWithMessageText(@"T", @"OK", nil, nil,\n'
     '     @"%@", x), [self window],\n'
     '                                 self,\n'
     '                                @selector(end:returnCode:contextInfo:),\n'
     '                                   NULL);\n'
     'if ([IsiXLegacyAlertWithMessageText(@"T", nil, @"No", nil, @"") runModal] == IsiXLegacyAlertAlternateReturn) stop();\n',
     ['alert-message-text', 'alert-modal-sheet', 'alert-message-text', 'alert-return']),
    ('application sheets', False,
     '[NSApp beginSheet: window modalForWindow:[NSApp keyWindow] modalDelegate:self didEndSelector:nil contextInfo:nil];\n'
     '[[NSApplication sharedApplication] beginSheet:s modalForWindow:w modalDelegate:d didEndSelector:@selector(e:returnCode:contextInfo:) contextInfo:(void*)c];\n'
     '[other beginSheet:s modalForWindow:w modalDelegate:d didEndSelector:nil contextInfo:nil];\n',
     'IsiXLegacyBeginSheet(window, [NSApp keyWindow], self, nil, nil);\n'
     'IsiXLegacyBeginSheet(s, w, d, @selector(e:returnCode:contextInfo:), (void*)c);\n'
     '[other beginSheet:s modalForWindow:w modalDelegate:d didEndSelector:nil contextInfo:nil];\n',
     ['app-sheet', 'app-sheet']),
    ('save and open panels', False,
     '[panel setRequiredFileType:@"txt"];\n'
     '[panel beginSheetForDirectory:NULL file:name modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(e:returnCode:contextInfo:) contextInfo:f];\n'
     '[open beginSheetForDirectory:d file:nil types:t modalForWindow:w modalDelegate:self didEndSelector:nil contextInfo:nil];\n'
     'if ([panel runModalForDirectory:nil file:@"a.txt"] == NSFileHandlingPanelOKButton) ok();\n'
     'if ([open runModalForDirectory:d file:nil types:t] == NSOKButton) ok();\n'
     'if ([open runModalForTypes:t] == NSCancelButton) return;\n'
     'NSArray *paths = [open filenames]; NSArray *mine = [self filenames];\n',
     'IsiXLegacyPanelSetRequiredFileType(panel, @"txt");\n'
     'IsiXLegacyPanelBeginSheet(panel, NULL, name, nil, [self window], self, @selector(e:returnCode:contextInfo:), f);\n'
     'IsiXLegacyPanelBeginSheet(open, d, nil, t, w, self, nil, nil);\n'
     'if (IsiXLegacyPanelRunModal(panel, nil, @"a.txt", nil) == NSModalResponseOK) ok();\n'
     'if (IsiXLegacyPanelRunModal(open, d, nil, t) == NSModalResponseOK) ok();\n'
     'if (IsiXLegacyPanelRunModal(open, nil, nil, t) == NSModalResponseCancel) return;\n'
     'NSArray *paths = IsiXLegacyPanelFilenames(open); NSArray *mine = [self filenames];\n',
     ['panel-required-type', 'panel-sheet', 'panel-sheet', 'panel-return', 'panel-modal', 'panel-return',
      'panel-modal', 'panel-return', 'panel-modal', 'panel-filenames']),
    ('nib loading', False,
     '[NSBundle loadNibNamed:@"Panel" owner:self];\n'
     'if (![NSBundle loadNibNamed: name owner: controller]) return;\n'
     '[bundle loadNibNamed:@"Panel" owner:self];\n',
     'IsiXLegacyLoadNibNamed(@"Panel", self);\n'
     'if (!IsiXLegacyLoadNibNamed(name, controller)) return;\n'
     '[bundle loadNibNamed:@"Panel" owner:self];\n',
     ['nib-loading', 'nib-loading']),
    ('file paths', False,
     '[[NSFileManager defaultManager] removeFileAtPath:path handler:nil];\n'
     '[fm copyPath:a toPath:b handler:0L];\n'
     '[fm movePath:a toPath:b handler:NULL];\n'
     '[fm createDirectoryAtPath:dir attributes:nil];\n'
     'NSArray *n = [fm directoryContentsAtPath:dir];\n'
     'NSDictionary *x = [fm fileAttributesAtPath:p traverseLink:YES], *y = [fm fileAttributesAtPath:p traverseLink:NO];\n'
     'NSString *s = [NSString stringWithContentsOfFile:p];\n'
     '[fm removeFileAtPath:path handler:self];\n'
     'NSDictionary *z = [fm fileAttributesAtPath:p traverseLink:follow];\n',
     '[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];\n'
     '[fm copyItemAtPath:a toPath:b error:NULL];\n'
     '[fm moveItemAtPath:a toPath:b error:NULL];\n'
     '[fm createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:nil error:NULL];\n'
     'NSArray *n = [fm contentsOfDirectoryAtPath:dir error:NULL];\n'
     'NSDictionary *x = [fm attributesOfItemAtPath:[p stringByResolvingSymlinksInPath] error:NULL], *y = [fm attributesOfItemAtPath:p error:NULL];\n'
     'NSString *s = [NSString stringWithContentsOfFile:p usedEncoding:NULL error:NULL];\n'
     '[fm removeFileAtPath:path handler:self];\n'
     'NSDictionary *z = [fm fileAttributesAtPath:p traverseLink:follow];\n',
     ['file-path'] * 8),
    ('NSCalendarDate', False,
     'NSCalendarDate *d = [NSCalendarDate dateWithYear:2026 month:10 day:29 hour:0 minute:0 second:0 timeZone:nil];\n'
     'NSString *t = [[NSDate date] descriptionWithCalendarFormat:@"%Y" timeZone:nil locale:nil];\n'
     'id c = [date dateWithCalendarFormat:@"%d" timeZone:zone];\n',
     'IsiXLegacyCalendarDate *d = [IsiXLegacyCalendarDate dateWithYear:2026 month:10 day:29 hour:0 minute:0 second:0 timeZone:nil];\n'
     'NSString *t = [IsiXLegacyCalendarDate descriptionOfDate:[NSDate date] calendarFormat:@"%Y" timeZone:nil locale:nil];\n'
     'id c = [IsiXLegacyCalendarDate dateWithDate:date calendarFormat:@"%d" timeZone:zone];\n',
     ['calendar-date'] * 4),
    ('garbage collection, manual reference counting', False,
     'if (objc_collectingEnabled()) objc_collect(OBJC_COLLECT_IF_NEEDED);\n'
     '[[NSGarbageCollector defaultCollector] collectIfNeeded];\n'
     'BOOL on = [[NSGarbageCollector defaultCollector] isEnabled];\n'
     'NSString *s = NSMakeCollectable(CFStringCreateCopy(NULL, r)); CFTypeRef t = CFMakeCollectable(r);\n'
     '- (void) finalize { [super finalize]; }\n',
     'if (NO) ((void)0);\n'
     '((void)0);\n'
     'BOOL on = 0;\n'
     'NSString *s = ((id)(CFStringCreateCopy(NULL, r))); CFTypeRef t = (r);\n'
     '- (void) finalize { [super finalize]; }\n',
     ['garbage-collection'] * 6),
    ('garbage collection, ARC', True,
     'NSString *s = NSMakeCollectable(r);\n',
     None, []),
]
# What each sample must leave in the report: (category, line).
LEFTOVERS = {
    'application sheets': [('legacy-alert/sheet', 3)],
    'nib loading': [('deprecated-nib-loading', 3)],
    'file paths': [('deprecated-file-api', 8), ('deprecated-file-api', 9)],
    'garbage collection, manual reference counting': [('garbage-collection', 5)],
    'garbage collection, ARC': [('garbage-collection', 1)],
}

for name, arc, before, after, rules in REWRITES:
    expected = before if after is None else after
    new, changes, leftovers = converter.rewrite_source(before, arc)
    check(new == expected, f'{name}: rewritten as\n{new}\nexpected\n{expected}')
    check(sorted(c['rule'] for c in changes) == sorted(rules), f'{name}: rules {[c["rule"] for c in changes]}')
    check(new.count('\n') == before.count('\n'), f'{name}: lines added or removed')
    found = sorted((item['category'], item['line']) for item in leftovers)
    check(found == sorted(LEFTOVERS.get(name, [])), f'{name}: left {found}')
    # The same sample with legacy Mac line endings: the same text, the same lines.
    cr_new, cr_changes, cr_left = converter.rewrite_source(before.replace('\n', '\r'), arc)
    check(cr_new == expected.replace('\n', '\r'), f'{name}: with CR line endings rewritten as {cr_new!r}')
    check(sorted((i['category'], i['line']) for i in cr_left) == found, f'{name}: CR leftovers {cr_left}')

# Lines of the report: the line in the legacy file.
_, changes, _ = converter.rewrite_source('a();\nb();\n[NSBundle loadNibNamed:@"X" owner:self];\nNSRunAlertPanel(@"t", @"m", nil, nil, nil);\n', False)
check([(c['rule'], c['line']) for c in changes] == [('nib-loading', 3), ('alert-panel', 4)], f'lines {changes}')

# ---------------------------------------------------------------- Carbon and the former SDK are reported
_, _, left = converter.rewrite_source('#include <Carbon/Carbon.h>\nFSRef ref;\n#if defined(__ppc__) || ppc\n#endif\n', False)
check(sorted((i['category'], i['line']) for i in left) == [('Carbon', 1), ('Carbon', 2), ('legacy-sdk/arch', 3)],
      f'Carbon and architectures: {left}')

# ---------------------------------------------------------------- the synthetic legacy plugin
with tempfile.TemporaryDirectory(prefix='port-legacy-plugin-') as temporary:
    work = Path(temporary)
    dry = converter.convert(SAMPLE)
    check('project' not in dry and not (SAMPLE / 'LegacySample').exists(), 'a dry run wrote files')
    report = converter.convert(SAMPLE, work / 'projects')
    project = Path(report['project'])
    check(project == work / 'projects' / 'LegacySample', f'project at {project}')
    for key in ('rewrites', 'unconverted', 'projectChanges', 'capabilities'):
        check(dry[key] == report[key], f'dry run and conversion differ in {key}')

    # The legacy target's files: SampleFilter.m (MRC) and SampleARC.m (ARC); not Stray.m, not the former SDK.
    manifest = json.loads((project / 'Config' / 'port.json').read_text())
    plugin_sources = [s for s in manifest['sources'] if s['path'].startswith('Sources/')]
    check([(s['path'], s['arc'], s['flags'], s.get('language')) for s in plugin_sources] ==
          [('Sources/Sources/SampleFilter.m', False, [], None),
           ('Sources/Sources/SampleARC.m', True, ['-Wno-unused-variable'], None),
           ('Sources/Sources/SampleCxx.cxx', False, [], 'objective-c++')], f'sources {plugin_sources}')
    kit_sources = sorted(Path(s['path']).name for s in manifest['sources'] if s['path'].startswith('IsiXLegacyBridge/'))
    check(kit_sources == sorted(p.name for p in (KIT / 'Sources').iterdir() if p.suffix in ('.m', '.swift'))
          and all(s['arc'] for s in manifest['sources'] if s['path'].startswith('IsiXLegacyBridge/')),
          f'kit sources {kit_sources}')
    check(manifest['resources'] == [
        {'path': 'Sources/Resources/English.lproj/InfoPlist.strings', 'destination': 'English.lproj/InfoPlist.strings'},
        {'path': 'Sources/Resources/Panel.xib', 'destination': 'Panel.xib'}], f'resources {manifest["resources"]}')
    check(manifest['frameworks'] == ['Cocoa', 'Accelerate', 'QuartzCore', 'CoreImage', 'UniformTypeIdentifiers', 'CoreData']
          and manifest['libraries'] == ['z'], f'linked {manifest["frameworks"]} {manifest["libraries"]}')
    check(manifest['defines'] == ['SAMPLE_DEFINE=1'] and manifest['archs'] == ['arm64', 'x86_64']
          and manifest['minimumSystem'] == '15.0', f'settings {manifest}')
    check(not (project / 'Sources' / 'OsiriX Headers').exists() and not list(project.rglob('*.osirixplugin')),
          'the former SDK was copied')
    check((project / 'Sources' / 'Sources' / 'Stray.m').is_file(), 'the plugin\'s other files are kept')
    check(not (project / 'Sources' / 'Resources' / 'Plugin-Info.plist').exists()
          and (project / 'Porting' / 'original' / 'Info.plist').read_bytes()
          == (SAMPLE / 'Resources' / 'Plugin-Info.plist').read_bytes(), 'the legacy Info.plist')
    prefix = (project / 'Config' / 'Prefix.pch').read_text()
    check('#include "IsiXLegacyPrefix.h"' in prefix and '#include "../Sources/Sources/Sample_Prefix.pch"' in prefix
          and prefix.index('IsiXLegacyPrefix') < prefix.index('Sample_Prefix'), f'prefix header {prefix}')
    check(sorted(p.name for p in (project / 'IsiXLegacyBridge' / 'Sources').iterdir())
          == sorted(p.name for p in (KIT / 'Sources').iterdir())
          and (project / 'IsiXLegacyBridge' / 'Include' / 'OsiriXAPI').is_symlink(), 'the kit\'s copy')

    info = plistlib.loads((project / 'Config' / 'Info.plist').read_bytes())
    expected_info = {
        'NSPrincipalClass': 'LegacySample.IsiXLegacyPluginEntry', 'IsiXLegacyFilterClass': 'SampleFilter',
        'IsiXLegacyPluginType': 'imageFilter', 'IsiXLegacyMenuTitles': ['Sample One', 'Sample Two'],
        'IsiXPluginAPIVersion': 1, 'IsiXPluginCapabilities': ['viewer.read', 'viewer.write', 'roi'],
        'CFBundleExecutable': 'LegacySample', 'CFBundleIdentifier': 'com.example.osirixplugin.LegacySample',
        'CFBundleName': 'LegacySample', 'CFBundleShortVersionString': '2.1', 'CFBundleVersion': '2.1',
        'LSMinimumSystemVersion': '15.0', 'CFBundlePackageType': 'BNDL'}
    check({k: info.get(k) for k in expected_info} == expected_info, f'Info.plist {info}')
    check(not {'pluginType', 'MenuTitles', 'ToolbarNames', 'HorosCompatiblePlugin', 'FileFormats', 'Requirements'}
          & info.keys(), f'former keys in {sorted(info)}')

    # The rewrites: in the file, in the original kept, in the diff and in the report.
    converted = (project / 'Sources' / 'Sources' / 'SampleFilter.m').read_text()
    original = (SAMPLE / 'Sources' / 'SampleFilter.m').read_text()
    check((project / 'Porting' / 'original' / 'Sources' / 'SampleFilter.m').read_text() == original, 'original kept')
    check(converter.rewrite_source(original, False)[0] == converted, 'the project has the rewritten file')
    check('NSRunAlertPanel(' not in converter.masks(converted)[1] and '@"NSRunAlertPanel("' in converted,
          'alerts in code rewritten, the string kept')
    diff = (project / 'Porting' / 'rewrites.diff').read_text()
    check('--- original/Sources/SampleFilter.m\n+++ Sources/Sources/SampleFilter.m' in diff
          and '-    [NSBundle loadNibNamed: @"Panel" owner: self];\n' in diff
          and '+    IsiXLegacyLoadNibNamed(@"Panel", self);\n' in diff
          and '--- original/Info.plist\n+++ Config/Info.plist' in diff, 'diff')
    rules = sorted({r['rule'] for r in report['rewrites']})
    check(rules == sorted(['alert-panel', 'alert-return', 'alert-sheet', 'alert-message-text', 'alert-modal-sheet',
                           'nib-loading', 'app-sheet', 'panel-required-type', 'panel-sheet', 'panel-return',
                           'panel-modal', 'panel-filenames', 'file-path', 'calendar-date', 'garbage-collection']),
          f'rules {rules}')
    nib = next(r for r in report['rewrites'] if r['rule'] == 'nib-loading')
    check((nib['file'], nib['line']) == ('Sources/Sources/SampleFilter.m', 34), f'nib rewrite at {nib}')
    check(report['changedFiles'] == ['Sources/Sources/SampleARC.m', 'Sources/Sources/SampleCxx.cxx',
                                     'Sources/Sources/SampleFilter.m'],
          f'changed {report["changedFiles"]}')
    check(sorted((c['category'], c['setting']) for c in report['projectChanges']) ==
          [('garbage-collection', 'GCC_ENABLE_OBJC_GC'), ('legacy-sdk/arch', 'ARCHS'),
           ('legacy-sdk/arch', 'OTHER_LDFLAGS / BUNDLE_LOADER'), ('legacy-sdk/arch', 'SDKROOT')],
          f'project changes {report["projectChanges"]}')
    unconverted = '\n'.join(item['text'] for item in report['unconverted'])
    for expected in ('target SamplePrefs', 'ShellScriptBuildPhase', '-faltivec -I ../../osirix/ITK180',
                     'libSampleITK.a', 'ToolbarNames', 'framework QTKit'):
        check(expected in unconverted, f'not reported: {expected}\n{unconverted}')
    check(report['memoryManagement'] == {'default': 'MRC', 'ARC': ['Sources/SampleARC.m'],
                                         'MRC': ['Sources/SampleCxx.cxx', 'Sources/SampleFilter.m']},
          f'memory {report["memoryManagement"]}')
    check('## Rewrites' in (project / 'Porting' / 'REPORT.md').read_text(), 'REPORT.md')

    # The Xcode project says what Config/port.json says.
    xcconfig = (project / 'Config' / 'LegacySample.xcconfig').read_text()
    for line in ('PRODUCT_NAME = LegacySample', 'WRAPPER_EXTENSION = isixplugin', 'MACOSX_DEPLOYMENT_TARGET = 15.0',
                 'ARCHS = arm64 x86_64', 'CLANG_ENABLE_OBJC_ARC = NO', 'GCC_PREFIX_HEADER = Config/Prefix.pch',
                 'USE_HEADERMAP = NO', 'SWIFT_OBJC_INTERFACE_HEADER_NAME = IsiXLegacyBridge-Swift.h',
                 'PRODUCT_BUNDLE_IDENTIFIER = com.example.osirixplugin.LegacySample',
                 'GCC_PREPROCESSOR_DEFINITIONS = $(inherited) ISIX_LEGACY_NAMESPACE=$(PRODUCT_MODULE_NAME) "SAMPLE_DEFINE=1"',
                 'OTHER_LDFLAGS = $(inherited) -framework IsiXPluginKit -framework Cocoa -framework Accelerate '
                 '-framework QuartzCore -framework CoreImage -framework UniformTypeIdentifiers -framework CoreData -lz'):
        check(line in xcconfig.splitlines(), f'xcconfig lacks {line}')
    pbx = converter.parse_openstep((project / 'LegacySample.xcodeproj' / 'project.pbxproj').read_text())
    objects = pbx['objects']
    target = next(o for o in objects.values() if o.get('isa') == 'PBXNativeTarget')
    check(target['productType'] == 'com.apple.product-type.bundle' and target['name'] == 'LegacySample', 'target')
    phases = {objects[p]['isa']: objects[p] for p in target['buildPhases']}
    compiled = {}
    for build in phases['PBXSourcesBuildPhase']['files']:
        reference = objects[objects[build]['fileRef']]
        compiled[reference['path']] = objects[build].get('settings', {}).get('COMPILER_FLAGS', '')
        if reference['path'] == 'SampleCxx.cxx':
            check(reference.get('explicitFileType') == 'sourcecode.cpp.objcpp', f'type of SampleCxx.cxx: {reference}')
    check(compiled.get('SampleFilter.m') == '' and compiled.get('SampleARC.m') == '-fobjc-arc -Wno-unused-variable'
          and compiled.get('IsiXLegacyPortSupport.m') == '-fobjc-arc' and 'IsiXLegacyPluginEntry.swift' in compiled
          and 'Stray.m' not in compiled, f'compiled {compiled}')
    copied = [objects[objects[b]['fileRef']] for b in phases['PBXResourcesBuildPhase']['files']]
    check(sorted((o['isa'], o.get('name', o.get('path'))) for o in copied) ==
          [('PBXFileReference', 'Panel.xib'), ('PBXVariantGroup', 'InfoPlist.strings')], f'resources {copied}')
    configurations = objects[target['buildConfigurationList']]['buildConfigurations']
    check(all(objects[objects[c]['baseConfigurationReference']]['path'] == 'LegacySample.xcconfig'
              for c in configurations), 'configurations are based on the xcconfig')
    again = converter.convert(SAMPLE, work / 'again')
    check((Path(again['project']) / 'LegacySample.xcodeproj' / 'project.pbxproj').read_text()
          == (project / 'LegacySample.xcodeproj' / 'project.pbxproj').read_text(), 'the project is not reproducible')

    # A plugin without an Xcode project: the folder's files, the overrides of the build tool.
    bare = work / 'Bare'
    (bare / 'Sources').mkdir(parents=True)
    shutil.copy2(SAMPLE / 'Resources' / 'Plugin-Info.plist', bare / 'Info.plist')
    (bare / 'Sources' / 'Bare.m').write_text('#import "PluginFilter.h"\n@interface BareFilter : PluginFilter\n@end\n'
                                             '@implementation BareFilter\n- (long) filterImage: (NSString*) t { '
                                             '[[BrowserController currentBrowser] addFilesToDatabase: nil]; return 0; }\n@end\n')
    (bare / 'Sources' / 'Skip.m').write_text('#error left out\n')
    bare_report = converter.convert(bare, work / 'bare', name='BarePlugin', arc=True, exclude=['Skip.m'])
    bare_manifest = json.loads((Path(bare_report['project']) / 'Config' / 'port.json').read_text())
    check([(s['path'], s['arc']) for s in bare_manifest['sources'] if s['path'].startswith('Sources/')]
          == [('Sources/Sources/Bare.m', True)] and bare_report['module'] == 'BarePlugin', f'bare {bare_manifest}')
    check(bare_report['capabilities'] == ['viewer.read', 'viewer.write', 'roi', 'database.read', 'database.import'],
          f'capabilities from the database use: {bare_report["capabilities"]}')
    # A viewer's image exported as DICOM writes into its study.
    exporting = work / 'Exporting'
    (exporting / 'Sources').mkdir(parents=True)
    shutil.copy2(SAMPLE / 'Resources' / 'Plugin-Info.plist', exporting / 'Info.plist')
    (exporting / 'Sources' / 'Export.m').write_text('#import "PluginFilter.h"\n@interface ExportFilter : PluginFilter\n@end\n'
                                                    '@implementation ExportFilter\n- (long) filterImage: (NSString*) t { '
                                                    '[viewerController exportDICOMFileInt: 0 withName: t allViewers: NO]; '
                                                    'return 0; }\n@end\n')
    export_report = converter.convert(exporting, None, name='ExportPlugin', arc=True)
    check(export_report['capabilities'] == ['viewer.read', 'viewer.write', 'roi', 'database.read', 'database.import'],
          f'capabilities from a viewer export: {export_report["capabilities"]}')

    # Built without Xcode: no warning in the kit or the plugin, where the original had deprecations.
    host = work / 'host'
    exporter.compile_framework(host, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host / 'IsiXPluginKit.framework', sdk, 'swiftc')
    warnings = {}
    try:
        bundle = builder.build_project(sdk, project, work / 'bundles', warnings=warnings)
    except RuntimeError as error:
        failures.append(f'the converted sample does not build: {error}')
        bundle = None
    if bundle:
        check(warnings == {'kit': [], 'plugin': [], 'nib': []}, f'warnings {warnings}')
        check(plistlib.loads((bundle / 'Contents' / 'Info.plist').read_bytes()) == info, 'bundle Info.plist')
        check((bundle / 'Contents' / 'Resources' / 'Panel.nib').exists()
              and (bundle / 'Contents' / 'Resources' / 'English.lproj' / 'InfoPlist.strings').is_file(), 'resources')
        check(subprocess.run(['codesign', '--verify', str(bundle)], capture_output=True).returncode == 0, 'signature')
        symbols = subprocess.run(['nm', '-gU', str(bundle / 'Contents' / 'MacOS' / 'LegacySample')], capture_output=True,
                                 text=True).stdout
        check(symbols and all(s.split()[-1].startswith(('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'))
                              for s in symbols.splitlines()), f'the bundle exports {symbols[:500]}')
    # Two plugins on one copy of the kit (--shared-kit): no copy in either project, each builds
    # the kit's objects into its own bundle under its own runtime names.
    shared = work / 'shared'
    for part in ('Headers', 'Include', 'Sources'):
        shutil.copytree(KIT / part, shared / 'IsiXLegacyBridge' / part, symlinks=True)
    shutil.copy2(KIT / 'README.md', shared / 'IsiXLegacyBridge' / 'README.md')
    second = work / 'second-plugin'
    (second / 'Sources').mkdir(parents=True)
    shutil.copy2(SAMPLE / 'Resources' / 'Plugin-Info.plist', second / 'Info.plist')
    (second / 'Sources' / 'Second.m').write_text('#import "PluginFilter.h"\n@interface SampleFilter : PluginFilter\n@end\n'
                                                 '@implementation SampleFilter\n- (long) filterImage: (NSString*) t { '
                                                 'return [[viewerController pixList] count] > 0 ? 0 : -1; }\n@end\n')
    shared_projects = {
        'LegacySample': Path(converter.convert(SAMPLE, shared, shared_kit='../IsiXLegacyBridge')['project']),
        'BarePlugin': Path(converter.convert(second, shared, name='BarePlugin', arc=True,
                                             shared_kit='../IsiXLegacyBridge/')['project'])}
    check(sorted(p.name for p in shared.iterdir()) == ['BarePlugin', 'IsiXLegacyBridge', 'LegacySample'],
          f'shared kit: {sorted(p.name for p in shared.iterdir())}')
    for module, shared_project in shared_projects.items():
        tag = f'shared kit, {module}: '
        check(not (shared_project / 'IsiXLegacyBridge').exists()
              and not [p for p in shared_project.rglob('*') if p.name in {k.name for k in (KIT / 'Sources').iterdir()}],
              tag + 'a copy of the kit in the project')
        shared_manifest = json.loads((shared_project / 'Config' / 'port.json').read_text())
        kit_paths = [s['path'] for s in shared_manifest['sources'] if not s['path'].startswith('Sources/')]
        check(shared_manifest.get('kit') == '../IsiXLegacyBridge' and kit_paths
              and all(p.startswith('../IsiXLegacyBridge/Sources/') and (shared_project / p).is_file() for p in kit_paths)
              and sorted(Path(p).name for p in kit_paths) == kit_sources, tag + f'manifest {shared_manifest.get("kit")} {kit_paths[:3]}')
        shared_xcconfig = (shared_project / 'Config' / f'{module}.xcconfig').read_text().splitlines()
        check('HEADER_SEARCH_PATHS = $(inherited) "$(PROJECT_DIR)/../IsiXLegacyBridge/Headers" '
              '"$(PROJECT_DIR)/../IsiXLegacyBridge/Include"' in shared_xcconfig, tag + 'header search')
        check('see ../IsiXLegacyBridge/README.md' in (shared_project / 'Porting' / 'REPORT.md').read_text(), tag + 'REPORT.md')
        shared_objects = converter.parse_openstep(
            (shared_project / f'{module}.xcodeproj' / 'project.pbxproj').read_text())['objects']
        kit_groups = [o for o in shared_objects.values() if o.get('isa') == 'PBXGroup' and 'IsiXLegacyBridge' in
                      (o.get('path', ''), o.get('name', ''))]
        main_group = next(o for o in shared_objects.values() if o.get('isa') == 'PBXProject')['mainGroup']
        check(len(kit_groups) == 1 and kit_groups[0]['path'] == '../IsiXLegacyBridge'
              and kit_groups[0]['name'] == 'IsiXLegacyBridge'
              and any(shared_objects[c] is kit_groups[0] for c in shared_objects[main_group]['children'])
              and not [o for o in shared_objects.values() if o.get('path') == '..'], tag + f'kit group {kit_groups}')
    shared_bundles = {}
    for module, shared_project in shared_projects.items():
        shared_warnings = {}
        try:
            shared_bundles[module] = builder.build_project(sdk, shared_project, work / 'shared-bundles', warnings=shared_warnings)
        except RuntimeError as error:
            failures.append(f'shared kit, {module} does not build: {error}')
            continue
        check(shared_warnings['kit'] == [] and shared_warnings['plugin'] == [], f'shared kit, {module} warnings {shared_warnings}')
    for module, shared_bundle in shared_bundles.items():
        classes = subprocess.run(['nm', '-gU', str(shared_bundle / 'Contents' / 'MacOS' / module)], capture_output=True,
                                 text=True).stdout
        check(f'_OBJC_CLASS_$_IsiXLegacy{module}_DCMPix' in classes
              and not [c for c in re.findall(r'_OBJC_CLASS_\$_(IsiXLegacy\w+?)_', classes) if c != f'IsiXLegacy{module}'],
              f'shared kit, {module}: the kit\'s classes are not its own: {classes[:400]}')

    sysroot = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    legacy = subprocess.run(['xcrun', 'clang', '-fsyntax-only', '-fno-objc-arc', '-target', 'arm64-apple-macos15.0',
                             '-isysroot', sysroot, '-DISIX_LEGACY_NAMESPACE=Legacy', '-I', str(KIT / 'Headers'),
                             '-include', str(SAMPLE / 'Sources' / 'Sample_Prefix.pch'), '-iquote', str(SAMPLE / 'Sources'),
                             str(SAMPLE / 'Sources' / 'SampleFilter.m')], capture_output=True, text=True)
    deprecated = len(re.findall(r'warning: .*deprecated', legacy.stderr))
    check(legacy.returncode == 0 and deprecated >= 20, f'the legacy sample has {deprecated} deprecation warnings')

    # With --xcodebuild, the project with its own copy of the kit and the one on the shared kit.
    for xcode_project, xcode in ((project, 'xcode'), (shared_projects['LegacySample'], 'xcode-shared')) if xcodebuild else ():
        log = work / f'{xcode}.log'
        with log.open('w') as output:
            built = subprocess.run(['xcodebuild', '-project', str(xcode_project / 'LegacySample.xcodeproj'), '-target',
                                    'LegacySample', '-configuration', 'Release', f'SYMROOT={work / xcode}',
                                    f'OBJROOT={work / (xcode + "-objects")}', f'ISIX_SDK_DIR={sdk}', 'ARCHS=arm64'],
                                   stdout=output, stderr=subprocess.STDOUT, timeout=900)
        text = log.read_text()
        check(built.returncode == 0, f'{xcode}: xcodebuild failed: '
              + '\n'.join(l for l in text.splitlines() if ' error: ' in l)[:3000])
        own = [l for l in text.splitlines() if ' warning: ' in l and (str(xcode_project) in l or 'IsiXLegacyBridge' in l)]
        check(not own, f'{xcode}: xcodebuild warnings {own}')
        product = work / xcode / 'Release' / 'LegacySample.isixplugin'
        if product.is_dir():
            check(plistlib.loads((product / 'Contents' / 'Info.plist').read_bytes())['NSPrincipalClass']
                  == 'LegacySample.IsiXLegacyPluginEntry', f'{xcode}: xcodebuild Info.plist')

    # The kit's replacements, run.
    probe = work / 'probe'
    probe.mkdir()
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-target', 'arm64-apple-macos15.0', '-DISIX_LEGACY_NAMESPACE=PortProbe',
                    '-Wall', '-Wextra', '-Wno-unused-parameter', '-I', str(KIT / 'Headers'), '-framework', 'Cocoa',
                    '-framework', 'UniformTypeIdentifiers', '-o', str(probe / 'probe'),
                    str(FIXTURES / 'PortSupportProbe.m'), str(KIT / 'Sources' / 'IsiXLegacyPortSupport.m'),
                    str(KIT / 'Sources' / 'IsiXLegacyCalendarDate.m')], check=True)
    subprocess.run(['xcrun', 'ibtool', '--compile', str(probe / 'Panel.nib'), str(SAMPLE / 'Resources' / 'Panel.xib')],
                   check=True)
    run = subprocess.run([str(probe / 'probe')], capture_output=True, text=True, timeout=60)
    try:
        result = json.loads(run.stdout)
    except ValueError:
        failures.append(f'probe exited {run.returncode}: {run.stderr[-2000:]}')
        result = {}
    if result:
        calendar = result['calendar']
        check(calendar['components'] == [2026, 10, 29, 13, 5, 9, 4, 302], f'components {calendar["components"]}')
        check(calendar['text'] == '2026-10-29 13:05:09 +0000|302|4|29|01 PM|26|Thu Oct|Thursday October|%|000',
              f'format {calendar["text"]}')
        check(calendar['description'] == '2026-10-29 13:05:09 +0000' and calendar['readEqual'] is True
              and calendar['unreadable'] == 1, f'description and reading {calendar}')
        check(calendar['later'] == '2026-12-02' and calendar['difference'] == [1, 3], f'arithmetic {calendar}')
        check(calendar['ofDate'] == '1970/01/01 00' and calendar['withDate'] == '29.10.2026', f'NSDate forms {calendar}')
        check(calendar['class'] == 'IsiXLegacyPortProbe_CalendarDate', f'runtime name {calendar["class"]}')
        check(result['alertPanels'] == [1, 0, -1, 1, 1], f'alert codes {result["alertPanels"]}')
        check(result['modalTexts'][:5] == [['Probe', '7 files']] * 3 + [['Alert', 'critical'], ['Probe', 'information']],
              f'alert texts {result["modalTexts"]}')
        check(result['messageText'] == {'answer': 0, 'text': 'x y', 'buttons': ['OK', 'No'], 'tags': [1, 0]},
              f'legacy NSAlert {result["messageText"]}')
        check(result['alertSheetWithoutWindow'] == [['_NSAlertPanel', 0, 3]]
              or (len(result['alertSheetWithoutWindow']) == 1 and result['alertSheetWithoutWindow'][0][1:] == [0, 3]),
              f'alert sheet without a window {result["alertSheetWithoutWindow"]}')
        check(result['appSheet'] == {'attached': True, 'calls': [['NSPanel', 7, 42]]}, f'sheet {result["appSheet"]}')
        check(result['alertSheet'] == {'attached': True, 'calls': [['NSAlert', 1001, 5]]}, f'alert sheet {result["alertSheet"]}')
        check(result['nib'] == {'loaded': True, 'window': 'Port probe', 'missing': False}, f'nib {result["nib"]}')
        check(result['panel'] == {'requiredType': ['public.plain-text'], 'anyType': [], 'filenames': ['/tmp/a', '/tmp/b'],
                                  'notAPanel': 1}, f'panels {result["panel"]}')

# ---------------------------------------------------------------- horosplugins
if collection:
    whole = converter.convert_collection(collection)
    check(whole['errors'] == [], f'the converter failed on {whole["errors"]}')
    check(len(whole['plugins']) >= 81, f'{len(whole["plugins"])} plugin folders')
    rotation = whole['plugins']['ROIRotation']
    check(sorted((r['rule'], r['line']) for r in rotation['rewrites'])
          == [('alert-panel', 107), ('alert-panel', 114), ('app-sheet', 27), ('nib-loading', 26)],
          f'ROIRotation rewrites {rotation["rewrites"]}')
    for name in PROOFS:
        plugin = whole['plugins'][name]
        check(plugin['legacyTarget'] and not [u for u in plugin['unconverted'] if u['category'] != 'build'],
              f'{name}: {plugin["unconverted"]}')
        check(any(c['setting'] == 'ARCHS' for c in plugin['projectChanges']), f'{name}: no architecture change')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('port-legacy-plugin: %d rewrite samples, the synthetic plugin converted, built and checked, the replacements run%s'
      % (len(REWRITES), ', horosplugins converted' if collection else ''))
