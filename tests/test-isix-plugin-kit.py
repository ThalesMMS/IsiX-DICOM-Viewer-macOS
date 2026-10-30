#!/usr/bin/env python3
"""The version 1 plugin path, end to end, without the application.

IsiXPluginKit is compiled with library evolution, as the Xcode target builds
it, and exported as the SDK a plugin sees: the public .swiftinterface and the
binary, without the host's private interface. The example plugin of
Examples/IsiXPluginExample is built against that SDK by
tools/build-isix-example-plugin.py, and so are misbehaving probe plugins and
bundles the loader must refuse. A host harness then runs the application's
loading path - IsiXPluginLoading's inspection, the bundle load, entry
resolution and the kit's runtime - with a synthetic viewer standing in for the
application's (tests/fixtures/isix-plugin-kit/HostHarness.swift), and this
test checks what it reports:

- metadata and diagnostics: missing, zero, string and future API versions,
  unknown capabilities, an embedded copy of the kit, a former plugin renamed
  to .isixplugin, and the wrong architecture are refused before any of their
  code is mapped;
- entry: the module-qualified Swift class resolves; an unqualified name, a
  class of another image and a class that does not adopt IsiXPlugin do not;
- lifecycle: activation registers commands and observations; a failing
  activation leaves nothing behind; deactivation cancels tasks and removes
  observations and commands, and nothing is delivered afterwards;
- the API: geometry, pixels copied and measured off the main actor, ROIs
  created and measured, a commit and the refusal of a stale one, events,
  capabilities enforced, a viewer handle and a snapshot used after the viewer
  closed; input handlers asked for their kinds only and taking events, an
  overlay drawing in the image's pixels in a graphics state of its own, both
  gone once their token is invalidated or the plugin deactivated;
- the same for x86_64 under Rosetta, when Rosetta is installed.
"""
from pathlib import Path
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-plugin-kit'
failures = []


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(condition, message):
    if not condition:
        failures.append(message)


def rosetta_available():
    return subprocess.run(['arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0


if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('builder', 'build-isix-example-plugin.py')


def build_refused(sdk, folder, arch, other_arch):
    """Bundles the loader must refuse, by file name."""
    bundles = []

    def example(name, **changes):
        bundles.append(builder.build(sdk, folder, arch, name=name, module='Refused' + name, **changes))

    example('NoVersion', info_changes={'IsiXPluginAPIVersion': None})
    example('ZeroVersion', info_changes={'IsiXPluginAPIVersion': 0})
    example('StringVersion', info_changes={'IsiXPluginAPIVersion': '1'})
    example('FutureVersion', info_changes={'IsiXPluginAPIVersion': 2})
    example('UnknownCapability', info_changes={'IsiXPluginCapabilities': ['viewer.read', 'network.dicom']})
    example('NoEntry', info_changes={'NSPrincipalClass': None})
    bundles.append(builder.build(sdk, folder, other_arch, name='OtherArchitecture', module='RefusedOtherArchitecture'))
    if arch == 'arm64':
        # macOS runs arm64 code only signed: refused before loading, with that reason.
        example('Unsigned')
        subprocess.run(['codesign', '--remove-signature', str(bundles[-1])], check=True)
    embedded = builder.build(sdk, folder, arch, name='EmbeddedKit', module='RefusedEmbeddedKit')
    shutil.copytree(sdk / 'IsiXPluginKit.framework', embedded / 'Contents/Frameworks/IsiXPluginKit.framework', symlinks=True)
    bundles.append(embedded)

    # A former plugin renamed to .isixplugin: former keys, a former SDK
    # linked, no API version, not linked against the kit.
    legacy_sdk = folder / 'legacy-sdk'
    horos = legacy_sdk / 'Horos.framework' / 'Versions' / 'A'
    horos.mkdir(parents=True)
    (folder / 'Horos.swift').write_text('public func horosLegacySymbol() -> Int { 1 }\n')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'Horos', '-emit-library',
                    '-target', f'{arch}-apple-macos15.0', '-Xlinker', '-install_name', '-Xlinker',
                    '@executable_path/../Frameworks/Horos.framework/Versions/A/Horos',
                    '-o', str(horos / 'Horos'), str(folder / 'Horos.swift')], check=True, cwd=folder)
    (legacy_sdk / 'Horos.framework' / 'Horos').symlink_to('Versions/A/Horos')
    (folder / 'Legacy.swift').write_text('import Foundation\n@objc(LegacyFilter) public final class LegacyFilter: NSObject {}\n')
    legacy = builder.build(sdk, folder, arch, name='LegacyRenamed', module='LegacyRenamed', link_kit=False,
                           sources=[folder / 'Legacy.swift'],
                           info_changes={'IsiXPluginAPIVersion': None, 'IsiXPluginCapabilities': None,
                                         'NSPrincipalClass': 'LegacyFilter', 'pluginType': 'imageFilter',
                                         'MenuTitles': ['Run']},
                           extra=['-F', str(legacy_sdk), '-Xlinker', '-needed_framework', '-Xlinker', 'Horos'])
    bundles.append(legacy)
    return bundles


