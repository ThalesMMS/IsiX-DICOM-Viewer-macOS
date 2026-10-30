#!/usr/bin/env python3
"""Inventory of the legacy plugin API used by plugin sources.

Reads plugin source trees (Objective-C, Objective-C++, C/C++ and Swift), their
Info.plist files and Xcode projects, and the headers of the host SDK given with
--api-headers. Reports, per plugin and per area (viewer, series/image/pixels,
ROI, database, menus/tools, export, network, other): host classes, selectors,
ivars and attributes, KVC keys, notifications, headers and frameworks, ABI
dependencies, dynamic or indirect accesses, obsolete platform APIs, licence
markers found in file headers and the declared architectures.

The analysis is static and textual. Nothing in the inputs is built, loaded or
executed; git revisions are read from the .git directory without running git.

    python3 tools/inventory-plugin-api.py \\
        --api-headers PATH/Horos.framework/Headers \\
        --collection horosplugins=PATH/horosplugins \\
        --plugin "Template=PATH/MyIsiXPluginFolder-dev" \\
        --plugin "T2 Fit Map (IsiX)=Horos/Sources/T2FitMap.swift,Horos/Sources/ViewerController+T2FitMap.swift" \\
        --markdown out.md --json out.json

--collection treats every immediate subdirectory as a plugin (descending one
level into folders that only group plugins, such as `_obsolete`). --plugin
treats the listed paths (directories or files, comma-separated) as one plugin.
--macos-sdk adds the selectors of Foundation, AppKit and related system
headers, so that a selector shared with Cocoa is not attributed to the host.
"""
import argparse
import json
import plistlib
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

AREAS = ["viewer", "series-image-pixels", "roi", "database", "menus-tools", "export", "network", "other"]
AREA_TITLES = {
    "viewer": "Viewer",
    "series-image-pixels": "Série/imagem/pixels",
    "roi": "ROI",
    "database": "Banco",
    "menus-tools": "Menus/ferramentas",
    "export": "Exportação",
    "network": "Rede",
    "other": "Outros",
}

# Ordered: the first matching rule names the area of a host class or header.
AREA_RULES = [
    ("menus-tools", r"^(PluginFilter|PluginManager.*|ReportPluginFilter|PluginFileFormatDecoder|AppController.*|"
                    r"ToolbarPanel.*|ToolBarNSWindow|ThumbnailsListPanel|PreferencesWindowController|"
                    r"PreferencePane.*|.*PreferencePanePref|HorosPlugin.*|"
                    r"pluginSDKAdditions|NativeFilterMenus|Notifications)$"),
    ("roi", r"^(ROI.*|MyPoint|OSIROI.*|HorosROI.*|LiveWire.*|ITKBrushROIFilter|ITKSegmentation.*|"
            r"Interpolation3D|SRAnnotation|PluginROI.*|ROIsAndKeyImages.*|CurvedMPR.*|Spline.*|HornRegistration)$"),
    ("export", r"^(DICOMExport|Reports|ReportPluginFilter|Burner.*|DiscPublishing.*|DCMExport.*|QTExport.*|"
               r"AYDicomPrint.*|AYNSImageToDicom|Anonymization.*|Anonymizer|ExportSeries.*|"
               r"QuicktimeExport|.*Movie.*Export.*|DicomStudy\+Report|DCMEncapsulatedPDF|"
               r"CIA.*|SRController\+Export|DicomFileExport.*|DicomDir.*|DiscBurning.*|DicomCompressor)$"),
    ("network", r"^(DCMTK.*|DCMNetServiceDelegate|QueryController.*|QueryFilter|DICOMTLS|DCMBonjour.*|"
                r"Bonjour.*|RemoteDicomDatabase|WebPortal.*|HTTP.*|AsyncSocket|N2Connection.*|"
                r"XMLRPC.*|XMLRPCMethods|OsiriXHTTPConnection|SendController|WADO.*|DICOMweb.*|"
                r"DCMNetworking|DDKeychain|DDData|Echo|AutoroutingQueue.*|NetworkMoveDataHandler|"
                r"DicomNode.*|DCMNode.*|.*SCU|.*SCP|N2MutableURLRequest|N2XMLRPC.*|"
                r"OSIDicomNode.*|IncomingDICOM.*|.*Retrieve.*|.*QueryNode.*)$"),
    ("database", r"^(BrowserController.*|DicomDatabase.*|DicomStudy.*|DicomSeries.*|DicomImage.*|"
                 r"DicomAlbum.*|N2ManagedObject.*|N2ManagedDatabase.*|NSManagedObject\+N2|"
                 r"DataNodeIdentifier|DatabaseIsEdited|ThreadsManager|LogManager|LogEntry|"
                 r"ComparativeStudy.*|OSIStudy|OSISeries|OSIDatabase.*|SmartWindowController|"
                 r"BrowserMatrix|BrowserSource.*|ImageAndTextCell|DicomFileDCMTKCategory|"
                 r"Database.*|AlbumsTable.*|.*Album.*)$"),
    ("series-image-pixels", r"^(DCMPix.*|DCMObject|DCMAttribute.*|DCMSequenceAttribute|DCMTransferSyntax|"
                            r"DCMCalendarDate|DCMLimitedObject|DCMCharacterSet|DCMValueRepresentation|"
                            r"DCMTag.*|DCMAbstractSyntaxUID|DCMUIDs|DCM|DicomFile|Analyze|N3.*|"
                            r"OSIVolumeData|OSIFloatVolumeData|OSIGeometry|VolumeData.*|DCMWaveform.*|"
                            r"BioradHeader|Papyrus.*|DCMCursor|DicomFileDCMTK.*|.*Volume.*Data.*|"
                            r"NSImage\+N2|N2Image.*|ITK.*|OSIEnvironment.*)$"),
    ("viewer", r"^(ViewerController.*|DCMView.*|DCMSubView|OrthogonalMPR.*|OrthogonalReslice|MPR.*|"
               r"VR.*|SR.*|Window3DController.*|ThickSlab.*|CPR.*|Endoscopy.*|SeriesView|StudyView|"
               r"OSIVolumeWindow|OSIWindowController.*|OSIWindow.*|KeyObject.*|Navigator.*|"
               r"ColorTransferView|CLUTOpacityView|OpacityTransferView|HistoView|FlyThru.*|"
               r"LayoutWindowController|Layout.*|PaletteController|ShadingArrayController|"
               r"Wait.*|WindowLayoutManager|.*Viewer.*|.*MPR.*|.*VR.*|GLString|StringTexture|"
               r"ColorView|ThumbnailCell|.*ImageView.*|CLUT.*|WLWW.*|ToolbarItem.*)$"),
]

# Selectors that Cocoa and C++ code send far more often than the host does.
# Without --macos-sdk these are never attributed to the host by name alone.
COMMON_SELECTORS = set("""
alloc init new copy mutableCopy release retain autorelease dealloc description count objectAtIndex:
addObject: removeObject: removeAllObjects lastObject firstObject objectForKey: setObject:forKey:
removeObjectForKey: valueForKey: setValue:forKey: valueForKeyPath: setValue:forKeyPath: length
stringWithFormat: stringValue intValue floatValue doubleValue boolValue integerValue longValue
setStringValue: setIntValue: setFloatValue: setDoubleValue: setTitle: title setTag: tag window
setNeedsDisplay: display close show hide isEqual: isEqualToString: hash class superclass self
respondsToSelector: performSelector: performSelector:withObject: name setName: path setPath:
isKindOfClass: isMemberOfClass: conformsToProtocol: performSelector:withObject:afterDelay: zone
copyWithZone: mutableCopyWithZone: initWithCoder: encodeWithCoder: awakeFromNib
data setData: frame setFrame: bounds setBounds: string setString: image setImage: delegate
setDelegate: target setTarget: action setAction: state setState: enabled setEnabled: isEnabled
objectEnumerator nextObject allKeys allValues containsObject: indexOfObject: array dictionary
arrayWithArray: arrayWithObjects: dictionaryWithObjectsAndKeys: numberWithInt: numberWithFloat:
numberWithDouble: numberWithBool: numberWithLong: lock unlock start stop run cancel reset update
setHidden: isHidden size setSize: width height setWidth: setHeight: type setType: value setValue:
x y setX: setY: point setPoint: color setColor: selected setSelected: index setIndex: mode setMode:
identifier setIdentifier: label setLabel: object setObject: info setInfo: version contents
setContents: sharedInstance shared defaultCenter postNotificationName:object:
postNotificationName:object:userInfo: addObserver:selector:name:object: removeObserver:
removeObserver:name:object: userInfo standardUserDefaults synchronize min max mean total
""".split())

# Swift standard library and Foundation members that share a name with a host selector.
SWIFT_STANDARD_MEMBERS = set("""
filter map compactMap flatMap reduce forEach contains first last count isEmpty append insert remove
removeAll sorted sort reversed enumerated min max index indices joined components lowercased uppercased
hasPrefix hasSuffix replacingOccurrences trimmingCharacters description debugDescription success
failure some none rawValue init deinit self type dropFirst dropLast prefix suffix split zip keys values
startIndex endIndex lazy union intersection subtracting formUnion contains allSatisfy firstIndex
lastIndex popLast removeFirst removeLast appending path url data string value values
""".split())

STOP_IDENTIFIERS = {"if", "for", "while", "switch", "return", "sizeof", "case", "do", "else", "new",
                    "delete", "throw", "catch", "typeof", "__typeof__", "defined", "static_cast",
                    "reinterpret_cast", "const_cast", "dynamic_cast"}

SOURCE_SUFFIXES = {".h", ".hh", ".hpp", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".txx", ".hxx", ".pch",
                   ".swift"}
OBJC_SUFFIXES = SOURCE_SUFFIXES - {".swift"}
BINARY_SUFFIXES = {".a", ".dylib", ".so", ".o"}

# Directories that hold a copy of an SDK or of a third-party library rather
# than the plugin's own code. They are reported, not scanned as plugin sources.
VENDORED_DIR = re.compile(r"(?i)(\.framework$|^itk|^vtk|^insight|^dcmtk|^gsl|^boost|^binaries$|headers$|"
                          r"^osirix$|^build$|^derived ?data$|^libxml|^freetype)")
SKIPPED_DIR = re.compile(r"(?i)(^\.git$|^\.svn$|\.xcodeproj$|\.xcworkspace$|\.lproj$|\.nib$|^__pycache__$)")

