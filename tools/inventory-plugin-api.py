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
        --plugin "Template=PATH/MyIsiXPlugin" \\
        --plugin "T2 Fit Map (IsiX)=Horos/Sources/T2FitMap.swift,Horos/Sources/ViewerController+T2FitMap.swift" \\
        --markdown out.md --json out.json

--collection treats every immediate subdirectory as a plugin (descending one
level into folders that only group plugins, such as `_obsolete`). --plugin
treats the listed paths (directories or files, comma-separated) as one plugin.
--macos-sdk adds the selectors of Foundation, AppKit and related system
headers, so that a selector shared with Cocoa is not attributed to the host.

--registry writes the registry of the binary surface that
tests/test-legacy-plugin-abi.py checks: the registry given with
--registry-base, of which nothing is taken out, with what the SDK headers
(--api-headers) and the headers of the Horos the fork started from
(--baseline-headers, --baseline-public-headers) declare and an application
had. A header and a definition count together when one SDK had both: an item
the baseline's headers declare is added when a source the baseline's project
compiled defined it (--baseline-project, --baseline-sources), and any item
when the reference application or the current build exports or implements it
(--reference-exports, --reference-objc, --current-exports, --current-objc:
listings of `nm -gUj` and of `dyld_info -objc`). What a branch of a
preprocessor conditional declares or defines for PowerPC alone is not read.
The use counts are those of the plugins given with --collection and --plugin,
read against the headers of both SDKs; a count the registry already has only
rises.

"isix5_additions" of the registry is written again at each run: the classes
and symbols that the SDK headers declare and no compiled source of the
baseline defined, each with the header that declares it. "sdk_selectors" too:
the selectors the baseline's headers declare and its sources implement, each
with the header and the line. "osirix_selectors" is never read from headers:
it names the selectors that only later headers of the OsiriX SDK declare and
the application answers, each with the source of its name and types, and is
kept as --registry-base has it, every one of its entries in "selectors" too.

In "missing", an entry whose item the current build has again leaves; a class
or a symbol of isix5_additions that the build lacks is listed as an addition,
an instance variable it does not export and no plugin scanned reads with what
it waits for, and a selector or an instance variable whose class is listed,
with that. Nothing else is excused by this tool: a class or a symbol of the
baseline that the build lacks is left for the test to refuse, and so are an
instance variable a plugin reads and a selector of a class that is there,
since the listings do not show what a class of the system or Core Data
answers; one that no SDK of Horos had is then listed by hand with the reason
true of it. The about is the text given with --registry-about, where
{left_out} stands for what was left out and why, or, without it, the about of
--registry-base with its sentence "Left out: ... ." written again. A second
run over the registry written changes nothing.

--recount-ivars rewrites, in the registry given, the use count of every entry
of ivars with the number of plugins scanned whose sources read or write the
instance variable directly, in a subclass or in a category of the host's
class; nothing else of the registry changes. The headers given with
--api-headers say which class declares each variable: give those of every SDK
the registry's variables come from.

--export-table-ivars rewrites, in the registry given, what the table of the
instance variables that Swift classes export decides
(Horos/Scripts/Horos/legacy-plugin-ivars.json, or the one given with
--ivar-table): an entry of the table leaves missing; one the registry does not
have enters ivars with its use counted as --recount-ivars counts it, and must
be declared by a header given with --api-headers, so that its count is not a
zero for want of the declaration; an instance variable left in missing with
the reason that a Swift stored property has no _OBJC_IVAR_$_ symbol, which the
table disproves, gets the reason that its storage is not yet in the SDK's
layout; and about says where the exported ones come from and names the ones
added, at the end of the sentence a former run left when there is one. Nothing else of the registry changes, and a second run changes nothing.

--older-sdk-headers gives a third source of declarations: a copy of the
headers of an older SDK of OsiriX, as plugins carry one in their sources. Only
its instance variables count, and only those that no header of the other two
sources declares in that class: a plugin built with that copy looks each up by
name, under the class the copy declares it in, as it does the others. They are
declared for the uses to be counted and for --export-table-ivars, which names
apart in about the ones it adds from this source.

--baseline-zlib-header gives the zlib.h of the copy of zlib the baseline linked
statically into its executable, under the library's own names (in Horos,
GDCM/Utilities/gdcmzlib/zlib.h): no header of an SDK declares those functions,
and a plugin linked with the executable as its bundle loader had its zlib
references bound to the executable all the same. Every function that header
declares ZEXTERN, outside its comments, enters symbols, and host_resolution
says where they come from. --registry does it with the rest, and
--static-zlib-symbols does it alone in the registry given, without reading a
plugin or an SDK: nothing else of the registry changes, and a second run
changes nothing.
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
            j = min(j, n)
            # A quote the line does not close (an apostrophe in a #pragma mark, an
            # #import that ends with >) ends with the line, whose newline stays:
            # taking it would join the next line to this one, and every line after
            # would be counted one short.
            closed = j < n and text[j] == c
            j += 1 if closed else 0
            nc.append(text[i:j])
            code.append(c + re.sub(r"[^\n]", " ", text[i + 1:j - 1 if closed else j]) + (c if closed else ""))
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


OTHER_PROCESSORS = {"__ppc__", "__ppc64__", "__POWERPC__", "__powerpc__", "__powerpc64__"}
CONDITIONAL = re.compile(r"[ \t]*#[ \t]*(if|ifdef|ifndef|elif|else|endif)\b(.*)")


def only_other_processors(condition):
    """Whether a preprocessor condition holds for no processor the application was built for."""
    condition = re.sub(r"/\*.*?\*/|//.*", " ", condition)
    words = [word for word in re.findall(r"[A-Za-z_]\w*", condition) if word != "defined"]
    return bool(words) and set(words) <= OTHER_PROCESSORS and not re.search(r"[!&<>=]", condition)


def without_other_processors(text):
    """`text` with the lines blanked of every branch of a conditional that only a
    PowerPC build takes (`#if __ppc__ || __ppc64__` up to its #elif, #else or #endif).

    What such a branch declares or defines was never in an Intel or an Apple
    silicon build: no plugin that loads today found it. Line numbers are kept.
    """
    lines, dead = [], []                     # dead: per open conditional, whether the branch being read is of another processor
    for line in text.split("\n"):
        directive = CONDITIONAL.match(line)
        if not directive:
            lines.append(" " * len(line) if any(dead) else line)
            continue
        word, rest = directive.groups()
        if word in ("if", "ifdef", "ifndef"):
            dead.append(word != "ifndef" and only_other_processors(rest))
        elif dead and word == "elif":
            dead[-1] = only_other_processors(rest)
        elif dead and word == "else":
            dead[-1] = False
        elif dead and word == "endif":
            dead.pop()
        lines.append(line)
    return "\n".join(lines)


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
    signature = ATTRIBUTE_WORD.sub(" ", signature)
    signature = signature.split(",")[0]
    # An attribute macro in capitals comes after the declaration: after the name
    # of a method without arguments or after the name of the last argument. A
    # word in capitals anywhere else is a label (UID:, AET:) or an argument's name.
    flat = flatten_depth0(signature, "#")
    while True:
        trailing = re.search(r"(?<=\w)\s+[A-Z][A-Z0-9_]{2,}\s*$", flat)
        if not trailing:
            break
        flat = flat[:trailing.start()]
    signature = signature[:len(flat)]
    if ":" not in signature:
        match = re.match(r"\s*([A-Za-z_]\w*)", signature)
        return match.group(1) if match else None
    # Each part is `keyword:(type) name`; an anonymous part is `:(type) name`.
    parts = [m.group(1) + ":" for m in re.finditer(r"([A-Za-z_]\w*|)\s*:[\s#]*[A-Za-z_]\w*", flat)]
    return "".join(parts) or None


