#!/usr/bin/env python3
"""tools/build-isix-legacy-plugin.py: a xib that ibtool does not compile fails
the build, and every nib the project expects is in the bundle.

    python3 tests/test-legacy-plugin-nib-build.py

ibtool reports its errors in its output and does not always exit with an
error code; a bundle built without its nib loads and then fails when the
plugin opens its window. On tests/fixtures/port-legacy-plugin/LegacySample,
converted by tools/port-legacy-plugin.py and built for arm64:

- converted and built through the command lines with relative --output,
  --project and --sdk, run from another folder: the bundle has Panel.nib;
- the converter's rewrite of a xib's system: a legacy xib set to build for
  macOS 10.5, which ibtool refuses before 10.6 (the IB 3 archive's target and
  plugin dependency, the document format's deployment), builds for the
  plugin's system; a later system and the other values are left alone; the
  sample with its xib set to 10.5 converts and builds;
- a broken xib (malformed XML), and a xib set to 10.5 that the converter did
  not rewrite: the build fails, names the xib and ibtool's message, leaves no
  bundle, and the command line exits with an error;
- an ibtool that exits with 0 and reports an error in its XML, and one that
  exits with 0, reports nothing and writes no nib (stand-ins for ibtool): the
  build fails and leaves no bundle.

Exits with 2 without the Xcode command line tools.
"""
from pathlib import Path
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / 'tests' / 'fixtures' / 'port-legacy-plugin' / 'LegacySample'
BUILDER = ROOT / 'tools' / 'build-isix-legacy-plugin.py'
CONVERTER = ROOT / 'tools' / 'port-legacy-plugin.py'
OLD_DEPLOYMENT = '<deployment version="1050" identifier="macosx"/>'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def with_old_deployment(xib):
    text = xib.read_text()
    xib.write_text(text.replace('<dependencies>', '<dependencies>\n        ' + OLD_DEPLOYMENT, 1))


def build_fails(label, project, needle):
    """The project's build raises RuntimeError naming Panel.xib and `needle`, and leaves no bundle."""
    output = project.parent / 'bundles'
    try:
        builder.build_project(sdk, project, output)
        failures.append(f'{label}: the build did not fail')
    except RuntimeError as error:
        text = str(error)
        check('Panel.xib' in text and needle in text, f'{label}: the error does not say why: {text}')
    check(not (output / 'LegacySample.isixplugin').exists(), f'{label}: a bundle was left')


if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')
converter = builder.converter

# The rewrite of a xib's system, on text.
archive = ('<int key="IBDocument.SystemTarget">1050</int>\n'
           '<object class="NSMutableDictionary" key="IBDocument.PluginDeclaredDependencies">\n'
           '\t<string key="NS.key.0">com.apple.InterfaceBuilder.CocoaPlugin.macosx</string>\n'
           '\t<integer value="1060" key="NS.object.0"/>\n</object>\n'
           '<object class="NSMutableDictionary" key="IBDocument.PluginDeclaredDevelopmentDependencies">\n'
           '\t<string key="NS.key.0">com.apple.InterfaceBuilder.CocoaPlugin.InterfaceBuilder3</string>\n'
           '\t<integer value="3000" key="NS.object.0"/>\n</object>\n')
new, changes = converter.rewrite_xib(archive)
check(new == archive.replace('>1050<', '>150000<').replace('"1060"', '"150000"'), f'archive rewrite:\n{new}')
check([(c['rule'], c['category'], c['line']) for c in changes]
      == [('xib-system', 'legacy-sdk/arch', 1), ('xib-system', 'legacy-sdk/arch', 4)], f'archive changes {changes}')
document = f'<dependencies>\n    {OLD_DEPLOYMENT}\n    <deployment defaultVersion="1070" identifier="macosx"/>\n'
new, changes = converter.rewrite_xib(document)
check(new == document.replace(' version="1050"', ''), f'document rewrite:\n{new}')
check([(c['line'], c['before'], c['after']) for c in changes]
      == [(2, OLD_DEPLOYMENT, '<deployment identifier="macosx"/>')], f'document changes {changes}')
later = ('<int key="IBDocument.SystemTarget">260000</int>\n<deployment version="150000" identifier="macosx"/>\n'
         '<deployment version="1050" identifier="iphoneos"/>\n')
check(converter.rewrite_xib(later) == (later, []), 'a later system or another platform is left alone')

