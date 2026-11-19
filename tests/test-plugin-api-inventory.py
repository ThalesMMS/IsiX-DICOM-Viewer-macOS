#!/usr/bin/env python3
"""tools/inventory-plugin-api.py over a tiny synthetic SDK and plugin collection.

Checks the host model (classes, comma-separated properties, anonymous selector
parts, deprecation, notifications), typed and inherited receivers, overrides,
ivars, KVC keys, dynamic accesses, private host methods, vendored SDK copies,
Info.plist/pbxproj metadata, licence markers, the plugin count of a
collection, Swift sources, and that nothing in the inputs is executed.

An instance variable of a host class counts as used where a plugin's binary
would look its offset up: read or written by name in a method of a subclass or
of a category of the host's class, or through self->. The same name as a
message ([list count], [self count]), as a part of a selector, as a parameter
or behind a local variable of that name is not the variable. --recount-ivars
writes those counts into a registry's ivars and changes nothing else of it.

--registry writes the registry of the binary surface from a synthetic
baseline (a project, its headers and its sources), the headers of a later SDK,
the listings of a reference application and of a current build, and the
registry there is, of which nothing leaves. An item enters when one SDK had
both its declaration and its definition; what a header and a source hold for
PowerPC alone is not read; a line with a quote it does not close keeps its
newline, so that the lines after it are counted right; a C++ function has the
name the reference gave it; a count only rises; the additions of the later
SDK are what its headers declare and the baseline did not define. In missing,
only what the listings decide and the rules of tests/test-legacy-plugin-abi.py
accept is written: an addition the build lacks, an instance variable no plugin
reads, a selector whose class is listed. The registry written holds those
rules, and written again from itself is the same text.

--export-table-ivars applies to a registry the table of the instance variables
that Swift classes export: an entry of the table leaves missing, one the
registry lacks enters ivars with its count, a variable left in missing with
the reason that Swift has no symbol for a stored property gets the reason that
holds, about says so and names what was added, every other entry is as it
was, and a second run writes the same text. An entry no header declares, or of
a class the registry does not have, is refused and nothing is written. With
--older-sdk-headers, an entry only the copy of an older SDK declares enters
too, and about names it apart; what that copy declares in a class the SDK
does not have, or that the SDK declares as well, changes nothing.
"""
import importlib.util
import json
import re
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
    long count;
    short curImage;
    NSString *yearOld;
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
    # Every form a header gives a datum or a function a plugin looks up by name,
    # and beside them the declarations that have no symbol.
    "Declarations.h": """
#import <Cocoa/Cocoa.h>
#define MacroOnlyName @"macro"
#define EXTERNC extern "C"
typedef struct { float x, y, z; } SampleVector;
typedef struct SampleRun { int fieldOfStruct; long otherField; } SampleRun;
typedef void (*SampleCallback)(int value);
static const int StaticConstantInHeader = 4;
static NSString * const StaticStringInHeader = @"static";

extern NSString * const __deprecated pasteBoardSample;
extern NSString * const pasteBoardAfter __deprecated;
extern NSString *writableSample;
extern NSString * const SampleDeprecatedAttribute DEPRECATED_ATTRIBUTE;
extern NSString * const SampleAttribute __attribute__((deprecated("use another")));
extern NSString * _Nonnull const SampleNonnull;
extern const SampleVector SampleVectorZero;
extern const int32_t SampleTokenNone;
extern const SampleRun SampleRunZero;
extern BOOL SampleFlag;
extern int SAMPLEBARS, SAMPLELINES, SAMPLEMAX;
extern NS_SWIFT_UI_ACTOR BOOL SAMPLEREBUILD, SAMPLECOMPLETE;
extern NSRecursiveLock *SampleLock NS_SWIFT_NONISOLATED_UNSAFE, *SampleStore NS_SWIFT_NONISOLATED_UNSAFE;
extern int sampleSplit[3], sampleCount;
extern const char *sampleText, * const sampleFixedText;
extern short SampleShort;
extern unichar SampleSeparator;
extern const CGFloat SampleFlatness API_AVAILABLE(macos(10.15));
FOUNDATION_EXPORT NSString * const SampleExported;
FOUNDATION_EXTERN NSString * const SampleExternMacro;
APPKIT_EXTERN const CGFloat SampleAppKit;
CF_EXPORT const CFStringRef SampleCoreFoundation;
OBJC_EXTERN NSString * const SampleObjC;
extern NSString * const SampleDidChangeNotification;
extern void (*SampleFunctionPointer)(int value);

extern NSRect sampleFrame(void);
NSString * sampleDocuments(void) __deprecated;
EXTERNC void* sample_decompress(void *data, long size, long *outSize);
extern "C" int sampleLinkage(int value);
static inline float SampleInlineHalf(float v) { return v / 2; }
NS_INLINE float SampleNSInline(float v) { return v; }
CG_INLINE float SampleCGInline(float v) { return v; }

#ifdef __cplusplus
extern "C"
{
#endif
    extern NSString * const SampleInsideBlock;
    extern BOOL SampleInsideFlag;
    NSRect sampleScreenFrame(void);
    NSString * sampleDocumentsFor(int mode, NSString *url) __deprecated;
    CFDictionaryRef SampleCreateDictionary(SampleVector v) CF_RETURNS_RETAINED;
#ifdef __cplusplus
}
#endif

@interface DeclarationsHolder : NSObject
@property (retain) NSString *heldProperty;
extern NSString * const InsideInterface;
@end
""",
    "LinkageOnly.h": """
extern "C" {
}
""",
}