class HostSDK:
    def __init__(self):
        self.classes = {}        # name -> dict(super, header, methods{sel: info}, ivars{}, props{})
        self.defined = set()     # classes whose @interface (not only a category) is in the SDK
        self.protocols = {}
        self.selectors = defaultdict(set)
        self.notifications = {}  # name -> header
        self.constants = {}      # name -> header: data declared const
        self.globals = {}        # name -> header: data a plugin can also write
        self.data = {}           # name -> dict(header, type, mutable), notifications included
        self.functions = {}
        self.inline_functions = set()  # static or inline in the header: no symbol to look up
        self.c_linkage = set()   # functions a header declares extern "C"
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
    raw = without_other_processors(raw)
    nc, code = strip_source(raw)
    raw_lines = raw.splitlines()
    basename = path.name
    sdk.headers[basename] = str(path)
    sdk.headers_lower.add(basename.lower())
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
        body_start = match.end()             # where `body` starts in `code`, for the lines of what it declares
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
                    visibility = "protected"
                    for statement in body[ivar_open.end():close - 1].split(";"):
                        marks = re.findall(r"@(public|private|protected|package)", statement)
                        visibility = marks[-1] if marks else visibility
                        statement = re.sub(r"@(public|private|protected|package)", " ", statement).strip()
                        statement = re.sub(r"\[[^\]]*\]", "", statement)
                        names = re.findall(r"([A-Za-z_]\w*)\s*(?:,|$)", statement)
                        decl_type = type_name(re.split(r"[A-Za-z_]\w*\s*(?:,|$)", statement)[0]) if statement else None
                        if names and len(statement.split()) >= 2:
                            for ivar in names:
                                target["ivars"][ivar] = decl_type
                                target.setdefault("ivar_visibility", {})[ivar] = visibility
                    body = body[close:]
                    body_start += close
        for prop in re.finditer(r"@property\s*(\([^)]*\))?\s*([^;]+);", body):
            attrs = prop.group(1) or ""
            # Each declarator of the list has its own attributes after its name:
            # «NSString *old __deprecated, *current;» declares two properties, and
            # one marked unavailable declares nothing a caller can send.
            raw_segments = MACRO_CALL.sub(
                lambda call: " NS_UNAVAILABLE " if "UNAVAILABLE" in call.group(0)
                else " __deprecated " if "DEPRECATED" in call.group(0).upper() else " ", prop.group(2)).split(",")
            segments = [ATTRIBUTE_WORD.sub(" ", seg).rstrip() for seg in raw_segments]
            first = re.search(r"([A-Za-z_]\w*)\s*$", segments[0])
            if not first:
                continue
            prop_type = type_name(segments[0][:first.start()])
            declared = [(first.group(1), raw_segments[0])] + [
                (m.group(1), raw) for m, raw in ((re.search(r"([A-Za-z_]\w*)\s*$", seg), raw)
                                                 for seg, raw in zip(segments[1:], raw_segments[1:])) if m]
            prop_names = [name for name, raw in declared if "UNAVAILABLE" not in raw]
            line = code.count("\n", 0, body_start + prop.start())
            deprecated_names = {name for name, raw in declared if DEPRECATED.search(raw)}
            getter = re.search(r"getter\s*=\s*(\w+)", attrs)
            custom_setter = re.search(r"setter\s*=\s*(\w+:)", attrs)
            for prop_name in prop_names:
                deprecated = prop_name in deprecated_names
                target.setdefault("props", {})[prop_name] = prop_type
                info = {"ret": prop_type, "class_method": "class" in attrs, "deprecated": deprecated,
                        "property": True, "header": basename, "line": line + 1}
                target["methods"][getter.group(1) if getter and len(prop_names) == 1 else prop_name] = info
                if "readonly" not in attrs:
                    # setter= names the one selector that sets it.
                    setter = (custom_setter.group(1) if custom_setter and len(prop_names) == 1
                              else "set" + prop_name[:1].upper() + prop_name[1:] + ":")
                    target["methods"][setter] = dict(info, ret="void")
        for method in re.finditer(r"(?m)^\s*([-+])\s*\(((?:[^()]|\([^()]*\))*)\)\s*([^;{]+?)\s*[;{]", body):
            selector = selector_of(method.group(3))
            # What ends an object is NSObject's: a class answers -dealloc whether or not it declares it.
            if not selector or selector in ("dealloc", "finalize"):
                continue
            line = code.count("\n", 0, body_start + method.start(3))
            nearby = " ".join(raw_lines[max(0, line - 1):line + 2]) if raw_lines else ""
            info = {"ret": type_name(method.group(2)) if method.group(2).strip() not in ("id", "instancetype")
                    else method.group(2).strip(),
                    "class_method": method.group(1) == "+",
                    "deprecated": bool(DEPRECATED.search(method.group(3)) or DEPRECATED.search(nearby)),
                    "property": False, "header": basename, "line": line + 1}
            target["methods"][selector] = info
    # C functions declared outside @interface blocks.
    outside = list(code)
    for start, end in blocks:
        end = min(len(outside), end + len("@end"))
        outside[start:end] = " " * (end - start)
    outside = "".join(outside)
    cxx = path.suffix in (".hh", ".hpp", ".hxx")
    for name, inline, c_linkage in c_function_declarations(outside, linkage=True):
        sdk.functions[name] = basename
        if inline:
            sdk.inline_functions.add(name)
        # C linkage where the header says so; the others have it or not by the
        # language of the file that defines them.
        if c_linkage and not cxx:
            sdk.c_linkage.add(name)
    # Data declared extern outside @interface blocks. As above, a name with
    # "Notification" in it is the notification or a key of its userInfo.
    for name, decl_type, mutable in extern_data(outside):
        sdk.data[name] = {"header": basename, "type": decl_type, "mutable": mutable}
        if "Notification" in name:
            sdk.notifications[name] = basename
        else:
            (sdk.globals if mutable else sdk.constants)[name] = basename


# What stands before a declaration with external linkage. strip_source() blanks
# the "C" of extern "C", so the linkage string is matched by its quotes.
LINKAGE = (r"extern\s+\"[^\"\n]*\"|extern\b|EXTERNC\b|FOUNDATION_EXPORT\b|FOUNDATION_EXTERN\b|APPKIT_EXTERN\b|"
           r"CF_EXPORT\b|OBJC_EXTERN\b")
EXTERN_PREFIX = re.compile(r"\s*(?:" + LINKAGE + r")\s*")
NO_SYMBOL = r"NS_INLINE\b|CG_INLINE\b|CF_INLINE\b|static\b|inline\b|__inline__\b|__inline\b"
# Attributes and annotations that are neither the type nor the name of a declaration.
ATTRIBUTE_WORD = re.compile(r"\b(?:__(?:deprecated|unused|used|nonnull|nullable|null_unspecified|strong|weak|"
                            r"unsafe_unretained|autoreleasing|kindof|block)|_Nonnull|_Nullable|_Null_unspecified|"
                            r"DEPRECATED_ATTRIBUTE|UNAVAILABLE_ATTRIBUTE|NS_SWIFT_\w+|API_\w+|"
                            r"(?:NS|CF|CG)_\w*(?:DEPRECATED|UNAVAILABLE|AVAILABLE)\w*)\b")
PARENS = r"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"
FUNCTION_DECL = re.compile(r"(?m)^[ \t]*((?:(?:" + LINKAGE + "|" + NO_SYMBOL + r")\s*)*)"
                           r"(?:(?:const|unsigned|signed|struct|enum)\s+)*[A-Za-z_]\w*(?:\s*\*+\s*|\s+)\**\s*"
                           r"(?:const\s+)?([A-Za-z_]\w*)\s*\((?!\s*[*^])[^;{}]*\)\s*"
                           r"(?:\b[A-Za-z_]\w*\b(?:\s*" + PARENS + r")?\s*)*[;{]")


def file_level(code):
    """`code` with its preprocessor lines blanked and each `extern "C" { ... }` opened.

    A header declares most of its C functions and some of its data inside such
    a block, which is file level for the declarations in it; the braces of the
    block go, and what they held is left at depth 0. Offsets are kept.
    """
    code = re.sub(r"(?m)^[ \t]*#(?:[^\n\\]|\\\n|\\.)*", lambda m: re.sub(r"[^\n]", " ", m.group(0)), code)
    chars = list(code)
    for match in re.finditer(r"\bextern\s+\"[^\"\n]*\"\s*\{", code):
        close = balanced(code, match.end() - 1, "{", "}")
        chars[match.start():match.end()] = " " * (match.end() - match.start())
        if close > 0:
            chars[close - 1] = " "
    return "".join(chars)


