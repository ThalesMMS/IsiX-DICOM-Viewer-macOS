#!/usr/bin/env python3
"""Build a Horos/OsiriX plugin from its original source as an IsiX plugin (API 1),
with the porting kit IsiXLegacyBridge compiled in, without Xcode.

    tools/build-isix-legacy-plugin.py --sdk <folder with IsiXPluginKit.framework> \\
        --source <legacy plugin folder> --output <folder> [--name ModuleName] [--arch arm64|x86_64]
        [--arc] [--framework Accelerate ...] [--exclude <file name> ...] [--keep-project <folder>]
        [--library <installed library> ...] [--define NAME=VALUE ...]
    tools/build-isix-legacy-plugin.py --sdk <SDK> --project <converted project> --output <folder> [--arch ...]
        [--library <installed library> ...] [--define NAME=VALUE ...]

With --source the plugin is first converted by tools/port-legacy-plugin.py
(into a temporary folder, or into --keep-project), which decides everything
about the build: the Info.plist of API 1, the files the legacy target compiled
and copied, each file's memory management, the prefix header, the frameworks
and the source rewrites. With --project an already converted project is built.
Either way the build follows the project's Config/port.json, as its Xcode
project does:

- the kit's Swift is compiled into the plugin's module; the kit's Objective-C
  with ARC, the plugin's files each with its own setting, all with the
  project's prefix header (the kit's, then the plugin's own);
- the legacy headers come from the kit's copy (IsiXLegacyBridge/Headers and
  Include), never from the copy of the former SDK the plugin carried. A
  project converted with --shared-kit names the kit's folder in port.json
  ("kit", relative to the project, such as ../IsiXLegacyBridge), and its
  paths may lead out of the project's folder;
- the plugin's files are compiled with the project's diagnostics, which turn
  back into warnings the errors of current compilers that the legacy ones
  reported as warnings (an integer assigned to a pointer...);
- xibs are compiled by ibtool for the project's system; nibs, images,
  folders and .lproj files are copied into the bundle's resources. ibtool
  reports its errors in its output and may still exit with 0, so its report
  is read in XML: an error fails the build, and its warnings go with the
  compiler's. Every resource the project lists, each xib's nib included,
  must then be in the bundle;
- the bundle exports only its Objective-C classes, which the kit looks up in
  the plugin's own image (Config/Exports.exp; hidden visibility would hide
  the classes too, so only inline functions are compiled hidden): a library
  the plugin carries keeps its C++ templates and inline functions from being
  bound to the application's copies;
- --library adds a C or C++ library the plugin carries, installed as the
  plugin template's script/build-library.py installs it (include/ and
  lib/lib<Name>.a, built static with hidden visibility): its headers as
  system headers, its archive linked. The copy of a library the legacy
  plugin kept in its folder (ITK..., VTK..., DCMTK..., GSL...) is left out of
  the build and of the header search, as the former SDK is. --define adds a
  preprocessor definition, for a plugin that renamed the library's namespace
  in its own copy (NMSegmentation's ITKNS nmITK: --define nmITK=itk). With
  ITK, the plugin is converted from a copy where an ITK smart pointer
  initialised with the integer 0 (`Filter::Pointer f = 0L;`, accepted by the
  ITK of those plugins and ambiguous since ITK 5) is initialised with
  nullptr; the original folder is left as it is. ITK_TEMPLATE_TXX, with which
  ITK 3 had headers include their template code, is defined to 1 for the
  plugin's own ITK classes, and Id is defined as id, which turns the
  `#define id Id` those plugins put around ITK's headers, against
  Objective-C's id, into nothing: renamed, the standard library's own `id`
  (locale::id, thread::id) would no longer link, and ITK 5 compiles in
  Objective-C++ as it is. The functions of VNL's math named vnl_math_<name>
  before ITK 5 (vnl_math_abs, vnl_math_sqr...) are defined as their
  vnl_math::<name>, and VXL's vcl_<name> aliases of the standard library
  (vcl_sqrt, vcl_vector...) as std::<name>. Objective-C++ and C++ are
  compiled as C++17 without the C++11 narrowing error of constant
  initialisers, which C++98 code relied on;
- the bundle is signed ad hoc.

Writes <output>/<name>.isixplugin and prints its path; a build that fails
leaves no bundle. Relative paths are taken from the current folder (ibtool's
daemon does not run in it, so every path is made absolute first). The
application's own build never builds this; the kit's test and the in-app
check call it.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# An ITK smart pointer initialised with the integer 0; ITK 5 takes nullptr.
ITK_NULL_POINTER = re.compile(r'(\bPointer\s+\w+\s*=\s*)(?:0L|0|NULL)(\s*;)')
ITK_SOURCE_SUFFIXES = {'.h', '.hxx', '.txx', '.cxx', '.m', '.mm'}
# Definitions for the names of ITK 3 that ITK 5 dropped; see --library.
ITK_LEGACY_DEFINES = ['ITK_TEMPLATE_TXX=1', 'Id=id'] + [
    f'vnl_math_{name}=vnl_math::{name}' for name in (
        'abs', 'ceil', 'cube', 'floor', 'hypot', 'isfinite', 'isinf', 'isnan', 'max', 'min', 'rnd', 'sgn', 'sgn0', 'sqr',
        'squared_magnitude')] + [
    f'vcl_{name}=std::{name}' for name in (
        'abs', 'acos', 'asin', 'atan', 'atan2', 'ceil', 'cerr', 'cos', 'cosh', 'cout', 'endl', 'exp', 'fabs', 'floor',
        'fmod', 'log', 'log10', 'map', 'max', 'min', 'pair', 'pow', 'sin', 'sinh', 'sort', 'sqrt', 'string', 'swap',
        'tan', 'tanh', 'vector')]


def load_converter():
    spec = importlib.util.spec_from_file_location('port_legacy_plugin', ROOT / 'tools' / 'port-legacy-plugin.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


converter = load_converter()
# ibtool, through xcrun; the nib test points it at a stand-in.
IBTOOL = ['xcrun', 'ibtool']


def run(command, **options):
    result = subprocess.run(command, capture_output=True, text=True, **options)
    if result.returncode != 0:
        raise RuntimeError(f'{" ".join(map(str, command[:3]))} ... failed:\n{result.stderr[-6000:]}')
    return result


def ibtool_issues(report, kind):
    """The messages of `kind` ('errors', 'warnings') in ibtool's XML report:
    the tool's own (com.apple.ibtool.errors: a document it could not open...)
    and the document's (com.apple.ibtool.document.errors, by object)."""
    messages = []
    for key in (f'com.apple.ibtool.{kind}', f'com.apple.ibtool.document.{kind}'):
        value = report.get(key) or []
        groups = value.values() if isinstance(value, dict) else [value]
        for group in groups:
            for issue in group if isinstance(group, list) else [group]:
                if isinstance(issue, dict):
                    text = issue.get('message') or issue.get('description') or str(issue)
                    reason = issue.get('failure-reason') or ''
                    messages.append(' '.join((text if reason in text else f'{text} {reason}').split()))
                else:
                    messages.append(str(issue))
    return messages