def scenario(arch, work, host_kit, sdk):
    folder = work / arch
    folder.mkdir()
    other = 'x86_64' if arch == 'arm64' else 'arm64'
    example = builder.build(sdk, folder, arch)
    probe = builder.build(sdk, folder, arch, name='ProbePlugins', module='ProbePlugins',
                          sources=[FIXTURES / 'ProbePlugins.swift'],
                          info_changes={'CFBundleIdentifier': 'org.isix.plugin-probe',
                                        'NSPrincipalClass': 'ProbePlugins.ObserverPlugin',
                                        'IsiXPluginCapabilities': ['viewer.read', 'roi']})
    refused = build_refused(sdk, folder, arch, other)

    loading = folder / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', f'{arch}-apple-macos15.0'])
    harness = folder / 'HostHarness'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', f'{arch}-apple-macos15.0',
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading',
                    '-o', str(harness), str(FIXTURES / 'HostHarness.swift')], check=True)
    command = [str(harness), str(example), str(probe), *map(str, refused)]
    if arch == 'x86_64':
        command = ['arch', '-x86_64', *command]
    run = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if run.returncode != 0:
        failures.append(f'{arch}: harness exited {run.returncode}: {run.stderr[-2000:]}')
        return None
    return json.loads(run.stdout)