def brace_depths(code):
    depth, depths = 0, []
    for ch in code:
        depths.append(depth)
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
    return depths


def c_function_declarations(code, linkage=False, defined=False):
    """(name, inline) of each C function declared at file level (not a C++ member).

    inline is true for a function the header defines static or inline: it is
    part of the API a plugin compiles against, and the host has no symbol for it.
    With `linkage`, a third value says whether the declaration is extern "C",
    by its own prefix or by the block it is in. With `defined`, only the
    functions that have a body here.
    """
    blocks = [(match.start(), balanced(code, match.end() - 1, "{", "}"))
              for match in re.finditer(r"\bextern\s+\"[^\"\n]*\"\s*\{", code)]
    code = file_level(code)
    depths = brace_depths(code)
    found = []
    for match in FUNCTION_DECL.finditer(code):
        name = match.group(2)
        if depths[match.start(2)] != 0 or name in STOP_IDENTIFIERS or name.isupper():
            continue
        if defined and not match.group(0).endswith("{"):
            continue
        inline = bool(re.search(NO_SYMBOL, match.group(1)))
        c_linkage = bool(re.search(r"extern\s+\"|EXTERNC", match.group(1))) or any(
            start < match.start() and (end < 0 or match.start() < end) for start, end in blocks)
        found.append((name, inline, c_linkage) if linkage else (name, inline))
    return found


def c_functions(code):
    """Names of C functions declared at file level (not C++ members)."""
    return [name for name, _ in c_function_declarations(code)]


def extern_data(code, definitions=False):
    """(name, type, mutable) of each datum declared with external linkage at file level.

    With `definitions`, the data a source file defines instead: the statements
    of file level that are neither extern, static nor a typedef.

    Reads `extern` and the export macros before any type (object pointer,
    scalar, struct or typedef), const on either side of the `*`, a list of
    declarators with their own `*`, const and `[n]`, and attributes anywhere in
    the declaration. Function prototypes and function pointers are not data.
    mutable is false when the datum itself is const.
    """
    code = file_level(code)
    if definitions:
        # A definition may come right after the line that opens an implementation.
        code = re.sub(r"@(?:implementation|interface)\b[^\n]*|@end\b", lambda m: " " * len(m.group(0)), code)
    found = []
    depth, start, initializer = 0, 0, False
    for index, ch in enumerate(code):
        if ch == "{":
            # The braces of an initializer are part of the statement they are in.
            if depth == 0:
                initializer = code[start:index].rstrip().endswith("=") or (initializer and "=" in code[start:index])
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
            if depth == 0 and not initializer:
                start = index + 1
        elif ch == ";" and depth == 0:
            statement, start, initializer = code[start:index], index + 1, False
            statement = re.sub(r"=\s*\{[^;]*\}", "= 0", statement) if definitions else statement
            prefix = EXTERN_PREFIX.match(statement)
            if definitions:
                if prefix or re.match(r"\s*(?:%s|typedef\b|@|using\b|namespace\b|class\b|struct\b|enum\b|union\b|return\b)"
                                      % NO_SYMBOL, statement):
                    continue
                prefix = re.match(r"\s*", statement)
            elif not prefix:
                continue
            body = ATTRIBUTE_WORD.sub(" ", MACRO_CALL.sub(" ", statement[prefix.end():]))
            body = EXTERN_PREFIX.sub(" ", body, count=1) if EXTERN_PREFIX.match(body) else body
            if definitions:
                # An initializer may call or send: only the declarators count.
                body = re.sub(r"=(?:[^,\[(]|\[[^\]]*\]|\([^)]*\))*", "", body)
            if "(" in body or re.match(r"\s*(?:" + NO_SYMBOL + ")", body):
                continue
            declarators = [part.split("=")[0] for part in body.split(",")]
            base = None
            for position, declarator in enumerate(declarators):
                tokens = re.findall(r"[A-Za-z_]\w*|\*|\[[^\]]*\]", declarator)
                arrays = [token for token in tokens if token.startswith("[")]
                tokens = [token for token in tokens if not token.startswith("[")]
                if not tokens or tokens[-1] in ("*", "const"):
                    break
                name, own = tokens[-1], tokens[:-1]
                if position == 0:
                    words = [token for token in own if token not in ("*", "const", "struct", "enum", "union")]
                    if not words:
                        break
                    base = own[:own.index("*")] if "*" in own else own
                    own = own[len(base):]
                stars = own.count("*")
                if stars:
                    constant = "const" in own[len(own) - own[::-1].index("*"):]
                else:
                    constant = "const" in base
                found.append((name, " ".join(base + own) + "".join(arrays), not constant))
    return found


def load_sdk(dirs, macos_sdk=None):
    """The model of the headers in `dirs`; an entry that is a file is one header."""
    sdk = HostSDK()
    for directory in dirs:
        for path in [Path(directory)] if Path(directory).is_file() else sorted(Path(directory).glob("*.h")):
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


def message_parts(inner):
    """(receiver, parts) of the message whose text between [ and ] is `inner`, or None.

    Each part is (keyword, start): the name of a message without arguments, or
    `keyword:` for each argument, with where the keyword starts in `inner`
    (None for a part without a keyword, `: b`).
    """
    split = parse_receiver(inner)
    if not split:
        return None
    receiver, rest = split
    base = len(inner) - len(rest)
    first = re.match(r"\s+([A-Za-z_]\w*)\s*", rest)
    if not first or first.group(1) in STOP_IDENTIFIERS:
        return None
    tail = rest[first.end():]
    if not tail.strip():
        return receiver, [(first.group(1), base + first.start(1))]
    if not tail.startswith(":"):
        return None
    flat = flatten_depth0(rest, "#")
    parts, ternary = [], 0
    for token in re.finditer(r"\?|(?<![\w#.])([A-Za-z_]\w*)?\s*:(?!:)", flat):
        if token.group(0) == "?":
            ternary += 1
            continue
        if ternary:
            ternary -= 1
            continue
        keyword = token.group(1) or ""
        before = flat[:token.start()].rstrip()
        if keyword and parts and before and not re.search(r"[\w#\])\"']$", before):
            # `[r k: a : b]` or `[r k: &a : b]`: `a` starts the argument of `k:`,
            # so the colon after it opens an anonymous part.
            keyword = ""
        parts.append((keyword + ":", base + token.start(1) if keyword else None))
    return receiver, parts


def parse_message(inner):
    """(receiver, selector) of the message whose text between [ and ] is `inner`, or None."""
    parsed = message_parts(inner)
    return (parsed[0], "".join(keyword for keyword, _ in parsed[1])) if parsed else None


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


# A word before a name that is not the type of a declaration of that name.
NOT_A_TYPE = STOP_IDENTIFIERS | {"goto", "in", "break", "continue"}
TYPE_QUALIFIERS = (r"(?:(?:const|volatile|static|register|unsigned|signed|long|short|struct|enum|union|"
                   r"__block|__strong|__weak|__unsafe_unretained|__autoreleasing)\s+)*")


def implementation_methods(body):
    """(declaration, start, end) of each method the text of an @implementation defines.

    The declaration is what follows the return type; start and end are those
    of the method's braces in `body`.
    """
    depths = brace_depths(body)
    for method in re.finditer(r"(?m)^[ \t]*[-+]\s*\((?:[^()]|\([^()]*\))*\)\s*([^;{]+?)\s*(?:;\s*)?\{", body):
        if depths[method.start()] == 0:
            end = balanced(body, method.end() - 1, "{", "}")
            yield method.group(1), method.end() - 1, len(body) if end < 0 else end