HOST_FRAMEWORKS = {"OsiriX", "OsiriXAPI", "OsiriX Headers", "HorosAPI", "Horos", "IsiX", "IsiXPluginKit"}
APPLE_FRAMEWORKS = set("""
Cocoa Foundation AppKit CoreFoundation CoreServices ApplicationServices CoreData Quartz QuartzCore
QuartzComposer OpenGL GLUT CoreImage CoreGraphics CoreText CoreVideo CoreMedia AVFoundation AVKit
QTKit QuickTime Carbon Accelerate vecLib Security SystemConfiguration IOKit AddressBook ImageIO
PDFKit WebKit ScreenSaver Python OSAKit ExceptionHandling DiscRecording DiscRecordingUI Metal
MetalKit MetalPerformanceShaders CoreAudio AudioToolbox AudioUnit CoreMIDI SceneKit SpriteKit
Automator Message InstantMessage CalendarStore SyncServices PubSub ScriptingBridge OpenCL
CoreLocation UniformTypeIdentifiers Combine SwiftUI Dispatch Darwin os simd Cocoa_Prefix
LDAP Kerberos GSS CFNetwork Network JavaScriptCore ImageCaptureCore Collaboration
QuickLook QuickLookUI LocalAuthentication CryptoKit CommonCrypto objc mach libkern sys
""".split())
C_STANDARD = re.compile(r"^(std\w*|stdio|stdlib|string|strings|math|unistd|time|limits|float|assert|ctype|"
                        r"errno|fcntl|signal|setjmp|stdarg|stddef|stdint|stdbool|inttypes|pthread|dlfcn|"
                        r"vector|map|set|list|deque|algorithm|iostream|fstream|sstream|cmath|cstdlib|"
                        r"cstdio|cstring|memory|utility|functional|numeric|iterator|complex|valarray|"
                        r"exception|stdexcept|limits|climits|cfloat|cassert|queue|stack|bitset|"
                        r"zlib|libgen|dirent|glob|regex|termios|pwd|grp|netdb|arpa|netinet|sys)$")
THIRD_PARTY_HINTS = [
    ("VTK", re.compile(r"(?i)^vtk")),
    ("ITK", re.compile(r"(?i)^itk|InsightToolkit")),
    ("DCMTK", re.compile(r"^(dcmtk|osconfig|dcdatset|dcfilefo|dcmdata|dcmimgle|dcmnet|ofstd|dcdeftag|"
                         r"dcuid|dctk|dcmjpeg|djencode|djdecode|dcrledrg|diregist)")),
    ("FreeType", re.compile(r"(?i)^(ft2build|freetype)")),
    ("libxml2", re.compile(r"(?i)^(libxml|xmlversion|tree\.h)")),
    ("GSL", re.compile(r"(?i)^gsl")),
    ("GraphX", re.compile(r"(?i)^(graphx|GRChart|GRAxes|GRDataSet)")),
    ("OpenJPEG", re.compile(r"(?i)^(openjpeg|opj_)")),
    ("Kakadu", re.compile(r"(?i)^kdu")),
    ("MATLAB", re.compile(r"(?i)^(engine|mat|mex)\.h$")),
    ("libssh/libcurl", re.compile(r"(?i)^(libssh|curl)")),
]

OBSOLETE_PATTERNS = [
    ("garbage-collection", r"GCC_ENABLE_OBJC_GC\s*=\s*(supported|required|YES)|objc_collect|NSGarbageCollector"),
    ("QuickTime/QTKit", r"\bQTMovie\w*|<QTKit/|<QuickTime/|\bQTKit\b|\bQTTime\w*|\bMovies\.h|EnterMovies"),
    ("Carbon", r"<Carbon/|\bFSRef\b|\bFSSpec\b|\bGetEventKind\b|\bAliasHandle\b"),
    ("OpenGL", r"<OpenGL/|\bNSOpenGL\w+|\bCGL\w+\(|\bglBegin\b|\bgluPerspective\b"),
    ("legacy-alert/sheet", r"\bNSRunAlertPanel\w*|\bNSRunCriticalAlertPanel\w*|\bNSRunInformationalAlertPanel\w*|"
                           r"\bNSBeginAlertSheet\b|beginSheet:\s*\w+\s+modalForWindow:|modalDelegate:"),
    ("WebView-legacy", r"<WebKit/WebView\.h>|\bWebView\s*\*|\bWebFrame\b"),
    ("NSURLConnection", r"\bNSURLConnection\b"),
    ("manual-retain-release", r"\[\s*\w+\s+(?:retain|release|autorelease)\s*\]|\bNSAutoreleasePool\b"),
    ("NSCalendarDate", r"\bNSCalendarDate\b"),
    ("deprecated-file-api", r"removeFileAtPath:\s*\w+\s+handler:|copyPath:|movePath:|"
                            r"createDirectoryAtPath:\s*\w+\s+attributes:|directoryContentsAtPath:|"
                            r"fileAttributesAtPath:|stringWithContentsOfFile:\s*\w+\s*\]"),
    ("deprecated-nib-loading", r"loadNibNamed:\s*@?\"?[^\]]*?owner:\s*\w+\s*\]|\bNSBundle\s+loadNibNamed:"),
    ("legacy-sdk/arch", r"\b(MacOSX10\.[0-9]+u?\.sdk|ppc64|ppc7400|ppc970|ppc\b|i386)\b"),
    ("objc_msgSend-cast", r"\bobjc_msgSend\w*"),
    ("NSTask-shell", r"\bNSTask\b|\bsystem\s*\(|\bpopen\s*\("),
    ("Python/MATLAB bridge", r"<Python/|Py_Initialize|\bengOpen\b"),
]

DYNAMIC_PATTERNS = [
    ("performSelector", r"\bperformSelector\w*:|\.perform\s*\("),
    ("NSClassFromString", r"\bNSClassFromString\s*\(|\bobjc_getClass\s*\(|\bobjc_lookUpClass\s*\(|"
                          r"\bclassNamed:|\bprincipalClass\b"),
    ("NSSelectorFromString", r"\bNSSelectorFromString\s*\(|\bsel_registerName\s*\(|\bSelector\s*\(\s*\""),
    ("@selector/#selector", r"@selector\s*\(|#selector\s*\("),
    ("respondsToSelector", r"\brespondsToSelector:|\binstancesRespondToSelector:|\.responds\s*\(\s*to:"),
    ("KVC", r"\bvalueForKey(?:Path)?:|\bsetValue:[^\]]*forKey(?:Path)?:|\bmutableArrayValueForKey:|"
            r"\.value\s*\(\s*forKey(?:Path)?:|\.setValue\s*\([^)]*forKey(?:Path)?:"),
    ("KVO/bindings", r"\baddObserver:\s*\w+\s+forKeyPath:|\bbind:\s*@?\"|\bobserveValueForKeyPath:|\.observe\s*\(\\\."),
    ("NSPredicate/sort keys", r"\bpredicateWithFormat:|\bsortDescriptorWithKey:|\binitWithKey:|NSPredicate\s*\(\s*format:"),
    ("NSInvocation", r"\bNSInvocation\b|\binvocationWithMethodSignature:"),
    ("objc runtime", r"\bclass_getInstanceVariable\b|\bobject_getInstanceVariable\b|\bobject_getIvar\b|"
                     r"\bobject_setIvar\b|\bmethod_exchangeImplementations\b|\bclass_replaceMethod\b|"
                     r"\bclass_addMethod\b|\bmethod_setImplementation\b|\bclass_getInstanceMethod\b|"
                     r"\bobjc_msgSend\w*\b|\bobjc_setAssociatedObject\b"),
    ("dlopen/dlsym", r"\bdlopen\s*\(|\bdlsym\s*\(|\bCFBundleGetFunctionPointerForName\b"),
    ("NSNotification by string", r"postNotificationName:\s*@\"|name:\s*@\"\w+\"|Notification\.Name\s*\(\s*\""),
]

LICENCE_PATTERNS = [
    ("LGPL", r"GNU\s+(Lesser|Library)\s+General\s+Public|\bLGPL"),
    ("GPL", r"GNU\s+General\s+Public\s+License|\bGNU\s*-?\s*GPL\b|\bGPL\b"),
    ("BSD", r"\bBSD\b|Redistribution and use in source and binary forms"),
    ("MIT", r"\bMIT License\b|Permission is hereby granted, free of charge"),
    ("Apache", r"Apache License"),
    ("CeCILL", r"CeCILL"),
    ("public-domain", r"public domain"),
    ("all-rights-reserved", r"All rights reserved"),
]


def area_of(name):
    if "|" in name:
        areas = [area_of(part) for part in name.split("|") if part != "…"]
        known = [a for a in areas if a != "other"]
        return Counter(known).most_common(1)[0][0] if known else "other"
    base = name[:-2] if name.endswith(".h") else name
    for area, pattern in AREA_RULES:
        if re.match(pattern, base):
            return area
    stem = base.split("+")[0]
    if stem != base:
        for area, pattern in AREA_RULES:
            if re.match(pattern, stem):
                return area
    return "other"


def notification_area(name):
    rules = [("roi", r"ROI"), ("viewer", r"Viewer|WLWW|CLUT|DCMView|Drag|Mouse|Window|Sync|Fusion|Opacity|"
                                         r"Slice|Movie|Display|Draw|Tool|Zoom|Pan|Image"),
             ("database", r"Database|Added|Album|Browser|Study|Series|Import|Files"),
             ("menus-tools", r"Plugin|Menu|Preferences|Defaults"),
             ("network", r"Send|Store|Query|Retrieve|DICOMSend|Bonjour|Network|Node|WADO|Portal|Echo"),
             ("export", r"Export|Report|Burn|Print")]
    for area, pattern in rules:
        if re.search(pattern, name):
            return area
    return "other"


# ---------------------------------------------------------------- lexing

