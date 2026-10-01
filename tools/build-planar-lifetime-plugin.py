#!/usr/bin/env python3
"""Build a synthetic native plugin against the built public Horos framework.

The output is local; this command never installs into the user's plugin folder.
Pass --proof-directory inside local-validation. A preexisting event file makes
the plugin refuse to arm, preserving old evidence across launches.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import tempfile
import subprocess

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('output', type=Path)
p.add_argument('--proof-directory', type=Path, required=True)
p.add_argument('--host-bundle-id', choices=('org.horosproject.horos.planar-performance', 'org.horosproject.horos.local-development'), default='org.horosproject.horos.planar-performance')
p.add_argument('--products', type=Path, default=root/'build/Build/Products/Release')
p.add_argument('--vtk-install', type=Path, help='built VTK Install directory; enables the ObjC++ scene SDK case')
p.add_argument('--dcmtk-install', type=Path, help='DCMTK Install headers required by the ObjC++ public SDK; defaults beside VTK.build')
a = p.parse_args()
proof = a.proof_directory.resolve()
if root/'local-validation' not in proof.parents:
    p.error('proof directory must be inside this checkout/local-validation')
if a.output.exists():
    p.error('output must not exist')
proof.mkdir(parents=True, exist_ok=True)
bundle = a.output.resolve()
executable = bundle/'Contents/MacOS/QAHorosLifetime'
executable.parent.mkdir(parents=True)
command = ['xcrun', 'clang', '-fno-objc-arc', '-O2', '-bundle', '-undefined', 'dynamic_lookup',
    '-framework', 'AppKit', '-DHOROS_LIFETIME_HOST_BUNDLE_ID="'+a.host_bundle_id+'"']
with tempfile.TemporaryDirectory(prefix='horos-plugin-sdk-') as directory:
    sdk = Path(directory)
    shutil.copytree(a.products.resolve()/'Horos.framework', sdk/'Horos.framework', symlinks=True)
    source = sdk/'probe.m'
    source.write_bytes((root/'tools/probe-planar-host-lifetime.m').read_bytes())
    command += ['-F'+str(sdk)]
    if a.vtk_install:
        install = a.vtk_install.resolve()
        if not (install/'include/vtk-9.7/vtkAbstractBuffer.h').is_file():
            p.error('VTK Install must preserve include/vtk-9.7/vtkAbstractBuffer.h')
        shutil.copytree(install/'include', sdk/'include', symlinks=True)
        dcmtk = (a.dcmtk_install or install.parent.parent/'DCMTK.build/Install').resolve()
        if not (dcmtk/'include/dcmtk/config/osconfig.h').is_file():
            p.error('ObjC++ SDK requires --dcmtk-install with installed DCMTK headers')
        shutil.copytree(dcmtk/'include/dcmtk', sdk/'include/dcmtk', symlinks=True)
        command += ['-x', 'objective-c++', '-std=c++17', '-DHOROS_LIFETIME_VTK_SDK=1',
                    '-isystem', str(sdk/'include'), '-isystem', str(sdk/'include/vtk-9.7')]
    # A copied SDK must compile without reaching into the original checkout.
    profile = '(version 1)(allow default)(deny file-read* (subpath "%s"))' % root
    subprocess.run(['sandbox-exec', '-p', profile, *command, str(source), '-o', str(sdk/'plugin')], check=True)
    shutil.copy2(sdk/'plugin', executable)
info = {'CFBundleExecutable':'QAHorosLifetime','CFBundleIdentifier':'org.horosproject.qa.lifetime373',
        'CFBundleName':'QAHorosLifetime','CFBundleVersion':'1.0','CFBundlePackageType':'BNDL',
        'NSPrincipalClass':'QAHorosLifetime','pluginType':'imageFilter',
        'MenuTitles':['Capture Lifetime Pixels','Capture Lifetime Registry'],
        'ProofDirectory':str(proof), 'HostBundleIdentifier':a.host_bundle_id}
if a.vtk_install:
    info['MenuTitles'] = ['Capture VTK Scene']
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(bundle)],check=True,capture_output=True)
print(bundle)