def direct_ivar_uses(body, names):
    """How many times the text of an @implementation reads or writes each of `names` as a variable.

    A binary that does so looks the variable's offset up by name when it
    loads. Counted: the bare name inside a method, and self->name. Not
    counted, because the compiler does not take them for the variable: the
    name as the selector of a message or a part of one ([view count],
    [view setWL: a count: b]) or inside @selector(), as the member of
    something else (other.count, other->count), called as a function, in the
    declaration of a method, outside any method (a C function has no self),
    and where a parameter of the method or a local variable declared before
    it in the block has that name and hides the variable.
    """
    found = Counter()
    for declaration, start, end in implementation_methods(body):
        text = body[start:end]
        present = [name for name in names if name in text]
        if not present:
            continue
        chars, stack = list(text), []
        for index, ch in enumerate(text):
            if ch == "[":
                stack.append(index)
            elif ch == "]" and stack:
                opening = stack.pop()
                if opening > 0 and text[opening - 1] == "@":
                    continue
                inner = text[opening + 1:index]
                parsed = message_parts(inner)
                selectors = [(keyword.rstrip(":"), position) for keyword, position in parsed[1]] if parsed else []
                if not parsed:
                    # A receiver the parser does not read, as in [*view count]: two
                    # operands in a row before the bracket closes are a receiver and
                    # the name of a message.
                    last = re.search(r"[\w\]]\s+([A-Za-z_]\w*)\s*$", inner)
                    selectors = [(last.group(1), last.start(1))] if last else []
                for keyword, position in selectors:
                    if position is not None:
                        at = opening + 1 + position
                        chars[at:at + len(keyword)] = " " * len(keyword)
        for selector in re.finditer(r"@selector\s*\(([^()]*)\)", text):
            chars[selector.start(1):selector.end(1)] = " " * (selector.end(1) - selector.start(1))
        text = "".join(chars)
        parameters = set(re.findall(r":\s*(?:\((?:[^()]|\([^()]*\))*\))?\s*([A-Za-z_]\w*)", declaration))
        for name in present:
            # Where a local variable of that name is in scope: from its declaration,
            # at the start of a statement, to the end of the block it is in.
            hidden = []
            for local in re.finditer(r"(?:(?<=[;{}])|(?<=\bfor)\s*\()\s*" + TYPE_QUALIFIERS + r"([A-Za-z_]\w*)(?:\s*<[^;{}<>]*>)?"
                                     r"(?:\s*\*+\s*(?:const\s+)?|\s+)(" + re.escape(name) + r")\s*(?==(?!=)|[;,\[]|in\b)", text):
                if local.group(1) in NOT_A_TYPE:
                    continue
                depth, close = 0, len(text)
                for index in range(local.start(2), len(text)):
                    if text[index] == "{":
                        depth += 1
                    elif text[index] == "}":
                        if depth == 0:
                            close = index
                            break
                        depth -= 1
                hidden.append((local.start(2), close))
            for use in re.finditer(r"(?<!\w)%s\b" % re.escape(name), text):
                before, after = text[max(0, use.start() - 80):use.start()].rstrip(), text[use.end():use.end() + 80].lstrip()
                if before.endswith("->"):
                    if re.search(r"(?<![\w.>])self\s*$", before[:-2]):
                        found[name] += 1
                elif before.endswith(".") or after.startswith("("):
                    continue
                elif name not in parameters and not any(a <= use.start() < b for a, b in hidden):
                    found[name] += 1
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
    # A constant or a global of the SDK may start in lower case (pasteBoardOsiriX).
    for word in re.findall(r"\b[A-Za-z_][A-Za-z0-9_]+\b", code):
        if word in sdk.defined and word not in own:
            scan.classes[word] += 1
        elif word in sdk.notifications:
            scan.notifications[(word, True)] += 1
        elif word in sdk.constants or word in sdk.globals:
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
    for match in re.finditer(r"@implementation\s+([A-Za-z_]\w*)\s*(\(\s*\w*\s*\))?", code):
        name = match.group(1)
        if name in sdk.classes:
            # A category of a host class reaches the class's instance variables as a
            # subclass does. The class under its own name is a copy of the host's
            # source, not a plugin's access.
            host = name if match.group(2) else None
        else:
            host = context.host_chain_class(name)
        if not host:
            continue
        end = code.find("@end", match.end())
        body = code[match.end():end if end > 0 else len(code)]
        chain, _ = sdk.chain(host)
        uses = direct_ivar_uses(body, {ivar for cls in chain for ivar in sdk.classes[cls]["ivars"]})
        for cls in chain:
            for ivar in sdk.classes[cls]["ivars"]:
                if uses[ivar]:
                    scan.ivars[(cls, ivar, "inherited")] += uses[ivar]
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
    "Ivars herdadas (`inherited`) contam o nome usado como variável dentro de um método de uma subclasse ou de uma categoria de classe do host, e `self->nome`; não contam mensagens (`[x nome]`), partes de seletor, membros de outro objeto, nem o nome encoberto por parâmetro ou variável local. Só as ivars dos headers dados em --api-headers são vistas: uma ivar que só a cópia do SDK do próprio plugin declara não aparece.",
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


# ---------------------------------------------------------------- registry of the binary surface
#
# tests/legacy-plugin-abi.json: what a plugin built for Horos or OsiriX looks
# up in the application without being rebuilt. --registry writes it from the
# registry there is (--registry-base, nothing of which is taken out), the SDK
# headers (--api-headers), the headers and the compiled sources of the Horos
# the fork started from (--baseline-*), and the listings of nm -gUj and
# dyld_info -objc of the reference application and of the current build
# (--reference-*, --current-*). Every input is a text file.

REGISTRY_ITEMS = ("frameworks", "classes", "selectors", "used_outside_sdk", "ivars", "symbols")
# The sentence of the registry's about that says what was left out and why,
# written again at each run. No reason has a full stop in it.
LEFT_OUT = re.compile(r"Left out: [^.]*\.")
ISIX5_ADDITION = "added by the IsiX 5 SDK: Horos did not define it"
# A class whose superclass in Horos was a class of the system or of a library
# that the application no longer has or no longer descends from: the registry
# keeps the superclass it has today, which is the decided exception.
SUPERCLASS_TODAY = {"DCMView": "NSView", "NavigatorView": "NSView", "DCMCalendarDate": "NSDate", "VTKView": "NSView"}
METHOD_DEFINITION = re.compile(r"(?m)^[ \t]*([-+])\s*\(((?:[^()]|\([^()]*\))*)\)\s*([^;{]+?)\s*[;{]")
OBJC_INTERFACE = re.compile(r"^@interface ([^\s(:]+)(\([^)]*\))?\s*(?::\s*(\S+))?")
OBJC_METHOD = re.compile(r"^(?:0x[0-9A-Fa-f]+\s+)?([-+])\[(\S+) (\S+)\]$")


def render_registry(registry):
    """The registry's canonical text: sections and entries sorted, one entry per line."""
    lines = ["{"]
    names = sorted(registry)
    for i, name in enumerate(names):
        value = registry[name]
        comma = "," if i < len(names) - 1 else ""
        if not isinstance(value, dict):
            lines.append(" %s: %s%s" % (json.dumps(name), json.dumps(value, ensure_ascii=False), comma))
            continue
        lines.append(" %s: {" % json.dumps(name))
        keys = sorted(value)
        for j, key in enumerate(keys):
            lines.append("  %s: %s%s" % (json.dumps(key, ensure_ascii=False),
                                         json.dumps(value[key], sort_keys=True, ensure_ascii=False),
                                         "," if j < len(keys) - 1 else ""))
        lines.append(" }" + comma)
    lines.append("}")
    return "\n".join(lines) + "\n"


def read_exports(paths):
    """The symbol names of listings of `nm -gUj`."""
    names = set()
    for path in paths:
        names.update(line.strip() for line in Path(path).read_text(errors="replace").splitlines()
                     if line.strip() and not line.rstrip().endswith(":"))
    return names


def read_objc_metadata(paths):
    """{class: {super, defined, '-': {selector}, '+': {selector}}} of listings of `dyld_info -objc`."""
    classes = {}
    for path in paths:
        in_class = False
        for line in Path(path).read_text(errors="replace").splitlines():
            text = line.strip()
            if text.startswith("@protocol"):
                in_class = False
                continue
            interface = OBJC_INTERFACE.match(text)
            if interface:
                in_class = True
                entry = classes.setdefault(interface.group(1), {"super": None, "defined": False, "-": set(), "+": set()})
                if not interface.group(2):
                    entry["defined"] = True
                    entry["super"] = interface.group(3)
                continue
            if text == "@end":
                in_class = False
                continue
            method = OBJC_METHOD.match(text) if in_class else None
            if method:
                entry = classes.setdefault(method.group(2), {"super": None, "defined": False, "-": set(), "+": set()})
                entry[method.group(1)].add(method.group(3))
    return classes