def strip_source(text, swift=False):
    """Return (no_comments, code): comments blanked in both, strings also blanked in `code`.

    Newlines are kept so that line numbers survive.
    """
    nc, code = [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank = " " * (j - i)
            nc.append(blank)
            code.append(blank)
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank = re.sub(r"[^\n]", " ", text[i:j])
            nc.append(blank)
            code.append(blank)
            i = j
        elif swift and text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            nc.append(text[i:j])
            code.append('"' + re.sub(r"[^\n]", " ", text[i + 1:j - 1]) + '"')
            i = j
        elif c == '"' or (c == "'" and not swift):
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            nc.append(text[i:j])
            code.append(c + " " * max(0, j - i - 2) + (c if j - i >= 2 else ""))
            i = j
        else:
            j = i
            while j < n and text[j] not in "/\"'":
                j += 1
            if j == i:
                j = i + 1
            nc.append(text[i:j])
            code.append(text[i:j])
            i = j
    return "".join(nc), "".join(code)


def balanced(text, start, opening, closing):
    """Index just past the bracket matching text[start] == opening, or -1."""
    depth = 0
    for k in range(start, len(text)):
        if text[k] == opening:
            depth += 1
        elif text[k] == closing:
            depth -= 1
            if depth == 0:
                return k + 1
    return -1


def type_name(text):
    """Class name of a declared Objective-C type such as `DCMPix *` or `NSMutableArray<ROI*>*`."""
    text = re.sub(r"\b(const|__strong|__weak|__unsafe_unretained|__kindof|nullable|nonnull|_Nullable|_Nonnull|"
                  r"__autoreleasing|oneway|in|out|inout|bycopy|byref|IBOutlet|IBAction|volatile|struct|unsigned|"
                  r"signed)\b", " ", text)
    text = re.sub(r"<[^<>]*>", " ", text)
    match = re.search(r"([A-Za-z_]\w*)\s*\**\s*$", text.strip())
    return match.group(1) if match else None


# ---------------------------------------------------------------- host SDK model

MACRO_CALL = re.compile(r"\b(?:__attribute__|[A-Z][A-Z0-9_]{2,})\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)")
DEPRECATED = re.compile(r"(?i)deprecated|DEPRECATED|__deprecated|unavailable")


def selector_of(signature):
    """Selector of a method declaration such as `computeROI:(ROI*) roi mean:(float*) m`."""
    signature = MACRO_CALL.sub(" ", signature)
    signature = re.sub(r"\b[A-Z][A-Z0-9_]{2,}\b", " ", signature)
    signature = signature.split(",")[0]
    if ":" not in signature:
        match = re.match(r"\s*([A-Za-z_]\w*)", signature)
        return match.group(1) if match else None
    # Each part is `keyword:(type) name`; an anonymous part is `:(type) name`.
    flat = flatten_depth0(signature, "#")
    parts = [m.group(1) + ":" for m in re.finditer(r"([A-Za-z_]\w*|)\s*:[\s#]*[A-Za-z_]\w*", flat)]
    return "".join(parts) or None


class HostSDK:
    def __init__(self):
        self.classes = {}        # name -> dict(super, header, methods{sel: info}, ivars{}, props{})
        self.defined = set()     # classes whose @interface (not only a category) is in the SDK
        self.protocols = {}
        self.selectors = defaultdict(set)
        self.notifications = {}  # name -> header
        self.constants = {}
        self.functions = {}
        self.headers = {}        # basename -> label
        self.headers_lower = set()
        self.system_selectors = set()
        self.system_functions = set(["floor", "ceil", "round", "sqrt", "fabs", "abs", "pow", "log", "exp", "sin",
                                     "cos", "tan", "atan", "atan2", "acos", "asin", "min", "max", "write", "read",
                                     "clear", "free", "malloc", "calloc", "realloc", "memcpy", "memset"])

    def klass(self, name):
        return self.classes.setdefault(name, {"super": None, "header": None, "methods": {}, "ivars": {},
                                              "props": {}, "categories": set()})

    def chain(self, name):
        seen = []
        while name and name in self.classes and name not in seen:
            seen.append(name)
            name = self.classes[name]["super"]
        return seen, name

    def lookup(self, name, selector):
        chain, _ = self.chain(name)
        for cls in chain:
            info = self.classes[cls]["methods"].get(selector)
            if info:
                return cls, info
        return None, None

    def ivar(self, name, ivar):
        chain, _ = self.chain(name)
        for cls in chain:
            if ivar in self.classes[cls]["ivars"]:
                return cls, self.classes[cls]["ivars"][ivar]
        return None, None

    def prop(self, name, prop):
        chain, _ = self.chain(name)
        for cls in chain:
            if prop in self.classes[cls]["props"]:
                return cls, self.classes[cls]["props"][prop]
        return None, None


def parse_header(sdk, path, raw):
    nc, code = strip_source(raw)
    raw_lines = raw.splitlines()
    basename = path.name
    sdk.headers[basename] = str(path)
    sdk.headers_lower.add(basename.lower())
    for match in re.finditer(r"\bextern\s+(?:const\s+)?(?:NSString|NSNotificationName|CFStringRef)\s*\*?\s*"
                             r"(?:const\s+)?(?:_Nonnull\s+)?([A-Za-z_]\w*)", code):
        name = match.group(1)
        (sdk.notifications if "Notification" in name else sdk.constants)[name] = basename
    # As above, a name with "Notification" in it: the notification or a key of its userInfo.
    for match in re.finditer(r"#\s*define\s+([A-Za-z_]\w*Notification\w*)\s+@\"", nc):
        sdk.notifications[match.group(1)] = basename
    blocks = []
    for match in re.finditer(r"@(interface|protocol)\s+([A-Za-z_]\w*)", code):
        start = match.start()
        if match.group(1) == "protocol" and re.match(r"@protocol\s+\w+\s*[;,]", code[start:]):
            continue
        end = code.find("@end", start)
        end = len(code) if end < 0 else end
        blocks.append((start, end))
        head = code[match.end():code.find("\n", match.end()) if "\n" in code[match.end():] else len(code)]
        name = match.group(2)
        body = code[match.end():end]
        if match.group(1) == "protocol":
            target = sdk.protocols.setdefault(name, {"methods": {}, "header": basename})
        else:
            target = sdk.klass(name)
            category = re.match(r"\s*(?:<[^>]*>)?\s*\(\s*(\w*)", head)
            superclass = re.match(r"\s*:\s*([A-Za-z_]\w*)", head)
            if category:
                target["categories"].add(category.group(1) or "(extension)")
                target.setdefault("category_headers", set()).add(basename)
            else:
                sdk.defined.add(name)
                if superclass:
                    target["super"] = superclass.group(1)
                target["header"] = target["header"] or basename
            ivar_open = re.match(r"[^{@;]*?\{", body)
            if ivar_open and not category:
                close = balanced(body, ivar_open.end() - 1, "{", "}")
                if close > 0:
                    for statement in body[ivar_open.end():close - 1].split(";"):
                        statement = re.sub(r"@(public|private|protected|package)", " ", statement).strip()
                        statement = re.sub(r"\[[^\]]*\]", "", statement)
                        names = re.findall(r"([A-Za-z_]\w*)\s*(?:,|$)", statement)
                        decl_type = type_name(re.split(r"[A-Za-z_]\w*\s*(?:,|$)", statement)[0]) if statement else None
                        if names and len(statement.split()) >= 2:
                            for ivar in names:
                                target["ivars"][ivar] = decl_type
                    body = body[close:]
        for prop in re.finditer(r"@property\s*(\([^)]*\))?\s*([^;]+);", body):
            attrs = prop.group(1) or ""
            decl = MACRO_CALL.sub(" ", prop.group(2)).strip()
            segments = decl.split(",")
            first = re.search(r"([A-Za-z_]\w*)\s*$", segments[0])
            if not first:
                continue
            prop_type = type_name(segments[0][:first.start()])
            prop_names = [first.group(1)] + [m.group(1) for m in
                                             (re.search(r"([A-Za-z_]\w*)\s*$", seg) for seg in segments[1:]) if m]
            line = code.count("\n", 0, match.end() + prop.start())
            deprecated = bool(DEPRECATED.search(raw_lines[line] if line < len(raw_lines) else ""))
            getter = re.search(r"getter\s*=\s*(\w+)", attrs)
            for prop_name in prop_names:
                target.setdefault("props", {})[prop_name] = prop_type
                info = {"ret": prop_type, "class_method": "class" in attrs, "deprecated": deprecated,
                        "property": True}
                target["methods"][getter.group(1) if getter and len(prop_names) == 1 else prop_name] = info
                if "readonly" not in attrs:
                    setter = "set" + prop_name[:1].upper() + prop_name[1:] + ":"
                    target["methods"][setter] = dict(info, ret="void")
        for method in re.finditer(r"(?m)^\s*([-+])\s*\(((?:[^()]|\([^()]*\))*)\)\s*([^;{]+?)\s*[;{]", body):
            selector = selector_of(method.group(3))
            if not selector:
                continue
            line = code.count("\n", 0, match.end() + method.start(3))
            nearby = " ".join(raw_lines[max(0, line - 1):line + 2]) if raw_lines else ""
            info = {"ret": type_name(method.group(2)) if method.group(2).strip() not in ("id", "instancetype")
                    else method.group(2).strip(),
                    "class_method": method.group(1) == "+",
                    "deprecated": bool(DEPRECATED.search(method.group(3)) or DEPRECATED.search(nearby)),
                    "property": False}
            target["methods"][selector] = info
    # C functions declared outside @interface blocks.
    outside = list(code)
    for start, end in blocks:
        outside[start:end] = " " * (end - start)
    outside = "".join(outside)
    for name in c_functions(outside):
        sdk.functions[name] = basename


FUNCTION_DECL = re.compile(r"(?m)^[ \t]*(?:extern\s+(?:\"C\"\s+)?|FOUNDATION_EXPORT\s+|CF_EXPORT\s+|APPKIT_EXTERN\s+|"
                           r"NS_INLINE\s+|CG_INLINE\s+|static\s+inline\s+|inline\s+|static\s+)?"
                           r"(?:const\s+)?[A-Za-z_]\w*(?:\s*\*+\s*|\s+)\**\s*([A-Za-z_]\w*)\s*\([^;{}]*\)\s*[;{]")


def c_functions(code):
    """Names of C functions declared at brace depth 0 (not C++ members)."""
    depth, depths = 0, []
    for ch in code:
        depths.append(depth)
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
    names = []
    for match in FUNCTION_DECL.finditer(code):
        name = match.group(1)
        if depths[match.start(1)] == 0 and name not in STOP_IDENTIFIERS and not name.isupper():
            names.append(name)
    return names


def load_sdk(dirs, macos_sdk=None):
    sdk = HostSDK()
    for directory in dirs:
        for path in sorted(Path(directory).glob("*.h")):
            parse_header(sdk, path, path.read_text(errors="replace"))
    for name, info in sdk.classes.items():
        for selector in info["methods"]:
            sdk.selectors[selector].add(name)
    for name, info in sdk.protocols.items():
        for selector in info["methods"]:
            sdk.selectors[selector].add(name)
    if macos_sdk:
        frameworks = ["Foundation", "AppKit", "CoreData", "QuartzCore", "CoreImage", "WebKit", "Quartz",
                      "CoreFoundation", "AVFoundation", "PDFKit"]
        roots = [Path(macos_sdk) / "System/Library/Frameworks" / (f + ".framework") / "Headers" for f in frameworks]
        roots.append(Path(macos_sdk) / "usr/include/objc")
        for root in roots:
            for path in root.rglob("*.h") if root.is_dir() else []:
                _, code = strip_source(path.read_text(errors="replace"))
                sdk.system_functions.update(c_functions(code))
                for method in re.finditer(r"(?m)^\s*[-+]\s*\(((?:[^()]|\([^()]*\))*)\)\s*([^;{]+?)\s*[;{]", code):
                    selector = selector_of(method.group(2))
                    if selector:
                        sdk.system_selectors.add(selector)
                for prop in re.finditer(r"@property\s*(\([^)]*\))?\s*([^;]+);", code):
                    names = re.findall(r"([A-Za-z_]\w*)\s*$", MACRO_CALL.sub(" ", prop.group(2)).strip())
                    getter = re.search(r"getter\s*=\s*(\w+)", prop.group(1) or "")
                    if getter:
                        sdk.system_selectors.add(getter.group(1))
                    if names:
                        sdk.system_selectors.add(names[0])
                        sdk.system_selectors.add("set" + names[0][:1].upper() + names[0][1:] + ":")
    return sdk


# ---------------------------------------------------------------- Objective-C message parsing

def flatten_depth0(text, fill=" "):
    """`text` with bracketed groups replaced by `fill`, keeping positions."""
    out, depth = [], 0
    for ch in text:
        if ch in "([{":
            depth += 1
            out.append(fill)
        elif ch in ")]}":
            depth -= 1
            out.append(fill)
        else:
            out.append(ch if depth == 0 else fill)
    return "".join(out)


def parse_receiver(inner):
    """Split `inner` (text between [ and ]) into (receiver, rest) or None."""
    s = inner.lstrip()
    if not s:
        return None
    if s[0] == "[":
        end = balanced(s, 0, "[", "]")
        if end < 0:
            return None
        return s[:end], s[end:]
    k = 0
    if s[0] == "(":
        end = balanced(s, 0, "(", ")")
        if end < 0:
            return None
        k = end
        while k < len(s) and s[k].isspace():
            k += 1
        if k < len(s) and s[k] == "[":
            end = balanced(s, k, "[", "]")
            return (s[:end], s[end:]) if end > 0 else None
    match = re.match(r"@?\"[^\"]*\"|[A-Za-z_]\w*", s[k:])
    if not match:
        return None
    k += match.end()
    while k < len(s):
        if s.startswith("->", k):
            m = re.match(r"->\s*[A-Za-z_]\w*", s[k:])
            if not m:
                break
            k += m.end()
        elif s[k] == ".":
            m = re.match(r"\.\s*[A-Za-z_]\w*", s[k:])
            if not m:
                break
            k += m.end()
        elif s[k] in "([":
            end = balanced(s, k, s[k], ")" if s[k] == "(" else "]")
            if end < 0:
                break
            k = end
        else:
            break
    return s[:k], s[k:]


def parse_message(inner):
    split = parse_receiver(inner)
    if not split:
        return None
    receiver, rest = split
    first = re.match(r"\s+([A-Za-z_]\w*)\s*", rest)
    if not first or first.group(1) in STOP_IDENTIFIERS:
        return None
    tail = rest[first.end():]
    if not tail.strip():
        return receiver, first.group(1)
    if not tail.startswith(":"):
        return None
    flat = flatten_depth0(rest, "#")
    selector, ternary = [], 0
    for token in re.finditer(r"\?|(?<![\w#.])([A-Za-z_]\w*)?\s*:(?!:)", flat):
        if token.group(0) == "?":
            ternary += 1
            continue
        if ternary:
            ternary -= 1
            continue
        keyword = token.group(1) or ""
        before = flat[:token.start()].rstrip()
        if keyword and selector and before and not re.search(r"[\w#\])\"']$", before):
            # `[r k: a : b]` or `[r k: &a : b]`: `a` starts the argument of `k:`,
            # so the colon after it opens an anonymous part.
            keyword = ""
        selector.append(keyword + ":")
    return receiver, "".join(selector)


def message_sends(code):
    """Yield (start, receiver, selector) for every Objective-C message expression in `code`."""
    stack = []
    pairs = []
    for index, ch in enumerate(code):
        if ch == "[":
            stack.append(index)
        elif ch == "]" and stack:
            pairs.append((stack.pop(), index))
    for start, end in sorted(pairs):
        if start > 0 and code[start - 1] == "@":
            continue
        parsed = parse_message(code[start + 1:end])
        if parsed:
            yield start, parsed[0], parsed[1]


# ---------------------------------------------------------------- plugin scanning

class FileContext:
    def __init__(self, sdk, own_classes):
        self.sdk = sdk
        self.own = own_classes  # name -> super
        self.vars = {}
        self.impl = None

    def host_chain_class(self, name):
        """The nearest host class a plugin class inherits from, if any."""
        seen = set()
        while name and name not in seen:
            seen.add(name)
            if name in self.sdk.classes:
                return name
            name = self.own.get(name)
        return None

    def resolve(self, receiver, cache):
        receiver = receiver.strip()
        if receiver in cache:
            return cache[receiver]
        result = (None, False)
        cast = re.match(r"\(\s*([A-Za-z_]\w*)\s*\*?\s*\)\s*(.*)$", receiver, re.S)
        if cast and cast.group(1) in self.sdk.classes:
            result = (cast.group(1), False)
        elif cast:
            result = self.resolve(cast.group(2), cache)
        elif receiver.startswith("["):
            parsed = parse_message(receiver[1:-1])
            if parsed:
                inner_class, is_class = self.resolve(parsed[0], cache)
                info = None
                if inner_class:
                    _, info = self.sdk.lookup(inner_class, parsed[1])
                elif parsed[1] in self.sdk.selectors and len(self.sdk.selectors[parsed[1]]) == 1 \
                        and parsed[1] not in COMMON_SELECTORS and parsed[1] not in self.sdk.system_selectors:
                    _, info = self.sdk.lookup(next(iter(self.sdk.selectors[parsed[1]])), parsed[1])
                if info:
                    ret = info["ret"]
                    if ret == "instancetype":
                        result = (inner_class, False)
                    elif ret in self.sdk.classes:
                        result = (ret, False)
        else:
            parts = re.split(r"\s*(?:\.|->)\s*", receiver)
            head = parts[0]
            current = None
            if head in self.sdk.classes and head not in self.vars:
                current, is_class = head, True
                if len(parts) == 1:
                    result = (head, True)
            elif head == "self" and self.impl:
                current = self.host_chain_class(self.impl)
            elif head == "super" and self.impl:
                current = self.host_chain_class(self.own.get(self.impl))
            elif head in self.vars:
                current = self.vars[head]
            elif self.impl:
                host = self.host_chain_class(self.impl)
                if host:
                    current = self.sdk.ivar(host, head)[1]
            if result == (None, False):
                for member in parts[1:]:
                    if not current:
                        break
                    _, prop_type = self.sdk.prop(current, member)
                    if not prop_type:
                        _, prop_type = self.sdk.ivar(current, member)
                    current = prop_type if prop_type in self.sdk.classes else None
                result = (current if current in self.sdk.classes else None, False)
        cache[receiver] = result
        return result


def detect(patterns, text):
    found = Counter()
    for name, pattern in patterns:
        hits = re.findall(pattern, text)
        if hits:
            found[name] += len(hits)
    return found


def classify_import(target, sdk, local_files=()):
    first = target.split("/")[0]
    base = target.split("/")[-1]
    if "/" not in target and base in local_files:
        return "local", base
    if first in HOST_FRAMEWORKS and "/" in target:
        return "host", first
    if base.lower() in sdk.headers_lower:
        return "host", "(host header by name)"
    if "/" in target and first in APPLE_FRAMEWORKS:
        return "apple", first
    stem = base.rsplit(".", 1)[0]
    if C_STANDARD.match(stem) or C_STANDARD.match(first) or first in APPLE_FRAMEWORKS:
        return "system", first if "/" in target else stem
    for label, pattern in THIRD_PARTY_HINTS:
        if pattern.search(base) or pattern.search(first):
            return "third-party", label
    return "local", base


class PluginScan:
    def __init__(self, name, kind, paths):
        self.name = name
        self.kind = kind
        self.paths = paths
        self.files = []
        self.vendored = []
        self.binaries = []
        self.loc = Counter()
        self.languages = Counter()
        self.imports = defaultdict(Counter)   # category -> Counter(target)
        self.frameworks = Counter()
        self.third_party = Counter()
        self.missing_headers = Counter()
        self.classes = Counter()               # host class -> refs
        self.selectors = Counter()             # (class, selector, how) -> refs
        self.unresolved = Counter()            # (class, selector) not declared in the SDK
        self.private_decls = Counter()         # (host class, selector) declared by a plugin category
        self.deprecated = Counter()            # (class, selector)
        self.ivars = Counter()                 # (class, ivar, how)
        self.kvc = Counter()                   # (key, candidate classes)
        self.notifications = Counter()         # (name, host?)
        self.functions = Counter()             # host C functions / constants
        self.subclasses = Counter()            # (own, host super)
        self.categories = Counter()            # host class extended
        self.dynamic = Counter()
        self.dynamic_literals = Counter()      # (kind, literal)
        self.obsolete = Counter()
        self.licences = Counter()
        self.licence_files = []
        self.copyrights = Counter()
        self.unlicensed_files = 0
        self.plists = []
        self.projects = []
        self.git = None

    def area_counts(self):
        counts = Counter()
        for cls in self.classes:
            counts[area_of(cls)] += 1
        for (cls, _sel, _how) in self.selectors:
            counts[area_of(cls) if cls else "other"] += 1
        return counts


def git_info(path):
    path = Path(path).resolve()
    for candidate in [path] + list(path.parents):
        dot = candidate / ".git"
        if dot.is_file():
            text = dot.read_text(errors="replace")
            match = re.match(r"gitdir:\s*(.+)", text)
            if not match:
                return None
            dot = (candidate / match.group(1).strip()).resolve()
        if dot.is_dir():
            head = (dot / "HEAD").read_text(errors="replace").strip()
            common = dot
            if (dot / "commondir").is_file():
                common = (dot / (dot / "commondir").read_text().strip()).resolve()
            revision, branch = head, None
            if head.startswith("ref:"):
                ref = head[4:].strip()
                branch = ref.rsplit("/", 1)[-1]
                revision = None
                for base in (dot, common):
                    if (base / ref).is_file():
                        revision = (base / ref).read_text().strip()
                        break
                if not revision and (common / "packed-refs").is_file():
                    for line in (common / "packed-refs").read_text().splitlines():
                        if line.endswith(" " + ref):
                            revision = line.split()[0]
            url = None
            config = common / "config"
            if config.is_file():
                section = None
                for line in config.read_text(errors="replace").splitlines():
                    line = line.strip()
                    if line.startswith("["):
                        section = line
                    elif section == '[remote "origin"]' and line.startswith("url"):
                        url = line.split("=", 1)[1].strip()
                        url = re.sub(r"//[^/@]+@", "//", url)  # drop user names from URLs
            return {"revision": revision, "branch": branch, "remote": url}
    return None


def macho_archs(path):
    cpu = {7: "i386", 0x01000007: "x86_64", 18: "ppc", 0x01000012: "ppc64", 12: "arm", 0x0100000C: "arm64"}
    try:
        with open(path, "rb") as handle:
            head = handle.read(4096)
    except OSError:
        return None
    if len(head) < 8:
        return None
    magic = int.from_bytes(head[:4], "big")
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = int.from_bytes(head[4:8], "big")
        if count > 30:
            return None
        size = 20 if magic == 0xCAFEBABE else 32
        archs = []
        for k in range(count):
            offset = 8 + k * size
            archs.append(cpu.get(int.from_bytes(head[offset:offset + 4], "big"), "cpu%d" % k))
        return archs
    for order in ("little", "big"):
        if int.from_bytes(head[:4], order) in (0xFEEDFACE, 0xFEEDFACF):
            return [cpu.get(int.from_bytes(head[4:8], order), "unknown")]
    if head.startswith(b"!<arch>\n"):
        return ["static-archive"]
    return None


def parse_pbxproj(path):
    text = path.read_text(errors="replace")
    info = {"path": path.name, "products": [], "settings": defaultdict(set), "frameworks": set(), "libraries": set()}
    for match in re.finditer(r"isa\s*=\s*PBXFileReference;[^}]*?path\s*=\s*(\"[^\"]*\"|[^;]+);[^}]*?"
                             r"sourceTree\s*=\s*BUILT_PRODUCTS_DIR", text):
        info["products"].append(match.group(1).strip('"'))
    for match in re.finditer(r"isa\s*=\s*PBXFileReference;[^}]*?(?:name|path)\s*=\s*(\"[^\"]*\"|[^;]+);", text):
        name = match.group(1).strip('"').split("/")[-1]
        if name.endswith(".framework"):
            info["frameworks"].add(name[:-10])
        elif name.endswith((".a", ".dylib", ".tbd")):
            info["libraries"].add(name)
    for key in ("ARCHS", "VALID_ARCHS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "GCC_ENABLE_OBJC_GC",
                "WRAPPER_EXTENSION", "BUNDLE_LOADER", "CLANG_ENABLE_OBJC_ARC", "GCC_VERSION", "SWIFT_VERSION",
                "SWIFT_OBJC_BRIDGING_HEADER", "CLANG_CXX_LIBRARY", "INFOPLIST_KEY_NSPrincipalClass",
                "PRODUCT_BUNDLE_IDENTIFIER"):
        for match in re.finditer(r"\b%s\s*=\s*(\([^)]*\)|\"[^\"]*\"|[^;]+);" % key, text):
            value = match.group(1).strip()
            if value.startswith("("):
                value = value[1:-1]
            value = re.sub(r"\s+", " ", value).replace('"', "").strip(" ,")
            if value:
                info["settings"][key].add(value)
    for match in re.finditer(r"OTHER_LDFLAGS\s*=\s*(\([^)]*\)|\"[^\"]*\"|[^;]+);", text):
        flags = re.sub(r"[\s\"(),]+", " ", match.group(1)).strip()
        if "dynamic_lookup" in flags:
            info["settings"]["OTHER_LDFLAGS"].add("-undefined dynamic_lookup")
        for framework in re.findall(r"-framework\s+(\S+)", flags):
            info["frameworks"].add(framework)
    for match in re.finditer(r"(FRAMEWORK_SEARCH_PATHS|HEADER_SEARCH_PATHS)\s*=\s*(\([^)]*\)|\"[^\"]*\"|[^;]+);", text):
        for host in HOST_FRAMEWORKS:
            if host in match.group(2):
                info["settings"]["host search path"].add(host)
    info["settings"] = {k: sorted(v) for k, v in info["settings"].items()}
    info["frameworks"] = sorted(info["frameworks"])
    info["libraries"] = sorted(info["libraries"])
    return info


def read_plist(path):
    raw = path.read_bytes()
    try:
        data = plistlib.loads(raw)
    except Exception:
        text = raw.decode("utf-8", "replace")
        data = {}
        for key in ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
                    "NSPrincipalClass", "pluginType"):
            match = re.search(r"<key>%s</key>\s*<string>([^<]*)</string>" % key, text)
            if match:
                data[key] = match.group(1)
        titles = re.search(r"<key>MenuTitles</key>\s*<array>(.*?)</array>", text, re.S)
        if titles:
            data["MenuTitles"] = re.findall(r"<string>([^<]*)</string>", titles.group(1))
        data["_unparsed"] = True
    if not isinstance(data, dict):
        return None
    keys = ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
            "NSPrincipalClass", "pluginType", "MenuTitles", "FileFormats", "ToolbarNames", "IsiXPluginAPIVersion",
            "LSMinimumSystemVersion", "_unparsed")
    picked = {k: data[k] for k in keys if k in data}
    if "MenuTitles" in picked and isinstance(picked["MenuTitles"], list):
        picked["MenuTitles"] = [str(t) for t in picked["MenuTitles"]][:12]
    return picked if any(k in picked for k in ("NSPrincipalClass", "pluginType", "CFBundleExecutable",
                                               "MenuTitles", "CFBundleIdentifier")) else None


