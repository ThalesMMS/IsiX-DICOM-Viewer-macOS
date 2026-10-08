#!/usr/bin/env python3
"""Exercise archive merging with real ARM and Intel Mach-O files."""
import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('merge_archives', root / 'tools/merge-appstore-archives.py')
merger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merger)


class UniversalArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        source = self.work / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        self.inputs = []
        for arch in ('arm64', 'x86_64'):
            archive = self.work / (arch + '.xcarchive')
            app = archive / 'Products/Applications/Fixture.app'
            main = app / 'Contents/MacOS/Fixture'
            main.parent.mkdir(parents=True)
            subprocess.run(['xcrun', 'clang', '-g', '-target', arch + '-apple-macos26.0',
                            str(source), '-o', str(main)], check=True)
            symbols = main.with_suffix('.dSYM')
            if symbols.exists():
                (archive / 'dSYMs').mkdir()
                shutil.move(symbols, archive / 'dSYMs/Fixture.app.dSYM')
            helper = app / 'Contents/Resources/helper'
            helper.parent.mkdir(parents=True)
            shutil.copy2(main, helper)
            module = app / 'Contents/Modules/Fixture.swiftmodule' / (arch + '.swiftmodule')
            module.parent.mkdir(parents=True)
            module.write_text(arch)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '22'}))
            (archive / 'Info.plist').write_bytes(plistlib.dumps({'ApplicationProperties': {
                'ApplicationPath': 'Applications/Fixture.app', 'CFBundleIdentifier': 'test.fixture',
                'CFBundleVersion': '22', 'CFBundleShortVersionString': '5.1.0', 'Team': 'TEST'}}))
            self.inputs.append(archive)
        self.output = self.work / 'Universal.xcarchive'

    def test_mergesEveryExecutableAndPreservesArchitectureModules(self):
        merger.merge(*self.inputs, self.output)
        for name in ('Contents/MacOS/Fixture', 'Contents/Resources/helper'):
            binary = self.output / 'Products/Applications/Fixture.app' / name
            self.assertEqual(set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()),
                             {'arm64', 'x86_64'})
        modules = self.output / 'Products/Applications/Fixture.app/Contents/Modules/Fixture.swiftmodule'
        self.assertEqual({p.name for p in modules.iterdir()}, {'arm64.swiftmodule', 'x86_64.swiftmodule'})
        for arch, archive in zip(('arm64', 'x86_64'), self.inputs):
            original = archive / 'Products/Applications/Fixture.app/Contents/MacOS/Fixture'
            self.assertEqual(subprocess.check_output(['lipo', '-archs', str(original)], text=True).strip(), arch)

    def test_installedInfoPlistIsReadableWithoutChangingSourcePermissions(self):
        relative = 'Products/Applications/Fixture.app/Contents/Info.plist'
        source = self.inputs[0] / relative
        source.chmod(0o600)
        merger.merge(*self.inputs, self.output)
        self.assertEqual((self.output / relative).stat().st_mode & 0o777, 0o644)
        self.assertEqual(source.stat().st_mode & 0o777, 0o600)
        self.assertEqual(source.read_bytes(), (self.output / relative).read_bytes())

    def test_rejectsMismatchedVersion(self):
        plist = self.inputs[1] / 'Info.plist'
        value = plistlib.loads(plist.read_bytes())
        value['ApplicationProperties']['CFBundleVersion'] = '23'
        plist.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(ValueError, 'CFBundleVersion'):
            merger.merge(*self.inputs, self.output)

    def test_preservesLibraryProvenanceAndHashesMergedBinary(self):
        for arch, archive in zip(('arm64', 'x86_64'), self.inputs):
            app = archive / 'Products/Applications/Fixture.app'
            libraries = app / 'Contents/Frameworks'
            libraries.mkdir()
            shutil.copy2(app / 'Contents/MacOS/Fixture', libraries / 'fixture.dylib')
            records = app / 'Contents/Resources/ExternalLibraries'
            records.mkdir()
            (records / 'embedded-identities.json').write_text(json.dumps({
                'format': 1, 'libraries': {'fixture.dylib': {'bottle': arch, 'sourceSha256': arch}}}))
        merger.merge(*self.inputs, self.output)
        app = self.output / 'Products/Applications/Fixture.app'
        record = json.loads((app / 'Contents/Resources/ExternalLibraries/embedded-identities.json').read_text())
        identity = record['libraries']['fixture.dylib']
        self.assertEqual(identity['embeddedSha256'], hashlib.sha256((app / 'Contents/Frameworks/fixture.dylib').read_bytes()).hexdigest())
        self.assertEqual(identity['architectures']['x86_64']['sourceSha256'], 'x86_64')
        self.assertEqual(identity['architectures']['arm64']['sourceSha256'], 'arm64')

    def test_rejectsMissingHelper(self):
        (self.inputs[1] / 'Products/Applications/Fixture.app/Contents/Resources/helper').unlink()
        with self.assertRaisesRegex(ValueError, 'only one architecture'):
            merger.merge(*self.inputs, self.output)

    def test_mergesDebugSymbols(self):
        for archive in self.inputs:
            symbols = archive / 'dSYMs/Fixture.app.dSYM'
            if not symbols.exists():
                subprocess.run(['dsymutil', str(archive / 'Products/Applications/Fixture.app/Contents/MacOS/Fixture'),
                                '-o', str(symbols)], check=True)
        merger.merge(*self.inputs, self.output)
        dwarf = self.output / 'dSYMs/Fixture.app.dSYM/Contents/Resources/DWARF/Fixture'
        self.assertEqual(set(subprocess.check_output(['lipo', '-archs', str(dwarf)], text=True).split()),
                         {'arm64', 'x86_64'})

    def test_rejectsDifferentSharedResources(self):
        for archive, text in zip(self.inputs, ('a', 'b')):
            (archive / 'Products/Applications/Fixture.app/Contents/Resources/shared.txt').write_text(text)
        with self.assertRaisesRegex(ValueError, 'resource differs'):
            merger.merge(*self.inputs, self.output)

    def test_generatedSwiftHeaderExposesAPIOnBothArchitectures(self):
        relative = 'Products/Applications/Fixture.app/Contents/Frameworks/Fixture.framework/Headers/Fixture-Swift.h'
        for arch, archive in zip(('arm64', 'x86_64'), self.inputs):
            header = archive / relative
            header.parent.mkdir(parents=True)
            header.write_text('#if 0\n#elif defined(__' + arch + '__) && __' + arch + '__\n'
                              'typedef int FixtureSwiftAPI;\n#endif\n')
        merger.merge(*self.inputs, self.output)
        source = self.work / 'header-client.c'
        source.write_text('FixtureSwiftAPI value;\n')
        for arch in ('arm64', 'x86_64'):
            subprocess.run(['xcrun', 'clang', '-target', arch + '-apple-macos26.0', '-fsyntax-only',
                            '-include', str(self.output / relative), str(source)], check=True)

    def addZipResources(self, contents):
        for archive, content, year in zip(self.inputs, contents, (2025, 2026)):
            path = archive / 'Products/Applications/Fixture.app/Contents/Resources/resources.zip'
            with zipfile.ZipFile(path, 'w') as zipped:
                zipped.writestr(zipfile.ZipInfo('resource.txt', (year, 1, 1, 0, 0, 0)), content)

    def test_acceptsZipTimestampDifferenceWithIdenticalContents(self):
        self.addZipResources(('same', 'same'))
        merger.merge(*self.inputs, self.output)

    def test_rejectsZipPayloadDifference(self):
        self.addZipResources(('first', 'second'))
        with self.assertRaisesRegex(ValueError, 'resource differs'):
            merger.merge(*self.inputs, self.output)


if __name__ == '__main__':
    unittest.main()