def project_names(project_text, phase):
    """The file names a project lists `in <phase>` (Sources, Headers)."""
    return set(re.findall(r"/\* ([^*]+?) in %s \*/" % phase, project_text))


def public_headers(project_text):
    """The names of the headers a project builds with the Public attribute."""
    return set(re.findall(r"/\* ([^*]+?) in Headers \*/ = \{[^}]*settings = \{ATTRIBUTES = \((?:[^)]*\b)?Public\b",
                          project_text))


class BaselineSources:
    """What the compiled sources of the baseline define: Objective-C classes and
    their methods, and the functions and data of file level with external linkage."""

    def __init__(self):
        self.classes = set()                 # with an @implementation, or a Swift class named with @objc(Name)
        self.methods = {}                    # class -> {'-': {selector}, '+': {selector}}, categories included
        self.functions = {}                  # name -> True when the file that defines it is C or Objective-C
        self.data = set()
        self.dynamic = {}                    # class -> the properties its implementation declares @dynamic

    def read(self, path):
        raw = without_other_processors(Path(path).read_text(errors="replace"))
        suffix = Path(path).suffix
        if suffix == ".swift":
            _, code = strip_source(raw, swift=True)
            self.classes.update(re.findall(r"@objc\(\s*([A-Za-z_]\w*)\s*\)[^{;]*?\bclass\s+[A-Za-z_]\w*", code))
            return
        _, code = strip_source(raw)
        for match in re.finditer(r"@implementation\s+([A-Za-z_]\w*)\s*(\([^)]*\))?", code):
            end = code.find("@end", match.end())
            body = code[match.end():len(code) if end < 0 else end]
            if not match.group(2):
                self.classes.add(match.group(1))
            depths = brace_depths(body)
            methods = self.methods.setdefault(match.group(1), {"-": set(), "+": set()})
            for dynamic in re.finditer(r"@dynamic\s+([^;]+);", body):
                self.dynamic.setdefault(match.group(1), set()).update(name.strip() for name in dynamic.group(1).split(","))
            for method in METHOD_DEFINITION.finditer(body):
                selector = selector_of(method.group(3))
                if selector and depths[method.start()] == 0:
                    methods[method.group(1)].add(selector)
        c_file = suffix in (".m", ".c")
        for name, inline, c_linkage in c_function_declarations(code, linkage=True, defined=True):
            if not inline:
                self.functions[name] = self.functions.get(name, False) or c_file or c_linkage
        self.data.update(name for name, _, _ in file_level_data(code))


def file_level_data(code):
    """(name, type, mutable) of each datum a source file defines at file level with external linkage."""
    return extern_data(code, definitions=True)


def mangled_function(symbol):
    """The name of the C++ function outside any namespace or class that `symbol` is, or None."""
    match = re.match(r"__Z(\d+)", symbol)
    if not match:
        return None
    length = int(match.group(1))
    name = symbol[match.end():match.end() + length]
    return name if len(name) == length and re.fullmatch(r"[A-Za-z_]\w*", name) else None


class Surface:
    """What one or more builds give a plugin, from their listings."""

    def __init__(self, exports, objc):
        self.exports, self.objc = exports, objc
        self.mangled = defaultdict(set)      # function name -> its C++ symbols
        for symbol in exports:
            name = mangled_function(symbol)
            if name:
                self.mangled[name].add(symbol)

    def chain(self, name):
        seen = []
        while name and name in self.objc and name not in seen:
            seen.append(name)
            name = self.objc[name]["super"]
        return seen

    def implements(self, name, kind, selector):
        return any(selector in self.objc[cls][kind] for cls in self.chain(name) or [name] if cls in self.objc)

    def has_class(self, name, superclass=None):
        """Whether the class is exported and, where the listings can tell, still descends from `superclass`.

        The listings hold the application's classes alone: a superclass of the
        system is past what they show, and is not held against the class."""
        if "_OBJC_CLASS_$_" + name not in self.exports:
            return False
        known = superclass and self.objc.get(superclass, {}).get("defined") and self.objc.get(name, {}).get("defined")
        return not known or superclass in self.chain(name)[1:]


def use_counts(plugins):
    """How many plugins use each selector, ivar and name of the SDK, as the inventory attributes it."""
    selectors, ivars, names, outside = defaultdict(set), defaultdict(set), defaultdict(set), defaultdict(set)
    for plugin in plugins:
        for entry in plugin["selectors"]:
            if entry["class"]:
                selectors[(entry["class"], entry["selector"])].add(plugin["name"])
        for entry in plugin["ivars_and_attributes"]:
            if entry["how"] == "inherited":
                ivars[(entry["class"], entry["name"])].add(plugin["name"])
        for entry in plugin["host_functions_and_constants"]:
            names[entry["name"].rstrip("()")].add(plugin["name"])
        for entry in plugin["notifications"]:
            if entry["declared_by_host"]:
                names[entry["name"]].add(plugin["name"])
        for entry in plugin["selectors_not_in_sdk"] + plugin["host_methods_declared_by_plugin"]:
            if entry.get("class"):
                outside[(entry["class"], entry["selector"])].add(plugin["name"])
    return {"selectors": selectors, "ivars": ivars, "names": names, "outside": outside}


NO_SWIFT_SYMBOL = ": a Swift stored property has no _OBJC_IVAR_$_ symbol"
NOT_IN_SDK_LAYOUT = ": its storage is not yet in the SDK's layout, a stored field of the class with the SDK's type"
ABOUT_EXPORTED_IVARS = (
    "The instance variables of a class implemented in Swift are exported from stored fields of the class, each through a linker "
    "alias of its field's offset: Horos/Scripts/Horos/legacy-plugin-ivars.json is the table of those fields, with the type the "
    "SDK declared, the state and the ownership of each, and every entry of it is in ivars and none in missing. One that is still "
    "in missing waits for its storage to be a field of the class with the SDK's type, and says so; one a known plugin reads may "
    "not wait.")
ABOUT_ADDED_IVARS = ("Added to ivars with that table, declared by the headers of the SDK and exported by the application though "
                     "the 5.3.4 executable no longer exported them: %s.")
ABOUT_ADDED_OLDER_IVARS = ("Added to ivars with that table, declared only by the copies of an older SDK of OsiriX that plugins "
                           "carry in their sources, which neither the headers of the SDK nor those of Horos declare, and "
                           "exported by the application for the plugins built with such a copy: %s.")


STATIC_ZLIB = "7 static zlib"
HOST_STATIC_ZLIB = (
    "The executable also carried the copy of zlib %s inside GDCM (GDCM/Utilities/gdcmzlib): GDCM was built without "
    "GDCM_USE_SYSTEM_ZLIB, so that copy was linked statically, under the library's own names, which it prefixes only under "
    "Z_PREFIX, and its globals were exported like every other. A plugin linked with BUNDLE_LOADER, which did not need to name "
    "the system's zlib, had its zlib references bound to the executable. Dead-code stripping kept the functions the "
    "application reached, a set no source gives: symbols has every function that copy's zlib.h declares ZEXTERN, %d of "
    "them, and the executable defines each one, as a call into the system's zlib.")


def zlib_functions(header):
    """The version a zlib.h gives and the names of the functions it declares ZEXTERN.

    What its comments declare is not read: they document as functions the
    macros over the entry points that take the version and the size."""
    code = re.sub(r"/\*.*?\*/", " ", header, flags=re.S)
    version = re.search(r'^\s*#\s*define\s+ZLIB_VERSION\s+"([^"]+)"', code, re.M)
    names = re.findall(r"\bZEXTERN\b[^;()]*?\b([A-Za-z_]\w*)\s*(?:OF\s*\(\(|\()", code)
    return (version.group(1) if version else None), sorted(set(names))


def enter_static_zlib(registry, header):
    """Enters in `registry` the functions of the zlib the baseline's executable carried; answers the symbols added.

    A count the registry has stays. Raises ValueError for a header that is not a zlib.h."""
    version, names = zlib_functions(header)
    if not version or not names:
        raise ValueError("the header defines no ZLIB_VERSION or declares no function ZEXTERN")
    added = [symbol for symbol in ("_" + name for name in names) if symbol not in registry["symbols"]]
    for symbol in added:
        registry["symbols"][symbol] = 0
    registry.setdefault("host_resolution", {})[STATIC_ZLIB] = HOST_STATIC_ZLIB % (version, len(names))
    return added