def compile_xib(xib, nib, minimum_system):
    """Compile `xib` into `nib` for `minimum_system`; ibtool's warnings, each
    as '<xib>: warning: <message>'. Raises RuntimeError on an error in ibtool's
    report, an exit code other than 0, a report that cannot be read, or no nib."""
    xib, nib = Path(xib).resolve(), Path(nib).resolve()
    result = subprocess.run([*IBTOOL, '--errors', '--warnings', '--output-format', 'xml1',
                             '--minimum-deployment-target', minimum_system, '--compile', str(nib), str(xib)],
                            capture_output=True)
    try:
        report = plistlib.loads(result.stdout)
    except Exception:
        report = None
    problems = []
    if not isinstance(report, dict):
        problems.append('ibtool wrote no report: ' + (result.stdout + result.stderr).decode(errors='replace')[-2000:])
        report = {}
    problems += ibtool_issues(report, 'errors')
    if result.returncode != 0 and not problems:
        problems.append(f'ibtool exited with {result.returncode}: ' + result.stderr.decode(errors='replace')[-2000:])
    if not problems and not nib.exists():
        problems.append(f'ibtool reported no error but wrote no {nib.name}')
    if problems:
        raise RuntimeError(f'ibtool failed on {xib}:\n' + '\n'.join(f'  error: {p}' for p in problems))
    return [f'{xib}: warning: {message}' for message in ibtool_issues(report, 'warnings')]


def uses_itk(libraries):
    return any((Path(library) / 'include' / 'itkConfigure.h').is_file() for library in libraries)


def adapt_to_itk5(source, copy):
    """`copy`: the plugin folder with ITK_NULL_POINTER rewritten; the changes, as file: count."""
    shutil.copytree(source, copy, symlinks=True)
    changes = {}
    for path in sorted(copy.rglob('*')):
        if path.is_file() and not path.is_symlink() and path.suffix in ITK_SOURCE_SUFFIXES:
            text = path.read_text(encoding='utf-8', errors='surrogateescape')
            adapted, count = ITK_NULL_POINTER.subn(r'\1nullptr\2', text)
            if count:
                path.write_text(adapted, encoding='utf-8', errors='surrogateescape')
                changes[str(path.relative_to(copy))] = count
    return changes


