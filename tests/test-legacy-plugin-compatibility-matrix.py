#!/usr/bin/env python3
"""tools/legacy-plugin-compatibility-matrix.py over small synthetic samples.

A legacy SDK, a porting kit that declares one call through
`@compatibility_alias`, plugin API v1 sources with one command placement, and a
collection of plugins: one that makes a covered call and an uncovered one, one
that uses OpenGL, one that uses QTKit, one that only imports OpenGL, one on the
maintainer's list of examples, one whose function the application will take
in natively, one under the GPL, one with a legacy alert and a Carbon
type, and one that imports a header of the legacy SDK the kit does not have
(`<OsiriX/DCM.h>`), and one that looks classes up by name and patches one with the
Objective-C runtime. Checks the band, the missing items with name, area and stage, the stage
labels, the out reasons with file and line, the licence decision, that the kit
is what makes a call covered, and that the converter's report
(tools/port-legacy-plugin.py over the same collection) covers the converter's
items it rewrote and lists, with file and line, the one it could not.

    python3 tests/test-legacy-plugin-compatibility-matrix.py [HOROSPLUGINS_DIR LEGACY_SDK_HEADERS_DIR [PORTED_DIR]]

With the two optional arguments it also runs over the real checkout and checks
the plugin count, that every name of the maintainer's list exists there, and
that every portable plugin, and only those, has a final state; with the third,
the collection of converted plugins kept outside this repository, that every
ported plugin has its project there and no other plugin has one. Exit status 2
when one of them is missing.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools/legacy-plugin-compatibility-matrix.py"
CONVERTER = ROOT / "tools/port-legacy-plugin.py"
SKIPPED = 2

SDK = {
    "PluginFilter.h": """
@class ViewerController;
@interface PluginFilter : NSObject
{
    ViewerController* viewerController;
}
- (long) filterImage: (NSString*) menuName;
@end
""",
    "ViewerController.h": """
@interface ViewerController : NSWindowController
- (NSMutableArray*) pixList;
- (NSMutableArray*) roiList;
@end
""",
    # The umbrella header of the legacy DICOM object framework, which the kit does not have.
    "DCM.h": """
@interface DCMObject : NSObject
@end
""",
    "BrowserController.h": """
@interface BrowserController : NSObject
+ (BrowserController*) currentBrowser;
@end
""",
}

# As in the real kit, the headers sit in Headers and the folder names of the
# legacy SDK reach them through symbolic links in Include (KIT_LINKS).
KIT = {
    "Headers/IsiXLegacyViewerController.h": """
@interface IsiXLegacyViewerController : NSObject
- (NSMutableArray*) pixList;
@end
@compatibility_alias ViewerController IsiXLegacyViewerController;
""",
    "Headers/PluginFilter.h": """
@class IsiXLegacyViewerController;
@interface IsiXLegacyPluginFilter : NSObject
{
    IsiXLegacyViewerController* viewerController;
}
- (long) filterImage: (NSString*) menuName;
@end
@compatibility_alias PluginFilter IsiXLegacyPluginFilter;
""",
    # The kit's lookup by name: NSClassFromString() of a legacy name reaches the kit's class.
    "Headers/IsiXLegacyPrefix.h": """
#define NSClassFromString(name) IsiXLegacyClassFromString(name)
""",
}
KIT_LINKS = {"Include/OsiriXAPI": "../Headers"}

PLUGIN_KIT = {
    "IsiXCommands.swift": """
public struct IsiXCommand {
    public enum Placement: Hashable {
        case imageFilters
    }
    public func run() {
        switch self { case .roiTools: break }
    }
}
""",
}

MIT = """/*
 * Copyright (c) 2020 Example Author
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software, to deal in the Software without restriction (MIT License).
 */
"""
GPL = """/*
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software Foundation.
 */
"""


def plugin(name, source, plugin_type="imageFilter", header=""):
    return {
        "Info.plist": """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>NSPrincipalClass</key><string>Filter</string>