CONSTANTS = {"pasteBoardSample": "NSString * const", "pasteBoardAfter": "NSString * const", "SampleDeprecatedAttribute": "NSString * const",
             "SampleAttribute": "NSString * const", "SampleNonnull": "NSString * const", "SampleVectorZero": "const SampleVector",
             "SampleTokenNone": "const int32_t", "SampleRunZero": "const SampleRun", "sampleFixedText": "const char * const",
             "SampleFlatness": "const CGFloat", "SampleExported": "NSString * const", "SampleExternMacro": "NSString * const",
             "SampleAppKit": "const CGFloat", "SampleCoreFoundation": "const CFStringRef", "SampleObjC": "NSString * const",
             "SampleInsideBlock": "NSString * const"}
GLOBALS = {"writableSample": "NSString *", "SampleFlag": "BOOL", "SAMPLEBARS": "int", "SAMPLELINES": "int",
           "SAMPLEMAX": "int", "SAMPLEREBUILD": "BOOL", "SAMPLECOMPLETE": "BOOL", "SampleLock": "NSRecursiveLock *",
           "SampleStore": "NSRecursiveLock *", "sampleSplit": "int[3]", "sampleCount": "int",
           "sampleText": "const char *", "SampleShort": "short", "SampleSeparator": "unichar",
           "SampleInsideFlag": "BOOL"}
EXPORTED_FUNCTIONS = {"sampleFrame", "sampleDocuments", "sample_decompress", "sampleLinkage", "sampleScreenFrame",
                      "sampleDocumentsFor", "SampleCreateDictionary"}
INLINE_FUNCTIONS = {"SampleInlineHalf", "SampleNSInline", "SampleCGInline"}
# Declared in the header without a symbol of that name in the host.
NOT_DECLARATIONS = {"MacroOnlyName", "EXTERNC", "StaticConstantInHeader", "StaticStringInHeader", "fieldOfStruct",
                    "otherField", "SampleCallback", "SampleFunctionPointer", "heldProperty", "InsideInterface",
                    "SampleVector", "SampleRun", "__deprecated", "DEPRECATED_ATTRIBUTE", "_Nonnull", "const", "C",
                    "NS_SWIFT_UI_ACTOR", "NS_SWIFT_NONISOLATED_UNSAFE", "value", "v", "x"}