def declare_older_ivars(sdk, older):
    """Declares in `sdk` the instance variables only `older` declares; answers their names.

    A class `sdk` has takes them by its own declaration: a copy that declares in
    a class what `sdk` declares in its superclass gave the plugins built with it
    the symbol of the class itself. A class `sdk` does not have is declared with
    its instance variables alone, for the table to name them."""
    only = set()
    for cls, info in older.classes.items():
        known = cls in sdk.classes
        own = sdk.klass(cls)["ivars"]
        for ivar, decl_type in info["ivars"].items():
            if ivar not in own:
                own[ivar] = decl_type
                if not known or sdk.ivar(cls, ivar)[0] == cls:
                    only.add("%s.%s" % (cls, ivar))
    return only


def export_table_ivars(registry, table, sdk, counts, older_only=frozenset()):
    """The registry with what the table of exported instance variables decides; answers what changed.

    older_only names the instance variables only a copy of an older SDK declares.
    Raises ValueError for an entry of the table that cannot enter the registry."""
    added, restored, reworded, wrong = [], [], 0, []
    for name in table:
        cls, _, ivar = name.partition(".")
        if name not in registry["ivars"]:
            if cls not in registry["classes"]:
                wrong.append("%s: %s is not in classes of the registry" % (name, cls))
            elif ivar not in sdk.classes.get(cls, {}).get("ivars", {}):
                wrong.append("%s: no header given with --api-headers declares it in %s, and its use cannot be counted" % (name, cls))
            else:
                registry["ivars"][name] = len(counts.get((cls, ivar), ()))
                added.append(name)
        if registry["missing"].pop("ivars " + name, None) is not None:
            restored.append(name)
    if wrong:
        raise ValueError("; ".join(wrong))
    for key, reason in registry["missing"].items():
        if key.startswith("ivars ") and isinstance(reason, str) and reason.endswith(NO_SWIFT_SYMBOL):
            registry["missing"][key] = reason[:-len(NO_SWIFT_SYMBOL)] + NOT_IN_SDK_LAYOUT
            reworded += 1
    if ABOUT_EXPORTED_IVARS not in registry["about"]:
        registry["about"] = registry["about"].rstrip() + " " + ABOUT_EXPORTED_IVARS
    for sentence, names in ((ABOUT_ADDED_IVARS, [name for name in added if name not in older_only]),
                            (ABOUT_ADDED_OLDER_IVARS, [name for name in added if name in older_only])):
        if names:
            # The sentence a former run left takes the new names at its end.
            before, after = (re.escape(part) for part in sentence.split("%s"))
            listed = None
            for listed in re.finditer(before + r"(\w+\.\w+(?:, \w+\.\w+)*)" + after, registry["about"]):
                pass
            if listed:
                registry["about"] = registry["about"][:listed.end(1)] + ", " + ", ".join(names) + registry["about"][listed.end(1):]
            else:
                registry["about"] = registry["about"].rstrip() + " " + sentence % ", ".join(names)
    return {"added": added, "restored": restored, "reworded": reworded}