with tempfile.TemporaryDirectory(prefix='isix-legacy-nib-') as temporary:
    work = Path(temporary)
    host = work / 'host'
    exporter.compile_framework(host, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host / 'IsiXPluginKit.framework', sdk, 'swiftc')
    elsewhere = work / 'elsewhere'
    elsewhere.mkdir()

    # Relative paths through the command lines, from another folder.
    shutil.copytree(SAMPLE, work / 'LegacySample')
    converted = subprocess.run([sys.executable, str(CONVERTER), '--source', '../LegacySample', '--output', '../projects'],
                               cwd=elsewhere, capture_output=True, text=True, timeout=300)
    check(converted.returncode == 0, f'relative conversion: {converted.stderr[-2000:]}')
    built = subprocess.run([sys.executable, str(BUILDER), '--sdk', '../sdk', '--project', '../projects/LegacySample',
                            '--output', '../relative'], cwd=elsewhere, capture_output=True, text=True, timeout=600)
    bundle = work / 'relative' / 'LegacySample.isixplugin'
    check(built.returncode == 0 and Path(built.stdout.strip()) == bundle.resolve(),
          f'relative build: {built.returncode} {built.stdout} {built.stderr[-2000:]}')
    check((bundle / 'Contents' / 'Resources' / 'Panel.nib').exists(), 'relative build: no Panel.nib in the bundle')

    # A xib set to build for 10.5: converted, it builds; as it was, it fails.
    old = work / 'old' / 'LegacySample'
    shutil.copytree(SAMPLE, old)
    with_old_deployment(old / 'Resources' / 'Panel.xib')
    report = converter.convert(old, work / 'old-project')
    project = Path(report['project'])
    check([(r['file'], r['rule']) for r in report['rewrites'] if r['rule'] == 'xib-system']
          == [('Sources/Resources/Panel.xib', 'xib-system')], f'the old xib is rewritten: {report["rewrites"]}')
    check(OLD_DEPLOYMENT in (project / 'Porting' / 'original' / 'Resources' / 'Panel.xib').read_text()
          and OLD_DEPLOYMENT not in (project / 'Sources' / 'Resources' / 'Panel.xib').read_text(),
          'the original xib is kept in Porting/original')
    warnings = {}
    try:
        bundle = builder.build_project(sdk, project, work / 'old-bundles', warnings=warnings)
        check((bundle / 'Contents' / 'Resources' / 'Panel.nib').exists(), 'old xib: no Panel.nib')
        check(warnings.get('nib') == [], f'old xib: ibtool warnings {warnings.get("nib")}')
    except RuntimeError as error:
        failures.append(f'the converted old xib does not build: {error}')
    with_old_deployment(project / 'Sources' / 'Resources' / 'Panel.xib')
    build_fails('xib set to 10.5, not rewritten', project, 'earlier than macOS 10.6')

    # A broken xib.
    broken = work / 'broken'
    shutil.copytree(work / 'projects' / 'LegacySample', broken / 'LegacySample')
    project = broken / 'LegacySample'
    (project / 'Sources' / 'Resources' / 'Panel.xib').write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<document type="com.apple.InterfaceBuilder3.Cocoa.XIB" version="3.0">'
        '<objects><customObject id="-2"')
    build_fails('broken xib', project, 'error:')
    command = subprocess.run([sys.executable, str(BUILDER), '--sdk', str(sdk), '--project', str(project),
                              '--output', str(broken / 'cli')], capture_output=True, text=True, timeout=600)
    check(command.returncode != 0 and 'Panel.xib' in command.stderr, f'broken xib, command line: {command.returncode}')
    check(not (broken / 'cli' / 'LegacySample.isixplugin').exists(), 'broken xib, command line: a bundle was left')

    # ibtool exiting with 0: an error in its report, or no report and no nib.
    project = work / 'projects' / 'LegacySample'
    stand_in = work / 'ibtool'
    report_error = ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                    '<key>com.apple.ibtool.errors</key><array><dict><key>description</key>'
                    '<string>Interface Builder could not open the document because it does not exist.</string>'
                    '</dict></array></dict></plist>')
    empty = ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
             '<key>com.apple.ibtool.document.errors</key><dict/></dict></plist>')
    for label, plist, needle in (('error with exit 0', report_error, 'does not exist'), ('no nib', empty, 'wrote no')):
        stand_in.write_text(f"#!/bin/sh\ncat <<'EOF'\n{plist}\nEOF\nexit 0\n")
        os.chmod(stand_in, 0o755)
        builder.IBTOOL = [str(stand_in)]
        try:
            build_fails(label, project, needle)
        finally:
            builder.IBTOOL = ['xcrun', 'ibtool']

if failures:
    print('FAIL:\n' + '\n'.join(failures))
    sys.exit(1)
print('PASS: a xib ibtool does not compile fails the build without a bundle; relative paths build; '
      'legacy xibs are set to the plugin\'s system')