<key>pluginType</key><string>%s</string>
</dict></plist>
""" % plugin_type,
        "Filter.h": header + "#import <OsiriXAPI/PluginFilter.h>\n@interface Filter : PluginFilter\n@end\n",
        "Filter.m": header + '#import "Filter.h"\n@implementation Filter\n' + source + "\n@end\n",
        name + ".xcodeproj/project.pbxproj": """
{ objects = {
  A1 /* %s.osirixplugin */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = "%s.osirixplugin"; sourceTree = BUILT_PRODUCTS_DIR; };
}; }
""" % (name, name),
    }


CALLS = """- (long) filterImage:(NSString*) menuName
{
    NSArray *pixels = [viewerController pixList];
    NSArray *rois = [viewerController roiList];
    return [pixels count] + [rois count];
}"""

COLLECTION = {
    "Covered Filter": plugin("Covered Filter", CALLS, header=MIT),
    "GL Filter": plugin("GL Filter", """- (long) filterImage:(NSString*) menuName
{
    NSOpenGLContext *context = nil;
    glBegin(GL_LINES);
    return 0;
}"""),
    "QT Import": plugin("QT Import", """- (long) filterImage:(NSString*) menuName
{
    QTMovie *movie = [QTMovie movieWithFile: @"a.mov" error: nil];
    return movie != nil;
}""", plugin_type="Database"),
    "Import Only": plugin("Import Only", CALLS.replace("{", "{\n    // glBegin(GL_LINES) in a comment is not a use", 1)),
    "HelloWorld": plugin("HelloWorld", CALLS, header=MIT),
    "GPL Filter": plugin("GPL Filter", CALLS, header=GPL),
    "Invert Data": plugin("Invert Data", CALLS, header=MIT),
    # The maintainer accepted dropping this plugin's QTKit initialisation in the port.
    "DiscPublishing": plugin("DiscPublishing", """- (long) filterImage:(NSString*) menuName
{
    [QTMovie movie];
    return 0;
}""", plugin_type="Database"),
}
COLLECTION["Alert Filter"] = plugin("Alert Filter", """- (long) filterImage:(NSString*) menuName
{
    NSRunAlertPanel(@"T", @"m", nil, nil, nil);
    FSRef ref;
    return 0;
}""")
COLLECTION["Import Only"]["Filter.m"] = "#import <OpenGL/gl.h>\n" + COLLECTION["Import Only"]["Filter.m"]
# Its calls are all covered; only the import of a header of the legacy SDK
# that the kit does not have (line 2) keeps it from compiling.
COLLECTION["DICOM Writer"] = plugin("DICOM Writer", """- (long) filterImage:(NSString*) menuName
{
    return [[viewerController pixList] count];
}""")
COLLECTION["Dynamic Filter"] = plugin("Dynamic Filter", """- (long) filterImage:(NSString*) menuName
{
    Class viewers = NSClassFromString(@"ViewerController");
    Class browser = NSClassFromString(@"BrowserController");
    Method method = class_getInstanceMethod(browser, @selector(currentBrowser));
    return viewers != nil && method != NULL;
}""")
COLLECTION["DICOM Writer"]["Filter.m"] = ('#import "Filter.h"\n#import <OsiriX/DCM.h>\n'
                                          + COLLECTION["DICOM Writer"]["Filter.m"].replace('#import "Filter.h"\n', ""))


def write_tree(base, files):
    for relative, text in files.items():
        path = base / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def fail(message):
    raise SystemExit("FAIL: " + message)


def run(args, timeout=300):
    return subprocess.run([sys.executable, "-I", str(TOOL)] + [str(a) for a in args],
                          capture_output=True, text=True, timeout=timeout)


def row(report, name):
    for entry in report["plugins"]:
        if entry["name"] == name:
            return entry
    fail("plugin %s missing from the matrix" % name)


def gap(entry, name):
    for item in entry["gaps"]:
        if item["name"] == name:
            return item
    fail("%s: no item %s in %s" % (entry["name"], name, [g["name"] for g in entry["gaps"]]))


def synthetic():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for folder, files in (("sdk", SDK), ("kit", KIT), ("v1", PLUGIN_KIT)):
            write_tree(tmp / folder, files)
        for link, target in KIT_LINKS.items():
            (tmp / "kit" / link).parent.mkdir(parents=True, exist_ok=True)
            (tmp / "kit" / link).symlink_to(target)
        collection = tmp / "collection"
        for name, files in COLLECTION.items():
            write_tree(collection / name, files)
        (tmp / "empty-kit").mkdir()
        common = ["--api-headers", tmp / "sdk", "--collection", collection, "--plugin-kit", tmp / "v1",
                  "--stage-issue", "core=STAGE-CORE-LABEL"]
        result = run(common + ["--kit-headers", tmp / "kit", "--json", tmp / "m.json", "--markdown", tmp / "m.md"])
        if result.returncode != 0:
            fail("tool exited %d: %s" % (result.returncode, result.stderr[-2000:]))
        report = json.loads((tmp / "m.json").read_text())
        text = (tmp / "m.md").read_text()

        covered = row(report, "Covered Filter")
        pixels = gap(covered, "ViewerController pixList")
        if not pixels["covered"] or pixels["by"] != "kit":
            fail("call declared by the kit through @compatibility_alias not covered: %s" % pixels)
        rois = gap(covered, "ViewerController roiList")
        if rois["covered"] or rois["area"] != "viewer" or rois["stage"] != "core":
            fail("call without equivalent not reported with its area and stage: %s" % rois)
        plugin_type = gap(covered, "pluginType imageFilter")
        if not plugin_type["covered"] or plugin_type["by"] != "API v1":
            fail("plugin type with a v1 placement not covered: %s" % plugin_type)
        if gap(row(report, "QT Import"), "pluginType Database")["covered"]:
            fail("plugin type without a v1 placement reported as covered")
        if covered["out"] or covered["band"] != "simples" or covered["state"] != "portável, com faltas":
            fail("plugin with core gaps only misclassified: %s %s %s" % (covered["out"], covered["band"],
                                                                         covered["state"]))
        if not covered["licence"]["publishable"]:
            fail("MIT-licensed plugin not publishable: %s" % covered["licence"])
        if "`ViewerController roiList`" not in text or "core (STAGE-CORE-LABEL)" not in text:
            fail("Markdown lacks the missing call or the stage label")

        opengl = row(report, "GL Filter")
        if opengl["out"] != ["depende de OpenGL"] or opengl["band"] != "fora":
            fail("OpenGL use not put out: %s" % opengl["out"])
        evidence = opengl["platforms"]["OpenGL"]["evidence"]
        if not any(e["file"] == "Filter.m" and e["text"] == "glBegin(" for e in evidence):
            fail("OpenGL evidence lacks file and line: %s" % evidence)
        qtkit = row(report, "QT Import")
        if qtkit["out"] != ["depende de QuickTime/QTKit"] or not qtkit["platforms"]["QuickTime/QTKit"]["uses"]:
            fail("QTKit use not put out: %s %s" % (qtkit["out"], qtkit["platforms"]))
        imported = row(report, "Import Only")
        if imported["out"] or imported["platforms"]["OpenGL"] != {
                "uses": 0, "imports": 1, "evidence": imported["platforms"]["OpenGL"]["evidence"]}:
            fail("an OpenGL import without use (or a use in a comment) put the plugin out: %s %s"
                 % (imported["out"], imported["platforms"]))
        planned = row(report, "Invert Data")
        if planned["out"] != ["incorporação prevista"] or planned["state"] != "incorporação prevista":
            fail("plugin planned for native incorporation not kept out: %s %s" % (planned["out"], planned["state"]))
        example = row(report, "HelloWorld")
        if example["out"] != ["exemplo"] or example["state"] != "fora":
            fail("maintainer's list not applied: %s" % example["out"])
        dropped = row(report, "DiscPublishing")
        if dropped["out"] or not dropped["platforms"]["QuickTime/QTKit"]["uses"]:
            fail("a QTKit use the port drops put the plugin out: %s %s" % (dropped["out"], dropped["platforms"]))
        gpl = row(report, "GPL Filter")
        if gpl["licence"]["publishable"] or "GPL" not in gpl["licence"]["counts"]:
            fail("GPL plugin reported as publishable: %s" % gpl["licence"])

        # A header of the legacy SDK is covered when the kit has it at the imported path (through
        # the Include links); one the kit does not have is missing, with file, line and stage.
        imported_kit = gap(covered, "OsiriXAPI/PluginFilter.h")
        if imported_kit["kind"] != "header do SDK" or not imported_kit["covered"]:
            fail("legacy header the kit has through Include not covered: %s" % imported_kit)
        writer = row(report, "DICOM Writer")
        dcm = gap(writer, "OsiriX/DCM.h")
        if (dcm["kind"], dcm["covered"], dcm["stage"]) != ("header do SDK", False, "database") or \
                dcm.get("where") != [{"file": "Filter.m", "line": 2}]:
            fail("legacy header the kit lacks not reported with file, line and stage: %s" % dcm)
        if writer["state"] != "portável, com faltas" or [g["name"] for g in writer["gaps"] if not g["covered"]] \
                != ["OsiriX/DCM.h"]:
            fail("plugin whose only gap is a legacy header shown without it: %s %s" % (writer["state"],
                                                                                    writer["gaps"]))
        if "`OsiriX/DCM.h` (header do SDK, " not in text or "em `Filter.m:2`" not in text:
            fail("Markdown lacks the missing legacy header with its file and line")

        # With the kit's divert, a lookup by name of a class the kit has is covered; the rest of the
        # dynamic access stays missing with the reason.
        dynamic = row(report, "Dynamic Filter")
        viewers = gap(dynamic, 'NSClassFromString(@"ViewerController")')
        browser = gap(dynamic, 'NSClassFromString(@"BrowserController")')
        runtime = gap(dynamic, "objc runtime")
        if not viewers["covered"] or viewers["stage"] != "dynamic":
            fail("lookup by name of a kit class not covered by the divert: %s" % viewers)
        if browser["covered"] or "nunca a classe do app" not in browser.get("reason", ""):
            fail("lookup by name of a class without equivalent lacks its reason: %s" % browser)
        if runtime["covered"] or "o desvio entrega as do kit" not in runtime.get("reason", ""):
            fail("Objective-C runtime use lacks its reason: %s" % runtime)
        if "`NSClassFromString(@\"BrowserController\")` (acesso dinâmico, Banco; motivo: " not in text:
            fail("Markdown lacks the reason of a dynamic item")

        counts = report["summary"]
        if (counts["plugins"], counts["portable"], counts["out"], counts["ported"]) != (11, 7, 4, 0):
            fail("counting base wrong: %s" % {k: counts[k] for k in ("plugins", "portable", "out", "ported")})
        if counts["publishable"] != ["Covered Filter"]:
            fail("publishable list wrong: %s" % counts["publishable"])

        # Without the converter's report its items are missing; with it, what it rewrote is covered
        # and what it could not rewrite stays, with file and line.
        alert = row(report, "Alert Filter")
        if gap(alert, "legacy-alert/sheet")["covered"] or gap(alert, "Carbon")["covered"] or alert["converter"]:
            fail("converter items covered without the converter's report: %s" % alert["gaps"])
        converted = subprocess.run([sys.executable, "-I", str(CONVERTER), "--collection", collection,
                                    "--report", tmp / "converter.json"], capture_output=True, text=True, timeout=300)
        if converted.returncode != 0:
            fail("converter exited %d: %s" % (converted.returncode, converted.stderr[-2000:]))
        result = run(common + ["--kit-headers", tmp / "kit", "--converter-report", tmp / "converter.json",
                               "--json", tmp / "c.json", "--markdown", tmp / "c.md"])
        if result.returncode != 0:
            fail("tool exited %d with the converter's report: %s" % (result.returncode, result.stderr[-2000:]))
        with_converter = json.loads((tmp / "c.json").read_text())
        alert = row(with_converter, "Alert Filter")
        rewritten, carbon = gap(alert, "legacy-alert/sheet"), gap(alert, "Carbon")
        if not rewritten["covered"] or rewritten["by"] != "conversor" or carbon["covered"]:
            fail("converter's report not applied: %s %s" % (rewritten, carbon))
        if alert["converter"]["rewrites"] != {"legacy-alert/sheet": 1} or alert["converter"]["left"] != [
                {"category": "Carbon", "file": "Sources/Filter.m", "line": 6, "text": "FSRef ref;"}]:
            fail("converter summary wrong: %s" % alert["converter"])
        if "Carbon `Sources/Filter.m:6` `FSRef ref;`" not in (tmp / "c.md").read_text():
            fail("Markdown lacks what the converter left, with file and line")
        result = run(common + ["--converter-report", tmp / "absent.json"])
        if result.returncode != SKIPPED:
            fail("missing converter report should exit 2, got %d" % result.returncode)

        # The collection of converted plugins: a project per folder, named by its source.json.
        ported = tmp / "ported" / "CoveredModule" / "Porting"
        ported.mkdir(parents=True)
        (ported / "source.json").write_text(json.dumps({"folder": "Covered Filter"}))
        (ported / "hand-fixes.diff").write_text("--- a/CoveredModule/Sources/Filter.m\n+++ b/CoveredModule/Sources/Filter.m\n"
                                                "@@ -1 +1 @@\n-x\n+y\n")
        result = run(common + ["--kit-headers", tmp / "kit", "--ported-projects", tmp / "ported",
                               "--json", tmp / "p.json", "--markdown", tmp / "p.md"])
        if result.returncode != 0:
            fail("tool exited %d with the converted plugins: %s" % (result.returncode, result.stderr[-2000:]))
        with_ported = json.loads((tmp / "p.json").read_text())
        if row(with_ported, "Covered Filter").get("project") != {"module": "CoveredModule", "handFixedFiles": 1}:
            fail("converted project not found: %s" % row(with_ported, "Covered Filter").get("project"))
        if with_ported["ported_projects"]["unexpected"] != ["Covered Filter"] or with_ported["ported_projects"]["missing"]:
            fail("a project of a plugin not ported is not reported: %s" % with_ported["ported_projects"])
        if "| Covered Filter | portável, com faltas | — | `CoveredModule` | 1 arquivo(s) |" not in (tmp / "p.md").read_text():
            fail("Markdown lacks the converted project of the final states")
        result = run(common + ["--ported-projects", tmp / "absent-ported"])
        if result.returncode != SKIPPED:
            fail("missing converted plugins should exit 2, got %d" % result.returncode)

        # Without the kit the same call is missing: coverage comes from the kit's declarations.
        result = run(common + ["--kit-headers", tmp / "empty-kit", "--json", tmp / "n.json", "--markdown", tmp / "n.md"])
        if result.returncode != 0:
            fail("tool exited %d without a kit: %s" % (result.returncode, result.stderr[-2000:]))
        bare = json.loads((tmp / "n.json").read_text())
        if gap(row(bare, "Covered Filter"), "ViewerController pixList")["covered"]:
            fail("call covered without any kit declaration")
        if gap(row(bare, "Covered Filter"), "OsiriXAPI/PluginFilter.h")["covered"]:
            fail("legacy header covered without any kit header")
        # Without the divert the lookup by name finds the application's class: missing, and no reason.
        undiverted = gap(row(bare, "Dynamic Filter"), 'NSClassFromString(@"ViewerController")')
        if undiverted["covered"] or "reason" in undiverted:
            fail("lookup by name covered or explained without the kit's divert: %s" % undiverted)

        result = run(["--api-headers", tmp / "sdk", "--collection", tmp / "absent"])
        if result.returncode != SKIPPED:
            fail("missing collection should exit 2, got %d" % result.returncode)
    print("PASS: matrix classifies covered, uncovered, OpenGL and QTKit samples")


def real_checkout(collection, headers, ported=None):
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "matrix.json"
        result = run(["--api-headers", headers, "--collection", collection, "--json", out,
                      "--markdown", Path(tmp) / "matrix.md"] + (["--ported-projects", ported] if ported else []),
                     timeout=600)
        if result.returncode != 0:
            fail("tool exited %d on the checkout: %s" % (result.returncode, result.stderr[-2000:]))
        report = json.loads(out.read_text())
    names = {entry["name"] for entry in report["plugins"]}
    spec = importlib.util.spec_from_file_location("legacy_plugin_matrix", TOOL)
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    absent = sorted(set(tool.EPIC_REASON) - names)
    if absent:
        fail("names of the maintainer's list not found in the checkout: %s" % absent)
    if report["summary"]["plugins"] != 81:
        fail("expected 81 plugins in horosplugins, got %d" % report["summary"]["plugins"])
    listed = [entry for entry in report["plugins"] if entry["name"] in tool.EPIC_REASON]
    if any(not entry["out"] or entry["state"] in (tool.VERIFIED, tool.UNCHECKED) or entry["out"][0] != tool.EPIC_REASON[entry["name"]]
           for entry in listed):
        fail("a plugin of the maintainer's list is not out")
    # Every portable plugin ends in a final state, and only portable plugins have one.
    portable = {entry["name"] for entry in report["plugins"] if entry["plugin"] and not entry["out"]}
    if set(tool.FINAL) != portable:
        fail("final states and portable plugins differ: %s" % sorted(set(tool.FINAL) ^ portable))
    if any(entry["state"] != tool.FINAL[entry["name"]][0] for entry in report["plugins"] if entry["name"] in portable):
        fail("a portable plugin is not in its final state")
    if report["summary"]["ported"] != len(tool.PORTED):
        fail("ported %d, final states %d" % (report["summary"]["ported"], len(tool.PORTED)))
    if ported:
        found = report["ported_projects"]
        if found["missing"] or found["unexpected"]:
            fail("converted plugins: without a project %s, not ported %s" % (found["missing"], found["unexpected"]))
    print("PASS: matrix over the horosplugins checkout: %d plugins, %d portable, %d out, %d ported%s"
          % (report["summary"]["plugins"], report["summary"]["portable"], report["summary"]["out"],
             report["summary"]["ported"], ", each with its converted project" if ported else ""))


def main():
    if not TOOL.is_file():
        fail("tools/legacy-plugin-compatibility-matrix.py is missing")
    synthetic()
    if len(sys.argv) > 1:
        if len(sys.argv) not in (3, 4):
            fail("usage: %s [HOROSPLUGINS_DIR LEGACY_SDK_HEADERS_DIR [PORTED_DIR]]" % sys.argv[0])
        collection, headers = Path(sys.argv[1]), Path(sys.argv[2])
        ported = Path(sys.argv[3]) if len(sys.argv) == 4 else None
        if not collection.is_dir() or not headers.is_dir() or (ported and not ported.is_dir()):
            print("SKIP: horosplugins checkout, legacy SDK headers or converted plugins missing: %s %s %s"
                  % (collection, headers, ported or ""))
            sys.exit(SKIPPED)
        real_checkout(collection, headers, ported)


if __name__ == "__main__":
    main()