def build_registry(base, sdk, baseline_sdk, baseline, reference, current, counts, about):
    """The registry: `base` with what the headers declare and a build or the baseline had.

    sdk and baseline_sdk are the models of the later SDK's headers and of the
    baseline's; baseline is its BaselineSources; reference and current are the
    Surface of the reference application and of the current build. Returns
    the registry and what was left out, by kind.
    """
    registry = {name: (dict(value) if isinstance(value, dict) else value) for name, value in base.items()}
    for section in REGISTRY_ITEMS + ("missing", "isix5_additions", "sdk_selectors", "osirix_selectors"):
        registry.setdefault(section, {})
    # What only later headers of the other SDK declare is entered by hand, with
    # its source, and kept as the base has it: no header given here declares
    # it. Each is a selector of the registry like the others.
    for key in registry["osirix_selectors"]:
        registry["selectors"].setdefault(key, 0)
    # What the baseline declared and implemented is read again each time: it is
    # derived from the baseline alone, and nothing of the base's list is kept.
    registry["sdk_selectors"] = {}
    registry["about"] = about
    left, left_seen = Counter(), set()
    both = Surface(reference.exports | current.exports, None)

    def leave(what, item):
        """Count `item` as left out for the reason `what`, once whichever headers declare it."""
        if (what, item) not in left_seen:
            left_seen.add((what, item))
            left[what] += 1

    def kind_of(info):
        return "+" if info.get("class_method") else "-"

    def baseline_implements(name, kind, selector, info):
        seen = []
        while name and name not in seen:
            seen.append(name)
            if selector in baseline.methods.get(name, {}).get(kind, ()):
                return True
            # A property of a class the baseline implemented is synthesized, unless
            # the implementation says @dynamic: then the class has no method for
            # it, and what answers is the runtime (Core Data, from the model).
            if info.get("property") and name in baseline.classes and selector in baseline_sdk.classes.get(name, {}).get("methods", {}):
                prop = selector[3:4].lower() + selector[4:-1] if selector.endswith(":") else selector
                if {prop, selector[3:-1] if selector.endswith(":") else selector} & baseline.dynamic.get(name, set()):
                    leave("properties the baseline declared @dynamic, which the runtime answers", (name, kind, selector))
                    return False
                return True
            name = baseline_sdk.classes.get(name, {}).get("super")
        return False

    def leads_to(name, ancestor):
        """Whether the superclasses the registry records lead from `name` to `ancestor`."""
        seen = []
        while name and name not in seen:
            if name == ancestor:
                return True
            seen.append(name)
            name = registry["classes"].get(name)
        return False

    # Classes: by their Objective-C runtime name, with the superclass of the
    # baseline for its classes and of the later SDK for the others. A header
    # and a definition count together when one SDK had both: a class the
    # baseline's headers declare, with the baseline's sources; one that only
    # the later SDK declares, with a build that exports it. A class the
    # baseline kept out of its headers, which the later SDK declared when no
    # build of it exported the class, was never one a plugin could bind.
    for source, is_baseline in ((baseline_sdk, True), (sdk, False)):
        for name in sorted(source.defined):
            in_baseline = name in baseline.classes
            exported = "_OBJC_CLASS_$_" + name in both.exports
            if name not in registry["classes"] and not exported and not (is_baseline and in_baseline):
                if in_baseline:
                    leave("classes the baseline compiled and kept out of its headers, which the later SDK declared and "
                          "no build of it exported", name)
                else:
                    leave("classes no build exported and the baseline did not compile", name)
                continue
            if in_baseline and name in baseline_sdk.defined:
                superclass = SUPERCLASS_TODAY.get(name, baseline_sdk.classes[name]["super"])
                # The superclass the registry has stays when it leads to the baseline's:
                # it asks for that one and for the class a later SDK put between them.
                if name in registry["classes"] and leads_to(registry["classes"][name], superclass):
                    superclass = registry["classes"][name]
            else:
                superclass = registry["classes"].get(name, source.classes[name]["super"])
            registry["classes"][name] = superclass

    # Selectors and ivars, by the class that declares them.
    for source, is_baseline in ((baseline_sdk, True), (sdk, False)):
        for name, info in sorted(source.classes.items()):
            for selector, method in sorted(info["methods"].items()):
                kind = kind_of(method)
                key = "%s %s%s" % (name, kind, selector)
                # A class the baseline's headers declare and its project never
                # compiled had no method of its own, whatever its ancestors had.
                compiled_there = name in baseline.classes or name in baseline.methods
                in_baseline = is_baseline and compiled_there and baseline_implements(name, kind, selector, method)
                if in_baseline:
                    registry["sdk_selectors"][key] = "%s:%d" % (method["header"], method["line"])
                count = len(counts["selectors"].get((name, selector), ()))
                if key in registry["selectors"]:
                    registry["selectors"][key] = max(registry["selectors"][key], count)
                elif in_baseline or reference.implements(name, kind, selector) or current.implements(name, kind, selector):
                    registry["selectors"][key] = count
                else:
                    leave("selectors no class implemented", key)
            for ivar in sorted(info["ivars"]):
                key = "%s.%s" % (name, ivar)
                count = len(counts["ivars"].get((name, ivar), ()))
                if key in registry["ivars"]:
                    registry["ivars"][key] = max(registry["ivars"][key], count)
                elif info.get("ivar_visibility", {}).get(ivar) in ("private", "package"):
                    leave("instance variables that were @private or @package", key)
                elif "_OBJC_IVAR_$_" + key in both.exports or (is_baseline and name in baseline.classes):
                    registry["ivars"][key] = count
                else:
                    leave("instance variables no build exported", key)

    # Symbols: the data and the functions the headers declare with external linkage.
    defined_by_baseline = set()
    for source, is_baseline in ((baseline_sdk, True), (sdk, False)):
        declared = [(name, False) for name in source.data] + [(name, True) for name in source.functions]
        for name, is_function in sorted(declared):
            if is_function and name in source.inline_functions:
                leave("C functions the header defines static or inline", name)
                continue
            count = len(counts["names"].get(name, ()))
            in_baseline = name in (baseline.functions if is_function else baseline.data)
            # The C++ name of the function as the reference application had it. The
            # current build's says which function it is only where the reference
            # has none and the baseline defined it: a function of that name the
            # application has today with other arguments is another function.
            mangled = set()
            if is_function:
                mangled = reference.mangled.get(name, set()) or (current.mangled.get(name, set()) if in_baseline else set())
            if "_" + name in both.exports:
                symbols = {"_" + name}
            elif mangled:
                symbols = mangled
            elif (in_baseline and not is_baseline and "_" + name not in registry["symbols"]
                  and name not in baseline_sdk.data and name not in baseline_sdk.functions):
                # As for a class: the baseline defined it without declaring it, and
                # no build that declared it had it.
                leave("names the baseline defined and kept out of its headers, which the later SDK declared and no "
                      "build of it exported", name)
                continue
            elif in_baseline and (not is_function or baseline.functions[name] or name in source.c_linkage):
                symbols = {"_" + name}
            elif in_baseline:
                leave("C++ functions of the baseline whose mangled name no build has", name)
                continue
            else:
                leave("names only declared, which neither a build nor the baseline defined", name)
                continue
            if in_baseline:
                defined_by_baseline.update(symbols)
            for symbol in symbols:
                registry["symbols"][symbol] = max(registry["symbols"].get(symbol, 0), count)

    # Host methods the plugins call without the SDK declaring them.
    for (name, selector), plugins in sorted(counts["outside"].items()):
        for kind in "-+":
            key = "%s %s%s" % (name, kind, selector)
            if key in registry["selectors"] or key in registry["used_outside_sdk"]:
                break
            if name in registry["classes"] and (reference.implements(name, kind, selector)
                                                or selector in baseline.methods.get(name, {}).get(kind, ())):
                registry["used_outside_sdk"][key] = len(plugins)
                break

    # What the later SDK added to the baseline: the classes and symbols of the
    # registry that its headers declare and the baseline did not define, each
    # with the header that declares it. A name neither had (one that only
    # another SDK's headers declare) is not an addition of the later SDK.
    registry["isix5_additions"] = {}
    for name in registry["classes"]:
        if name not in baseline.classes and name in sdk.defined:
            registry["isix5_additions"]["classes " + name] = sdk.classes[name]["header"]
    for symbol in registry["symbols"]:
        bare = mangled_function(symbol) or symbol[1:]
        header = sdk.functions.get(bare) or sdk.data.get(bare, {}).get("header")
        if header and symbol not in defined_by_baseline and bare not in baseline.functions and bare not in baseline.data:
            registry["isix5_additions"]["symbols " + symbol] = header

    # missing: what the current build lacks. Only selectors and ivars may be
    # listed there, and a class or a symbol the baseline did not define.
    lacking_classes = {name for name, superclass in registry["classes"].items() if not current.has_class(name, superclass)}
    # A class that is there under another superclass is lacking as the SDK's class and still answers its selectors.
    absent_classes = {name for name in lacking_classes if not current.has_class(name)}
    # What the registry there is listed as missing and the current build has again is no longer missing.
    for entry in sorted(registry["missing"]):
        section, _, key = entry.partition(" ")
        if section == "classes":
            back = key not in lacking_classes
        elif section == "symbols":
            back = key in current.exports
        elif section == "ivars":
            back = "_OBJC_IVAR_$_" + key in current.exports
        else:
            parts = re.match(r"^(\S+) ([-+])(\S+)$", key)
            back = bool(parts) and current.implements(*parts.groups())
        if back:
            del registry["missing"][entry]
    for name in sorted(lacking_classes):
        key = "classes " + name
        if key in registry["isix5_additions"]:
            registry["missing"][key] = ISIX5_ADDITION
    for symbol in sorted(registry["symbols"]):
        key = "symbols " + symbol
        if symbol not in current.exports and key in registry["isix5_additions"]:
            registry["missing"][key] = ISIX5_ADDITION
    # A selector is excused here only by its class being missing, which the
    # listings decide. Whether a class that is there answers a selector they do
    # not: a class of the system or Core Data may, past what they show. The test
    # of the registry says which selectors the build lacks, and one that no SDK
    # of Horos had is then listed by hand, with the reason that is true of it.
    for section in ("selectors", "used_outside_sdk"):
        for key in sorted(registry[section]):
            name = key.split(" ", 1)[0]
            entry = "%s %s" % (section, key)
            if entry not in registry["missing"] and name in absent_classes and "classes " + name in registry["missing"]:
                registry["missing"][entry] = "its class is missing (classes %s)" % name
    # An instance variable a known plugin reads is not excused either: that plugin is
    # refused whole without it.
    for key in sorted(registry["ivars"]):
        entry = "ivars " + key
        if entry not in registry["missing"] and "_OBJC_IVAR_$_" + key not in current.exports and not registry["ivars"][key]:
            name = key.split(".", 1)[0]
            registry["missing"][entry] = ("its class is missing (classes %s)" % name
                                          if name in absent_classes and "classes " + name in registry["missing"]
                                          else "%s exports no _OBJC_IVAR_$_ symbol for it%s" % (name, NOT_IN_SDK_LAYOUT))
    return registry, left