def walk(paths, scan):
    files = []
    for root in paths:
        root = Path(root)
        if root.is_file():
            files.append(root)
            continue
        stack = [root]
        while stack:
            current = stack.pop()
            try:
                entries = sorted(current.iterdir())
            except OSError:
                continue
            for entry in entries:
                if entry.is_symlink():
                    continue
                if entry.is_dir():
                    if entry.name.endswith(".xcodeproj"):
                        pbx = entry / "project.pbxproj"
                        if pbx.is_file():
                            scan.projects.append(parse_pbxproj(pbx))
                        continue
                    if SKIPPED_DIR.search(entry.name):
                        continue
                    if VENDORED_DIR.search(entry.name) and entry != root:
                        count = sum(1 for p in entry.rglob("*") if p.is_file())
                        scan.vendored.append({"path": str(entry.relative_to(root)), "files": count})
                        for candidate in entry.rglob("*"):
                            if candidate.is_file() and not candidate.is_symlink() and \
                                    (candidate.suffix in BINARY_SUFFIXES or not candidate.suffix):
                                archs = macho_archs(candidate)
                                if archs:
                                    scan.binaries.append({"path": str(candidate.relative_to(root)), "archs": archs})
                        continue
                    stack.append(entry)
                elif entry.is_file():
                    files.append(entry)
    return files