# The inputs of the registry of the binary surface: the Horos the fork started
# from, as a project, its headers and its sources; the listings of a reference
# application and of the current build; and the registry there is.
BASELINE = {
    "Project.xcodeproj/project.pbxproj": """
		A1 /* OldClass.m in Sources */ = {isa = PBXBuildFile; fileRef = B1 /* OldClass.m */; };
		A2 /* Cxx.mm in Sources */ = {isa = PBXBuildFile; fileRef = B2 /* Cxx.mm */; };
		A3 /* PublicThing.m in Sources */ = {isa = PBXBuildFile; fileRef = B3 /* PublicThing.m */; };
		A4 /* PublicThing.h in Headers */ = {isa = PBXBuildFile; fileRef = B4 /* PublicThing.h */; settings = {ATTRIBUTES = (Public, ); }; };
		A5 /* PrivateThing.h in Headers */ = {isa = PBXBuildFile; fileRef = B5 /* PrivateThing.h */; };
		A6 /* PrivateThing.m in Sources */ = {isa = PBXBuildFile; fileRef = B6 /* PrivateThing.m */; };
""",
    "Sources/OldClass.h": """
#import <Cocoa/Cocoa.h>
@interface OldClass : NSObject
{
    int kept;
@private
    int hidden;
@public
    float shown;
}
@property int oldProp, otherProp;
@property(readonly) NSString *stalePath __deprecated, *freshPath;
@property(retain) id goneProp NS_UNAVAILABLE;
@property(retain) NSString *managedName;
@property(setter=setTool:) int currentTool;
#pragma mark the class's own methods
- (void) afterPragma;
- (void) oldMethod;
- (void) dealloc;
- (void) neverImplemented;
+ (id) oldFactory;
@end
@interface DCMView : NSOpenGLView
@end
@interface Ghost : NSObject
@end
extern NSString * const OldConstant;
extern int OldGlobal;
extern const float OldVector[3];
extern int OnlyDeclaredGlobal;
#ifdef __cplusplus
extern "C" {
#endif
NSRect oldFunction(void);
void onlyDeclaredFunction(void);
#ifdef __cplusplus
}
#endif
float cxxNowhere(float value);
float cxxInReference(float value);
static inline int oldInline(int v) { return v; }
#if __ppc__ || __ppc64__
extern void onlyPowerPC(int *values, long size);
extern int OnlyPowerPCFlag;
#elif __i386__ || __x86_64__
extern void onlyIntel(int *values, long size);
#else
extern void otherProcessors(int *values, long size);
#endif
#ifdef __ppc__
@interface OnlyPowerPCClass : NSObject
@end
@interface DeclaredForPowerPC : NSObject
@end
#endif
extern void definedForPowerPC(void);
""",
    "Sources/OldClass.m": """
#import "OldClass.h"
static int hiddenStatic = 1;
int OldGlobal = 3;
const float OldVector[3] = {1, 2, 3};
@implementation OldClass
@dynamic managedName;

NSString * const OldConstant = @"old";

- (void) oldMethod { if (hiddenStatic) { [self description]; } }
- (void) afterPragma { }
+ (id) oldFactory;
{
    return nil;
}
@end
@implementation DCMView
@end
NSRect oldFunction(void) { return NSZeroRect; }
static void hiddenFunction(void) { }
#if __ppc__ || __ppc64__
void onlyPowerPC(int *values, long size) { }
int OnlyPowerPCFlag = 1;
#elif __i386__ || __x86_64__
void onlyIntel(int *values, long size) { }
#else
void otherProcessors(int *values, long size) { }
#endif
#ifdef __ppc__
@implementation OnlyPowerPCClass
@end
void definedForPowerPC(void) { }
#endif
// Compiled for every processor, and declared by the header for PowerPC alone.
@implementation DeclaredForPowerPC
@end
// What the baseline compiled and kept out of its headers.
@implementation KeptPrivate
@end
void privateHelper(void) { }
void privateButExported(void) { }
""",
    "Sources/Cxx.mm": """
float cxxNowhere(float value) { return value; }
float cxxInReference(float value) { return value; }
""",
    "Sources/NotCompiled.m": """
@implementation Ghost
@end
int OnlyDeclaredGlobal = 1;
void onlyDeclaredFunction(void) { }
""",
    "Framework/PublicThing.h": """
@interface PublicThing : NSObject
- (int) answer;
@end
""",
    "Framework/PublicThing.m": """
@implementation PublicThing
- (int) answer { return 42; }
@end
""",
    "Framework/PrivateThing.h": """
@interface PrivateThing : NSObject
@end
""",
    "Framework/PrivateThing.m": """
@implementation PrivateThing
@end
""",
}
# What a later SDK declares that the baseline's headers do not, read with the
# other headers of the SDK for the registry alone.
LATER_HEADERS = {
    "Later.h": """
@interface KeptPrivate : NSObject
@end
@interface Reparented : ViewerController
- (void) stillAnswers;
@end
void privateHelper(void);
void privateButExported(void);
float cxxLater(float value);
""",
}
REFERENCE_EXPORTS = """_OBJC_CLASS_$_ViewerController
_OBJC_CLASS_$_DCMPix
_OBJC_CLASS_$_DCMView
_OBJC_CLASS_$_OldClass
_OBJC_IVAR_$_PluginFilter.viewerController
_OsirixROIChangeNotification
_SampleInsideFlag
_sampleFrame
__Z14cxxInReferencef
_privateButExported
__Z8cxxLaterf
"""
REFERENCE_OBJC = """    -- Objective-C Metadata:
        @interface ViewerController : NSWindowController
          0x100  -[ViewerController pixList]
          0x100  -[ViewerController roiList]
        @end
        @interface DCMPix : NSObject
          0x100  -[DCMPix fImage]
        @end
        @interface NSString(Horos)
          0x100  -[NSString contains:]
        @end
"""
CURRENT_EXPORTS = """_OBJC_CLASS_$_ViewerController
_OBJC_CLASS_$_DCMView
_OBJC_CLASS_$_Reparented
_OsirixROIChangeNotification
_OldGlobal
__Z8cxxLaterd
"""
CURRENT_OBJC = """        @interface ViewerController : NSWindowController
          0x100  -[ViewerController pixList]
          0x100  -[ViewerController backSelector]
        @end
        @interface DCMView : NSView
        @end
        @interface Reparented : NSObject
          0x100  -[Reparented stillAnswers]
        @end
"""
REGISTRY_BASE = {
    "about": "the registry there is", "host_resolution": {"flat": "kept as it is"}, "frameworks": {},
    "classes": {"ViewerController": "NSWindowController", "DCMView": "NSView", "Reparented": "ViewerController"},
    "selectors": {"ViewerController -pixList": 0, "ViewerController -goneSelector": 0, "ViewerController -backSelector": 0,
                  "ViewerController -imageView": 9, "Reparented -stillAnswers": 0},
    "used_outside_sdk": {}, "ivars": {}, "symbols": {"_OsirixROIChangeNotification": 0, "_KeptThoughUndeclared": 4},
    "osirix_selectors": {"ViewerController -onlyLaterHeaders:": "Later.h, a header no option of this run reads"},
    "missing": {"selectors ViewerController -goneSelector": "the reason it already had",
                "selectors ViewerController -backSelector": "it was gone when the registry was written",
                "classes Reparented": "its superclass was ViewerController; now its ancestors are NSObject"},
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
    # A category of a host class: yearOld and scaleValue are read as variables.
    # count is only the name of messages, in the category and in a subclass, and
    # a part of a selector, and curImage is a local variable: neither is the
    # host's variable.
    "SampleNumbers.m": """/*
 * Copyright (c) 2010 Example Author
 * Distributed under GNU - LGPL
 */
#import "OsiriXAPI/DCMView.h"
@implementation DCMView (SampleNumbers)
- (NSString *) sampleYear { return yearOld; }
- (long) sampleCount:(NSArray *) list count:(long) limit
{
    short curImage = 0;
    curImage += [list count] + [self count] + [list sampleFrom: curImage count: limit];
    return curImage * self->scaleValue;
}
@end
@interface SampleView : DCMView
@end
@implementation SampleView
- (long) sampleLength:(NSArray *) list { return [list count]; }
@end
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


# A declaration and the selector it declares: a label or an argument's name in
# capitals is part of it, an attribute macro after it is not.
SELECTORS = {
    "importReport:(NSString*) path UID: (NSString*) uid": "importReport:UID:",
    "importReport:(NSString*) path UID:(NSString*) uid error:(NSError**) error": "importReport:UID:error:",
    "writeObject:(id)object AET:(NSString*)aet URL:(NSURL*)url": "writeObject:AET:URL:",
    "setWL:(float) wl WW:(float) ww": "setWL:WW:",
    "setWL:(float) wl WW:(float) ww DEPRECATED_ATTRIBUTE": "setWL:WW:",
    "legacyPath __deprecated": "legacyPath",
    "gone NS_UNAVAILABLE": "gone",
    "old NS_DEPRECATED_MAC(10_0, 10_5)": "old",
    "initWithROI:(ROI*) ROI": "initWithROI:",
    "initWithROI:(ROI*)ROI NS_DESIGNATED_INITIALIZER": "initWithROI:",
    "drawRectIn:(NSRect)r :(float)a :(float)b": "drawRectIn:::",
    "point:(Point3D *)p InVolumeX:(int)x Y:(int)y Z:(int)z": "point:InVolumeX:Y:Z:",
    "save:(id)object XML:(BOOL)XML": "save:XML:",
}


def check_selectors():
    spec = importlib.util.spec_from_file_location("inventory_plugin_api", TOOL)
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    wrong = {declaration: tool.selector_of(declaration) for declaration, selector in SELECTORS.items()
             if tool.selector_of(declaration) != selector}
    if wrong:
        fail("selectors read wrong: %s" % wrong)


def check_registry(tmp):
    """--registry: the registry there is, with what the headers declare and a build or the baseline had."""
    base = tmp / "baseline"
    write_tree(base, BASELINE)
    listings = {"reference.nm": REFERENCE_EXPORTS, "reference.objc": REFERENCE_OBJC,
                "current.nm": CURRENT_EXPORTS, "current.objc": CURRENT_OBJC,
                "registry-base.json": json.dumps(REGISTRY_BASE), "about.txt": "What it is. Left out: {left_out}.\n"}
    write_tree(tmp / "listings", listings)
    write_tree(tmp / "sdk-later", LATER_HEADERS)
    out = tmp / "registry.json"

    def generate(registry_base, written, *about):
        return subprocess.run([sys.executable, "-I", str(TOOL), "--api-headers", str(tmp / "sdk"),
                               "--api-headers", str(tmp / "sdk-later"),
                               "--collection", "synthetic=%s" % (tmp / "collection"), "--markdown", str(tmp / "unused.md"),
                               "--baseline-project", str(base / "Project.xcodeproj/project.pbxproj"),
                               "--baseline-headers", str(base / "Sources"), "--baseline-public-headers", str(base / "Framework"),
                               "--baseline-sources", str(base / "Sources"), "--baseline-sources", str(base / "Framework"),
                               "--reference-exports", str(tmp / "listings/reference.nm"),
                               "--reference-objc", str(tmp / "listings/reference.objc"),
                               "--current-exports", str(tmp / "listings/current.nm"),
                               "--current-objc", str(tmp / "listings/current.objc"),
                               "--registry-base", str(registry_base), "--registry", str(written)] + list(about),
                              capture_output=True, text=True, timeout=120)

    result = generate(tmp / "listings/registry-base.json", out, "--registry-about", str(tmp / "listings/about.txt"))
    if result.returncode != 0:
        fail("--registry exited %d: %s" % (result.returncode, result.stderr[-2000:]))
    text = out.read_text()
    registry = json.loads(text)
    # The text is the one tests/test-legacy-plugin-abi.py requires of the registry.
    spec = importlib.util.spec_from_file_location("legacy_plugin_abi", ROOT / "tests/test-legacy-plugin-abi.py")
    abi = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(abi)
    if text != abi.render(registry):
        fail("the registry written is not in the canonical text of tests/test-legacy-plugin-abi.py")

    def has(section, present, absent):
        wrong = [key for key in present if key not in registry[section]] + ["not " + key for key in absent if key in registry[section]]
        if wrong:
            fail("registry %s wrong: %s (it has %s)" % (section, wrong, sorted(registry[section])[:60]))

    for section, items in REGISTRY_BASE.items():
        # What was missing and is back leaves the missing list; nothing else leaves the registry.
        if section != "missing" and isinstance(items, dict) and set(items) - set(registry[section]):
            fail("the registry lost %s of %s" % (sorted(set(items) - set(registry[section])), section))
    if registry["symbols"]["_KeptThoughUndeclared"] != 4 or registry["host_resolution"] != REGISTRY_BASE["host_resolution"]:
        fail("the registry changed what it already had")
    # A class the baseline compiled or a build exports; not one of a header alone,
    # of a source the project did not compile, or of a header that is not public.
    has("classes", ["OldClass", "PublicThing", "DCMPix", "ViewerController", "DCMView"], ["Ghost", "PrivateThing"])
    if registry["classes"]["OldClass"] != "NSObject" or registry["classes"]["DCMPix"] != "NSObject":
        fail("superclasses wrong: %s" % registry["classes"])
    if registry["classes"]["DCMView"] != "NSView":
        fail("DCMView's superclass of a library that is gone was not kept as it is today: %s" % registry["classes"]["DCMView"])
    has("symbols", ["_OldConstant", "_OldGlobal", "_OldVector", "_oldFunction", "__Z14cxxInReferencef", "_SampleInsideFlag",
                    "_sampleFrame"],
        ["_OnlyDeclaredGlobal", "_onlyDeclaredFunction", "_cxxNowhere", "_cxxInReference", "_oldInline", "_hiddenStatic",
         "_hiddenFunction", "_SampleInlineHalf", "_SampleFlag"])
    # What a header declares and a source defines for PowerPC alone was in no build a plugin loads in;
    # the other branches of the same conditional are read.
    has("symbols", ["_onlyIntel", "_otherProcessors"], ["_onlyPowerPC", "_OnlyPowerPCFlag", "_definedForPowerPC"])
    has("classes", [], ["OnlyPowerPCClass", "DeclaredForPowerPC"])
    # A header and a definition count together when one SDK had both. What the baseline compiled
    # without declaring it, and a later SDK declared, enters when a build of that SDK exported it,
    # and is then no addition of the later SDK; with no such build, no plugin could bind it.
    has("classes", ["Reparented"], ["KeptPrivate"])
    has("symbols", ["_privateButExported"], ["_privateHelper"])
    # A C++ function has the name the reference application gave it: the current
    # build's function of that name with other arguments is another function.
    has("symbols", ["__Z8cxxLaterf"], ["__Z8cxxLaterd", "_cxxLater"])
    # A count the registry has only rises: with the plugins that use the item now, not down to them.
    if registry["selectors"]["ViewerController -pixList"] < 1 or registry["selectors"]["ViewerController -imageView"] != 9:
        fail("use counts wrong: pixList %s (a plugin sends it), imageView %s (it had 9)"
             % (registry["selectors"]["ViewerController -pixList"], registry["selectors"]["ViewerController -imageView"]))
    has("selectors", ["OldClass -oldMethod", "OldClass +oldFactory", "OldClass -oldProp", "OldClass -setOtherProp:",
                      "PublicThing -answer", "DCMPix -fImage", "NSString -contains:", "ViewerController -roiList"],
        ["OldClass -neverImplemented", "ViewerController -legacyPath"])
    has("ivars", ["OldClass.kept", "OldClass.shown", "PluginFilter.viewerController"], ["OldClass.hidden", "DCMView.scaleValue"])
    # What only later headers declare is entered by hand: it is kept with its
    # source though no header given declares it, and is a selector like the others.
    if registry.get("osirix_selectors") != REGISTRY_BASE["osirix_selectors"]:
        fail("the registry did not keep osirix_selectors as its base had it: %s" % registry.get("osirix_selectors"))
    has("selectors", ["ViewerController -onlyLaterHeaders:"], [])
    has("sdk_selectors", [], ["ViewerController -onlyLaterHeaders:"])
    # A list of properties gives each name, without the attribute after it; an
    # unavailable property and one the implementation leaves to the runtime give none.
    has("sdk_selectors", ["OldClass -oldMethod", "OldClass -oldProp", "PublicThing -answer", "OldClass -stalePath",
                          "OldClass -freshPath", "OldClass -currentTool", "OldClass -setTool:", "OldClass -afterPragma"],
        ["DCMPix -fImage", "OldClass -neverImplemented", "OldClass -__deprecated", "OldClass -goneProp",
         "OldClass -NS_UNAVAILABLE", "OldClass -setNS_UNAVAILABLE:", "OldClass -managedName", "OldClass -setManagedName:",
         "OldClass -setCurrentTool:", "OldClass -dealloc"])
    # Where the baseline declared it: the line of the header, also after a block of instance
    # variables and after a line with a quote it does not close, which keeps its own newline.
    for key, declaration in (("OldClass -oldMethod", "- (void) oldMethod;"), ("OldClass -freshPath", "*freshPath;"),
                             ("OldClass -afterPragma", "- (void) afterPragma;")):
        line = next(number for number, text in enumerate(BASELINE["Sources/OldClass.h"].split("\n"), 1) if declaration in text)
        if registry["sdk_selectors"][key] != "OldClass.h:%d" % line:
            fail("sdk_selectors does not say where the baseline declared %s: %s, not line %d" % (key, registry["sdk_selectors"][key], line))
    # What the later SDK added: declared by its headers and not defined by the baseline, each
    # with the header that declares it. A name no header of it declares is not its addition.
    has("isix5_additions", ["classes DCMPix", "classes ViewerController", "classes Reparented", "symbols _SampleInsideFlag",
                            "symbols _OsirixROIChangeNotification", "symbols __Z8cxxLaterf"],
        ["classes OldClass", "classes DCMView", "symbols _OldConstant", "symbols _oldFunction", "symbols __Z14cxxInReferencef",
         "symbols _privateButExported", "symbols _KeptThoughUndeclared"])
    if registry["isix5_additions"]["classes DCMPix"] != "DCMPix.h" or registry["isix5_additions"]["symbols __Z8cxxLaterf"] != "Later.h":
        fail("isix5_additions does not name the header that declares each addition: %s" % registry["isix5_additions"])
    missing = registry["missing"]
    if "selectors ViewerController -backSelector" in missing:
        fail("a selector the current build has again is still listed as missing")
    if missing.get("selectors ViewerController -goneSelector") != "the reason it already had":
        fail("a reason the registry had was rewritten")
    addition = "added by the IsiX 5 SDK: Horos did not define it"
    layout = ": its storage is not yet in the SDK's layout, a stored field of the class with the SDK's type"
    expected = {"classes DCMPix": addition, "symbols _SampleInsideFlag": addition, "symbols __Z8cxxLaterf": addition,
                # A class that is there under another superclass is not the SDK's class: it stays listed.
                "classes Reparented": addition,
                "selectors DCMPix -fImage": "its class is missing (classes DCMPix)",
                "ivars OldClass.kept": "OldClass exports no _OBJC_IVAR_$_ symbol for it" + layout}
    wrong = {key: missing.get(key) for key, reason in expected.items() if missing.get(key) != reason}
    if wrong:
        fail("missing wrong: %s" % wrong)
    # A class or a symbol of the baseline that the current build lacks is not excused, nor what
    # waits for it; nor a selector of a class that is there, which the listings cannot decide: the
    # test of the registry reports those, and no reason is written for them here. A class that is
    # there under another superclass still answers its selectors. An instance variable a plugin
    # reads is not excused either.
    excused = [key for key in ("classes OldClass", "classes PublicThing", "symbols _OldConstant", "symbols _oldFunction",
                               "selectors ViewerController -pixList", "symbols _OldGlobal", "selectors OldClass -oldMethod",
                               "selectors ViewerController -roiList", "symbols _privateButExported",
                               "selectors Reparented -stillAnswers", "ivars PluginFilter.viewerController") if key in missing]
    if excused:
        fail("listed as missing: %s" % excused)
    for words in ("1 C++ functions of the baseline whose mangled name no build has",
                  "1 instance variables that were @private or @package", "Left out:",
                  "1 classes the baseline compiled and kept out of its headers, which the later SDK declared and no build of it "
                  "exported",
                  "1 names the baseline defined and kept out of its headers, which the later SDK declared and no build of it "
                  "exported"):
        if words not in registry["about"]:
            fail("about does not say %r: %s" % (words, registry["about"]))
    # What is written holds the rules the test of the binary surface has for the registry's own text.
    refused = abi.shape_problems(registry, text) + abi.missing_problems(registry)
    if refused:
        fail("the registry written does not hold the rules of tests/test-legacy-plugin-abi.py: %s" % refused[:6])
    # Written again from itself, with no about given, it is the same text: the sentence of what
    # was left out is the one part of about that is derived.
    again = tmp / "registry-again.json"
    result = generate(out, again)
    if result.returncode != 0 or again.read_text() != text:
        fail("a second run over the registry written changed it (exit %d): %s" % (result.returncode, result.stderr[-1000:]))
    # A registry whose about has no such sentence needs the text of its about.
    result = generate(tmp / "listings/registry-base.json", again)
    if result.returncode == 0 or "--registry-about" not in result.stderr:
        fail("--registry without --registry-about was expected to refuse a registry whose about has no \"Left out:\" sentence")


def check_recount(tmp):
    """--recount-ivars: the use counts of ivars from the plugins scanned, and the rest of the registry as it was."""
    registry = {"about": "what it is", "classes": {"DCMView": "NSView"}, "selectors": {"DCMView -curDCM": 7},
                "ivars": {"DCMView.yearOld": 0, "DCMView.count": 5, "DCMView.scaleValue": 0, "DCMView.curImage": 2,
                          "PluginFilter.viewerController": 0, "DCMView.notInTheHeaders": 3},
                "missing": {"ivars DCMView.count": "the reason it has"}}
    path = tmp / "recount.json"
    path.write_text(json.dumps(registry))
    result = subprocess.run([sys.executable, "-I", str(TOOL), "--api-headers", str(tmp / "sdk"),
                             "--collection", "synthetic=%s" % (tmp / "collection"), "--markdown", str(tmp / "unused.md"),
                             "--recount-ivars", str(path)], capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        fail("--recount-ivars exited %d: %s" % (result.returncode, result.stderr[-2000:]))
    text = path.read_text()
    written = json.loads(text)
    expected = {"DCMView.yearOld": 1, "DCMView.count": 0, "DCMView.scaleValue": 1, "DCMView.curImage": 0,
                "PluginFilter.viewerController": 1, "DCMView.notInTheHeaders": 0}
    if written["ivars"] != expected:
        fail("--recount-ivars wrote %s, not %s" % (written["ivars"], expected))
    if {key: value for key, value in written.items() if key != "ivars"} != {key: value for key, value in registry.items() if key != "ivars"}:
        fail("--recount-ivars changed something else of the registry")
    spec = importlib.util.spec_from_file_location("legacy_plugin_abi", ROOT / "tests/test-legacy-plugin-abi.py")
    abi = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(abi)
    if text != abi.render(written):
        fail("--recount-ivars did not write the canonical text of tests/test-legacy-plugin-abi.py")


def check_export_table_ivars(tmp):
    """--export-table-ivars: what the table of exported instance variables decides, and the rest of the registry as it was."""
    swift = "DCMView is implemented in Swift now: a Swift stored property has no _OBJC_IVAR_$_ symbol"
    registry = {"about": "What it is.", "classes": {"DCMView": "NSView", "PluginFilter": "NSObject"},
                "selectors": {"DCMView -curDCM": 7, "DCMView -gone": 0},
                "ivars": {"DCMView.scaleValue": 1, "DCMView.count": 0, "DCMView.curImage": 0, "PluginFilter.viewerController": 1},
                "missing": {"ivars DCMView.scaleValue": swift, "ivars DCMView.count": swift,
                            "ivars DCMView.curImage": "another reason it has", "selectors DCMView -gone": swift}}

    def entry(field, sdk="float", ownership="value"):
        return {"sdk": sdk, "field": field, "symbol": "_$s5Horos7DCMViewC%d%sSfvpWvd" % (len(field), field),
                "state": "live", "ownership": ownership}

    table = {"about": ["what it is"], "ivars": {"PluginFilter.viewerController": entry("viewerController", "ViewerController *", "unowned"),
                                                 "DCMView.scaleValue": entry("scaleValue"),
                                                 "DCMView.yearOld": entry("yearOld", "NSString *", "strong")}}
    path, table_path = tmp / "exported.json", tmp / "ivar-table.json"

    def run(entries, *more):
        table_path.write_text(json.dumps(dict(table, ivars=entries)))
        return subprocess.run([sys.executable, "-I", str(TOOL), "--api-headers", str(tmp / "sdk"),
                               "--collection", "synthetic=%s" % (tmp / "collection"), "--markdown", str(tmp / "unused.md"),
                               "--export-table-ivars", str(path), "--ivar-table", str(table_path), *more],
                              capture_output=True, text=True, timeout=120)

    spec = importlib.util.spec_from_file_location("legacy_plugin_abi", ROOT / "tests/test-legacy-plugin-abi.py")
    abi = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(abi)
    path.write_text(abi.render(registry))
    result = run(table["ivars"])
    if result.returncode != 0:
        fail("--export-table-ivars exited %d: %s" % (result.returncode, result.stderr[-2000:]))
    text = path.read_text()
    written = json.loads(text)
    if text != abi.render(written):
        fail("--export-table-ivars did not write the canonical text of tests/test-legacy-plugin-abi.py")
    # yearOld enters with the one plugin whose category reads it; the counts there were stay.
    if written["ivars"] != dict(registry["ivars"], **{"DCMView.yearOld": 1}):
        fail("--export-table-ivars wrote the ivars %s" % written["ivars"])
    layout = "DCMView is implemented in Swift now: its storage is not yet in the SDK's layout, a stored field of the class with the SDK's type"
    if written["missing"] != {"ivars DCMView.count": layout, "ivars DCMView.curImage": "another reason it has",
                              "selectors DCMView -gone": swift}:
        fail("--export-table-ivars wrote the missing %s" % written["missing"])
    about = written["about"]
    if not about.startswith("What it is. The instance variables of a class implemented in Swift are exported") \
            or not about.endswith("no longer exported them: DCMView.yearOld.") or "legacy-plugin-ivars.json" not in about:
        fail("--export-table-ivars did not say in about where the exported variables come from and which it added: %s" % about)
    if {key: value for key, value in written.items() if key not in ("about", "ivars", "missing")} \
            != {key: value for key, value in registry.items() if key not in ("about", "ivars", "missing")}:
        fail("--export-table-ivars changed something else of the registry")
    # The registry it wrote holds the rules the test of the binary surface has for these variables.
    if abi.missing_ivar_problems(written) or not abi.missing_ivar_problems(registry):
        fail("the registry --export-table-ivars wrote was expected to hold the rules of missing instance variables, and the one "
             "before it not to: %s" % abi.missing_ivar_problems(written))
    result = run(table["ivars"])
    if result.returncode != 0 or path.read_text() != text:
        fail("a second run of --export-table-ivars changed the registry: %s" % result.stderr[-2000:])
    for what, name in (("no header declares", "DCMView.notInTheHeaders"), ("of a class the registry does not have", "ROI.thickness")):
        result = run(dict(table["ivars"], **{name: entry(name.split(".")[1])}))
        if result.returncode == 0 or name not in result.stderr or path.read_text() != text:
            fail("--export-table-ivars was expected to refuse an entry %s (%s) and to write nothing: %s"
                 % (what, name, result.stderr[-2000:]))
    # The copy of an older SDK a plugin carries: iChatWidth is declared only
    # there, scaleValue by the SDK too, and Theatre is not a class of the SDK.
    older = tmp / "older-sdk"
    older.mkdir()
    (older / "DCMView.h").write_text("@interface DCMView : NSView\n{\n    float scaleValue, iChatWidth;\n}\n@end\n"
                                     "@interface Theatre : NSObject\n{\n    float seats;\n}\n@end\n")
    entries = dict(table["ivars"], **{"DCMView.iChatWidth": entry("iChatWidth")})
    result = run(entries, "--older-sdk-headers", str(older))
    if result.returncode != 0:
        fail("--export-table-ivars with --older-sdk-headers exited %d: %s" % (result.returncode, result.stderr[-2000:]))
    older_text = path.read_text()
    older_written = json.loads(older_text)
    if older_written["ivars"] != dict(written["ivars"], **{"DCMView.iChatWidth": 0}) or older_written["missing"] != written["missing"]:
        fail("--export-table-ivars with --older-sdk-headers wrote the ivars %s and the missing %s"
             % (older_written["ivars"], older_written["missing"]))
    if not older_written["about"].startswith(about) or "older SDK of OsiriX" not in older_written["about"][len(about):] \
            or not older_written["about"].endswith(": DCMView.iChatWidth."):
        fail("--export-table-ivars did not name apart in about the variable only the older SDK declares: %s" % older_written["about"])
    result = run(entries, "--older-sdk-headers", str(older))
    if result.returncode != 0 or path.read_text() != older_text:
        fail("a second run of --export-table-ivars with --older-sdk-headers changed the registry: %s" % result.stderr[-2000:])
    # A later run with one more variable of that source names it in the same sentence.
    (older / "DCMView.h").write_text("@interface DCMView : NSView\n{\n    float scaleValue, iChatWidth, iChatHeight;\n}\n@end\n"
                                     "@interface Theatre : NSObject\n{\n    float seats;\n}\n@end\n")
    entries["DCMView.iChatHeight"] = entry("iChatHeight")
    result = run(entries, "--older-sdk-headers", str(older))
    older_text = path.read_text()
    if result.returncode != 0 or json.loads(older_text)["about"] != older_written["about"][:-1] + ", DCMView.iChatHeight.":
        fail("--export-table-ivars was expected to name DCMView.iChatHeight at the end of the sentence the run before left: %s\n%s"
             % (json.loads(older_text)["about"], result.stderr[-2000:]))
    result = run(dict(entries, **{"Theatre.seats": entry("seats")}), "--older-sdk-headers", str(older))
    if result.returncode == 0 or "Theatre.seats" not in result.stderr or path.read_text() != older_text:
        fail("--export-table-ivars was expected to refuse an entry of a class only the older SDK has: %s" % result.stderr[-2000:])


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
        if report["sdk"]["classes"] < 6 or report["sdk"]["notifications"] != 2:
            fail("SDK model incomplete: %s" % {k: v for k, v in report["sdk"].items() if not isinstance(v, dict)})

        data, functions = report["sdk"]["data"], report["sdk"]["function_names"]
        read = {name: (entry["type"], entry["mutable"]) for name, entry in data.items()}
        expected = {name: (kind, False) for name, kind in CONSTANTS.items()}
        expected.update({name: (kind, True) for name, kind in GLOBALS.items()})
        expected["OsirixROIChangeNotification"] = ("NSString * const", False)
        expected["SampleDidChangeNotification"] = ("NSString * const", False)
        if read != expected:
            fail("extern data read wrong: missing %s, extra %s, different %s" % (
                sorted(set(expected) - set(read)), sorted(set(read) - set(expected)),
                sorted((n, read[n], expected[n]) for n in set(read) & set(expected) if read[n] != expected[n])))
        if any(entry["header"] != "Declarations.h" for name, entry in data.items() if name != "OsirixROIChangeNotification"):
            fail("a datum is not attributed to its header")
        exported = {name for name, entry in functions.items() if not entry["inline"]}
        inline = {name for name, entry in functions.items() if entry["inline"]}
        if exported != EXPORTED_FUNCTIONS or inline != INLINE_FUNCTIONS:
            fail("C functions read wrong: exported %s, inline %s" % (sorted(exported ^ EXPORTED_FUNCTIONS),
                                                                    sorted(inline ^ INLINE_FUNCTIONS)))
        taken = NOT_DECLARATIONS & (set(data) | set(functions))
        if taken:
            fail("taken for a datum or a function of the SDK: %s" % sorted(taken))
        if report["sdk"]["constants"] != len(CONSTANTS) or report["sdk"]["globals"] != len(GLOBALS):
            fail("constants and globals not told apart: %s constants, %s globals" % (
                report["sdk"]["constants"], report["sdk"]["globals"]))

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
        direct = {(e["class"], e["name"]): e["refs"] for e in sample["ivars_and_attributes"] if e["how"] == "inherited"}
        if direct.get(("DCMView", "yearOld")) != 1 or direct.get(("DCMView", "scaleValue")) != 1:
            fail("an ivar a category of a host class reads, by name and through self->, is not reported: %s" % direct)
        if ("DCMView", "count") in direct:
            fail("[list count], [self count] and a part of a selector were taken for the ivar count: %s" % direct)
        if ("DCMView", "curImage") in direct:
            fail("a local variable was taken for the ivar of its name: %s" % direct)
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
        if sorted((e["class"], e["host_super"], e["refs"]) for e in sample["subclasses_of_host"]) != [
                ("SampleFilter", "PluginFilter", 1), ("SampleView", "DCMView", 1)]:
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
        check_registry(tmp)
        check_recount(tmp)
        check_export_table_ivars(tmp)
        check_selectors()
    print("PASS: plugin API inventory over synthetic SDK and plugins, the instance variables a category reads and "
          "the messages that are not one, the registry of the binary surface generated from a synthetic baseline, "
          "listings and registry, written again from itself unchanged and holding the rules of the test of that surface, "
          "the recount of its instance variables and the entries of the table of exported instance variables applied to it")


if __name__ == "__main__":
    main()