def build_project(sdk, project, output, arch='arm64', warnings=None, libraries=(), defines=()):
    """<output>/<module>.isixplugin from a project written by the converter.
    `warnings`, a dict, receives the compiler's warnings: 'kit' for the kit's
    own files and 'plugin' for the plugin's, and ibtool's under 'nib'.
    `libraries` are installed libraries the plugin carries; `defines`,
    NAME=VALUE preprocessor definitions. A build that fails raises
    RuntimeError and leaves no bundle."""
    sdk, project, output = (Path(path).resolve() for path in (sdk, project, output))
    libraries = [Path(library).resolve() for library in libraries]
    manifest = json.loads((project / 'Config' / 'port.json').read_text())
    bundle = output / f'{manifest["module"]}.isixplugin'
    if bundle.exists():
        shutil.rmtree(bundle)
    try:
        return assemble(sdk, project, manifest, bundle, arch, warnings, libraries, defines)
    except BaseException:
        shutil.rmtree(bundle, ignore_errors=True)
        raise


def assemble(sdk, project, manifest, bundle, arch, warnings, libraries, defines):
    """build_project's work: `bundle` from the converted `project`."""
    module = manifest['module']
    contents = bundle / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    resources = contents / 'Resources'
    resources.mkdir()
    shutil.copy2(project / manifest['infoPlist'], contents / 'Info.plist')
    target = f'{arch}-apple-macos{manifest["minimumSystem"]}'
    sysroot = run(['xcrun', '--show-sdk-path']).stdout.strip()
    kit = (project / manifest.get('kit', converter.KIT_FOLDER)).resolve()
    if not (kit / 'Headers').is_dir():
        raise RuntimeError(f'{project.name}: the porting kit is not at {kit}')

    def in_kit(path):
        return (project / path).resolve().is_relative_to(kit)

    if warnings is not None:
        warnings.setdefault('kit', [])
        warnings.setdefault('plugin', [])
        warnings.setdefault('nib', [])

    def collect(path, result):
        if warnings is not None:
            kind = 'kit' if in_kit(path) else 'plugin'
            warnings[kind] += [line for line in result.stderr.splitlines() if ': warning:' in line]

    swift = [s['path'] for s in manifest['sources'] if s['path'].endswith('.swift')]
    with tempfile.TemporaryDirectory(prefix='isix-legacy-') as temporary:
        work = Path(temporary)
        generated = work / 'include'
        generated.mkdir()
        swift_object = work / 'IsiXLegacyBridge-swift.o'
        result = run(['xcrun', 'swiftc', '-c', '-wmo', '-parse-as-library', '-swift-version', '5', '-module-name', module,
                      '-target', target, '-F', str(sdk), '-emit-objc-header-path', str(generated / 'IsiXLegacyBridge-Swift.h'),
                      '-emit-clang-header-min-access', 'internal', '-o', str(swift_object),
                      *(str(project / path) for path in swift)])
        collect(swift[0], result)
        common = ['xcrun', 'clang', '-c', '-target', target, '-isysroot', sysroot, '-fobjc-exceptions',
                  '-fvisibility-inlines-hidden', f'-DISIX_LEGACY_NAMESPACE={module}',
                  *(f'-D{d}' for d in [*manifest['defines'], *defines]),
                  '-I', str(kit / 'Headers'), '-I', str(kit / 'Include'), '-I', str(generated)]
        for library in libraries:
            common += ['-isystem', str(Path(library) / 'include')]
        for folder in manifest['headerFolders']:
            common += ['-iquote', str(project / folder)]
        common += ['-include', str(project / manifest['prefixHeader'])]
        objects = [swift_object]
        for index, source in enumerate(s for s in manifest['sources'] if not s['path'].endswith('.swift')):
            path = Path(source['path'])
            language = source.get('language', converter.SUFFIX_LANGUAGES.get(path.suffix, 'c'))
            command = list(common)
            if language.startswith('objective'):
                command.append('-fobjc-arc' if source['arc'] else '-fno-objc-arc')
            if in_kit(path):
                command += ['-Wall', '-Wextra', '-Wno-unused-parameter']
            else:
                command += manifest.get('diagnostics', [])
            if language.endswith('++'):
                command += ['-std=c++17', '-Wno-c++11-narrowing']
            if 'language' in source:
                command += ['-x', language]
            target_object = work / f'{index}-{path.stem}.o'
            result = run([*command, *source['flags'], '-o', str(target_object), str(project / path)])
            collect(path, result)
            objects.append(target_object)
        binary = contents / 'MacOS' / module
        link = ['xcrun', 'swiftc', '-module-name', module, '-target', target, '-F', str(sdk), '-framework', 'IsiXPluginKit',
                '-Xlinker', '-bundle', '-Xlinker', '-exported_symbols_list', '-Xlinker',
                str(project / manifest['exportedSymbols']), '-o', str(binary), *map(str, objects)]
        for library in map(Path, libraries):
            archives = sorted((library / 'lib').glob('lib*.a'))
            if not archives:
                raise RuntimeError(f'{library}: no lib/lib<Name>.a')
            link += ['-L', str(library / 'lib'), *(f'-l{archive.stem[3:]}' for archive in archives)]
        cplusplus = any(source.get('language', converter.SUFFIX_LANGUAGES.get(Path(source['path']).suffix, ''))
                        .endswith('++') for source in manifest['sources'])
        for library in [*manifest['libraries'], *(['z', 'c++'] if libraries else []), *(['c++'] if cplusplus else [])]:
            if f'-l{library}' not in link:
                link += [f'-l{library}']
        for framework in manifest['frameworks']:
            link += ['-framework', framework]
        run(link)

    for resource in manifest['resources']:
        path = project / resource['path']
        destination = resources / resource['destination']
        destination.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix == '.xib':
            found = compile_xib(path, destination.with_suffix('.nib'), manifest['minimumSystem'])
            if warnings is not None:
                warnings['nib'] += found
        elif path.is_dir():
            shutil.copytree(path, destination, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(path, destination)
    expected = [Path(r['destination']) for r in manifest['resources']]
    expected = [path.with_suffix('.nib') if path.suffix == '.xib' else path for path in expected]
    missing = [str(path) for path in expected if not (resources / path).exists()]
    if missing:
        raise RuntimeError(f'{bundle.name}: missing from the bundle: {", ".join(missing)}')
    run(['codesign', '--force', '--sign', '-', str(bundle)])
    return bundle


def build(sdk, source, output, name=None, arch='arm64', arc=None, frameworks=(), exclude=(), warnings=None,
          libraries=(), defines=(), keep_project=None):
    """<output>/<name>.isixplugin from the legacy plugin at `source`, converted
    first by tools/port-legacy-plugin.py. `arc` (True or False) overrides the
    memory management of the files the legacy project does not set.
    `warnings`, a dict, receives the compiler's warnings: 'kit' for the kit's
    own files and 'plugin' for the plugin's, ibtool's under 'nib', and, with ITK, 'adapted': the
    files of the copy adapted to ITK 5. `libraries` are installed libraries
    the plugin carries; `defines`, NAME=VALUE preprocessor definitions."""
    source = Path(source).resolve()
    keep_project = Path(keep_project).resolve() if keep_project else None
    with tempfile.TemporaryDirectory(prefix='isix-legacy-port-') as temporary:
        if uses_itk(libraries):
            copy = Path(temporary) / 'itk5' / source.name
            changes = adapt_to_itk5(source, copy)
            if warnings is not None:
                warnings['adapted'] = changes
            source, defines = copy, [*defines, *ITK_LEGACY_DEFINES]
        report = converter.convert(source, keep_project or Path(temporary) / 'projects', name, arc, frameworks,
                                   exclude, sdk)
        return build_project(sdk, report['project'], output, arch, warnings, libraries, defines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sdk', type=Path, required=True)
    what = parser.add_mutually_exclusive_group(required=True)
    what.add_argument('--source', type=Path, help='folder of the legacy plugin')
    what.add_argument('--project', type=Path, help='a project written by tools/port-legacy-plugin.py')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--name', help="the plugin's module name (default: its product name)")
    parser.add_argument('--arch', default='arm64', choices=('arm64', 'x86_64'))
    parser.add_argument('--arc', action='store_true', default=None,
                        help='the files the legacy project does not set are written for ARC')
    parser.add_argument('--framework', action='append', default=[])
    parser.add_argument('--exclude', action='append', default=[], help='a source file name to leave out')
    parser.add_argument('--keep-project', type=Path, help='write the converted project here instead of a temporary folder')
    parser.add_argument('--library', action='append', default=[], type=Path,
                        help='an installed library the plugin carries (include/, lib/lib<Name>.a)')
    parser.add_argument('--define', action='append', default=[], help='a preprocessor definition, NAME=VALUE')
    arguments = parser.parse_args()
    if not (arguments.sdk / 'IsiXPluginKit.framework').is_dir():
        sys.exit(f'{arguments.sdk}: no IsiXPluginKit.framework; export one with tools/export-isix-plugin-kit.py')
    if arguments.project:
        if not (arguments.project / 'Config' / 'port.json').is_file():
            sys.exit(f'{arguments.project}: no Config/port.json; convert the plugin with tools/port-legacy-plugin.py')
        print(build_project(arguments.sdk, arguments.project, arguments.output, arguments.arch,
                            libraries=arguments.library, defines=arguments.define))
        return
    if not arguments.source.is_dir():
        sys.exit(f'{arguments.source}: not a folder')
    print(build(arguments.sdk, arguments.source, arguments.output, arguments.name, arguments.arch, arguments.arc,
                arguments.framework, arguments.exclude, libraries=arguments.library, defines=arguments.define,
                keep_project=arguments.keep_project))


if __name__ == '__main__':
    main()