def parse_named(value):
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    name, paths = value.split("=", 1)
    return name.strip(), [Path(p.strip()) for p in paths.split(",") if p.strip()]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--api-headers", action="append", default=[], type=Path,
                        help="directory with the host SDK headers (repeatable; required, except with "
                        "--static-zlib-symbols alone)")
    parser.add_argument("--collection", action="append", default=[], type=parse_named,
                        help="NAME=DIR whose subdirectories are plugins")
    parser.add_argument("--plugin", action="append", default=[], type=parse_named,
                        help="NAME=PATH[,PATH...] scanned as one plugin")
    parser.add_argument("--macos-sdk", type=Path, help="macOS SDK root, to recognise Cocoa selectors")
    parser.add_argument("--markdown", type=Path, help="write the Markdown report here (default: stdout)")
    parser.add_argument("--json", type=Path, help="write the JSON report here")
    group = parser.add_argument_group("registry of the binary surface (tests/legacy-plugin-abi.json)")
    group.add_argument("--registry", type=Path, help="write the registry here")
    group.add_argument("--registry-base", type=Path, help="the registry there is: nothing of it is taken out")
    group.add_argument("--registry-about", type=Path, help="text file with the registry's about, where {left_out} "
                       "stands for what was left out and why (default: the about of --registry-base, with its "
                       "sentence \"Left out: ... .\" written again)")
    group.add_argument("--recount-ivars", type=Path, metavar="REGISTRY",
                       help="rewrite in this registry the use count of every entry of ivars, and nothing else")
    group.add_argument("--export-table-ivars", type=Path, metavar="REGISTRY",
                       help="rewrite in this registry what the table of exported instance variables decides")
    group.add_argument("--ivar-table", type=Path, default=Path(__file__).resolve().parents[1]
                       / "Horos/Scripts/Horos/legacy-plugin-ivars.json",
                       help="the table of the instance variables that Swift classes export (default: the application's)")
    group.add_argument("--older-sdk-headers", action="append", default=[], type=Path,
                       help="directory or header of a copy of an older SDK of OsiriX that plugins carry: the instance "
                       "variables only it declares count as declared (repeatable)")
    group.add_argument("--baseline-headers", action="append", default=[], type=Path,
                       help="directory or header of the SDK the baseline published (repeatable)")
    group.add_argument("--baseline-public-headers", action="append", default=[], type=Path,
                       help="directory of which only the headers --baseline-project builds Public count (repeatable)")
    group.add_argument("--baseline-project", type=Path, help="project.pbxproj of the baseline")
    group.add_argument("--baseline-sources", action="append", default=[], type=Path,
                       help="directory searched for the sources --baseline-project compiles (repeatable)")
    group.add_argument("--baseline-zlib-header", type=Path,
                       help="zlib.h of the copy of zlib the baseline linked statically into its executable: every function "
                       "it declares ZEXTERN enters symbols")
    group.add_argument("--static-zlib-symbols", type=Path, metavar="REGISTRY",
                       help="rewrite in this registry the symbols of --baseline-zlib-header and what host_resolution says "
                       "of them, and nothing else")
    for name in ("reference", "current"):
        group.add_argument("--%s-exports" % name, action="append", default=[], type=Path,
                           help="listing of nm -gUj of the %s application (repeatable)" % name)
        group.add_argument("--%s-objc" % name, action="append", default=[], type=Path,
                           help="listing of dyld_info -objc of the %s application (repeatable)" % name)
    args = parser.parse_args(argv)
    zlib_header = None
    if args.baseline_zlib_header:
        if not args.baseline_zlib_header.is_file():
            parser.error("missing: %s" % args.baseline_zlib_header)
        zlib_header = args.baseline_zlib_header.read_text(errors="replace")
    if args.static_zlib_symbols:
        if zlib_header is None:
            parser.error("--static-zlib-symbols needs --baseline-zlib-header")
        registry = json.loads(args.static_zlib_symbols.read_text(encoding="utf-8"))
        try:
            added = enter_static_zlib(registry, zlib_header)
        except ValueError as error:
            parser.error("--baseline-zlib-header: %s" % error)
        args.static_zlib_symbols.write_text(render_registry(registry), encoding="utf-8")
        sys.stderr.write("%s: %d symbols of the baseline's static zlib entered (%s)\n"
                         % (args.static_zlib_symbols, len(added), ", ".join(added) or "none"))
        if not (args.api_headers or args.collection or args.plugin or args.registry):
            return 0
    if not args.api_headers:
        parser.error("the following arguments are required: --api-headers")
    if not args.collection and not args.plugin:
        parser.error("give at least one --collection or --plugin")
    for directory in args.api_headers:
        if not directory.is_dir():
            parser.error("not a directory: %s" % directory)
    sdk = load_sdk(args.api_headers, args.macos_sdk)
    scan_sdk, baseline_headers = sdk, []
    if args.registry:
        if not (args.registry_base and args.baseline_project):
            parser.error("--registry needs --registry-base and --baseline-project")
        project = args.baseline_project.read_text(errors="replace")
        baseline_headers = list(args.baseline_headers)
        for directory in args.baseline_public_headers:
            baseline_headers += [path for path in sorted(directory.glob("*.h")) if path.name in public_headers(project)]
        # The uses are counted against both SDKs at once: a plugin written for
        # the baseline's headers uses what only they declare, and the classes
        # descend as the baseline's did, which is read last.
        scan_sdk = load_sdk(list(args.api_headers) + baseline_headers, args.macos_sdk)
    older_only = set()
    if args.older_sdk_headers:
        for path in args.older_sdk_headers:
            if not path.exists():
                parser.error("missing: %s" % path)
        # In the model the uses are counted against, which is also the one
        # --export-table-ivars asks: what --registry writes from the headers
        # of the two SDKs does not change.
        older_only = declare_older_ivars(scan_sdk, load_sdk(args.older_sdk_headers))
    report = {"sdk": {"headers": len(sdk.headers), "classes": len(sdk.classes), "selectors": len(sdk.selectors),
                      "notifications": len(sdk.notifications), "functions": len(sdk.functions),
                      "dirs": [str(d) for d in args.api_headers], "git": [git_info(d) for d in args.api_headers],
                      "system_selectors": len(sdk.system_selectors),
                      "constants": len(sdk.constants), "globals": len(sdk.globals),
                      # What a plugin looks up by name: each datum with its header, its type and
                      # whether a plugin can write it, and each function, marked when the header
                      # defines it static or inline and the host therefore has no symbol for it.
                      "data": sdk.data,
                      "function_names": {name: {"header": header, "inline": name in sdk.inline_functions}
                                         for name, header in sdk.functions.items()}},
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
            scan = scan_plugin(entry_name, "%s/%s" % (name, kind), [path], scan_sdk)
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
        scan = scan_plugin(name, "plugin", paths, scan_sdk)
        scan.git = git_info(paths[0] if paths[0].is_dir() else paths[0].parent)
        data = to_json(scan)
        data["source"] = name
        report["plugins"].append(data)
        counts = {"entries": 1, "plugins": 1 if data["plugin_products"] else 0,
                  "products": len(data["plugin_products"]), "no_sources": 0, "no_source_names": [],
                  "not_plugins": []}
        report["sources"].append({"name": name, "label": ", ".join(p.name for p in paths), "git": scan.git,
                                  "counts": counts})
    if args.registry:
        compiled = project_names(project, "Sources")
        baseline_sdk = load_sdk(baseline_headers)
        baseline = BaselineSources()
        for directory in args.baseline_sources:
            for path in sorted(directory.rglob("*")):
                if path.is_file() and path.name in compiled and path.suffix in SOURCE_SUFFIXES:
                    baseline.read(path)
        base = json.loads(args.registry_base.read_text(encoding="utf-8"))
        registry, left = build_registry(
            base, sdk, baseline_sdk, baseline,
            Surface(read_exports(args.reference_exports), read_objc_metadata(args.reference_objc)),
            Surface(read_exports(args.current_exports), read_objc_metadata(args.current_objc)),
            use_counts(report["plugins"]), "")
        left_out = "; ".join("%d %s" % (count, what) for what, count in sorted(left.items()))
        if args.registry_about:
            registry["about"] = args.registry_about.read_text(encoding="utf-8").strip().replace("{left_out}", left_out)
        elif not LEFT_OUT.search(base.get("about", "")):
            parser.error("the about of --registry-base has no sentence \"Left out: ... .\" to write again: give --registry-about")
        else:
            registry["about"] = LEFT_OUT.sub(lambda _: "Left out: %s." % left_out, base["about"], count=1)
        if zlib_header is not None:
            try:
                enter_static_zlib(registry, zlib_header)
            except ValueError as error:
                parser.error("--baseline-zlib-header: %s" % error)
        args.registry.write_text(render_registry(registry), encoding="utf-8")
    if args.recount_ivars:
        registry = json.loads(args.recount_ivars.read_text(encoding="utf-8"))
        counts = use_counts(report["plugins"])["ivars"]
        registry["ivars"] = {key: len(counts.get(tuple(key.split(".", 1)), ())) for key in registry["ivars"]}
        args.recount_ivars.write_text(render_registry(registry), encoding="utf-8")
    if args.export_table_ivars:
        registry = json.loads(args.export_table_ivars.read_text(encoding="utf-8"))
        table = json.loads(args.ivar_table.read_text(encoding="utf-8"))["ivars"]
        try:
            changed = export_table_ivars(registry, table, scan_sdk, use_counts(report["plugins"])["ivars"], older_only)
        except ValueError as error:
            parser.error("--export-table-ivars: %s" % error)
        args.export_table_ivars.write_text(render_registry(registry), encoding="utf-8")
        sys.stderr.write("%s: %d entries of the table left missing, %d entered ivars (%s), %d reasons of missing instance "
                         "variables reworded\n" % (args.export_table_ivars, len(changed["restored"]), len(changed["added"]),
                                                   ", ".join("%s %d" % (name, registry["ivars"][name]) for name in changed["added"])
                                                   or "none", changed["reworded"]))
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