def scan_plugin(name, kind, paths, sdk, display_root=None):
    scan = PluginScan(name, kind, [str(p) for p in paths])
    files = walk(paths, scan)
    sources = []
    for path in files:
        lower = path.name.lower()
        if path.suffix in SOURCE_SUFFIXES:
            sources.append(path)
        elif path.name.endswith("Info.plist") or lower == "info.plist":
            plist = read_plist(path)
            if plist:
                plist["file"] = path.name
                scan.plists.append(plist)
        elif re.match(r"(?i)^(license|licence|copying|copyright|notice)", path.name):
            scan.licence_files.append(path.name)
            text = path.read_text(errors="replace")[:4000]
            for licence, pattern in LICENCE_PATTERNS:
                if re.search(pattern, text, re.I if licence != "GPL" else 0):
                    scan.licences[licence + " (file)"] += 1
                    break
        elif path.suffix in BINARY_SUFFIXES or (not path.suffix and path.stat().st_size > 1024):
            archs = macho_archs(path)
            if archs:
                scan.binaries.append({"path": path.name, "archs": archs})
    # Plugin classes first, so that inheritance from host classes is known in every file.
    own = {}
    parsed = []
    for path in sources:
        raw = path.read_text(errors="replace")
        swift = path.suffix == ".swift"
        nc, code = strip_source(raw, swift=swift)
        parsed.append((path, raw, nc, code, swift))
        if swift:
            for match in re.finditer(r"\b(?:class|struct|enum|actor)\s+([A-Za-z_]\w*)\s*(?::\s*([A-Za-z_]\w*))?", code):
                own.setdefault(match.group(1), match.group(2))
        else:
            for match in re.finditer(r"@interface\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)", code):
                own[match.group(1)] = match.group(2)
            for match in re.finditer(r"\bclass\s+([A-Za-z_]\w*)\s*(?::\s*(?:public\s+)?([\w:]+))?\s*\{", code):
                own.setdefault(match.group(1), None)
    own_selectors = set()
    for _path, _raw, _nc, code, swift in parsed:
        if not swift:
            # Methods declared in a category on a host class name host methods the
            # plugin expects to exist (often private ones), not its own.
            host_blocks = []
            for block in re.finditer(r"@(?:interface|implementation)\s+([A-Za-z_]\w*)\s*\(\s*\w*\s*\)", code):
                if block.group(1) in sdk.defined:
                    end = code.find("@end", block.end())
                    host_blocks.append((block.start(), end if end > 0 else len(code), block.group(1),
                                        code[block.start():block.start() + 2] == "@i"))
            for method in re.finditer(r"(?m)^\s*[-+]\s*\(((?:[^()]|\([^()]*\))*)\)\s*([^;{]+?)\s*[;{]", code):
                selector = selector_of(method.group(2))
                if not selector:
                    continue
                inside = [b for b in host_blocks if b[0] <= method.start() < b[1]]
                if inside:
                    host_class, is_interface = inside[0][2], inside[0][3]
                    if is_interface and not sdk.lookup(host_class, selector)[1]:
                        scan.private_decls[(host_class, selector)] += 1
                    continue
                own_selectors.add(selector)
            for prop in re.finditer(r"@property\s*(?:\([^)]*\))?\s*[^;]*?([A-Za-z_]\w*)\s*;", code):
                own_selectors.add(prop.group(1))
                own_selectors.add("set" + prop.group(1)[:1].upper() + prop.group(1)[1:] + ":")
    own["__selectors__"] = own_selectors
    own["__files__"] = {path.name for path in sources}
    plugin_vars = {}
    for _path, _raw, _nc, code, swift in parsed:
        if not swift:
            plugin_vars.update({k: v for k, v in declared_vars(code, sdk).items() if k not in plugin_vars})
    own["__vars__"] = plugin_vars
    own["__swift_members__"] = {name for _p, _r, _n, code, swift in parsed if swift
                                for name in re.findall(r"\b(?:case|func|var|let)\s+([a-z_]\w*)", code)}
    for cls, superclass in own.items():
        if cls.startswith("__"):
            continue  # metadata entries, not classes
        if superclass in sdk.defined and cls not in sdk.classes:
            scan.subclasses[(cls, superclass)] += 1
    for path, raw, nc, code, swift in parsed:
        scan_source(scan, sdk, own, path, raw, nc, code, swift)
    for project in scan.projects:
        settings = project["settings"]
        if any(v in ("supported", "required", "YES") for v in settings.get("GCC_ENABLE_OBJC_GC", [])):
            scan.obsolete["garbage-collection"] += 1
        archs = " ".join(settings.get("ARCHS", []) + settings.get("VALID_ARCHS", []))
        sdkroot = " ".join(settings.get("SDKROOT", []))
        if re.search(r"\b(ppc\w*|i386)\b|ARCHS_STANDARD_32", archs) or re.search(r"10\.[0-9]\b|10\.1[0-5]", sdkroot):
            scan.obsolete["legacy-sdk/arch"] += 1
    return scan


