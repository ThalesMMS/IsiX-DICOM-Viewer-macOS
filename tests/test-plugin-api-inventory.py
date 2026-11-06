#!/usr/bin/env python3
"""tools/inventory-plugin-api.py over a tiny synthetic SDK and plugin collection.

Checks the host model (classes, comma-separated properties, anonymous selector
parts, deprecation, notifications), typed and inherited receivers, overrides,
ivars, KVC keys, dynamic accesses, private host methods, vendored SDK copies,
Info.plist/pbxproj metadata, licence markers, the plugin count of a
collection, Swift sources, and that nothing in the inputs is executed.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools/inventory-plugin-api.py"

HEADERS = {
    "PluginFilter.h": """
#import <Cocoa/Cocoa.h>
@class ViewerController;
@interface PluginFilter : NSObject
{
    ViewerController* viewerController;
}
- (long) filterImage: (NSString*) menuName;
- (void) initPlugin;
- (long) prepareFilter:(ViewerController*) vC;
@end
""",
    "ViewerController.h": """
@class DCMPix, DCMView, ROI;
@interface ViewerController : NSWindowController
- (NSMutableArray*) pixList;
- (NSMutableArray*) roiList;
- (DCMView*) imageView;
- (ROI*) newROI: (long) type;
- (void) setWL:(float) wl WW:(float) ww;
- (NSString*) legacyPath __deprecated;
@end
extern NSString* const OsirixROIChangeNotification;
""",
    "DCMView.h": """
@class DCMPix;
@interface DCMView : NSView
{
    float scaleValue;
}
- (DCMPix*) curDCM;
- (void) setWLWW:(float) wl :(float) ww;
@end
""",
    "DCMPix.h": """
@interface DCMPix : NSObject
@property (nonatomic) long pwidth, pheight;
@property (readonly) double pixelSpacingX;
- (float*) fImage;
@end
""",
    "ROI.h": """
@interface ROI : NSObject
@property (retain) NSString *name;
- (float) roiArea;
@end
""",
    "DicomStudy.h": """
@interface DicomStudy : NSManagedObject
@property (nonatomic, retain) NSString *modality;
@end
""",
    "NSString+N2.h": """
@interface NSString (N2)
- (BOOL) contains:(NSString*) str;
@end
""",
}

MARKER = "INVENTORY-MUST-NOT-RUN"

OBJC_PLUGIN = {
    "Info.plist": """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Sample</string>
<key>NSPrincipalClass</key><string>SampleFilter</string>
<key>pluginType</key><string>roiTool</string>
<key>MenuTitles</key><array><string>Sample Tool</string></array>
</dict></plist>
""",
    "SampleFilter.h": """/*
 * Copyright (c) 2010 Example Author
 * Distributed under GNU - LGPL
 */
#import "OsiriXAPI/PluginFilter.h"
#import "OsiriXAPI/RemovedHeader.h"
@interface SampleFilter : PluginFilter
@end
@interface ViewerController (SamplePrivate)
- (void) privateRefresh;
@end
""",
    "SampleFilter.m": """/*
 * Copyright (c) 2010 Example Author
 * Distributed under GNU - LGPL
 */
#import "SampleFilter.h"
#import <QTKit/QTKit.h>
@implementation SampleFilter
- (void) initPlugin { }
- (long) filterImage:(NSString*) menuName
{
    DCMPix *pix = [[viewerController pixList] objectAtIndex: 0];
    long w = [pix pwidth];
    ROI *roi = [viewerController newROI: 5];
    [roi setName: @"area"];
    [[viewerController imageView] setWLWW: 40 : 400];
    [viewerController setWL: 40 WW: 400];
    [viewerController legacyPath];
    [viewerController removedSelector: 3];
    [viewerController privateRefresh];
    id study = nil;
    NSString *m = [study valueForKey: @"modality"];
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(roiChanged:) name: OsirixROIChangeNotification object: nil];
    Class c = NSClassFromString(@"DicomStudy");
    [self performSelector: @selector(initPlugin)];
    [roi release];
    NSRunAlertPanel(@"t", @"m", nil, nil, nil);
    return w;
}
@end
""",
    "Sample.xcodeproj/project.pbxproj": """
