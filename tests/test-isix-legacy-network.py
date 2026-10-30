#!/usr/bin/env python3
"""IsiXLegacyBridge, network and integration part: legacy Horos/OsiriX plugins
that send, query, answer XML-RPC or listen to the application's notifications,
built from their original source as plugins of the IsiX plugin API 1, without
the application and without any network.

    python3 tests/test-isix-legacy-network.py HOROSPLUGINS_DIR

HOROSPLUGINS_DIR is a checkout of horosproject/horosplugins; it is external
input and not part of this repository. Without it the test exits with 2.

The test exports the SDK a plugin sees and builds with
tools/build-isix-legacy-plugin.py:

- Exec: a command run on each image of the database selection, and, set to
  run automatically (its Info.plist key Autoexec, which the plugin reads; its
  own plists name it Autoexecute), on each image an import adds, through
  OsirixAddToDBNotification. The command is set to write its arguments to a
  file of the test;
- XploreReports: the report address of each study an import completes,
  through OsirixAddToDBCompleteNotification and key-value coding (its menu
  command, which opens an intranet address, is never run);
- SSH: built and loaded (its window and its tunnels are the in-app check's);
- the test's own probe (tests/fixtures/isix-legacy-bridge/NetworkProbe), with
  manual reference counting and with ARC: the nodes of Locations, a send with
  DCMTKStoreSCU and with SendController, studies and series with the query
  nodes, XML-RPC values, the XML-RPC method ProbeEcho, the legacy
  notifications, and a send to an address no user configured, refused.

Through tests/fixtures/isix-legacy-bridge/LegacyNetworkHarness.swift (the
application's loading path, a synthetic network that applies the
application's rules from IsiXDICOMNetwork, a synthetic database and viewer)
it checks what each plugin did, that the application's own notifications,
posted under the names the application uses, never reach a plugin, and that
no send or query reaches an address outside the configured nodes.
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module, dependencies  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-legacy-bridge'
PROOFS = ['Exec', 'XploreReports', 'SSH']
ALLOWED_LIBRARY = re.compile(r'^(@rpath/IsiXPluginKit\.framework/Versions/A/IsiXPluginKit'
                             r'|/usr/lib/(libSystem\.B|libobjc\.A|libc\+\+\.1|swift/libswift\w+)\.dylib'
                             r'|/System/Library/Frameworks/\w+\.framework/Versions/\w+/\w+)$')
BASE = ['viewer.read', 'viewer.write', 'roi']
EXPECTED_CAPABILITIES = {
    'Exec': BASE + ['database.read'],
    'XploreReports': BASE + ['database.read', 'database.write'],
    'SSH': BASE + ['database.read'],
    'NetworkProbeMRC': BASE + ['database.read', 'network.send', 'network.query', 'xmlrpc'],
    'NetworkProbeARC': BASE + ['database.read', 'network.send', 'network.query', 'xmlrpc'],
}
STUDY = '1.2.826.0.1.3680043.9.1546.1'
NODE = 'LOCALPACS@127.0.0.1:11112'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if len(sys.argv) < 2 or not all((Path(sys.argv[1]) / p).is_dir() for p in PROOFS):
    sys.stderr.write('SKIP: needs a horosplugins checkout as argument (HOROSPLUGINS_DIR)\n')
    sys.exit(2)
if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
collection = Path(sys.argv[1])
headers = ROOT / 'IsiXLegacyBridge' / 'Headers'
for name in ('SendController', 'DCMTKStoreSCU', 'DCMNetServiceDelegate', 'N2XMLRPC', 'DCMTKServiceClassUser'):
    check(f'@compatibility_alias {name} IsiXLegacy{name};' in (headers / f'{name}.h').read_text(), f'{name}.h does not give the legacy name')
for name in ('DCMTKQueryNode', 'DCMTKRootQueryNode', 'DCMTKStudyQueryNode', 'DCMTKSeriesQueryNode'):
    check(f'@compatibility_alias {name} IsiXLegacy{name};' in (headers / 'DCMTKQueryNode.h').read_text(), f'{name} has no legacy name')
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')

with tempfile.TemporaryDirectory(prefix='isix-legacy-network-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    plugins = work / 'plugins'
    plugins.mkdir()
    bundles = {}
    for folder in PROOFS:
        warnings = {}
        try:
            bundles[folder] = builder.build(sdk, collection / folder, plugins, folder, warnings=warnings)
        except RuntimeError as error:
            failures.append(f'{folder} does not build: {error}')
            continue
        check(not warnings['kit'], f'{folder}: the kit has warnings: {warnings["kit"]}')
        missing = [w for w in warnings['plugin'] if 'not found' in w or 'may not respond' in w]
        check(not missing, f'{folder}: calls the kit does not cover: {missing}')
    for module, arc in (('NetworkProbeMRC', False), ('NetworkProbeARC', True)):
        warnings = {}
        bundles[module] = builder.build(sdk, FIXTURES / 'NetworkProbe', plugins, module, arc=arc, warnings=warnings)
        check(not warnings['kit'] and not warnings['plugin'], f'{module}: warnings {warnings}')
    for name, bundle in bundles.items():
        info = plistlib.loads((bundle / 'Contents' / 'Info.plist').read_bytes())
        check(info.get('IsiXPluginCapabilities') == EXPECTED_CAPABILITIES[name], f'{name}: capabilities {info.get("IsiXPluginCapabilities")}')
        binary = bundle / 'Contents' / 'MacOS' / bundle.stem
        libraries = [line.split(' (compatibility')[0].strip() for line in
                     subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True, check=True).stdout.splitlines()[1:]]
        bad = [library for library in libraries if not ALLOWED_LIBRARY.match(library)]
        check(not bad, f'{bundle.name}: links {bad}')
    for module in ('NetworkProbeMRC', 'NetworkProbeARC'):
        info = plistlib.loads((bundles[module] / 'Contents' / 'Info.plist').read_bytes())
        # The converter lists the method names the source compared the call's name with.
        check(info.get('IsiXLegacyXMLRPCMethods') == ['ProbeEcho', 'DisplayStudy'], f'{module}: XML-RPC methods {info.get("IsiXLegacyXMLRPCMethods")}')

    scratch = work / 'scratch'
    scratch.mkdir()
    if 'Exec' in bundles:
        # Exec set to run on what an import adds, with a command that writes its arguments.
        info_path = bundles['Exec'] / 'Contents' / 'Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['Autoexec'] = True
        info['Command'] = ['/bin/sh', '-c', 'echo "$@" >> "%s"' % (scratch / 'exec.txt'), 'exec',
                           '%DicomFilePath%', '%0010,0010%', '%PatientsBirthDate%']
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', str(bundles['Exec'])], check=True, capture_output=True)

    modules = work / 'modules'
    target = ['-target', 'arm64-apple-macos15.0']
    for name in ('IsiXPluginLoading', 'IsiXDICOMNetwork'):
        build_module(name, modules, extra=target)
    harness = work / 'LegacyNetworkHarness'
    libraries = ['-lIsiXPluginLoading', '-lIsiXDICOMNetwork', *(f'-l{each}' for each in dependencies('IsiXDICOMNetwork'))]
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target,
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(modules), '-L', str(modules), *libraries,
                    '-o', str(harness), str(FIXTURES / 'LegacyNetworkHarness.swift')], check=True)
    probe_output = work / 'probe'
    environment = dict(os.environ, ISIX_LEGACY_PROBE_OUTPUT=str(probe_output), NSZombieEnabled='YES')
    order = [bundles[n] for n in ('NetworkProbeMRC', 'NetworkProbeARC', 'Exec', 'XploreReports', 'SSH') if n in bundles]
    run = subprocess.run([str(harness), str(scratch), *map(str, order)], capture_output=True, text=True, timeout=120, env=environment)
    if run.returncode != 0:
        failures.append(f'harness exited {run.returncode}: {run.stderr[-3000:]}')
        report = {}
    else:
        report = json.loads(run.stdout)
        if os.environ.get('ISIX_LEGACY_NETWORK_REPORT'):
            Path(os.environ['ISIX_LEGACY_NETWORK_REPORT']).write_text(run.stdout)
    check('deallocated instance' not in run.stderr, 'a zombie was messaged: ' + run.stderr[-2000:])

    def probe(kind, arc):
        path = Path(f'{probe_output}-network-{kind}-{arc}.plist')
        return plistlib.loads(path.read_bytes()) if path.is_file() else None

    if report:
        plugins = report['plugins']
        check(report['unprefixedLegacyClasses'] == [], f'legacy names in the runtime: {report["unprefixedLegacyClasses"]}')
        for name, outcome in plugins.items():
            check(outcome.get('state') == 'active', f'{name}: {outcome.get("state")} {outcome.get("activationError")} {outcome.get("diagnostics")}')
        network = report['network']
        # Every send and query went to the configured node, and nothing else reached the network.
        check(network.count(f'send:{NODE}:files=2:sops=0') == 2, f'DCMTKStoreSCU sends: {network}')
        check(network.count(f'send:{NODE}:files=0:sops=2') == 2, f'SendController sends: {network}')
        check(network.count(f'find:{NODE}:study:QueryRetrieveLevel=STUDY,PatientName=*') == 2, f'study queries: {network}')
        check(network.count(f'find:{NODE}:series:QueryRetrieveLevel=SERIES,StudyInstanceUID={STUDY}') == 2, f'series queries: {network}')
        check(all(NODE in entry for entry in network), f'a send or query left the configured nodes: {network}')

        # XML-RPC: the first probe answers ProbeEcho; the second cannot take the
        # same name; neither takes a method of the application.
        check(plugins['NetworkProbeMRC'].get('xmlRPCMethods') == ['ProbeEcho'], f'MRC methods {plugins["NetworkProbeMRC"].get("xmlRPCMethods")}')
        check(plugins['NetworkProbeARC'].get('xmlRPCMethods') == [], f'ARC methods {plugins["NetworkProbeARC"].get("xmlRPCMethods")}')
        echo = plugins['NetworkProbeMRC'].get('xmlrpcEcho', '')
        check('"echo"' in echo and 'hello' in echo and '"hadDocument": IsiXPluginKit.IsiXXMLRPCValue.bool(true)' in echo, f'ProbeEcho answered {echo}')
        check(plugins['NetworkProbeARC'].get('xmlrpcEcho') == 'nil', f'ARC ProbeEcho {plugins["NetworkProbeARC"].get("xmlrpcEcho")}')

        exec_lines = plugins.get('Exec', {}).get('lines', [])
        image_files = sorted(str(scratch / f'image-{i}.dcm') for i in range(2))
        check(plugins.get('Exec', {}).get('runError') == '', f'Exec: {plugins.get("Exec", {}).get("runError")}')
        # Twice per image: its command on the selection, and on the images the import added.
        check(exec_lines == sorted(f'{f} NET^PROBE 19700101' for f in image_files * 2), f'Exec ran {exec_lines}')
        check(plugins.get('XploreReports', {}).get('report') == 'http://172.16.1.13/xploreintranet/Patients/PatientExamens.asp?PatientID=NET-1',
              f'XploreReports report {plugins.get("XploreReports", {}).get("report")}')
        check(plugins.get('XploreReports', {}).get('commands') == ['Xplore Reports|other|none'], f'XploreReports commands')
        check(plugins.get('SSH', {}).get('commands') == ['SSH|database|none'], f'SSH commands {plugins.get("SSH", {}).get("commands")}')

        for arc, module in ((0, 'NetworkProbeMRC'), (1, 'NetworkProbeARC')):
            tag = f'{module}: '
            outcome = plugins[module]
            check(outcome.get('runError') == '', tag + f'run {outcome.get("runError")}')
            check('is not a DICOM node configured in Locations' in outcome.get('unconfiguredError', ''),
                  tag + f'unconfigured node: {outcome.get("unconfiguredError")}')
            main = probe('main', arc) or {}
            check(main.get('nodes') == ['LOCALPACS', 'SENDONLY'] and main.get('sendNodes') == ['LOCALPACS', 'SENDONLY']
                  and main.get('queryNodes') == ['LOCALPACS'], tag + f'nodes {main}')
            check(main.get('selectedImages') == 2 and main.get('storeOutcome') == 'sent', tag + f'send {main}')
            check(main.get('studyQuerySucceeded') is True and main.get('studies') == [f'NET^PROBE|{STUDY}|OT|20261029'], tag + f'studies {main}')
            check(main.get('series') == [f'{STUDY}.1|OT|Network series|2'], tag + f'series {main.get("series")}')
            check(main.get('xmlrpcRoundTrip') is True, tag + 'XML-RPC values')
            refusal = probe('refusal', arc) or {}
            check(refusal.get('exception') == 'DICOM Network Failure (STORE-SCU)'
                  and 'is not a DICOM node configured' in refusal.get('reason', ''), tag + f'refusal {refusal}')
            seen = (probe('seen', arc) or {}).get('seen', [])
            # Once each, from the kit, with the kit's objects; the viewers'
            # notifications are tests/test-isix-legacy-viewer-events.py's.
            expected = [f'OsirixAddToDBNotification:2:DicomImage:{STUDY}:MODALITY', f'OsirixAddToDBCompleteNotification:2:DicomImage:{STUDY}:MODALITY',
                        'literal:ROI']
            if arc == 0:
                expected.append('XMLRPC:ProbeEcho')
            check(sorted(seen) == sorted(expected), tag + f'notifications {seen}')
            # The application's own notifications never reach the plugin.
            check(not any('ApplicationObject' in entry for entry in seen), tag + f'an object of the application arrived: {seen}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'IsiXLegacyBridge network: {", ".join(PROOFS)} and the probe (MRC, ARC) built from source and checked')
