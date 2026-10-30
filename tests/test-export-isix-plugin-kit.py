#!/usr/bin/env python3
"""tools/export-isix-plugin-kit.py --framework exports Xcode's build of
IsiXPluginKit and refuses, with the reason, a copy it cannot export.

A plugin compiles against the kit's public .swiftinterface. Xcode writes it in
the framework it builds (build/Build/Products/<configuration>), but leaves the
Modules folder out when it embeds the framework in the application
(Contents/Frameworks), so the embedded copy has no interface and cannot be
an SDK. With a framework compiled by swiftc and laid out in those places,
the test checks that:

- the build product exports, with the configuration in SDK.json taken from
  its folder (Debug or Release), and only the public interface;
- the embedded copy, made as Xcode's embedding makes it (without Modules), is
  refused with a message that names the embedding and the framework to
  export instead;
- a framework built without an interface is refused with the build setting
  to change.

When this checkout has them, the same is checked on the real Debug build
product and on the framework embedded in the development application.
"""
from pathlib import Path
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools' / 'export-isix-plugin-kit.py'
NAME = 'IsiXPluginKit'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def export(framework, output):
    return subprocess.run([sys.executable, str(TOOL), '--framework', str(framework), '--output', str(output)],
                          capture_output=True, text=True, timeout=120)


def check_exports(framework, output, configuration, tag):
    result = export(framework, output)
    check(result.returncode == 0, f'{tag}: refused: {result.stderr[-1000:]}')
    if result.returncode != 0:
        return
    description = json.loads((output / 'SDK.json').read_text())
    check(description['configuration'] == configuration, f'{tag}: configuration {description["configuration"]}')
    module = output / f'{NAME}.framework' / 'Modules' / f'{NAME}.swiftmodule'
    names = sorted(p.name for p in module.iterdir())
    check(names and all(n.endswith(('.swiftinterface', '.swiftdoc')) and '.private.' not in n for n in names),
          f'{tag}: the SDK module holds {names}')


def check_embedded_refused(framework, output, tag):
    result = export(framework, output)
    check(result.returncode != 0, f'{tag}: the embedded copy was exported')
    message = result.stderr
    for part in ('copy embedded in', 'Xcode leaves Modules out', f'build/Build/Products/<configuration>/{NAME}.framework',
                 '--xcode Release'):
        check(part in message, f'{tag}: the refusal does not say {part!r}: {message.strip()}')


if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

spec = importlib.util.spec_from_file_location('exporter', TOOL)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

with tempfile.TemporaryDirectory(prefix='export-isix-plugin-kit-') as temporary:
    work = Path(temporary)
    built = exporter.compile_framework(work / 'compiled', ['arm64'])

    product = work / 'build' / 'Build' / 'Products' / 'Debug' / f'{NAME}.framework'
    shutil.copytree(built, product, symlinks=True)
    check_exports(product, work / 'sdk-debug', 'Debug', 'build product')

    # Xcode's embedding: builtin-copy -exclude Headers -exclude PrivateHeaders -exclude Modules.
    embedded = work / 'App.app' / 'Contents' / 'Frameworks' / f'{NAME}.framework'
    shutil.copytree(built, embedded, symlinks=True,
                    ignore=shutil.ignore_patterns('Headers', 'PrivateHeaders', 'Modules'))
    check(not (embedded / 'Versions' / 'A' / 'Modules').exists(), 'the simulated embedding kept Modules')
    check_embedded_refused(embedded, work / 'sdk-embedded', 'simulated embedding')
    check(not (work / 'sdk-embedded' / 'SDK.json').exists(), 'an SDK.json was written for the refused copy')

    without = work / 'without' / f'{NAME}.framework'
    shutil.copytree(built, without, symlinks=True)
    for interface in (without / 'Versions' / 'A' / 'Modules' / f'{NAME}.swiftmodule').glob('*.swiftinterface'):
        interface.unlink()
    result = export(without, work / 'sdk-without')
    check(result.returncode != 0 and 'BUILD_LIBRARY_FOR_DISTRIBUTION = YES' in result.stderr,
          f'a framework built without an interface: {result.returncode} {result.stderr.strip()}')

    real_product = ROOT / 'build' / 'Build' / 'Products' / 'Debug' / f'{NAME}.framework'
    real_embedded = ROOT / 'build' / 'Development' / 'HorosDevelopment.app' / 'Contents' / 'Frameworks' / f'{NAME}.framework'
    if real_product.is_dir():
        check_exports(real_product, work / 'sdk-real-debug', 'Debug', 'Debug build product')
    else:
        print(f'not checked: no {real_product.relative_to(ROOT)}')
    if real_embedded.is_dir():
        check_embedded_refused(real_embedded, work / 'sdk-real-embedded', 'development application')
    else:
        print(f'not checked: no {real_embedded.relative_to(ROOT)}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('the exporter exports the build product and refuses the embedded copy and a build without an interface')