def scan_source(scan, sdk, own, path, raw, nc, code, swift):
    lines = raw.count("\n") + 1
    language = {".swift": "Swift", ".m": "Objective-C", ".mm": "Objective-C++", ".c": "C", ".h": "header",
                ".pch": "header", ".hh": "header", ".hpp": "header", ".hxx": "header", ".txx": "C++"}.get(path.suffix, "C++")
    scan.languages[language] += 1
    scan.loc[language] += lines
    # Licence markers: comment header of every file.
    header = "\n".join(raw.splitlines()[:80])
    found = False
    for licence, pattern in LICENCE_PATTERNS:
        if re.search(pattern, header, 0 if licence == "GPL" else re.I):
            if licence == "GPL" and re.search(LICENCE_PATTERNS[0][1], header, re.I):
                continue
            scan.licences[licence] += 1
            if licence != "all-rights-reserved":
                found = True
    if not found:
        scan.unlicensed_files += 1
    for match in re.finditer(r"(?im)^\W*copyright\s*(?:\(c\)|©)?\s*([^\n]{0,70})", header):
        holder = re.sub(r"\s+", " ", match.group(1)).strip(" .*/")
        holder = re.sub(r"^(?:\(c\)|©)\s*", "", holder, flags=re.I)
        holder = re.sub(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", "<e-mail>", holder)  # names stay, addresses do not
        if holder and "free software foundation" not in holder.lower():
            scan.copyrights[holder[:60]] += 1
    scan.obsolete.update(detect(OBSOLETE_PATTERNS, code))
    if swift:
        scan_swift(scan, sdk, own, nc, code)
    else:
        scan_objc(scan, sdk, own, nc, code)
    scan.dynamic.update(detect(DYNAMIC_PATTERNS, nc if True else code))
    # Literal arguments of dynamic lookups.
    for kind, pattern in [("class", r"(?:NSClassFromString|objc_getClass|objc_lookUpClass)\s*\(\s*@?\"(\w+)\""),
                          ("class", r"classNamed:\s*@\"(\w+)\""),
                          ("selector", r"NSSelectorFromString\s*\(\s*@?\"([\w:]+)\""),
                          ("selector", r"[@#]selector\s*\(\s*([\w:()]+?)\s*\)"),
                          ("notification", r"postNotificationName:\s*@\"(\w+)\""),
                          ("notification", r"\bname:\s*@\"(\w+)\""),
                          ("notification", r"Notification\.Name\s*\(\s*(?:rawValue:\s*)?\"(\w+)\""),
                          ("entity", r"entityForName:\s*@\"(\w+)\""),
                          ("entity", r"fetchRequestWithEntityName:\s*@\"(\w+)\"")]:
        for match in re.finditer(pattern, nc):
            literal = match.group(1)
            scan.dynamic_literals[(kind, literal)] += 1
            if kind == "notification":
                scan.notifications[(literal, literal in sdk.notifications)] += 1
            if kind == "class" and literal in sdk.defined:
                scan.classes[literal] += 1
    for pattern in [r"valueForKey(?:Path)?:\s*@\"([\w.@]+)\"", r"forKey(?:Path)?:\s*@\"([\w.@]+)\"",
                    r"value\s*\(\s*forKey(?:Path)?:\s*\"([\w.@]+)\"", r"forKey(?:Path)?:\s*\"([\w.@]+)\"\s*\)",
                    r"sortDescriptorWithKey:\s*@\"([\w.]+)\"", r"initWithKey:\s*@\"([\w.]+)\""]:
        for match in re.finditer(pattern, nc):
            add_kvc(scan, sdk, match.group(1))
    for match in re.finditer(r"predicateWithFormat:\s*@\"([^\"]*)\"|NSPredicate\s*\(\s*format:\s*\"([^\"]*)\"", nc):
        text = match.group(1) or match.group(2) or ""
        for key in re.findall(r"([A-Za-z_][\w.]*)\s*(?:==|=|!=|<=|>=|<|>|\bCONTAINS|\bLIKE|\bBEGINSWITH|\bENDSWITH|"
                              r"\bIN\b|\bMATCHES)", text):
            if key.upper() not in ("ANY", "ALL", "NONE", "SOME", "SELF", "AND", "OR", "NOT"):
                add_kvc(scan, sdk, key)


def add_kvc(scan, sdk, key):
    first = key.split(".")[0].lstrip("@")
    owners = [name for name, info in sdk.classes.items() if first in info["props"]]
    scan.kvc[(key, owners_label(sdk, owners).replace("|", ",") if owners else "")] += 1


def owners_label(sdk, owners):
    """Declaring classes of an ambiguous selector, Objective-C SDK classes first."""
    ranked = sorted(owners, key=lambda c: (c.startswith(("Horos", "N2", "NS")), area_of(c) == "other", c))
    return "|".join(ranked[:3]) + ("|…" if len(ranked) > 3 else "")


def record_selector(scan, sdk, cls, selector, how):
    scan.selectors[(cls, selector, how)] += 1
    if cls and "|" not in cls:
        _, info = sdk.lookup(cls, selector)
        if info and info.get("deprecated"):
            scan.deprecated[(cls, selector)] += 1


def declared_vars(code, sdk):
    """Variables, parameters, ivars and properties declared with a host class type."""
    found = {}
    for pattern in (r"\b([A-Z]\w*)\s*\*\s*(?:const\s+)?([a-zA-Z_]\w*)\s*(?=[;,=)\[])",
                    r"\(\s*([A-Z]\w*)\s*\*\s*\)\s*([a-zA-Z_]\w*)",
                    r"@property\s*(?:\([^)]*\))?\s*([A-Z]\w*)\s*\*\s*(\w+)"):
        for match in re.finditer(pattern, code):
            if match.group(1) in sdk.classes:
                found.setdefault(match.group(2), match.group(1))
    return found


def scan_objc(scan, sdk, own, nc, code):
    for match in re.finditer(r"(?m)^\s*#\s*(?:import|include)\s*([<\"])([^>\"]+)[>\"]", nc):
        target = match.group(2).strip()
        category, label = classify_import(target, sdk, own.get("__files__", ()))
        scan.imports[category][target] += 1
        if category == "host":
            scan.frameworks[label] += 1
            base = target.split("/")[-1]
            # Plugins were built on case-insensitive volumes: browserController.h found BrowserController.h.
            if base.lower() not in sdk.headers_lower:
                scan.missing_headers[target] += 1
        elif category == "third-party":
            scan.third_party[label] += 1
        elif category == "apple":
            scan.frameworks[label] += 1
    context = FileContext(sdk, own)
    context.vars = dict(own.get("__vars__", {}))
    context.vars.update(declared_vars(code, sdk))
    # Preprocessor lines name frameworks, not classes.
    code = re.sub(r"(?m)^[ \t]*#.*$", lambda m: " " * len(m.group(0)), code)
    # Categories on host classes are part of the ABI surface a plugin relies on.
    for match in re.finditer(r"@(?:interface|implementation)\s+([A-Za-z_]\w*)\s*\(\s*(\w*)\s*\)", code):
        if match.group(1) in sdk.classes:
            scan.categories[match.group(1)] += 1
    # Host class names mentioned anywhere in code.
    for word in re.findall(r"\b[A-Z][A-Za-z0-9_]+\b", code):
        if word in sdk.defined and word not in own:
            scan.classes[word] += 1
        elif word in sdk.notifications:
            scan.notifications[(word, True)] += 1
        elif word in sdk.constants:
            scan.functions[word] += 1
    for word in re.findall(r"\b([A-Za-z_]\w*)\s*\(", code):
        if word in sdk.functions and word not in STOP_IDENTIFIERS and word not in sdk.system_functions:
            scan.functions[word + "()"] += 1
    # Implementation ranges, to resolve self/super and inherited ivars.
    impls = [(m.start(), m.group(1)) for m in re.finditer(r"@implementation\s+([A-Za-z_]\w*)", code)]
    cache_by_impl = {}

    def impl_at(position):
        current = None
        for start, name in impls:
            if start <= position:
                current = name
        return current

    for start, receiver, selector in message_sends(code):
        context.impl = impl_at(start)
        cache = cache_by_impl.setdefault(context.impl, {})
        cls, is_class = context.resolve(receiver, cache)
        if cls:
            declaring, info = sdk.lookup(cls, selector)
            if info:
                record_selector(scan, sdk, declaring, selector, "typed")
            elif selector in sdk.system_selectors or selector in COMMON_SELECTORS:
                continue  # inherited from Cocoa
            elif selector in own.get("__selectors__", ()):
                continue  # declared by the plugin itself (own subclass or category)
            elif selector in sdk.selectors:
                owners = sorted(sdk.selectors[selector])
                record_selector(scan, sdk, owners[0] if len(owners) == 1 else owners_label(sdk, owners), selector,
                                "name-only" if len(owners) == 1 else "ambiguous")
            elif cls in sdk.defined:
                scan.unresolved[(cls, selector)] += 1
        elif selector in sdk.selectors and selector not in COMMON_SELECTORS and \
                selector not in sdk.system_selectors and selector not in own.get("__selectors__", ()):
            owners = sorted(sdk.selectors[selector])
            record_selector(scan, sdk, owners[0] if len(owners) == 1 else owners_label(sdk, owners), selector,
                            "name-only" if len(owners) == 1 else "ambiguous")
    # Host methods a plugin class overrides: the entry points the host calls.
    for start, name in impls:
        host = context.host_chain_class(name)
        if not host or name in sdk.classes:
            continue
        end = code.find("@end", start)
        body = code[start:end if end > 0 else len(code)]
        for method in re.finditer(r"(?m)^\s*[-+]\s*\(((?:[^()]|\([^()]*\))*)\)\s*([^;{]+?)\s*\{", body):
            selector = selector_of(method.group(2))
            declaring, info = sdk.lookup(host, selector) if selector else (None, None)
            if info:
                record_selector(scan, sdk, declaring, selector, "override")
    # Direct ivar access and inherited ivars.
    for match in re.finditer(r"([A-Za-z_]\w*)\s*->\s*([A-Za-z_]\w*)", code):
        cls = context.vars.get(match.group(1))
        if cls:
            owner, _ = sdk.ivar(cls, match.group(2))
            if owner:
                scan.ivars[(owner, match.group(2), "->")] += 1
    for start, name in impls:
        host = context.host_chain_class(name)
        if not host or name in sdk.classes:
            continue
        end = code.find("@end", start)
        body = code[start:end if end > 0 else len(code)]
        chain, _ = sdk.chain(host)
        for cls in chain:
            for ivar in sdk.classes[cls]["ivars"]:
                hits = len(re.findall(r"(?<![\w.>])%s\b" % re.escape(ivar), body))
                if hits:
                    scan.ivars[(cls, ivar, "inherited")] += hits
    # Dot syntax on typed receivers (attributes).
    for match in re.finditer(r"\b([a-zA-Z_]\w*)\.([a-zA-Z_]\w*)\b", code):
        cls = context.vars.get(match.group(1))
        if cls:
            owner, _ = sdk.prop(cls, match.group(2))
            if owner:
                scan.ivars[(owner, match.group(2), "property")] += 1


def scan_swift(scan, sdk, own, nc, code):
    for match in re.finditer(r"(?m)^\s*(?:@\w+\s+)*import\s+(?:class\s+|struct\s+)?([A-Za-z_][\w.]*)", code):
        module = match.group(1).split(".")[0]
        category = "host" if module in HOST_FRAMEWORKS else ("apple" if module in APPLE_FRAMEWORKS else "local")
        scan.imports[category][module] += 1
        scan.frameworks[module] += 1
    for match in re.finditer(r"\bextension\s+([A-Za-z_]\w*)", code):
        if match.group(1) in sdk.classes:
            scan.categories[match.group(1)] += 1
    for word in re.findall(r"\b[A-Z][A-Za-z0-9_]+\b", code):
        if word in sdk.defined and word not in own:
            scan.classes[word] += 1
        elif word in sdk.notifications:
            scan.notifications[(word, True)] += 1
    # Swift has no message syntax to parse; member names are matched against
    # the first keyword of host selectors and host properties, without types.
    declared = own.get("__swift_members__", set())
    names = defaultdict(set)
    for selector, owners in sdk.selectors.items():
        names[selector.split(":")[0]].add(selector)
    for match in re.finditer(r"(?<=[\w)\]?!])\.([a-z_]\w*)\b", code):
        member = match.group(1)
        if member not in names or member in SWIFT_STANDARD_MEMBERS or member in declared:
            continue
        candidates = [s for s in names[member] if s not in COMMON_SELECTORS and s not in sdk.system_selectors]
        if not candidates or member in COMMON_SELECTORS:
            continue
        owners = sorted(set().union(*(sdk.selectors[s] for s in candidates)))
        selector = sorted(candidates, key=len)[0]
        record_selector(scan, sdk, owners[0] if len(owners) == 1 else owners_label(sdk, owners), selector,
                        "swift-member" if len(owners) == 1 else "swift-member-ambiguous")
    for word in re.findall(r"\b([A-Za-z_]\w*)\s*\(", code):
        if word in sdk.functions and word not in sdk.system_functions:
            scan.functions[word + "()"] += 1
    # Overrides of host methods by a plugin class that inherits from a host class.
    for match in re.finditer(r"\bclass\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)", code):
        if match.group(2) not in sdk.defined:
            continue
        end = re.search(r"(?m)^\}", code[match.end():])
        body = code[match.end():match.end() + end.start()] if end else code[match.end():]
        for method in re.finditer(r"\boverride\s+(?:public\s+|open\s+)?func\s+([A-Za-z_]\w*)", body):
            chain, _ = sdk.chain(match.group(2))
            for cls in chain:
                hits = [s for s in sdk.classes[cls]["methods"] if s.split(":")[0] == method.group(1)]
                if hits:
                    record_selector(scan, sdk, cls, sorted(hits, key=len)[0], "override")
                    break


# ---------------------------------------------------------------- collection and reports

def has_plugin_markers(directory):
    for path in directory.rglob("*"):
        if path.suffix == ".xcodeproj" or path.suffix in SOURCE_SUFFIXES or path.name == "Info.plist":
            return True
    return False


def collection_entries(root):
    entries = []
    for child in sorted(Path(root).iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        projects = list(child.glob("*.xcodeproj")) + list(child.glob("*/*.xcodeproj"))
        direct_sources = [p for p in child.iterdir() if p.suffix in SOURCE_SUFFIXES or p.name == "Info.plist"]
        groups = [g for g in sorted(child.iterdir()) if g.is_dir() and not g.name.startswith(".") and
                  list(g.glob("*.xcodeproj"))]
        if not list(child.glob("*.xcodeproj")) and not direct_sources and len(groups) > 1:
            for group in groups:
                entries.append((child.name + "/" + group.name, group, "grouped"))
        elif projects or has_plugin_markers(child):
            entries.append((child.name, child, "folder"))
        else:
            entries.append((child.name, child, "no-sources"))
    return entries


def plugin_products(scan):
    products = []
    for project in scan.projects:
        for product in project["products"]:
            if re.search(r"\.(osirixplugin|horosplugin|isixplugin|plugin|bundle)$", product):
                products.append(product)
    return products


def archs_of(scan):
    archs = set()
    for project in scan.projects:
        for key in ("ARCHS", "VALID_ARCHS"):
            for value in project["settings"].get(key, []):
                archs.update(a for a in re.split(r"[\s,]+", value) if a and not a.startswith("$"))
                if "$(ARCHS_STANDARD" in value or "ARCHS_STANDARD" in value:
                    archs.add(value.strip())
    for binary in scan.binaries:
        archs.update(binary["archs"])
    return sorted(archs)


def setting(scan, key):
    values = set()
    for project in scan.projects:
        values.update(project["settings"].get(key, []))
    return sorted(values)


def redistribution(scan):
    open_licences = [k for k in scan.licences if not k.startswith("all-rights-reserved")]
    total = sum(scan.languages.values())
    if total == 0:
        return "sem fontes"
    if open_licences and scan.unlicensed_files == 0:
        return "permitida (" + "/".join(sorted({k.replace(" (file)", "") for k in open_licences})) + ")"
    if open_licences:
        return "pendente: %d de %d arquivos sem licença no cabeçalho" % (scan.unlicensed_files, total)
    return "pendente: nenhuma licença declarada"


def to_json(scan):
    def pairs(counter, keys):
        return [dict(zip(keys, key if isinstance(key, tuple) else (key,)), refs=count)
                for key, count in sorted(counter.items(), key=lambda kv: (-kv[1], str(kv[0])))]
    return {
        "name": scan.name,
        "kind": scan.kind,
        "git": scan.git,
        "plists": scan.plists,
        "projects": scan.projects,
        "plugin_products": plugin_products(scan),
        "archs": archs_of(scan),
        "languages": dict(scan.languages),
        "loc": dict(scan.loc),
        "vendored": scan.vendored,
        "binaries": scan.binaries,
        "licences": dict(scan.licences),
        "licence_files": scan.licence_files,
        "files_without_licence": scan.unlicensed_files,
        "copyrights": pairs(scan.copyrights, ["holder"])[:8],
        "redistribution": redistribution(scan),
        "imports": {k: dict(v) for k, v in scan.imports.items()},
        "frameworks": dict(scan.frameworks),
        "third_party": dict(scan.third_party),
        "host_headers_missing_from_sdk": dict(scan.missing_headers),
        "classes": [{"class": c, "area": area_of(c), "refs": n} for c, n in scan.classes.most_common()],
        "selectors": [{"class": c, "selector": s, "how": h, "area": area_of(c) if c else "other", "refs": n}
                      for (c, s, h), n in sorted(scan.selectors.items(), key=lambda kv: (-kv[1], str(kv[0])))],
        "selectors_not_in_sdk": pairs(scan.unresolved, ["class", "selector"]),
        "host_methods_declared_by_plugin": pairs(scan.private_decls, ["class", "selector"]),
        "deprecated_in_sdk": pairs(scan.deprecated, ["class", "selector"]),
        "ivars_and_attributes": pairs(scan.ivars, ["class", "name", "how"]),
        "kvc_keys": pairs(scan.kvc, ["key", "host_classes"]),
        "notifications": pairs(scan.notifications, ["name", "declared_by_host"]),
        "host_functions_and_constants": pairs(scan.functions, ["name"]),
        "subclasses_of_host": pairs(scan.subclasses, ["class", "host_super"]),
        "categories_on_host": pairs(scan.categories, ["class"]),
        "dynamic": dict(scan.dynamic),
        "dynamic_literals": pairs(scan.dynamic_literals, ["kind", "literal"]),
        "obsolete": dict(scan.obsolete),
        "area_counts": dict(scan.area_counts()),
    }


LIMITS = [
    "Análise estática e textual: nada foi compilado, carregado ou executado; macros, #if e código gerado não são avaliados.",
    "Receptores Objective-C são tipados só por declarações `Classe *nome`, casts, `self`/`super`, ivars herdadas e tipos de retorno do SDK; o resto conta como correspondência por nome (`name-only`/`ambiguous`).",
    "Seletores comuns do Cocoa (lista interna e, com --macos-sdk, os headers do sistema) não são atribuídos ao host por nome.",
    "Swift é lido sem resolução de tipos: membros são casados com o primeiro rótulo dos seletores do SDK (`swift-member`).",
    "Acessos dinâmicos (performSelector, NSClassFromString, KVC, predicados) são contados; só argumentos literais são resolvidos.",
    "Licença vem dos cabeçalhos dos arquivos e de arquivos LICENSE/COPYING; não é parecer jurídico.",
    "Arquiteturas vêm de ARCHS/VALID_ARCHS do projeto e de binários Mach-O presentes; ARCHS ausente significa padrão do Xcode da época.",
    "Pastas de SDK/bibliotecas copiadas (`*.framework`, `*Headers`, ITK/VTK, `Binaries`) são listadas e não varridas como fonte do plugin.",
]


def cell(values, limit=12):
    values = [str(v).replace("|", "\\|") for v in values]
    if not values:
        return "—"
    more = len(values) - limit
    return ", ".join(values[:limit]) + (" (+%d)" % more if more > 0 else "")


def markdown(report):
    out = []
    out.append("# Inventário da API de plugins (gerado)\n")
    out.append("Gerado por `tools/inventory-plugin-api.py`. Não editar à mão; rodar de novo.\n")
    out.append("## Entradas\n")
    out.append("| Entrada | Caminho | Revisão | Origem |")
    out.append("| --- | --- | --- | --- |")
    for source in report["sources"]:
        git = source.get("git") or {}
        out.append("| %s | `%s` | %s | %s |" % (source["name"], source["label"], git.get("revision") or "—",
                                             git.get("remote") or "—"))
    sdk = report["sdk"]
    out.append("\nSDK do host: %d headers, %d classes, %d seletores, %d notificações, %d funções C; "
               "seletores do sistema para exclusão: %d.\n"
               % (sdk["headers"], sdk["classes"], sdk["selectors"], sdk["notifications"], sdk["functions"],
                  sdk["system_selectors"]))
    for directory, git in zip(sdk["dirs"], sdk["git"]):
        git = git or {}
        out.append("- Headers: `%s` — revisão %s (%s)" % (directory, git.get("revision") or "fora de git",
                                                         git.get("remote") or "sem remoto"))
    out.append("")
    out.append("## Contagens\n")
    for source in report["sources"]:
        c = source["counts"]
        out.append("- %s: %d pastas examinadas; %d projetos que produzem bundle de plugin; %d produtos de "
                   "bundle de plugin declarados; projetos sem bundle de plugin: %s; pastas sem fontes: %s."
                   % (source["name"], c["entries"], c["plugins"], c["products"], cell(c["not_plugins"]),
                      cell(c["no_source_names"])))
    out.append("\n## Limites da análise\n")
    for limit in LIMITS:
        out.append("- " + limit)
    plugins = report["plugins"]
    out.append("\n## Resumo por plugin\n")
    out.append("| Plugin | Tipo/classe principal | Versão | Linguagens (LOC) | Licença | Redistribuição | "
               "Arquiteturas | SDK/alvo | Obsoletos | Terceiros | Dinâmicos | Uso por área |")
    out.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for p in plugins:
        plist = p["plists"][0] if p["plists"] else {}
        kind = "%s / %s" % (plist.get("pluginType", "—"), plist.get("NSPrincipalClass", "—"))
        version = plist.get("CFBundleShortVersionString") or plist.get("CFBundleVersion") or "—"
        langs = cell(["%s %d" % (k, p["loc"][k]) for k in sorted(p["loc"], key=lambda k: -p["loc"][k])], 4)
        licences = cell(sorted(p["licences"]), 4)
        sdkroot = cell(sorted(set(p_ for proj in p["projects"] for p_ in proj["settings"].get("SDKROOT", []) +
                                  proj["settings"].get("MACOSX_DEPLOYMENT_TARGET", []))), 4)
        obsolete = cell(sorted(p["obsolete"]), 6)
        third = cell(sorted(p["third_party"]), 5)
        dynamic = sum(p["dynamic"].values())
        areas = cell(["%s %d" % (AREA_TITLES[a], p["area_counts"][a]) for a in AREAS if p["area_counts"].get(a)], 8)
        out.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %d | %s |" % (
            p["name"], kind, version, langs, licences, p["redistribution"], cell(p["archs"], 6), sdkroot,
            obsolete, third, dynamic, areas))
    out.append("\n## Uso por área (todos os plugins)\n")
    for area in AREAS:
        classes, selectors, plugin_sets = Counter(), Counter(), defaultdict(set)
        for p in plugins:
            for entry in p["classes"]:
                if entry["area"] == area:
                    classes[entry["class"]] += entry["refs"]
                    plugin_sets[("c", entry["class"])].add(p["name"])
            for entry in p["selectors"]:
                if entry["area"] == area:
                    key = "%s %s" % (entry["class"] or "?", entry["selector"])
                    selectors[key] += entry["refs"]
                    plugin_sets[("s", key)].add(p["name"])
        if not classes and not selectors:
            continue
        out.append("### %s\n" % AREA_TITLES[area])
        out.append("| Classe | Plugins | Referências |")
        out.append("| --- | --- | --- |")
        for name, refs in sorted(classes.items(), key=lambda kv: (-len(plugin_sets[("c", kv[0])]), -kv[1]))[:40]:
            out.append("| %s | %d | %d |" % (name, len(plugin_sets[("c", name)]), refs))
        out.append("\n| Seletor (classe declarante) | Plugins | Referências |")
        out.append("| --- | --- | --- |")
        for name, refs in sorted(selectors.items(), key=lambda kv: (-len(plugin_sets[("s", kv[0])]), -kv[1]))[:60]:
            out.append("| `%s` | %d | %d |" % (name, len(plugin_sets[("s", name)]), refs))
        out.append("")
    for title, key, fmt in [("Notificações", "notifications", lambda e: "%s%s" % (e["name"], "" if e["declared_by_host"] else " (não declarada no SDK)")),
                            ("Chaves KVC/predicados", "kvc_keys", lambda e: "%s → %s" % (e["key"], e["host_classes"] or "?")),
                            ("Ivars e atributos do host", "ivars_and_attributes", lambda e: "%s.%s (%s)" % (e["class"], e["name"], e["how"])),
                            ("Subclasses de classes do host", "subclasses_of_host", lambda e: "%s : %s" % (e["class"], e["host_super"])),
                            ("Categorias/extensões em classes do host", "categories_on_host", lambda e: e["class"]),
                            ("Seletores não declarados no SDK atual (receptor tipado)", "selectors_not_in_sdk", lambda e: "%s %s" % (e["class"], e["selector"])),
                            ("Métodos do host declarados pelo plugin e ausentes do SDK (API privada/removida)", "host_methods_declared_by_plugin", lambda e: "%s %s" % (e["class"], e["selector"])),
                            ("Seletores marcados como obsoletos no SDK", "deprecated_in_sdk", lambda e: "%s %s" % (e["class"], e["selector"])),
                            ("Funções C e constantes do host", "host_functions_and_constants", lambda e: e["name"])]:
        totals, users = Counter(), defaultdict(set)
        for p in plugins:
            for entry in p[key]:
                label = fmt(entry)
                totals[label] += entry["refs"]
                users[label].add(p["name"])
        if not totals:
            continue
        out.append("### %s\n" % title)
        out.append("| Item | Plugins | Referências |")
        out.append("| --- | --- | --- |")
        for label, refs in sorted(totals.items(), key=lambda kv: (-len(users[kv[0]]), -kv[1]))[:60]:
            out.append("| `%s` | %d | %d |" % (label, len(users[label]), refs))
        out.append("")
    totals, users = Counter(), defaultdict(set)
    for p in plugins:
        for kind, refs in p["dynamic"].items():
            totals[kind] += refs
            users[kind].add(p["name"])
    out.append("### Acessos dinâmicos/indiretos\n")
    out.append("| Tipo | Plugins | Ocorrências |")
    out.append("| --- | --- | --- |")
    for kind, refs in totals.most_common():
        out.append("| %s | %d | %d |" % (kind, len(users[kind]), refs))
    totals, users = Counter(), defaultdict(set)
    for p in plugins:
        for kind, refs in p["obsolete"].items():
            totals[kind] += refs
            users[kind].add(p["name"])
    out.append("\n### APIs de plataforma obsoletas\n")
    out.append("| Marca | Plugins | Ocorrências |")
    out.append("| --- | --- | --- |")
    for kind, refs in totals.most_common():
        out.append("| %s | %d | %d |" % (kind, len(users[kind]), refs))
    out.append("\n## Detalhe por plugin\n")
    for p in plugins:
        out.append("### %s\n" % p["name"])
        plist = p["plists"]
        out.append("- Info.plist: " + (cell(["%s: %s" % (k, v if not isinstance(v, list) else "/".join(map(str, v)))
                                             for pl in plist for k, v in pl.items() if k != "file"], 10)
                                       if plist else "—"))
        out.append("- Produtos de plugin: " + cell(p["plugin_products"]))
        settings = defaultdict(set)
        for project in p["projects"]:
            for key, values in project["settings"].items():
                settings[key].update(values)
        out.append("- Build: " + cell(["%s=%s" % (k, "/".join(sorted(v))) for k, v in sorted(settings.items())
                                       if k in ("ARCHS", "VALID_ARCHS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET",
                                                "GCC_ENABLE_OBJC_GC", "WRAPPER_EXTENSION", "BUNDLE_LOADER",
                                                "OTHER_LDFLAGS", "CLANG_ENABLE_OBJC_ARC", "SWIFT_VERSION",
                                                "SWIFT_OBJC_BRIDGING_HEADER", "host search path",
                                                "INFOPLIST_KEY_NSPrincipalClass")], 14))
        frameworks = sorted({f for project in p["projects"] for f in project["frameworks"]})
        out.append("- Frameworks ligados: " + cell(frameworks, 16))
        out.append("- Headers do host importados: " + cell(sorted(p["imports"].get("host", {})), 20))
        if p["host_headers_missing_from_sdk"]:
            out.append("- Headers do host ausentes do SDK atual: " + cell(sorted(p["host_headers_missing_from_sdk"])))
        out.append("- Terceiros: " + cell(sorted(p["third_party"])) + "; copiados: " +
                   cell(["%s (%d arq.)" % (v["path"], v["files"]) for v in p["vendored"]], 6) +
                   "; binários: " + cell(["%s %s" % (b["path"], "/".join(b["archs"])) for b in p["binaries"]], 6))
        out.append("- Licença: " + cell(["%s ×%d" % (k, v) for k, v in sorted(p["licences"].items())]) +
                   "; arquivos sem licença: %d; titulares: %s" % (p["files_without_licence"],
                                                                 cell([c["holder"] for c in p["copyrights"]], 4)))
        for area in AREAS:
            classes = [e["class"] for e in p["classes"] if e["area"] == area]
            selectors = ["%s%s" % (e["selector"], "" if e["how"] in ("typed", "override") else "*") for e in p["selectors"]
                         if e["area"] == area]
            if classes or selectors:
                out.append("- %s: classes %s; seletores %s" % (AREA_TITLES[area], cell(classes, 10),
                                                               cell(selectors, 20)))
        for label, key, fmt in [("Ivars/atributos", "ivars_and_attributes", lambda e: "%s.%s(%s)" % (e["class"], e["name"], e["how"])),
                                ("KVC", "kvc_keys", lambda e: e["key"]),
                                ("Notificações", "notifications", lambda e: e["name"]),
                                ("ABI: subclasses", "subclasses_of_host", lambda e: "%s:%s" % (e["class"], e["host_super"])),
                                ("ABI: categorias", "categories_on_host", lambda e: e["class"]),
                                ("ABI: funções/constantes", "host_functions_and_constants", lambda e: e["name"]),
                                ("Não declarados no SDK", "selectors_not_in_sdk", lambda e: "%s %s" % (e["class"], e["selector"])),
                                ("Declarados pelo plugin em classes do host", "host_methods_declared_by_plugin", lambda e: "%s %s" % (e["class"], e["selector"])),
                                ("Obsoletos no SDK", "deprecated_in_sdk", lambda e: "%s %s" % (e["class"], e["selector"])),
                                ("Literais dinâmicos", "dynamic_literals", lambda e: "%s:%s" % (e["kind"], e["literal"]))]:
            if p[key]:
                out.append("- %s: %s" % (label, cell([fmt(e) for e in p[key]], 16)))
        if p["dynamic"]:
            out.append("- Dinâmicos: " + cell(["%s ×%d" % (k, v) for k, v in sorted(p["dynamic"].items())]))
        if p["obsolete"]:
            out.append("- Plataforma obsoleta: " + cell(["%s ×%d" % (k, v) for k, v in sorted(p["obsolete"].items())]))
        out.append("")
    out.append("`*` = seletor atribuído por nome, sem receptor tipado; sem `*`: receptor tipado ou método do host "
               "sobrescrito pelo plugin.\n")
    return "\n".join(out) + "\n"