def verify(arch, report):
    tag = f'{arch}: '
    check(report['hostArchitecture'] == arch, tag + f'harness ran as {report["hostArchitecture"]}')
    example = report['example']
    check(example.get('state') == 'active', tag + f'example not active: {example}')
    check(example.get('commands') == ['inspect-image|imageFilters|viewer', 'mark-centre|roiTools|viewer',
                                      'negate-slice|imageFilters|viewer'], tag + f'commands {example.get("commands")}')
    check(example.get('observations') == 1, tag + 'the example observes once')
    check(example.get('commandChanges') == 3, tag + 'each registration tells the host to rebuild the menus')
    check(example.get('canRunWithoutViewer') is False and example.get('canRunWithViewer') is True,
          tag + 'a command that needs a viewer is disabled without one')
    # Refused by the runtime, as the menu disables it: the handler is not called.
    check(example.get('noViewerError') == 'viewerRequired("IsiX Example: Inspect Image")',
          tag + f'no viewer: {example.get("noViewerError")}')
    check(example.get('commandErrors') == [], tag + f'command errors {example.get("commandErrors")}')
    record = example.get('record', '')
    expected = [
        'activated org.isix.plugin-example 1.0',
        # Slice 2 of the synthetic series: 8 columns, 6 rows, spacing 0.5 mm
        # between rows and 0.75 between columns, oblique orientation; the centre
        # pixel (3.5, 2.5) maps to IPP + 3.5*0.75*row + 2.5*0.5*column.
        'image slice 2 phase 0 size 8x6 spacing 0.5000/0.7500 position -13.200,22.400,30.000 '
        'orientation 0.6000,0.8000,0.0000,0.0000,0.0000,-1.0000 centre -11.625,24.500,28.750',
        # Values 200 + 10*row + column: mean 228.5 over 48 pixels.
        'pixels 48 mean 228.5000 min 200.0000 max 257.0000',
        # Rectangle (2, 1.5)-(6, 4.5): rows 2-4, columns 2-6; 4 x 0.75 by 3 x 0.5 mm.
        ' mean 234.0000 min 222.0000 max 246.0000 area 4.5000 listed 2 point -11.625,24.500,28.750',
        'negated slice 2; second commit refused as stale',
        'slice 3',
        'roi added',
        'viewer closing',
        'deactivated',
    ]
    for line in expected:
        check(line in record, tag + f'the example did not report {line!r}:\n{record}')
    check(record.count('slice 1') == 0, tag + 'an event was delivered after deactivation')
    check(example.get('roisStored') == ['rectangle 2.0,1.5 6.0,4.5 IsiX Example', 'point 3.5,2.5 IsiX Example centre'],
          tag + f'ROIs {example.get("roisStored")}')
    check(example.get('negatedSlice') == [-200.0, -201.0, -202.0] and example.get('untouchedSlice') == [100.0, 101.0, 102.0],
          tag + 'the commit changed the wrong pixels')
    check(example.get('undeclaredWrite') == 'capabilityNotDeclared(viewer.write)',
          tag + f'undeclared write: {example.get("undeclaredWrite")}')
    check(example.get('afterClose') == ['viewerClosed'] * 3, tag + f'after close: {example.get("afterClose")}')
    check(example.get('snapshotAfterClose') == 48, tag + 'a snapshot is not readable after the viewer closed')
    check(example.get('isOpenAfterClose') is False and example.get('canRunAfterClose') is False,
          tag + 'the closed viewer still counts as open')
    check(example.get('afterDeactivate') == {'state': 'deactivated', 'commands': 0, 'observations': 0, 'tasks': 0},
          tag + f'after deactivation: {example.get("afterDeactivate")}')
    check(example.get('runAfterDeactivate') == 'pluginInactive', tag + 'a command ran after deactivation')

    probe = report['probe']
    throwing = probe['ProbePlugins.ThrowingPlugin']
    check(throwing.get('state', '').startswith('failed') and throwing.get('activationError') == 'the probe refused to activate',
          tag + f'throwing activation: {throwing}')
    check(throwing.get('commands') == [] and throwing.get('observations') == 0,
          tag + 'a failed activation left registrations behind')
    check(probe['ProbePlugins.NotAPlugin'].get('error') == 'entry: The entry class ProbePlugins.NotAPlugin does not adopt IsiXPlugin.',
          tag + f'not a plugin: {probe["ProbePlugins.NotAPlugin"]}')
    check(probe['NSObject'].get('error', '').startswith('entry: The entry class NSObject belongs to '),
          tag + f'a class of another image: {probe["NSObject"]}')
    check(probe['ThrowingPlugin'].get('error', '').startswith('entry: The entry class ThrowingPlugin was not found'),
          tag + 'an unqualified Swift class name resolved')
    check(probe['ProbePlugins.Missing'].get('error', '').startswith('entry: The entry class ProbePlugins.Missing was not found'),
          tag + 'a missing class resolved')
    observer = probe['observer']
    check(observer.get('observationsAfterDrop') == 1 and observer.get('observationsAfterInvalidate') == 0,
          tag + f'observation tokens: {observer}')
    check(observer.get('tasksBeforeDeactivate') == 1 and observer.get('tasksAfterDeactivate') == 0,
          tag + 'deactivation did not cancel the task')
    check(observer.get('record', '').startswith(
              'dropped 1 kept 2 cancelled true offMain true deactivated true errors capabilityNotDeclared(database.read),'
              'commandAlreadyRegistered("invalidate")'),
          tag + f'observer: {observer.get("record")}')
    # Input: only the kinds asked for, taken when the handler says so, none
    # once the token is invalidated or the plugin deactivated. Drawing: in the
    # image's pixels, in a graphics state of its own, until the token goes.
    interaction = probe['interaction']
    check(interaction.get('inputKinds') == 9 and interaction.get('taken') == [True, False, False, True, False],
          tag + f'input: {interaction}')
    check(interaction.get('overlaysBefore') is False and interaction.get('overlaysAfter') is True
          and interaction.get('redrawsForOverlay') == 1, tag + f'overlay: {interaction}')
    check(interaction.get('greenPixels') == ['1,2'] and interaction.get('bluePixels') == ['7,5'],
          tag + f'overlay drawing: {interaction.get("greenPixels")} {interaction.get("bluePixels")}')
    check(interaction.get('inputKindsAfterDrop') == 0 and interaction.get('overlaysAfterDrop') is False
          and interaction.get('takenAfterDrop') is False and interaction.get('overlaysAfterDeactivate') is False
          and interaction.get('takenAfterDeactivate') is False, tag + f'after drop and deactivation: {interaction}')
    # The overlay command ran twice; this host cannot show another phase.
    phase = 'phase hostFailure("This application cannot show another phase for a plugin.")'
    check(interaction.get('record') == 'seen mouseDown 1,3 slice 2,mouseDown 6,3 slice 2,keyDown 0,3 slice 2x,keyDown 0,3 slice 2y '
          f'drawn slice 2 point 0.5 errors {phase},{phase}', tag + f'interaction: {interaction.get("record")}')

    refused = report['refused']
    expected_refusals = {
        'NoVersion.isixplugin': ['missingAPIVersion'],
        'ZeroVersion.isixplugin': ['unsupportedAPIVersion(0)'],
        'StringVersion.isixplugin': ['invalidAPIVersion(found: "1")'],
        'FutureVersion.isixplugin': ['futureAPIVersion(2, newestSupported: 1)'],
        'UnknownCapability.isixplugin': ['unknownCapabilities(["network.dicom"])'],
        'NoEntry.isixplugin': ['missingPrincipalClass'],
        'OtherArchitecture.isixplugin': [f'architectureMismatch(found: ["{"x86_64" if arch == "arm64" else "arm64"}"], required: "{arch}")'],
        'EmbeddedKit.isixplugin': ['embedsKitCopy'],
        'LegacyRenamed.isixplugin': ['legacyMetadata(keys: ["pluginType", "MenuTitles"])', 'missingAPIVersion',
                                     'legacyDependency(frameworks: ["Horos.framework"])', 'kitNotLinked'],
    }
    if arch == 'arm64':
        expected_refusals['Unsigned.isixplugin'] = ['unsignedExecutable(architecture: "arm64")']
    for name, diagnostics in expected_refusals.items():
        outcome = refused.get(name, {})
        check(outcome.get('diagnostics') == diagnostics, tag + f'{name}: {outcome.get("diagnostics")}')
        check(outcome.get('mapped') is False and outcome.get('loaded') is False, tag + f'{name} was loaded')
    check(refused['LegacyRenamed.isixplugin'].get('renamedLegacy') is True, tag + 'the renamed former plugin was not named as such')


