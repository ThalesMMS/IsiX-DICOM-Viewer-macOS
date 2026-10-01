#!/usr/bin/env python3
"""Exercise the host hook's target graph and exact buffer exclusion conditions."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile
import json
import os
import sys

root = Path(__file__).resolve().parents[1]
from sources import dependency_source
vtk_source = dependency_source('VTK')
hook = root / 'Horos/Scripts/VTK/HostBuild.cmake'
vtk_pin = json.loads((root / 'Horos/Scripts/external-sources.json').read_text())['VTK']
def install_source_record(install):
    (install / 'share/licenses/VTK').mkdir(parents=True, exist_ok=True)
    (install / 'share/source.json').write_text(json.dumps(vtk_pin))
    shutil.copyfile(vtk_source / 'Copyright.txt', install / 'share/licenses/VTK/Copyright.txt')

# Hashes of these two files in the SHA-256-pinned official 9.7.1 release.
for name, digest in {
    'CMakeLists.txt': '6f9b76654f3e59aa1bd96af9ba8d38fa266ef23e6a8aeb4019bb752d87569717',
    'Common/Core/CMakeLists.txt': '8c0c0ae9952f4f337f390c61c92698655cb7f02cc3b80db74fdbfa434cf667b9',
}.items():
    assert hashlib.sha256((vtk_source / name).read_bytes()).hexdigest() == digest, name
if not shutil.which('cmake'):
    print('skipped: requires CMake')
    raise SystemExit(2)

with tempfile.TemporaryDirectory(prefix='horos-vtk-hook-') as directory:
    work = Path(directory)
    source = work / 'source'
    core = source / 'Common/Core'
    core.mkdir(parents=True)
    for name in ('vtkAbstractBuffer.h', 'vtkAbstractBuffer.cxx', 'Other.cxx', 'NotvtkAbstractBuffer.cxx'):
        (core / name).write_text('// synthetic configure fixture\n')
    (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.23)
project(VTK LANGUAGES CXX)
set(APPLE ${TEST_APPLE})
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
add_subdirectory(Common/Core)
add_library(Headers INTERFACE)
add_custom_target(Utility)
''')
    (core / 'CMakeLists.txt').write_text('''add_library(Core vtkAbstractBuffer.cxx Other.cxx NotvtkAbstractBuffer.cxx)
add_library(VTK::CommonCore ALIAS Core)
target_sources(Core PUBLIC FILE_SET public_headers TYPE HEADERS FILES vtkAbstractBuffer.h)
install(TARGETS Core FILE_SET public_headers DESTINATION include/vtk-9.7)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/properties.txt" CONTENT
"$<TARGET_PROPERTY:Core,CXX_VISIBILITY_PRESET>;$<TARGET_PROPERTY:Core,VISIBILITY_INLINES_HIDDEN>\n$<TARGET_PROPERTY:Core,SOURCES>\n$<TARGET_PROPERTY:Core,HEADER_SET_public_headers>\n")
''')
    for index, (apple, shared, wrapping) in enumerate(((True, False, False), (False, False, False),
                                                      (True, True, False), (True, False, True))):
        build = work / str(index)
        result = subprocess.run(['cmake', '-S', str(source), '-B', str(build),
            '-DCMAKE_PROJECT_VTK_INCLUDE=' + str(hook), '-DTEST_APPLE=' + ('ON' if apple else 'OFF'),
            '-DBUILD_SHARED_LIBS=' + ('ON' if shared else 'OFF'),
            '-DVTK_ENABLE_WRAPPING=' + ('ON' if wrapping else 'OFF')], capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'Warning' not in result.stderr, result.stderr
        visibility, sources, headers = (build / 'properties.txt').read_text().splitlines()
        assert visibility == 'default;OFF', visibility
        excluded = apple and not shared and not wrapping
        assert ('vtkAbstractBuffer.cxx' not in sources.split(';')) == excluded, sources
        assert 'NotvtkAbstractBuffer.cxx' in sources and 'Other.cxx' in sources, sources
        assert 'vtkAbstractBuffer.h' in headers
        assert 'vtkAbstractBuffer.h' in (build / 'Common/Core/cmake_install.cmake').read_text()
        flags = (build / 'Common/Core/CMakeFiles/Core.dir/flags.make').read_text()
        assert '-fvisibility=default' in flags and '-fvisibility-inlines-hidden' not in flags, flags
print('PASS: official CMake files intact; target visibility, precise buffer conditions and installed file set verified')

# Exercise the real installed-archive adapter with the original FreeType TU and
# public header. An independent raw-symbol provider must retain its own ABI.
adapter = root / 'Horos/Scripts/VTK/adapt-freetype.py'
freetype = vtk_source / 'ThirdParty/freetype/vtkfreetype'
with tempfile.TemporaryDirectory(prefix='horos-freetype-host-') as directory:
    work = Path(directory)
    includes = ['-I'+str(freetype.parent), '-I'+str(freetype/'include')]
    (work/'foreign.c').write_text('long FT_MulFix(long a,long b){return 424242;}\n'
                                 'long foreign_call(void){return FT_MulFix(0,0);}\n')
    caller = '''#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdint.h>
#include <dlfcn.h>
extern long foreign_call(void);
int main(int argc,char **argv) {
  if (foreign_call()!=424242) return 1;
  void *plugin=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  long (*raw)(long,long)=dlsym(RTLD_DEFAULT,"FT_MulFix");
  if(!plugin || (raw && raw(0,0)!=424242) ||
               dlsym(RTLD_DEFAULT,"vtkfreetype_FT_MulFix")!=(void*)FT_MulFix) return 2;
  long (*call)(long,long)=dlsym(plugin,"plugin_mulfix");
  if(!call) return 3;
  long values[]={INT32_MIN,INT32_MIN+1,-123456,-65536,-32769,-32768,-1,0,1,
                 2,32767,32768,32769,65535,65536,123456,INT32_MAX-1,INT32_MAX};
  for(unsigned i=0;i<18;i++) for(unsigned j=0;j<18;j++) {
    int64_t p=(int64_t)values[i]*values[j];
    long expected=(long)(p<0?-((-p+32768)>>16):((p+32768)>>16));
    if(FT_MulFix(values[i],values[j])!=expected || call(values[i],values[j])!=expected) return 4;
  }
  return 0;
}
'''
    (work/'caller.c').write_text(caller)
    (work/'plugin.c').write_text('#include <ft2build.h>\n#include FT_FREETYPE_H\n'
                                'long plugin_mulfix(long a,long b){return FT_MulFix(a,b);}\n')
    (work/'plugin-only-host.c').write_text('''#include <dlfcn.h>
int main(int argc,char **argv) {
  if(dlsym(RTLD_DEFAULT,"FT_MulFix"))return 1;
  if(!dlsym(RTLD_DEFAULT,"vtkfreetype_FT_MulFix"))return 2;
  void *plugin=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if(!plugin)return 3;
  long (*call)(long,long)=dlsym(plugin,"plugin_mulfix");
  return !call || call(65536,-123456)!=-123456;
}
''')
    project = (root/'Horos.xcodeproj/project.pbxproj').read_text()
    assert project.count('"-lVTK",\n\t\t\t\t\t"-Wl,-u,_vtkfreetype_FT_MulFix",') == 2
    for configuration, optimization in [('Debug', '-O0'), ('Release', '-O3')]:
        install = work/configuration/'Install'
        (install/'lib').mkdir(parents=True)
        (install/'.incomplete').touch()
        original = work/'ftbase.c.o'
        compiled = subprocess.run(['xcrun','clang','-arch','arm64',optimization,
            '-DFT2_BUILD_LIBRARY',*includes,'-c',str(freetype/'src/base/ftbase.c'),
            '-o',str(original)],capture_output=True,text=True)
        assert compiled.returncode == 0, compiled.stderr
        assert 'macro-redefined' in compiled.stderr, 'upstream diagnostic unexpectedly suppressed'
        archive = install/'lib/libvtkfreetype-9.7.a'
        subprocess.run(['xcrun','libtool','-static','-o',str(archive),str(original)],check=True,capture_output=True)
        before = hashlib.sha256(archive.read_bytes()).hexdigest()
        outcome = subprocess.run([sys.executable,str(adapter),str(install),str(freetype)],
            env=dict(os.environ,CONFIGURATION=configuration),capture_output=True,text=True)
        assert outcome.returncode == 0, outcome.stderr
        record = json.loads((install/'share/freetype-host-adaptation.json').read_text())
        assert record['originalArchiveSha256'] == before
        assert record['installedArchiveSha256'] == hashlib.sha256(archive.read_bytes()).hexdigest()
        assert record['sourcePatches'] == [] and record['configuration'] == configuration
        assert record['source']['treeSha256'] == json.loads((adapter.parent/'freetype-source.json').read_text())['treeSha256']
        assert str(root) not in json.dumps(record), 'private source/build path leaked into installed metadata'
        names = subprocess.check_output(['xcrun','nm','-g','--defined-only',str(archive)],text=True)
        assert '_FT_MulFix' not in {line.split()[-1] for line in names.splitlines() if line.split()}
        assert '_vtkfreetype_FT_MulFix' in names
        # The aggregate is produced from the adapted module, not another copy.
        aggregate = install/'libVTK.a'
        subprocess.run(['xcrun','libtool','-static','-o',str(aggregate),str(archive)],check=True,capture_output=True)
        plugin = work/'plugin.bundle'
        subprocess.run(['xcrun','clang','-arch','arm64',optimization,*includes,'-bundle',
            '-Wl,-undefined,dynamic_lookup',str(work/'plugin.c'),'-o',str(plugin)],check=True,capture_output=True)
        for library in (archive, aggregate):
            executable = work/'caller'
            linked = subprocess.run(['xcrun','clang','-arch','arm64',optimization,*includes,
                '-Wl,-dead_strip','-Wl,-u,_vtkfreetype_FT_MulFix',
                str(work/'caller.c'),str(work/'foreign.c'),str(library),'-o',str(executable)],capture_output=True,text=True)
            assert linked.returncode == 0, linked.stderr
            assert subprocess.run([str(executable),str(plugin)]).returncode == 0
            linked = subprocess.run(['xcrun','clang','-arch','arm64',optimization,
                '-Wl,-dead_strip','-Wl,-u,_vtkfreetype_FT_MulFix',str(work/'plugin-only-host.c'),
                str(library),'-o',str(executable)],capture_output=True,text=True)
            assert linked.returncode == 0, linked.stderr
            assert subprocess.run([str(executable),str(plugin)]).returncode == 0
        # An already-adapted module cannot silently be mistaken for original
        # CMake output on an incomplete installation's next invocation.
        outcome = subprocess.run([sys.executable,str(adapter),str(install),str(freetype)],capture_output=True,text=True)
        assert outcome.returncode != 0 and 'original FT_MulFix' in outcome.stderr
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == record['installedArchiveSha256']
        assert (install/'.incomplete').exists()
        (install/'wlib').mkdir()
        shutil.copyfile(aggregate, install/'wlib/libVTK.a')
        install_source_record(install)
        outcome = subprocess.run([sys.executable,str(adapter),'--complete',str(install)],capture_output=True,text=True)
        assert outcome.returncode == 0, outcome.stderr
        (install/'.incomplete').unlink()
        outcome = subprocess.run([sys.executable,str(adapter),'--verify-install',str(install)],capture_output=True,text=True)
        assert outcome.returncode == 0, outcome.stderr
        outcome = subprocess.run([sys.executable,str(adapter),'--verify-install',str(install)],
            env=dict(os.environ,CONFIGURATION='Release' if configuration == 'Debug' else 'Debug'),
            capture_output=True,text=True)
        assert outcome.returncode != 0 and 'configuration changed' in outcome.stderr
        source_record = install/'share/source.json'
        original_source_record = source_record.read_bytes()
        divergent = json.loads(original_source_record)
        divergent['sha256'] = 'f'*64
        source_record.write_text(json.dumps(divergent))
        outcome = subprocess.run([sys.executable,str(adapter),'--verify-install',str(install)],capture_output=True,text=True)
        assert outcome.returncode != 0 and 'original source/license identity changed' in outcome.stderr
        source_record.write_bytes(original_source_record)
        license_file = install/'share/licenses/VTK/Copyright.txt'
        original_license = license_file.read_bytes()
        license_file.write_bytes(original_license+b'changed\n')
        outcome = subprocess.run([sys.executable,str(adapter),'--verify-install',str(install)],capture_output=True,text=True)
        assert outcome.returncode != 0 and 'original source/license identity changed' in outcome.stderr
        license_file.write_bytes(original_license)
        original_bytes = archive.read_bytes()
        archive.write_bytes(original_bytes+b'changed\n')
        outcome = subprocess.run([sys.executable,str(adapter),'--verify-install',str(install)],capture_output=True,text=True)
        assert outcome.returncode != 0 and 'differs from its identity' in outcome.stderr
        archive.write_bytes(original_bytes)
        aggregate = install/'wlib/libVTK.a'
        aggregate.write_bytes(aggregate.read_bytes()+b'changed\n')
        outcome = subprocess.run([sys.executable,str(adapter),'--verify-install',str(install)],capture_output=True,text=True)
        assert outcome.returncode != 0 and 'differs from its identity' in outcome.stderr
    changed_source = work/'changed-source'
    shutil.copytree(freetype,changed_source)
    changed_header = changed_source/'include/freetype/internal/ftcalc.h'
    changed_header.chmod(0o644)
    changed_header.write_bytes(changed_header.read_bytes()+b'\n/* unexpected edit */\n')
    outcome = subprocess.run([sys.executable,str(adapter),'--verify-source',str(changed_source)],capture_output=True,text=True)
    assert outcome.returncode != 0 and 'differs from its pinned original' in outcome.stderr
print('PASS: original FreeType, 324 signed/rounding cases, raw-provider isolation and plugin resolution in modular/aggregate Debug/Release archives')

# Run the production packaging step with a synthetic installed SDK. Compilation
# and installation are stubs here; the copy/alias logic is the real Make.sh.
import os
with tempfile.TemporaryDirectory(prefix='horos-vtk-package-') as directory:
    work = Path(directory)
    target = work / 'VTK.build'
    install = target / 'Install'
    versioned = install / 'include/vtk-9.7'
    versioned.mkdir(parents=True)
    (versioned / 'vtkAbstractBuffer.h').write_text('// interface fixture\n')
    wrapper = (vtk_source / 'ThirdParty/tiff/vtk_tiff.h.in').read_text().replace(
        '#cmakedefine01 VTK_MODULE_USE_EXTERNAL_vtktiff', '#define VTK_MODULE_USE_EXTERNAL_vtktiff 1')
    (versioned / 'vtk_tiff.h').write_text(wrapper)
    (target / 'CMake').mkdir()
    source_prefix = target / 'Source'
    shutil.copytree(freetype, source_prefix / 'source/ThirdParty/freetype/vtkfreetype')
    shutil.copyfile(vtk_source / 'Copyright.txt', source_prefix / 'source/Copyright.txt')
    (source_prefix / 'share').mkdir()
    (source_prefix / 'share/source.json').write_text(json.dumps(vtk_pin))
    (install / 'lib').mkdir()
    (install / 'lib/libCore.a').touch()
    # The packaging fixture supplies native object bytes to the production
    # adapter; only make/install and final aggregation are stubbed here.
    (work/'ftbase.c').write_text('long FT_MulFix(long a,long b){return (a*b+32768)>>16;}\n')
    subprocess.run(['xcrun','clang','-arch','arm64','-c',str(work/'ftbase.c'),
                    '-o',str(work/'ftbase.c.o')],check=True,capture_output=True)
    original_archive = work/'original-freetype.a'
    subprocess.run(['xcrun','libtool','-static','-o',str(original_archive),str(work/'ftbase.c.o')],check=True,capture_output=True)
    external = work / 'ExternalInputs.build/Install/include'
    external.mkdir(parents=True)
    for name in ('tiff.h', 'tiffconf.h', 'tiffio.h', 'tiffvers.h'):
        (external / name).write_text('// pinned fixture ' + name + '\n')
    commands = work / 'bin'
    commands.mkdir()
    for name, body in {'make': 'exit 0', 'cmake': 'cp "$FT_ARCHIVE" "$TARGET_TEMP_DIR/Install/lib/libvtkfreetype-9.7.a"', 'libtool': 'touch "$3"'}.items():
        (commands / name).write_text('#!/bin/sh\n' + body + '\n')
        (commands / name).chmod(0o755)
    environment = dict(os.environ, PATH=str(commands)+os.pathsep+os.environ['PATH'],
                       TARGET_TEMP_DIR=str(target), CONFIGURATION_TEMP_DIR=str(work), PRODUCT_NAME='VTK',
                       PROJECT_DIR=str(root), TARGET_NAME='VTK', CONFIGURATION='Debug', FT_ARCHIVE=str(original_archive))
    result = subprocess.run(['/bin/bash', str(root / 'Horos/Scripts/VTK/Make.sh')],
                            env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert not (install / '.incomplete').exists()
    copied = work / 'copied-sdk'
    shutil.copytree(install, copied, symlinks=True)
    shutil.rmtree(install)
    assert (copied / 'include/vtk_tiff.h').read_text() == wrapper
    assert (copied / 'include/vtkAbstractBuffer.h').is_file()
    for name in ('tiff.h', 'tiffconf.h', 'tiffio.h', 'tiffvers.h'):
        for path in ('include/', 'include/vtk-9.7/', 'include/vtktiff/libtiff/'):
            assert (copied / (path + name)).read_bytes() == (external / name).read_bytes()
    for alias in (copied / 'include').iterdir():
        if alias.is_symlink():
            assert not os.path.isabs(os.readlink(alias)) and alias.exists(), alias
    # A foreign header cannot be silently replaced, and failure keeps the marker.
    shutil.copytree(copied, install, symlinks=True)
    (install / 'wlib/libVTK.a').unlink()
    alias = install / 'include/vtk_tiff.h'
    alias.unlink()
    alias.write_text('unmanaged\n')
    result = subprocess.run(['/bin/bash', str(root / 'Horos/Scripts/VTK/Make.sh')],
                            env=environment, capture_output=True, text=True)
    assert result.returncode != 0 and 'unmanaged VTK include' in result.stderr, result.stderr
    assert alias.read_text() == 'unmanaged\n' and (install / '.incomplete').is_file()
print('PASS: versioned SDK and relative aliases survive relocation; TIFF wrapper/input unchanged; collisions fail incomplete')

# With an actual completed build, check the SDK that will be handed to plugins
# and let CMake consume its exports, not just the synthetic packaging fixture.
installed = 0
for configuration in ('Debug', 'Release'):
    base = next((folder / 'Intermediates.noindex/Horos.build' / configuration
                 for folder in (root/'build', root/'build/Build')
                 if (folder/'Intermediates.noindex/Horos.build'/configuration).is_dir()),
                root/'build/Intermediates.noindex/Horos.build'/configuration)
    install = base/'VTK.build/Install'
    if not (install/'wlib/libVTK.a').is_file() or (install/'.incomplete').exists():
        continue
    installed += 1
    include = install/'include'
    versioned = include/'vtk-9.7'
    assert (versioned/'vtkAbstractBuffer.h').is_file()
    assert (versioned/'vtkBuffer.h').is_file()
    for entry in versioned.iterdir():
        alias = include/entry.name
        assert alias.is_symlink() and alias.resolve() == entry.resolve(), alias
    generated = base/'VTK.build/CMake/ThirdParty/tiff/vtk_tiff.h'
    assert (versioned/'vtk_tiff.h').read_bytes() == generated.read_bytes(), 'TIFF wrapper changed'
    for name in ('tiff.h', 'tiffconf.h', 'tiffio.h', 'tiffvers.h'):
        assert (versioned/name).read_bytes() == (base/'ExternalInputs.build/Install/include'/name).read_bytes(), name
    with tempfile.TemporaryDirectory(prefix='horos-vtk-cmake-sdk-') as directory:
        work = Path(directory)
        (work/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.23)
project(SDKConsumer LANGUAGES CXX)
find_package(VTK 9.7 REQUIRED COMPONENTS CommonCore)
add_library(Consumer INTERFACE)
target_link_libraries(Consumer INTERFACE VTK::CommonCore)
''')
        result = subprocess.run(['cmake', '-S', str(work), '-B', str(work/'build'),
                                 '-DVTK_DIR='+str(install/'lib/cmake/vtk-9.7')],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout+result.stderr
print(f'Installed SDK integration checks: {installed} completed configurations (requires current full build)')