def parse_named(value):
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    name, paths = value.split("=", 1)
    return name.strip(), [Path(p.strip()) for p in paths.split(",") if p.strip()]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--api-headers", action="append", required=True, type=Path,
                        help="directory with the host SDK headers (repeatable)")
    parser.add_argument("--collection", action="append", default=[], type=parse_named,
                        help="NAME=DIR whose subdirectories are plugins")
    parser.add_argument("--plugin", action="append", default=[], type=parse_named,
                        help="NAME=PATH[,PATH...] scanned as one plugin")
    parser.add_argument("--macos-sdk", type=Path, help="macOS SDK root, to recognise Cocoa selectors")
    parser.add_argument("--markdown", type=Path, help="write the Markdown report here (default: stdout)")
    parser.add_argument("--json", type=Path, help="write the JSON report here")
    args = parser.parse_args(argv)
    if not args.collection and not args.plugin:
        parser.error("give at least one --collection or --plugin")
    for directory in args.api_headers:
        if not directory.is_dir():
            parser.error("not a directory: %s" % directory)
    sdk = load_sdk(args.api_headers, args.macos_sdk)
    report = {"sdk": {"headers": len(sdk.headers), "classes": len(sdk.classes), "selectors": len(sdk.selectors),
                      "notifications": len(sdk.notifications), "functions": len(sdk.functions),
                      "dirs": [str(d) for d in args.api_headers], "git": [git_info(d) for d in args.api_headers],
                      "system_selectors": len(sdk.system_selectors)},
              "limits": LIMITS, "sources": [], "plugins": []}
    for name, paths in args.collection:
        root = paths[0]
        if not root.is_dir():
            parser.error("not a directory: %s" % root)
        git = git_info(root)
        entries = collection_entries(root)
        counts = {"entries": len(entries), "plugins": 0, "products": 0, "no_sources": 0, "no_source_names": [],
                  "not_plugins": []}
        for entry_name, path, kind in entries:
            if kind == "no-sources":
                counts["no_sources"] += 1
                counts["no_source_names"].append(entry_name)
                continue
            scan = scan_plugin(entry_name, "%s/%s" % (name, kind), [path], sdk)
            scan.git = git
            data = to_json(scan)
            data["source"] = name
            if data["plugin_products"]:
                counts["plugins"] += 1
            else:
                counts["not_plugins"].append("%s (%s)" % (entry_name, ", ".join(
                    p for project in data["projects"] for p in project["products"]) or "sem produto"))
            counts["products"] += len(data["plugin_products"])
            report["plugins"].append(data)
        report["sources"].append({"name": name, "label": root.name, "git": git, "counts": counts})
    for name, paths in args.plugin:
        for path in paths:
            if not path.exists():
                parser.error("missing: %s" % path)
        scan = scan_plugin(name, "plugin", paths, sdk)
        scan.git = git_info(paths[0] if paths[0].is_dir() else paths[0].parent)
        data = to_json(scan)
        data["source"] = name
        report["plugins"].append(data)
        counts = {"entries": 1, "plugins": 1 if data["plugin_products"] else 0,
                  "products": len(data["plugin_products"]), "no_sources": 0, "no_source_names": [],
                  "not_plugins": []}
        report["sources"].append({"name": name, "label": ", ".join(p.name for p in paths), "git": scan.git,
                                  "counts": counts})
    text = markdown(report)
    if args.markdown:
        args.markdown.write_text(text)
    else:
        sys.stdout.write(text)
    if args.json:
        args.json.write_text(json.dumps(report, indent=1, ensure_ascii=False, sort_keys=True, default=sorted) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
