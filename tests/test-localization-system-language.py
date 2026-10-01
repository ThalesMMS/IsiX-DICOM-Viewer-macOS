#!/usr/bin/env python3
"""System language aliases, project resource membership and optional built bundle."""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / "Horos/Info.plist").read_bytes())
assert info.get("CFBundleDevelopmentRegion") == "en"
languages = ("en", "es", "it-IT", "ja-JP", "pt-BR", "fr", "de", "ko", "hi", "ar", "ru", "zh-Hans")
new_languages = languages[4:]
for language in languages:
    assert (root / "Horos/Resources" / (language + ".lproj")).is_dir(), language

# Every translated XIB belongs to its existing variant group and the host's
# Resources phase. Preference controllers are compiled into the host target;
# their XIBs live there too, even when their source path is under PreferencePanes.
project = json.loads(subprocess.check_output([
    "plutil", "-convert", "json", "-o", "-", str(root / "Horos.xcodeproj/project.pbxproj")]))
objects = project["objects"]
host = next(o for o in objects.values() if o.get("isa") == "PBXNativeTarget" and o["name"] == "Horos")
resource_refs = {objects[f]["fileRef"] for phase in host["buildPhases"]
                 if objects[phase]["isa"] == "PBXResourcesBuildPhase" for f in objects[phase]["files"]}
variants = {o["name"]: (identifier, o) for identifier, o in objects.items()
            if o.get("isa") == "PBXVariantGroup"}
regions = objects[project["rootObject"]]["knownRegions"]
for language in new_languages:
    assert language in regions, language
    folder = root / "Horos/Resources" / (language + ".lproj")
    files = list(folder.rglob("*.xib")) + list(folder.glob("*.strings"))
    assert len(files) == 65, (language, len(files))
    for path in files:
        # Xcode recognizes a localized build input from its immediate .lproj
        # parent. Nested preference paths compile into unlocalized Resources.
        assert path.parent == folder, (language, path.name, "localized resource must be directly inside .lproj")
        identifier, variant = variants[path.name]
        assert identifier in resource_refs, (language, path.name, "not built")
        children = [objects[c] for c in variant["children"] if objects[c].get("name") == language]
        assert len(children) == 1, (language, path.name, "missing/duplicate")
        child = children[0]
        assert child["sourceTree"] == "SOURCE_ROOT"
        assert (root / child["path"]).resolve() == path.resolve(), child

for language in languages[1:]:
    subprocess.run([sys.executable, str(root / "tools/localize-main-menu.py"),
                    "--check", "--language", language], check=True)

# Set HOROS_TEST_BUNDLE, or pass a path, after integration to verify real
# compiled resources. The normal focused run validates native lookup and the
# project graph without claiming that a host build has happened.
bundle_path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("HOROS_TEST_BUNDLE")
if bundle_path:
    resources = Path(bundle_path) / "Contents/Resources"
    for language in new_languages:
        locale = resources / (language + ".lproj")
        for path in (root / "Horos/Resources" / (language + ".lproj")).rglob("*.xib"):
            assert (locale / (path.stem + ".nib")).exists(), (language, path.name)
        compiled = locale / "Localizable.strings"
        assert compiled.is_file(), (language, compiled)
        source = root / "Horos/Resources" / (language + ".lproj/Localizable.strings")
        def catalog(path):
            return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
        assert catalog(compiled) == catalog(source), (language, "compiled catalog differs")
    print("PASS: all eight languages have their 64 compiled nibs and complete catalogs in the host bundle")

# Native product lookup also honors historical Base fallback where the project
# declares no translation (es/it preference panes). A declared translation may
# never fall back: the compiled resource checks above remain mandatory.
native_nibs = ("MainMenu", "OSIGeneralPreferencePanePref", "OSILocationsPreferencePanePref")
native_declared = "@{" + ",".join(
    '@"' + nib + '":@[' + ','.join('@"' + objects[c]['name'] + '"' for c in variants[nib + '.xib'][1]['children']) + ']'
    for nib in native_nibs) + "}"

with tempfile.TemporaryDirectory(prefix="horos-system-language-") as folder:
    probe = Path(folder) / "Probe.app/Contents"
    resources = probe / "Resources"
    for language in (*languages, "Base"):
        locale = resources / (language + ".lproj")
        locale.mkdir(parents=True)
        # Test lookup of main UI and preference UI with the same bundle layout.
        (locale / "MainMenu.nib").write_text("lookup fixture")
        (locale / "OSIGeneralPreferencePanePref.nib").write_text("lookup fixture")
        (locale / "OSILocationsPreferencePanePref.nib").write_text("lookup fixture")
    (probe / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.horosproject.language-probe",
        "CFBundleDevelopmentRegion": "en",
    }))
    source = Path(folder) / "test.m"
    source.write_text(r'''
#import <Foundation/Foundation.h>
int main(int argc, char **argv) {@autoreleasepool {
    BOOL builtProduct = argc > 2;
    NSDictionary *declared = DECLARED;
    NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSArray *packaged = bundle.localizations;
    NSDictionary *aliases = @{@"es-ES":@"es", @"it-IT":@"it-IT", @"ja-JP":@"ja-JP",
        @"pt-BR":@"pt-BR", @"fr-FR":@"fr", @"de-DE":@"de", @"ko-KR":@"ko",
        @"hi-IN":@"hi", @"ar-SA":@"ar", @"ru-RU":@"ru", @"zh-CN":@"zh-Hans", @"zh-Hans":@"zh-Hans"};
    for (NSString *alias in aliases) {
        NSString *expected = aliases[alias];
        NSArray *resolved = [NSBundle preferredLocalizationsFromArray:packaged forPreferences:@[alias]];
        if (![resolved.firstObject isEqual:expected]) {
            NSLog(@"FAIL resolve %@: %@ expected %@", alias, resolved, expected); return 1;
        }
        for (NSString *nib in @[@"MainMenu", @"OSIGeneralPreferencePanePref", @"OSILocationsPreferencePanePref"]) {
            NSString *resourceLanguage = expected;
            if (builtProduct && ![declared[nib] containsObject:expected]) {
                resourceLanguage = [declared[nib] containsObject:@"Base"] ? @"Base" : @"en";
            }
            NSString *path = [bundle pathForResource:nib ofType:@"nib" inDirectory:nil forLocalization:resourceLanguage];
            if (![path containsString:[resourceLanguage stringByAppendingString:@".lproj/"]]) {
                NSLog(@"FAIL lookup %@ (%@): %@ expected %@", nib, expected, path, resourceLanguage);
                return 1;
            }
        }
    }
    // Unsupported preferences keep the English development fallback available.
    if (![packaged containsObject:@"en"] || ![bundle.developmentLocalization isEqual:@"en"]) return 1;
    NSLog(@"PASS: regional aliases resolve and declared main/preference resource languages are packaged");
}}
'''.replace('DECLARED', native_declared))
    executable = Path(folder) / "test"
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                    str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(probe.parent)], check=True)
    if bundle_path:
        subprocess.run([str(executable), str(Path(bundle_path).resolve()), "built-product"], check=True)
