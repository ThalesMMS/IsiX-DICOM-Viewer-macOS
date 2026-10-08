#!/usr/bin/env python3
"""Combine two App Store archives without changing their source artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile


MACHO = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def macho(path):
    with path.open('rb') as stream:
        return stream.read(4) in MACHO


def entries(root):
    return {p.relative_to(root): p for p in root.rglob('*')
            if not p.is_dir() and '_CodeSignature' not in p.parts}


def merge_tree(arm, intel, output):
    left, right = entries(arm), entries(intel)
    for relative in sorted(left.keys() | right.keys()):
        a, b = left.get(relative), right.get(relative)
        target = output / relative
        if a is None or b is None:
            present = a or b
            # Swift emits architecture-named modules; both sets belong in the archive.
            module = '.swiftmodule' in relative.parts[-2] and present.name.startswith(('arm64', 'x86_64'))
            relocation = 'Relocations' in relative.parts and any(p.endswith('.dSYM') for p in relative.parts)
            if module or relocation:
                if a is None:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(b, target)
                continue
            raise ValueError(f'Archive file exists on only one architecture: {relative}')
        if a.is_symlink() or b.is_symlink():
            if not (a.is_symlink() and b.is_symlink() and os.readlink(a) == os.readlink(b)):
                raise ValueError(f'Archive symlinks differ: {relative}')
            continue
        if macho(a):
            for arch, source in [('arm64', a), ('x86_64', b)]:
                found = subprocess.check_output(['lipo', '-archs', str(source)], text=True).split()
                if found != [arch]:
                    raise ValueError(f'{relative}: expected {arch}, found {found}')
            subprocess.run(['lipo', '-create', str(a), str(b), '-output', str(target)], check=True)
        elif a.read_bytes() != b.read_bytes():
            if relative.name == 'embedded.provisionprofile':
                continue
            if relative.name.endswith('-Swift.h') and relative.parent.name == 'Headers':
                guard = '#elif (defined(__arm64__) && __arm64__) || (defined(__x86_64__) && __x86_64__)'
                texts = [source.read_text().replace('#elif defined(__' + arch + '__) && __' + arch + '__', guard)
                         for arch, source in [('arm64', a), ('x86_64', b)]]
                if texts[0] == texts[1] and guard in texts[0]:
                    target.write_text(texts[0])
                    continue
            if relative.suffix == '.zip':
                with zipfile.ZipFile(a) as arm_zip, zipfile.ZipFile(b) as intel_zip:
                    records = lambda z: [(p.filename, p.external_attr, p.create_system, p.compress_type)
                                         for p in z.infolist()]
                    equal_payloads = all(arm_zip.read(x) == intel_zip.read(y)
                                         for x, y in zip(arm_zip.infolist(), intel_zip.infolist()))
                    if records(arm_zip) == records(intel_zip) and equal_payloads:
                        continue
            if 'ExternalLibraries' in relative.parts or 'CompiledSources' in relative.parts:
                # Keep each original provenance record, including architecture-specific hashes.
                for arch, source in [('arm64', a), ('x86_64', b)]:
                    record = target.parent / arch / target.name
                    record.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, record)
                if relative.name == 'embedded-libraries.txt':
                    target.write_text(a.read_text() + '\n' + b.read_text())
                continue
            raise ValueError(f'Architecture-independent resource differs: {relative}')


def merge(arm, intel, output):
    if output.exists():
        raise ValueError(f'Refusing to replace an existing archive: {output}')
    infos = [plistlib.loads((p / 'Info.plist').read_bytes()) for p in (arm, intel)]
    props = [v['ApplicationProperties'] for v in infos]
    for key in ('ApplicationPath', 'CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'Team'):
        if props[0].get(key) != props[1].get(key):
            raise ValueError(f'Archive metadata differs: {key}')
    shutil.copytree(arm, output, symlinks=True)
    merge_tree(arm / 'Products', intel / 'Products', output / 'Products')
    if (arm / 'dSYMs').exists() or (intel / 'dSYMs').exists():
        merge_tree(arm / 'dSYMs', intel / 'dSYMs', output / 'dSYMs')
    app_path = Path('Products') / props[0]['ApplicationPath']
    # The installed Info.plist must be readable when macOS verifies the app as a non-root user.
    (output / app_path / 'Contents/Info.plist').chmod(0o644)
    manifest = Path('Contents/Resources/ExternalLibraries/embedded-identities.json')
    if (arm / app_path / manifest).exists():
        originals = [json.loads((p / app_path / manifest).read_text())['libraries'] for p in (arm, intel)]
        if originals[0].keys() != originals[1].keys():
            raise ValueError('Embedded library manifests list different libraries')
        libraries = {}
        for name in originals[0]:
            binary = output / app_path / 'Contents/Frameworks' / name
            libraries[name] = {
                'embeddedSha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'architectures': dict(zip(('arm64', 'x86_64'), (v[name] for v in originals))),
            }
        (output / app_path / manifest).write_text(json.dumps({'format': 2, 'libraries': libraries}, indent=2) + '\n')
    infos[0]['ApplicationProperties']['Architectures'] = ['arm64', 'x86_64']
    (output / 'Info.plist').write_bytes(plistlib.dumps(infos[0]))
    print(f'Universal 2 archive prepared: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('arm64', type=Path)
    parser.add_argument('x86_64', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    merge(args.arm64, args.x86_64, args.output)