with tempfile.TemporaryDirectory(prefix='isix-plugin-kit-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64', 'x86_64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    module = sdk / 'IsiXPluginKit.framework' / 'Modules' / 'IsiXPluginKit.swiftmodule'
    shipped = sorted(p.name for p in module.iterdir())
    check(shipped == ['arm64-apple-macos.swiftdoc', 'arm64-apple-macos.swiftinterface',
                      'x86_64-apple-macos.swiftdoc', 'x86_64-apple-macos.swiftinterface'],
          f'the SDK ships host-only files: {shipped}')
    check(all('IsiXHost' not in (module / name).read_text() for name in shipped if name.endswith('.swiftinterface')),
          'the public interface exposes the host SPI')
    description = json.loads((sdk / 'SDK.json').read_text())
    check(description['apiVersion'] == 1 and sorted(description['architectures']) == ['arm64', 'x86_64'],
          f'SDK.json: {description}')
    check(description.get('binarySHA256') == exporter.sha256(sdk / 'IsiXPluginKit.framework' / 'IsiXPluginKit')
          and len(description['binarySHA256']) == 64, f'SDK.json binary checksum: {description.get("binarySHA256")}')
    check(description.get('interfaceSHA256') == {name: exporter.sha256(module / name) for name in shipped
                                                 if name.endswith('.swiftinterface')},
          f'SDK.json interface checksums: {description.get("interfaceSHA256")}')

    architectures = ['arm64'] + (['x86_64'] if rosetta_available() else [])
    for arch in architectures:
        report = scenario(arch, work, host_kit, sdk)
        if report is not None:
            verify(arch, report)
    if 'x86_64' not in architectures:
        print('x86_64 not exercised: Rosetta is not installed')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'IsiXPluginKit v1 plugin path checked for {", ".join(architectures)}')