// !$*UTF8*$!
{ objects = {
  A1 /* Sample.osirixplugin */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = Sample.osirixplugin; sourceTree = BUILT_PRODUCTS_DIR; };
  A2 /* OsiriX.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; path = OsiriX.framework; sourceTree = "<group>"; };
  B1 = {isa = XCBuildConfiguration; buildSettings = {
     ARCHS = "$(ARCHS_STANDARD_32_64_BIT)";
     VALID_ARCHS = "i386 ppc";
     SDKROOT = macosx10.5;
     GCC_ENABLE_OBJC_GC = supported;
     WRAPPER_EXTENSION = osirixplugin;
     OTHER_LDFLAGS = ("-undefined", dynamic_lookup);
  }; name = Release; };
}; }
""",
    # A copied SDK: reported as vendored, never read as plugin source.
    "OsiriX Headers/ViewerController.h": "@interface ViewerController : NSObject\n- (void) vendoredOnly;\n@end\n",
    "build.sh": "#!/bin/sh\ntouch \"$1/" + MARKER + "\"\n",
}

SWIFT_PLUGIN = {
    "Info.plist": """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>pluginType</key><string>Database</string>
<key>MenuTitles</key><array><string>Settings</string></array>
</dict></plist>
""",
    "Plugin.swift": """import Foundation

class SwiftSample: PluginFilter {
    override func filterImage(_ menuName: String!) -> Int {
        let study: DicomStudy? = nil
        _ = study?.value(forKey: "modality")
        let roi = ROI()
        _ = roi.roiArea()
        return 0
    }
}
""",
    "Bridging-Header.h": "#import <OsiriXAPI/PluginFilter.h>\n",
    "Swift.xcodeproj/project.pbxproj": """
{ objects = {
  C1 /* SwiftSample.osirixplugin */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = SwiftSample.osirixplugin; sourceTree = BUILT_PRODUCTS_DIR; };
  C2 = {isa = XCBuildConfiguration; buildSettings = { SWIFT_OBJC_BRIDGING_HEADER = "Bridging-Header.h"; WRAPPER_EXTENSION = osirixplugin; }; name = Debug; };
}; }
""",
}

APP_PROJECT = {
    "main.m": "int main(void) { return 0; }\n",
    "Tool.xcodeproj/project.pbxproj": """
{ objects = {
  D1 /* Tool.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; path = Tool.app; sourceTree = BUILT_PRODUCTS_DIR; };
}; }
""",
}


def write_tree(base, files):
    for relative, text in files.items():
        path = base / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def fail(message):
    raise SystemExit("FAIL: " + message)


def by_name(report, name):
    for plugin in report["plugins"]:
        if plugin["name"] == name:
            return plugin
    fail("plugin %s missing from %s" % (name, [p["name"] for p in report["plugins"]]))


def selectors(plugin):
    return {(e["class"], e["selector"], e["how"]) for e in plugin["selectors"]}


def main():
    if not TOOL.is_file():
        fail("tools/inventory-plugin-api.py is missing")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        write_tree(tmp / "sdk", HEADERS)
        collection = tmp / "collection"
        write_tree(collection / "Sample", OBJC_PLUGIN)
        write_tree(collection / "_grouped/Swift Sample", SWIFT_PLUGIN)
        write_tree(collection / "_grouped/App", APP_PROJECT)
        (collection / "_docs").mkdir(parents=True)
        (collection / "_docs/manual.txt").write_text("not a plugin\n")
        out_md, out_json = tmp / "out.md", tmp / "out.json"
        result = subprocess.run([sys.executable, "-I", str(TOOL), "--api-headers", str(tmp / "sdk"),
                                 "--collection", "synthetic=%s" % collection,
                                 "--plugin", "Single=%s" % (collection / "Sample/SampleFilter.m"),
                                 "--markdown", str(out_md), "--json", str(out_json)],
                                capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            fail("tool exited %d: %s" % (result.returncode, result.stderr[-2000:]))
        if (collection / "Sample" / MARKER).exists() or any(tmp.rglob(MARKER)):
            fail("the tool executed a script from the input")
        report = json.loads(out_json.read_text())
        text = out_md.read_text()

        counts = report["sources"][0]["counts"]
        if counts["plugins"] != 2 or counts["products"] != 2:
            fail("expected 2 plugin projects and 2 products, got %s" % counts)
        if counts["no_source_names"] != ["_docs"]:
            fail("folder without sources not reported: %s" % counts)
        if not any(entry.startswith("_grouped/App") for entry in counts["not_plugins"]):
            fail("app project counted as plugin: %s" % counts)
        if report["sdk"]["classes"] < 6 or report["sdk"]["notifications"] != 1:
            fail("SDK model incomplete: %s" % report["sdk"])

        sample = by_name(report, "Sample")
        found = selectors(sample)
        expected = {("ViewerController", "pixList", "typed"),          # inherited ivar receiver
                    ("DCMPix", "pwidth", "typed"),                     # comma-separated property
                    ("ViewerController", "newROI:", "typed"),
                    ("ROI", "setName:", "typed"),                      # typed through a local variable
                    ("DCMView", "setWLWW::", "typed"),                 # return type + anonymous part
                    ("ViewerController", "setWL:WW:", "typed"),
                    ("PluginFilter", "filterImage:", "override"),
                    ("PluginFilter", "initPlugin", "override")}
        missing = expected - found
        if missing:
            fail("selectors not found: %s (found %s)" % (sorted(missing), sorted(found)))
        if any(s == "vendoredOnly" for _, s, _ in found):
            fail("vendored SDK copy was scanned as plugin source")
        if {"class": "ViewerController", "selector": "removedSelector:", "refs": 1} not in sample["selectors_not_in_sdk"]:
            fail("selector missing from the SDK not reported: %s" % sample["selectors_not_in_sdk"])
        if not any(e["selector"] == "privateRefresh" for e in sample["host_methods_declared_by_plugin"]):
            fail("private category method not reported")
        if not any(e["selector"] == "legacyPath" for e in sample["deprecated_in_sdk"]):
            fail("deprecated host method not reported")
        if not any(e["name"] == "viewerController" and e["how"] == "inherited" for e in sample["ivars_and_attributes"]):
            fail("inherited ivar not reported")
        if not any(e["key"] == "modality" and "DicomStudy" in e["host_classes"] for e in sample["kvc_keys"]):
            fail("KVC key not mapped: %s" % sample["kvc_keys"])
        if not any(e["name"] == "OsirixROIChangeNotification" for e in sample["notifications"]):
            fail("notification not reported")
        for kind in ("NSClassFromString", "performSelector", "@selector/#selector", "KVC"):
            if kind not in sample["dynamic"]:
                fail("dynamic access %s not reported: %s" % (kind, sample["dynamic"]))
        if not any(e["kind"] == "class" and e["literal"] == "DicomStudy" for e in sample["dynamic_literals"]):
            fail("NSClassFromString literal not resolved")
        for kind in ("QuickTime/QTKit", "manual-retain-release", "legacy-alert/sheet", "garbage-collection"):
            if kind not in sample["obsolete"]:
                fail("obsolete API %s not reported: %s" % (kind, sample["obsolete"]))
        if "OsiriXAPI/RemovedHeader.h" not in sample["host_headers_missing_from_sdk"]:
            fail("host header missing from the SDK not reported")
        if not any(v["path"] == "OsiriX Headers" for v in sample["vendored"]):
            fail("vendored SDK copy not listed: %s" % sample["vendored"])
        if sample["subclasses_of_host"] != [{"class": "SampleFilter", "host_super": "PluginFilter", "refs": 1}]:
            fail("subclass not reported: %s" % sample["subclasses_of_host"])
        if "ViewerController" not in [e["class"] for e in sample["categories_on_host"]]:
            fail("category on a host class not reported")
        if sample["plists"][0].get("pluginType") != "roiTool" or sample["plugin_products"] != ["Sample.osirixplugin"]:
            fail("plist/product metadata wrong: %s %s" % (sample["plists"], sample["plugin_products"]))
        if not {"i386", "ppc"} <= set(sample["archs"]):
            fail("architectures not read: %s" % sample["archs"])
        settings = sample["projects"][0]["settings"]
        if settings.get("OTHER_LDFLAGS") != ["-undefined dynamic_lookup"] or "macosx10.5" not in settings.get("SDKROOT", []):
            fail("build settings not read: %s" % settings)
        if not sample["redistribution"].startswith("permitida (LGPL"):
            fail("licence not read: %s %s" % (sample["redistribution"], sample["licences"]))
        if sample["area_counts"].get("viewer", 0) < 2 or sample["area_counts"].get("roi", 0) < 1:
            fail("area counts wrong: %s" % sample["area_counts"])

        swift = by_name(report, "_grouped/Swift Sample")
        found = selectors(swift)
        if ("PluginFilter", "filterImage:", "override") not in found:
            fail("Swift override not reported: %s" % sorted(found))
        if not any(s == "roiArea" for _, s, _ in found):
            fail("Swift member not matched: %s" % sorted(found))
        if swift["subclasses_of_host"][0]["host_super"] != "PluginFilter":
            fail("Swift subclass not reported")
        if not swift["redistribution"].startswith("pendente"):
            fail("unlicensed sources reported as redistributable")

        single = by_name(report, "Single")
        if ("DCMPix", "pwidth", "typed") not in selectors(single):
            fail("--plugin with a single file not scanned")

        for heading in ("## Limites da análise", "## Resumo por plugin", "### Viewer", "### ROI",
                        "### Acessos dinâmicos/indiretos", "### Sample"):
            if heading not in text:
                fail("Markdown lacks %s" % heading)
    print("PASS: plugin API inventory over synthetic SDK and plugins")


if __name__ == "__main__":
    main()
