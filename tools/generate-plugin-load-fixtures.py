#!/usr/bin/env python3
"""Build local synthetic plugins, of the former API and of the version 1 API.

Former plugins: QAUniversal.horosplugin (an image filter), QAOsiriX.osirixplugin
(a database plugin) and the other QA*.horosplugin cases link only AppKit.
QAHostLinked.horosplugin is built as the plugins of the former SDK were: its
principal class is an Objective-C subclass of the host's PluginFilter, whose
+filter and -prepareFilter: it inherits, it messages the host's PluginManager
class, both found at run time with -undefined dynamic_lookup, and its load
commands name the SDK frameworks by their install names in the application
(Horos, HorosAPI, OsiriXAPI, OsiriX Headers, HorosDCM), built here as
stand-ins; it loads only in the application. QAMissingSymbol.horosplugin
looks up a constant that no application defines, and never loads. With
HOROS_PLUGIN_MARKER_DIR set,
a former plugin's -filterImage: leaves <Class>.executed there instead of
showing an alert, and QAHostLinked's -initPlugin, which the host's -init calls
when +filter makes its filter, leaves QAHostLinked.initPlugin.

QAModalDialog.horosplugin is a database plugin whose command keeps a modal
dialog open: the moment the application can be asked to quit with the code of
a plugin still on the stack. Left alone it only shows its dialog. To drive it
without a hand on the mouse, HOROS_PLUGIN_MODAL_AUTORUN=<seconds> makes it
choose its own menu item that long after the launch finishes, and
HOROS_PLUGIN_MODAL_QUIT says what it does two seconds after the dialog opens:
`key` posts Command-Q to the application's event queue, as the keyboard does;
`delegate` sends -terminate: to the application's delegate from a block of the
main run loop in the common modes, which is where the installation of an
update asks the application to quit; `application` sends -terminate: to
NSApplication. With HOROS_PLUGIN_MARKER_DIR set it also writes what it saw,
the note naming the running plugin included, to QAModalDialog.trace there.

QALegacyIvars.horosplugin reads and writes the instance variables of the
host's classes directly, as a plugin built for the former SDK does from a
category of DCMView, ROI, ViewerController or AppController: it is compiled
without ARC against the instance variable blocks of those four classes as the
headers of the Horos SDK declared them, copied here, and linked with
-undefined dynamic_lookup, so its binary looks up _OBJC_IVAR_$_Class.ivar for
each variable it touches, and loads only in an application that exports them
all. When a viewer posts OsirixViewerControllerDidLoadImagesNotification it
touches every variable known plugins read (the store of what it read, at the
offset the application exported, which must be inside the instance), compares
the ones the SDK had an accessor for with what the accessor answers, stores
another value in some and reads it back through the accessor before putting
back what was there, and expects the ones nothing of the application stands
behind (the OpenGL names and textures, the ROI's string textures) to be 0 or
nil; the block of DCMView ends with the variables only the header of an older
SDK of OsiriX declared, which it treats as the others; a variable that Horos/Scripts/Horos/legacy-plugin-ivars.json, when it is
there, gives a state other than inert is only touched. With
HOROS_PLUGIN_MARKER_DIR set it leaves QALegacyIvars.loaded when it loads and
QALegacyIvars.result after each viewer: the number of checks and one line per
failure.

QALegacySubclasses.horosplugin declares Objective-C subclasses of the host's
DCMView, ROI and ViewerController, as plugins built for the former SDK do:
compiled without ARC against the same declarations, with instance variables
of its own after the SDK's where those plugins had some, and linked with
-undefined dynamic_lookup. Each class overrides what the known plugins
override (Align, CMIV CTA, PrintingLayout, Ninety Degrees and
HipArthroplastyTemplating) and counts the calls of each override. When the
first viewer posts OsirixViewerControllerDidLoadImagesNotification it goes,
one step every second and a half, through what those plugins do: a ROI made
with -initWithType:::: and added to the image's list (roi), a length drawn
with the mouse, after which the application asks each ROI whether it is valid
(roivalid), a view made with
-init, -initWithFrame: and -initWithFrame:imageRows:imageColumns:, filled
from the viewer's view in a window of its own (view) and sent a click, a drag,
a right click, a key and a scroll (viewevents), a viewer made with
-viewCinit::: on a copy of the series (viewer), scaled to fit as the main
window (viewerreach) and closed (viewerclose), and, last, a copy of the ROI
(roicopy). Before that copy it does what no plugin does, to know which
overrides the application reaches whatever happens to a plugin's own
instance: the viewer's own view is given a class of the plugin without
instance variables, which is what Align's +poseAsClass: meant, and is drawn,
scaled and sent the events (pose), shown another image (poseimage) and given
its class back (unpose); two ROIs the application made are given such a class
and drawn (poseroi), clicked (poseroiclick) and copied (poseroicopy).
HOROS_PLUGIN_SUBCLASS_SKIP=<step>,<step> leaves steps out. With
HOROS_PLUGIN_MARKER_DIR set it leaves QALegacySubclasses.loaded when it loads,
rewrites QALegacySubclasses.trace at each line (the class objects, each
step's begin, what it made, and at its end the overrides that ran since it
began), so that a fault leaves what ran before it, and
QALegacySubclasses.result after the last step, with the times each override
ran.

QA.horosplugin (version 1.0) and QA.osirixplugin (version 2.0) are one database
plugin under the two former extensions, as two installers of one author leave
it; -filterImage: says which bundle and version ran, in QA.executed when
HOROS_PLUGIN_MARKER_DIR is set.

Never installs them.
"""
from pathlib import Path
import argparse
import json
import os
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
if any(args.destination.iterdir()):
    parser.error('destination must be empty')
for name, architectures, principal, throws, extension, plugin_type in [
    ('QADisabled', ['arm64', 'x86_64'], 'QADisabled', False, 'horosplugin', 'imageFilter'),
    ('QAUniversal', ['arm64', 'x86_64'], 'QAUniversal', False, 'horosplugin', 'imageFilter'),
    ('QAOsiriX', ['arm64', 'x86_64'], 'QAOsiriX', False, 'osirixplugin', 'Database'),
    ('QAIntel', ['x86_64'], 'QAIntel', False, 'horosplugin', 'imageFilter'),
    ('QAMissingClass', ['arm64', 'x86_64'], 'QAAbsent', False, 'horosplugin', 'imageFilter'),
    ('QAInvalidSignature', ['arm64', 'x86_64'], 'QAInvalidSignature', False, 'horosplugin', 'imageFilter'),
    ('QAInitializationFailure', ['arm64', 'x86_64'], 'QAInitializationFailure', True, 'horosplugin', 'imageFilter'),
]:
    bundle = args.destination / (name + '.' + extension)
    executable = bundle / 'Contents/MacOS' / name
    executable.parent.mkdir(parents=True)
    source = args.destination / (name + '.m')
    source.write_text('''#import <AppKit/AppKit.h>
@interface CLASS : NSObject
+ (id)filter;
- (long)filterImage:(NSString*)menu;
@end
@implementation CLASS
// +load runs while the loader is still inside -[NSBundle loadAndReturnError:],
// which is the only moment the note naming the plugin being loaded is true.
// Silent unless HOROS_PLUGIN_MARKER_DIR says where to look.
+ (void)load {
    const char *directory = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (!directory) return;
    NSString *where = @(directory);
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:where error:NULL])
        if ([entry hasPrefix:@"Plugin_Loading"])
            NSLog(@"PLUGINFIXTURE while CLASS loads, %@ names %@", entry,
                  [NSString stringWithContentsOfFile:[where stringByAppendingPathComponent:entry]
                                            encoding:NSUTF8StringEncoding error:NULL]);
}
+ (id)filter { BODY }
- (long)prepareFilter:(id)viewer { return 0; }
- (long)filterImage:(NSString*)menu {
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) {
        [menu writeToFile:[@(markers) stringByAppendingPathComponent:@"CLASS.executed"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return 0;
    }
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Synthetic plugin executed";
    alert.informativeText = @"QA universal filter completed without changing images.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return 0;
}
@end
'''.replace('CLASS', name).replace('BODY', '@throw [NSException exceptionWithName:@"SyntheticFailure" reason:@"Synthetic initialization failure" userInfo:nil];' if throws else 'return [[[self alloc] init] autorelease];'))
    command = ['xcrun', 'clang', '-bundle', '-framework', 'AppKit']
    for architecture in architectures:
        command += ['-arch', architecture]
    # clang leaves an empty folder per architecture in TMPDIR when it links a
    # universal binary; give it one that goes away with the build.
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(command + [str(source), '-o', str(executable)], check=True,
                       env=dict(os.environ, TMPDIR=scratch + '/'))
    info = {'CFBundleExecutable': name, 'CFBundleIdentifier': 'org.horosproject.qa.' + name,
            'CFBundleName': name, 'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL',
            'NSPrincipalClass': principal, 'pluginType': plugin_type, 'MenuTitles': [name]}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    resources = bundle/'Contents/Resources'
    resources.mkdir()
    (resources/'seal.txt').write_text('Original synthetic resource')
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    if name == 'QAInvalidSignature':
        (resources/'seal.txt').write_text('Modified after signing')

# A former plugin built against the former SDK: stand-ins of its frameworks,
# with the install names the application gives them, and a class that messages
# the host's PluginManager, which dyld finds at run time.
sdk = args.destination / 'FormerSDK'
sdk_source = args.destination / 'FormerSDK.c'
sdk_source.write_text(''.join(f'double {v}VersionNumber = 100;\nconst unsigned char {v}VersionString[] = "1.0.0";\n'
                              for v in ('HorosAPI', 'OsiriXAPI', 'OsiriX_Headers', 'HorosDCM')))
sdk_frameworks = ['Horos', 'HorosAPI', 'OsiriXAPI', 'OsiriX Headers', 'HorosDCM']
for framework in sdk_frameworks:
    binary = sdk / f'{framework}.framework/Versions/A/{framework}'
    binary.parent.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                        '-install_name', f'@executable_path/../Frameworks/{framework}.framework/Versions/A/{framework}',
                        str(sdk_source), '-o', str(binary)], check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
    (sdk / f'{framework}.framework/Versions/Current').symlink_to('A')
    (sdk / f'{framework}.framework/{framework}').symlink_to(f'Versions/Current/{framework}')
host_linked = args.destination / 'QAHostLinked.horosplugin'
(host_linked / 'Contents/MacOS').mkdir(parents=True)
host_source = args.destination / 'QAHostLinked.m'
host_source.write_text('''#import <Foundation/Foundation.h>
// What the former SDK declared of the host's classes; the classes themselves are the application's.
@interface PluginManager : NSObject
+ (NSMutableDictionary *)plugins;
@end
@interface PluginFilter : NSObject
+ (PluginFilter *)filter;
- (long)filterImage:(NSString *)menuName;
- (void)initPlugin;
- (long)prepareFilter:(id)vC;
@end
extern double HorosAPIVersionNumber, OsiriXAPIVersionNumber, OsiriX_HeadersVersionNumber, HorosDCMVersionNumber;
static void QAHostLinkedMark(NSString *name, NSString *text) {
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) [text writeToFile:[@(markers) stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
@interface QAHostLinked : PluginFilter
@end
@implementation QAHostLinked
- (void)initPlugin {
    QAHostLinkedMark(@"QAHostLinked.initPlugin", [NSStringFromClass([PluginManager class]) stringByAppendingFormat:@" %@ %@",
        NSStringFromClass([self class]), NSStringFromClass([self superclass])]);
}
- (long)filterImage:(NSString *)menu {
    QAHostLinkedMark(@"QAHostLinked.executed", [NSString stringWithFormat:@"%@ %@ %lu %g %g %g %g", menu, NSStringFromClass([PluginManager class]),
        (unsigned long)[[PluginManager plugins] count], HorosAPIVersionNumber, OsiriXAPIVersionNumber, OsiriX_HeadersVersionNumber, HorosDCMVersionNumber]);
    return 0;
}
@end
''')
command = ['xcrun', 'clang', '-bundle', '-framework', 'Foundation', '-mmacosx-version-min=15.0', '-arch', 'arm64', '-arch', 'x86_64',
           '-undefined', 'dynamic_lookup', '-F', str(sdk)]
for framework in sdk_frameworks:
    command += ['-framework', framework]
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(command + [str(host_source), '-o', str(host_linked / 'Contents/MacOS/QAHostLinked')], check=True,
                   env=dict(os.environ, TMPDIR=scratch + '/'))
(host_linked / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QAHostLinked', 'CFBundleIdentifier': 'org.horosproject.qa.QAHostLinked', 'CFBundleName': 'QAHostLinked',
    'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QAHostLinked', 'pluginType': 'Database',
    'MenuTitles': ['QAHostLinked A', '(-', 'QAHostLinked B']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(host_linked)], check=True, capture_output=True)

# A former plugin whose binary looks, as the former SDK's plugins do with
# -undefined dynamic_lookup, for a constant that no application defines:
# dyld refuses it with a link error that names the symbol.
missing_symbol = args.destination / 'QAMissingSymbol.horosplugin'
(missing_symbol / 'Contents/MacOS').mkdir(parents=True)
missing_source = args.destination / 'QAMissingSymbol.m'
missing_source.write_text('''#import <Foundation/Foundation.h>
extern NSString *const QAAbsentHostSymbol;
@interface QAMissingSymbol : NSObject
@end
@implementation QAMissingSymbol
+ (id)filter { return QAAbsentHostSymbol; }
@end
''')
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-bundle', '-framework', 'Foundation', '-mmacosx-version-min=15.0', '-arch', 'arm64', '-arch', 'x86_64',
                    '-undefined', 'dynamic_lookup', str(missing_source), '-o', str(missing_symbol / 'Contents/MacOS/QAMissingSymbol')],
                   check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(missing_symbol / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QAMissingSymbol', 'CFBundleIdentifier': 'org.horosproject.qa.QAMissingSymbol', 'CFBundleName': 'QAMissingSymbol',
    'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QAMissingSymbol', 'pluginType': 'imageFilter',
    'MenuTitles': ['QAMissingSymbol']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(missing_symbol)], check=True, capture_output=True)

# A former plugin that reads and writes the host's instance variables directly:
# see the module's description. The blocks are the instance variables of the
# four classes as the headers of the Horos SDK (Horos 4.0.0 RC5, of the Horos
# Project and the OsiriX Team, LGPL) declared them, without their comments: a
# plugin was compiled against these declarations, and each variable it touches
# becomes a lookup of _OBJC_IVAR_$_Class.ivar in the application. The block of
# DCMView ends, from curDCM on, with the variables that only the header of an
# older SDK of OsiriX declared (OsiriX Team, LGPL), with which some plugins
# were built: curDCM is the one the later SDK named _curDCM.
LEGACY_IVAR_BLOCKS = {
    'DCMView': ('NSOpenGLView', r'''
    NSInteger _imageRows;
    NSInteger _imageColumns;
    NSInteger _tag;
    BOOL flippedData;
    BOOL whiteBackground;
    NSString *yearOld;
    ROI *curROI;
    int volumicData;
    BOOL drawingROI, noScale, volumicSeries, mouseDraggedForROIUndo;
    DCMView *blendingView;
    float blendingFactor, blendingFactorStart;
    BOOL eraserFlag;
    BOOL colorTransfer;
    unsigned char *colorBuf, *blendingColorBuf;
    unsigned char alphaTable[256], opaqueTable[256], redTable[256], greenTable[256], blueTable[256];
    float redFactor, greenFactor, blueFactor;
    long blendingMode;
    float sliceFromTo[ 2][ 3], sliceFromToS[ 2][ 3], sliceFromToE[ 2][ 3], sliceFromTo2[ 2][ 3], sliceFromToThickness;
    float sliceVector[ 3];
    float slicePoint3D[ 3];
    float syncRelativeDiff;
    long syncSeriesIndex;
    float mprVector[ 3], mprPoint[ 3];
    NSTimeInterval timeIntervalForDrag;
    short thickSlabMode, thickSlabStacks;
    NSMutableArray *rectArray;
    BOOL recordAnnotationRects;
    NSMutableArray *dcmPixList;
    NSArray *dcmFilesList;
    NSMutableArray *dcmRoiList, *curRoiList;
    DCMPix *_curDCM;
    DCMExportPlugin *dcmExportPlugin;
    char listType;
    short curImage, startImage;
    ToolMode currentTool, currentToolRight, currentMouseEventTool;
    BOOL mouseDragging;
    BOOL suppress_labels;
    NSPoint start, originStart, previous;
    float startWW, curWW, startMin, startMax;
    float startWL, curWL;
    float bdstartWW, bdcurWW, bdstartMin, bdstartMax;
    float bdstartWL, bdcurWL;
    BOOL curWLWWSUVConverted;
    float curWLWWSUVFactor;
    NSSize scaleStart, scaleInit;
    double resizeTotal;
    float scaleValue, startScaleValue;
    float rotation, rotationStart;
    NSPoint origin;
    short crossMove;
    NSMatrix *matrix;
    long count;
    BOOL xFlipped, yFlipped;
    long fontListGLSize[256];
    long labelFontListGLSize[ 256];
    NSSize stringSize;
    NSFont *labelFont;
    NSFont *fontGL;
    NSColor *fontColor;
    GLuint fontListGL;
    GLuint labelFontListGL;
    float fontRasterY;
    NSPoint mesureA, mesureB;
    NSRect roiRect;
    NSString *stringID;
    NSSize previousViewSize;
    float contextualMenuInWindowPosX;
    float contextualMenuInWindowPosY;
    float mouseXPos, mouseYPos;
    float pixelMouseValue;
    long pixelMouseValueR, pixelMouseValueG, pixelMouseValueB;
    float blendingMouseXPos, blendingMouseYPos;
    float blendingPixelMouseValue;
    long blendingPixelMouseValueR, blendingPixelMouseValueG, blendingPixelMouseValueB;
    long textureX, blendingTextureX;
    long textureY, blendingTextureY;
    GLuint * pTextureName;
    GLuint * blendingTextureName;
    long textureWidth, blendingTextureWidth;
    long textureHeight, blendingTextureHeight;
    BOOL f_ext_texture_rectangle;
    BOOL f_arb_texture_rectangle;
    BOOL f_ext_client_storage;
    BOOL f_ext_packed_pixel;
    BOOL f_ext_texture_edge_clamp;
    BOOL f_gl_texture_edge_clamp;
    unsigned long edgeClampParam;
    long maxTextureSize;
    long maxNOPTDTextureSize;
    long TEXTRECTMODE;
    BOOL isKeyView;
    NSCursor *cursor;
    BOOL cursorSet;
    NSTrackingArea *cursorTracking;
    NSPoint display2DPoint;
    int display2DPointIndex;
    NSMutableDictionary *stringTextureCache;
    BOOL _dragInProgress;
    NSTimer *_mouseDownTimer;
    NSTimer *_rightMouseDownTimer;
    NSImage *destinationImage;
    BOOL _hasChanged, needToLoadTexture, showDescriptionInLarge;
    BOOL scaleToFitNoReentry;
    GLString *showDescriptionInLargeText;
    float previousScalingFactor;
    BOOL drawing;
    int repulsorRadius;
    NSPoint repulsorPosition;
    NSTimer *repulsorColorTimer;
    float repulsorAlpha, repulsorAlphaSign;
    BOOL repulsorROIEdition;
    long scrollMode;
    NSPoint ROISelectorStartPoint, ROISelectorEndPoint;
    BOOL selectorROIEdition;
    NSMutableArray *ROISelectorSelectedROIList;
    BOOL syncOnLocationImpossible, updateNotificationRunning;
    char *resampledBaseAddr, *blendingResampledBaseAddr;
    BOOL zoomIsSoftwareInterpolated, firstTimeDisplay;
    int resampledBaseAddrSize, blendingResampledBaseAddrSize;
    NSRect drawingFrameRect, screenCaptureRect;
    BOOL exceptionDisplayed;
    BOOL COPYSETTINGSINSERIES;
    BOOL is2DViewerCached, is2DViewerValue;
    char* lensTexture;
    int lensSize;
    float lensSizeFactor;
    float LENSRATIO;
    float lensZoomFactor;
    BOOL cursorhidden;
    int avoidRecursiveSync;
    BOOL avoidMouseMovedRecursive;
    BOOL avoidChangeWLWWRecursive;
    BOOL TextureComputed32bitPipeline;
    NSImage *loupeImage, *loupeMaskImage;
    GLuint loupeTextureID, loupeTextureWidth, loupeTextureHeight;
    GLubyte *loupeTextureBuffer;
    GLuint loupeMaskTextureID, loupeMaskTextureWidth, loupeMaskTextureHeight;
    GLubyte *loupeMaskTextureBuffer;
    float studyColorR, studyColorG, studyColorB;
    NSUInteger studyDateIndex;
    GLString *studyDateBox;
    int annotationType;
    NSArray *cleanedOutDcmPixArray;
    DCMPix *curDCM;
    NSPoint originOffset;
    int LENSSIZE;
    NSOpenGLContext *_alternateContext;
    float iChatWidth, iChatHeight;
    NSPoint iChatCursorHotSpot;
    NSSize iChatCursorImageSize;
    unsigned char* iChatCursorTextureBuffer;
    GLuint iChatCursorTextureName;
    float angle, slab;
    NSPoint cross;
    float slicePoint[ 3], slicePointO[ 3], slicePointI[ 3];
    float sliceVector2[ 3], slicePoint2[ 3], slicePointO2[ 3], slicePointI2[ 3];
    BOOL QuartzExtreme, dontEnterReshape, iChatDrawing;
    NSPoint crossPrev, originOffsetStart;
    NSSize iChatStringSize;
    float switchAngle;
    GLuint iChatFontListGL;
    long iChatFontListGLSize[ 256];
    char *resampledTempAddr;
    NSDictionary *_hotKeyDictionary, *localeDictionnary;
    NSFont *iChatFontGL;
    NSMutableDictionary *iChatStringTextureCache;
    NSTimer *mouseModifiers;
    NSImage *myImage;
    NSString *shortDateString, *shortDateTimeString;
    GLString *warningNotice;
'''),
    'ROI': ('NSObject', r'''
    NSRecursiveLock *roiLock;
    int textureWidth, textureHeight;
    unsigned char *textureBuffer, *textureBufferSelected;
    NSMutableArray *ctxArray;
    NSMutableArray *textArray;
    int textureUpLeftCornerX,textureUpLeftCornerY,textureDownRightCornerX,textureDownRightCornerY;
    int textureFirstPoint;
    NSMutableArray *points;
    NSMutableArray *zPositions;
    NSRect rect;
    BOOL _hasIsSpline, _isSpline;
    ToolMode type;
    long mode, previousMode;
    BOOL needQuartz;
    float thickness;
    BOOL fill;
    float opacity;
    RGBColor color;
    BOOL closed,clickInTextBox;
    NSString *name;
    NSString *comments;
    double pixelSpacingX, pixelSpacingY;
    NSPoint imageOrigin;
    BOOL mouseOverROI;
    int PointUnderMouse;
    long selectedModifyPoint;
    NSPoint clickPoint, previousPoint, originAnchor;
    DCMView *curView;
    DCMPix *pix;
    float rmean, rmax, rmin, rdev, rtotal, rskewness, rkurtosis;
    float Brmean, Brmax, Brmin, Brdev, Brtotal, Brskewness, Brkurtosis;
    double Brmedian;
    float mousePosMeasure;
    StringTexture *stringTex;
    NSMutableDictionary *stanStringAttrib;
    NSCache *stringTextureCache;
    ROI* parentROI;
    NSRect drawRect;
    float offsetTextBox_x, offsetTextBox_y;
    NSString *textualBoxLine1, *textualBoxLine2, *textualBoxLine3, *textualBoxLine4, *textualBoxLine5, *textualBoxLine6;
    BOOL _displayCalciumScoring;
    int _calciumThreshold;
    double _sliceThickness;
    int _calciumCofactor;
    NSString *layerReferenceFilePath;
    NSImage *layerImage;
    NSData *layerImageJPEG;
    float layerPixelSpacingX, layerPixelSpacingY;
    BOOL isLayerOpacityConstant;
    BOOL canColorizeLayer, canResizeLayer;
    NSColor *layerColor;
    NSNumber *uniqueID;
    NSTimeInterval groupID;
    BOOL displayTextualData;
    BOOL displayCMOrPixels;
    BOOL locked;
    BOOL selectable;
    BOOL isAliased;
    int originalIndexForAlias;
    BOOL hidden;
    StringTexture *stringTexA, *stringTexB, *stringTexC;
'''),
    'ViewerController': ('OSIWindowController', r'''
    NSRecursiveLock *roiLock;
    NSConditionLock *flipDataThread, *convThread;
    NSThread *loadingThread;
    ToolbarPanelController *toolbarPanel;
    IBOutlet StudyView *studyView;
    SeriesView *seriesView;
    IBOutlet NSMatrix *previewMatrix;
    IBOutlet NSScrollView *previewMatrixScrollView;
    IBOutlet NSView *previewRootView;
    BOOL matrixPreviewBuilt;
    float highLighted;
    NSTimer *highLightedTimer;
    IBOutlet NSSplitView *splitView;
    BOOL splitViewAllocated;
    IBOutlet NSWindow *quicktimeWindow;
    IBOutlet NSMatrix *quicktimeMode;
    IBOutlet NSSlider *quicktimeInterval, *quicktimeFrom, *quicktimeTo;
    IBOutlet NSTextField *quicktimeIntervalText, *quicktimeFromText, *quicktimeToText, *quicktimeNumber;
    IBOutlet NSBox *quicktimeBox;
    IBOutlet NSButton *quicktimeAllViewers;
    DCMView *imageView;
    IBOutlet NSView *windowsTiling, *annotations, *seriesPopupView;
    IBOutlet NSView *orientationView;
    IBOutlet NSMatrix *orientationMatrix;
    short currentOrientationTool, originalOrientation;
    IBOutlet NSSlider *slider, *speedSlider;
    IBOutlet NSButton *loopButton;
    IBOutlet NSView *speedView;
    IBOutlet NSView *toolsView;
    IBOutlet NSView *WLWWView;
    IBOutlet NSView *ReconstructionView;
    IBOutlet NSView *ConvView;
    IBOutlet NSView *FusionView;
    IBOutlet NSView *BlendingView;
    IBOutlet NSView *movieView, *serieView, *patientView, *keyImages, *PagePad;
    IBOutlet NSView *RGBFactorsView;
    IBOutlet NSTextField *speedText;
    IBOutlet NSPopUpButton *wlwwPopup;
    IBOutlet NSPopUpButton *convPopup;
    IBOutlet NSPopUpButton *clutPopup;
    IBOutlet NSPopUpButton *OpacityPopup;
    BOOL OpacityPopupSet, clutPopupSet, convPopupSet, wlwwPopupSet;
    IBOutlet NSPopUpButton *seriesPopupMenu;
    IBOutlet NSPopUpButton *windowsTilingMenu;
    NSMenuItem *seriesPopupContextualMenu;
    BOOL needsToBuildSeriesPopupMenu, needsToBuildSeriesMatrix;
    IBOutlet NSView *propagateSettingsView;
    IBOutlet NSView *subCtrlView;
    BOOL enableSubtraction;
    IBOutlet NSButton *subCtrlOnOff;
    long subCtrlMaskID;
    NSPoint subCtrlMinMax;
    BOOL subCtrlMinMaxComputed;
    IBOutlet NSTextField *subCtrlMaskText;
    NSPoint subCtrlOffset;
    IBOutlet NSButton *sc1;
    IBOutlet NSButton *sc2;
    IBOutlet NSButton *sc3;
    IBOutlet NSButton *sc4;
    IBOutlet NSButton *sc5;
    IBOutlet NSButton *sc6;
    IBOutlet NSButton *sc7;
    IBOutlet NSButton *sc8;
    IBOutlet NSButton *sc9;
    IBOutlet NSSlider *subCtrlSum;
    IBOutlet NSSlider *subCtrlPercent;
    IBOutlet NSButton *subCtrlSharpenButton;
    IBOutlet NSButton *shutterOnOff;
    IBOutlet NSView *shutterView;
    long speedometer;
    int statusValueToApply;
    IBOutlet NSView *StatusView;
    IBOutlet NSButton *CommentsField;
    IBOutlet NSPopUpButton *StatusPopup;
    IBOutlet NSWindow *CommentsWindow, *saveWindowsStateWindow;
    IBOutlet NSTextField *CommentsEditField;
    IBOutlet NSButton *keyImageCheck;
    IBOutlet NSWindow *ThickIntervalWindow;
    IBOutlet NSTextField *customInterval;
    IBOutlet NSTextField *customXSpacing;
    IBOutlet NSTextField *customYSpacing;
    IBOutlet NSMatrix *customVectors, *customOrigin;
    IBOutlet NSWindow *setWLWWWindow;
    IBOutlet NSTextField *wlset, *fromset;
    IBOutlet NSTextField *wwset, *toset;
    IBOutlet NSWindow *addWLWWWindow;
    IBOutlet NSTextField *newName;
    IBOutlet NSTextField *wl;
    IBOutlet NSTextField *ww;
    IBOutlet NSMatrix *toolsMatrix;
    IBOutlet NSWindow *roiSetPixWindow;
    IBOutlet NSTextField *maxValueText, *minValueText, *newValueText;
    IBOutlet NSMatrix *InOutROI, *AllROIsRadio, *newValueMatrix;
    IBOutlet NSButton *checkMaxValue, *checkMinValue, *setROI4DSeries;
    IBOutlet NSWindow *blendingTypeWindow;
    IBOutlet NSButton *blendingTypeMultiply, *blendingTypeSubtract;
    IBOutlet NSSegmentedControl *blendingTypeRGB;
    IBOutlet NSPopUpButton *blendingPlugins;
    IBOutlet NSButton *blendingResample;
    IBOutlet NSWindow *roiPropaWindow;
    IBOutlet NSMatrix *roiPropaMode, *roiPropaDim, *roiPropaCopy;
    IBOutlet NSTextField *roiPropaDest;
    IBOutlet NSWindow *roiApplyWindow;
    IBOutlet NSMatrix *roiApplyMatrix;
    IBOutlet NSWindow *addConvWindow;
    IBOutlet NSMatrix *convMatrix, *sizeMatrix;
    IBOutlet NSTextField *matrixName, *matrixNorm;
    IBOutlet NSWindow *addCLUTWindow;
    IBOutlet NSTextField *clutName;
    IBOutlet ColorTransferView *clutView;
    IBOutlet NSWindow *dcmExportWindow;
    IBOutlet NSMatrix *dcmSelection, *dcmFormat;
    IBOutlet NSSlider *dcmInterval, *dcmFrom, *dcmTo;
    IBOutlet NSTextField *dcmIntervalText, *dcmFromText, *dcmToText, *dcmNumber;
    IBOutlet NSBox *dcmBox;
    IBOutlet NSButton *dcmAllViewers;
    IBOutlet NSTextField *dcmSeriesName;
    IBOutlet NSWindow *imageExportWindow;
    IBOutlet NSMatrix *imageSelection, *imageFormat;
    IBOutlet NSButton *imageAllViewers;
    IBOutlet NSWindow *displaySUVWindow;
    IBOutlet NSForm *suvForm;
    IBOutlet NSMatrix *suvConversion;
    NSCalendarDate *editedRadiopharmaceuticalStartTime, *editedAcquisitionTime;
    NSCalendarDate *injectionDateTime;
    IBOutlet NSWindow *addOpacityWindow;
    IBOutlet NSTextField *OpacityName;
    IBOutlet OpacityTransferView *OpacityView;
    IBOutlet NSTextField *movieTextSlide;
    IBOutlet NSButton *moviePlayStop;
    IBOutlet NSSlider *movieRateSlider;
    IBOutlet NSSlider *moviePosSlider;
    IBOutlet NSPopUpButton *blendingPopupMenu;
    IBOutlet NSTextField *blendingPercentage;
    IBOutlet NSSlider *blendingSlider;
    ViewerController *blendingController;
    IBOutlet NSTextField *roiRenameName;
    IBOutlet NSMatrix *roiRenameMatrix;
    IBOutlet NSWindow *roiRenameWindow;
    NSString *curConvMenu, *curWLWWMenu, *curCLUTMenu, *backCurCLUTMenu, *curOpacityMenu;
    IBOutlet NSTextField *stacksFusion;
    IBOutlet NSSlider *sliderFusion;
    IBOutlet NSButton *activatedFusion;
    IBOutlet NSPopUpButton *popFusion, *popupRoi, *ReconstructionRoi;
    IBOutlet NSMatrix *buttonToolMatrix;
    IBOutlet NSButton* comparativesButton;
    NSNumber* flagListPODComparatives;
    NSMutableArray *fileList[ MAX4D];
    NSMutableArray<DCMPix *> *pixList[MAX4D];
    NSMutableArray<NSMutableArray<ROI *> *> *roiList[MAX4D];
    NSMutableArray<NSData *> *copyRoiList[MAX4D];
    NSData *volumeData[ MAX4D];
    short curMovieIndex, maxMovieIndex, orientationVector;
    NSToolbar *toolbar;
    float direction;
    float factorPET2SUV;
    BOOL FullScreenOn, SavedUseFloatingThumbnailsList;
    NSWindow *FullScreenWindow;
    NSWindow *StartingWindow;
    NSView *contentView;
    NSTimer *timer, *movieTimer;
    NSTimeInterval lastTime, lastTimeFrame;
    NSTimeInterval lastMovieTime;
    NSMutableArray *ROINamesArray;
    ThickSlabController *thickSlab;
    DICOMExport *exportDCM;
    BOOL windowWillClose;
    BOOL requestLoadingCancel;
    BOOL postprocessed;
    NSRect standardRect;
    IBOutlet NSWindow *brushROIFilterOptionsWindow;
    IBOutlet NSSlider *structuringElementRadiusSlider;
    IBOutlet NSTextField *structuringElementRadiusTextField;
    IBOutlet NSButton *brushROIFilterOptionsAllWithSameName;
    IBOutlet NSButton *brushROIFilterOptionsOKButton;
    NSString *morphoFunction;
    BOOL morphoFunctionPreviewApplied;
    IBOutlet NSPopUpButton *keyImagePopUpButton;
    BOOL displayOnlyKeyImages;
    int qt_to, qt_from, qt_interval, qt_dimension, current_qt_interval, qt_allViewers;
    IBOutlet NSView *reportTemplatesView;
    IBOutlet NSImageView *reportTemplatesImageView;
    IBOutlet NSPopUpButton *reportTemplatesListPopUpButton;
    NSConditionLock *processorsLock;
    IBOutlet NSWindow *printWindow;
    IBOutlet NSMatrix *printSelection;
    IBOutlet NSMatrix *printFormat;
    IBOutlet NSSlider *printInterval, *printFrom, *printTo;
    IBOutlet NSTextField *printIntervalText, *printFromText, *printToText;
    IBOutlet NSBox *printBox;
    IBOutlet NSMatrix *printSettings;
    IBOutlet NSPopUpButton *printLayout;
    IBOutlet NSTextField *printText, *printPagesToPrint;
    NSMutableArray *undoQueue, *redoQueue;
    BOOL titledGantry, updateTilingViews;
    float titledGantryDegrees;
    volatile BOOL checkEverythingLoaded;
    float resampleRatio;
    ViewerController *registeredViewer;
    ViewerController *blendedWindow;
    NSMutableArray *retainedToolbarItems;
    BOOL nonVolumicDataWarningDisplayed;
    IBOutlet NSView *display12bitToolbarItemView;
    IBOutlet NSMatrix *display12bitToolbarItemMatrix;
    NSTimer *t12BitTimer;
    IBOutlet NSWindow *injectionTimeWindow;
    int isDataVolumicIn4DLevel;
    int previousFullscreenColumns, previousFullscreenRows, previousFullscreenCurImage, previousFullscreenViewIndex, previousPropagate, previousScaledFit;
    NSRect previousFrameRect;
    NSString *windowsStateName;
    BOOL computeInterval;
    NSRect windowFrameToRestore;
    BOOL scaleFitToRestore;
    IBOutlet NSView *viewerView;
    NSString *printSpoolDirectory;
    BOOL openingScaleToFitRequested;
    CGFloat previousSliderStripHeight;
    NSDictionary *openingContentBoundsByPixels;
'''),
    'AppController': ('NSObject', r'''
    IBOutlet BrowserController *browserController;
    IBOutlet NSMenu *filtersMenu;
    IBOutlet NSMenu *roisMenu;
    IBOutlet NSMenu *othersMenu;
    IBOutlet NSMenu *dbMenu;
    IBOutlet NSWindow *dbWindow;
    IBOutlet NSMenu *windowsTilingMenuRows, *windowsTilingMenuColumns;
    IBOutlet NSMenu *recentStudiesMenu;
    NSDictionary *previousDefaults;
    BOOL showRestartNeeded;
    SplashScreen *splashController;
    volatile BOOL quitting;
    BOOL verboseUpdateCheck;
    NSNetService *BonjourDICOMService;
    NSTimer *updateTimer;
    XMLRPCInterface *XMLRPCServer;
    BOOL checkAllWindowsAreVisibleIsOff, isSessionInactive;
    int lastColumns, lastRows, lastCount;
    BonjourPublisher* _bonjourPublisher;
'''),
}
# What the SDK declared of the accessors this plugin compares the variables with.
LEGACY_IVAR_METHODS = {
    'DCMView': '''@property NSRect drawingFrameRect;
@property(readonly) NSMutableArray *rectArray, *curRoiList;
@property BOOL COPYSETTINGSINSERIES, flippedData, showDescriptionInLarge;
@property(readonly) NSMutableArray *dcmPixList,  *dcmRoiList;
@property(readonly) NSArray *dcmFilesList;
@property(retain,setter=setBlending:) DCMView *blendingView;
@property(readonly) float blendingFactor;
@property(nonatomic) BOOL xFlipped, yFlipped;
@property(retain) NSString *stringID;
@property(nonatomic) ToolMode currentTool;
@property(readonly) short curImage;
@property(readonly) BOOL suppressLabels;
@property(nonatomic) float scaleValue, rotation;
@property(nonatomic) NSPoint origin;
@property(readonly, strong) DCMPix *curDCM;
@property(readonly) float contextualMenuInWindowPosX, contextualMenuInWindowPosY;
@property(readonly) float curWW, curWL;
@property NSInteger rows, columns;
@property(readonly) BOOL isKeyView, mouseDragging;''',
    'ROI': '''@property NSPoint imageOrigin;
@property(nonatomic) float opacity;
@property(nonatomic) BOOL hidden, locked, selectable;
@property(nonatomic, copy) NSString *name;
@property ToolMode type;
@property(nonatomic, setter=setROIMode:) long ROImode;
@property(retain) NSMutableArray *points;
@property(setter=setROIRect:) NSRect rect;
@property(nonatomic, retain) DCMPix *pix;
@property(assign, nonatomic) DCMView *curView;
@property(nonatomic) float thickness;
@property(retain) ROI *parentROI;
@property double sliceThickness, pixelSpacingX, pixelSpacingY;''',
    'ViewerController': '''- (DCMView*) imageView;
- (NSMutableArray*) pixList;
- (NSMutableArray*) pixList: (long) i;
- (ROI*) newROI: (ToolMode) type;
- (short) maxMovieIndex;
- (short) curMovieIndex;
- (NSString*) curCLUTMenu;
- (NSString*) curWLWWMenu;
- (NSString*) curOpacityMenu;
- (ViewerController*) blendingController;
- (ThickSlabController*) thickSlabController;
- (SeriesView *) seriesView;''',
    'AppController': '''@property (readonly) NSMenu *filtersMenu, *recentStudiesMenu, *windowsTilingMenuRows, *windowsTilingMenuColumns;
+ (AppController*) sharedAppController;''',
}
# The instance variables the sources of known plugins read or write, by class:
# each is touched. Those of ViewerController and AppController are all of them.
LEGACY_IVARS_READ = {
    'DCMView': '''LENSRATIO ROISelectorEndPoint ROISelectorStartPoint TEXTRECTMODE _imageColumns _imageRows alphaTable blendingColorBuf
        blendingResampledBaseAddr blendingResampledBaseAddrSize blendingTextureHeight blendingTextureWidth blendingTextureX
        blendingTextureY blendingView blueFactor blueTable colorBuf colorTransfer contextualMenuInWindowPosX
        contextualMenuInWindowPosY curImage curRoiList curWL curWW currentTool dcmFilesList dcmPixList drawingFrameRect
        edgeClampParam f_arb_texture_rectangle f_ext_client_storage f_ext_texture_rectangle firstTimeDisplay fontListGLSize
        greenFactor greenTable isKeyView labelFontListGLSize loupeImage loupeMaskImage maxTextureSize mprVector needToLoadTexture
        noScale origin previous rectArray redFactor redTable repulsorAlpha repulsorPosition repulsorRadius resampledBaseAddr
        resampledBaseAddrSize rotation scaleValue showDescriptionInLarge showDescriptionInLargeText sliceFromTo sliceFromTo2
        sliceFromToE sliceFromToS slicePoint3D sliceVector start stringID stringSize suppress_labels syncOnLocationImpossible
        textureHeight textureWidth textureX textureY xFlipped yFlipped yearOld fontListGL labelFontListGL pTextureName
        blendingTextureName lensTexture loupeTextureID loupeTextureWidth loupeTextureHeight loupeTextureBuffer loupeMaskTextureID
        loupeMaskTextureWidth loupeMaskTextureHeight loupeMaskTextureBuffer _curDCM dcmRoiList blendingFactor
        curDCM originOffset LENSSIZE _alternateContext iChatWidth iChatHeight iChatCursorHotSpot iChatCursorImageSize
        iChatCursorTextureBuffer iChatCursorTextureName angle slab cross slicePoint slicePointO slicePointI sliceVector2
        slicePoint2 slicePointO2 slicePointI2
        QuartzExtreme dontEnterReshape iChatDrawing crossPrev originOffsetStart iChatStringSize switchAngle
        iChatFontListGL iChatFontListGLSize resampledTempAddr _hotKeyDictionary localeDictionnary iChatFontGL
        iChatStringTextureCache mouseModifiers myImage shortDateString shortDateTimeString warningNotice'''.split(),
    'ROI': 'pixelSpacingX pixelSpacingY type imageOrigin points thickness opacity name mode rect locked hidden selectable'.split(),
    'ViewerController': '''OpacityPopup backCurCLUTMenu blendingController blendingPercentage blendingPopupMenu blendingSlider clutPopup
        convPopup curCLUTMenu curConvMenu curOpacityMenu curWLWWMenu imageView maxMovieIndex pixList seriesView thickSlab
        wlwwPopup
        activatedFusion addCLUTWindow addConvWindow addOpacityWindow addWLWWWindow AllROIsRadio annotations blendedWindow
        blendingPlugins blendingResample blendingTypeMultiply blendingTypeRGB blendingTypeSubtract blendingTypeWindow
        BlendingView brushROIFilterOptionsAllWithSameName brushROIFilterOptionsOKButton brushROIFilterOptionsWindow
        buttonToolMatrix checkEverythingLoaded checkMaxValue checkMinValue clutName clutPopupSet clutView CommentsEditField
        CommentsField CommentsWindow comparativesButton computeInterval contentView convMatrix convPopupSet convThread
        ConvView copyRoiList curMovieIndex current_qt_interval currentOrientationTool customInterval customOrigin
        customVectors customXSpacing customYSpacing dcmAllViewers dcmBox dcmExportWindow dcmFormat dcmFrom dcmFromText
        dcmInterval dcmIntervalText dcmNumber dcmSelection dcmSeriesName dcmTo dcmToText direction
        display12bitToolbarItemMatrix display12bitToolbarItemView displayOnlyKeyImages displaySUVWindow editedAcquisitionTime
        editedRadiopharmaceuticalStartTime enableSubtraction exportDCM factorPET2SUV fileList flagListPODComparatives
        flipDataThread fromset FullScreenOn FullScreenWindow FusionView highLighted highLightedTimer imageAllViewers
        imageExportWindow imageFormat imageSelection injectionDateTime injectionTimeWindow InOutROI isDataVolumicIn4DLevel
        keyImageCheck keyImagePopUpButton keyImages lastMovieTime lastTime lastTimeFrame loadingThread loopButton matrixName
        matrixNorm matrixPreviewBuilt maxValueText minValueText morphoFunction morphoFunctionPreviewApplied moviePlayStop
        moviePosSlider movieRateSlider movieTextSlide movieTimer movieView needsToBuildSeriesMatrix
        needsToBuildSeriesPopupMenu newName newValueMatrix newValueText nonVolumicDataWarningDisplayed OpacityName
        OpacityPopupSet OpacityView openingContentBoundsByPixels openingScaleToFitRequested orientationMatrix
        orientationVector orientationView originalOrientation PagePad patientView popFusion popupRoi postprocessed
        previewMatrix previewMatrixScrollView previewRootView previousFrameRect previousFullscreenColumns
        previousFullscreenCurImage previousFullscreenRows previousFullscreenViewIndex previousPropagate previousScaledFit
        previousSliderStripHeight printBox printFormat printFrom printFromText printInterval printIntervalText printLayout
        printPagesToPrint printSelection printSettings printSpoolDirectory printText printTo printToText printWindow
        processorsLock propagateSettingsView qt_allViewers qt_dimension qt_from qt_interval qt_to quicktimeAllViewers
        quicktimeBox quicktimeFrom quicktimeFromText quicktimeInterval quicktimeIntervalText quicktimeMode quicktimeNumber
        quicktimeTo quicktimeToText quicktimeWindow ReconstructionRoi ReconstructionView redoQueue registeredViewer
        reportTemplatesImageView reportTemplatesListPopUpButton reportTemplatesView requestLoadingCancel resampleRatio
        retainedToolbarItems RGBFactorsView roiApplyMatrix roiApplyWindow roiList roiLock ROINamesArray roiPropaCopy
        roiPropaDest roiPropaDim roiPropaMode roiPropaWindow roiRenameMatrix roiRenameName roiRenameWindow roiSetPixWindow
        SavedUseFloatingThumbnailsList saveWindowsStateWindow sc1 sc2 sc3 sc4 sc5 sc6 sc7 sc8 sc9 scaleFitToRestore
        seriesPopupContextualMenu seriesPopupMenu seriesPopupView serieView setROI4DSeries setWLWWWindow shutterOnOff
        shutterView sizeMatrix slider sliderFusion speedometer speedSlider speedText speedView splitView splitViewAllocated
        stacksFusion standardRect StartingWindow StatusPopup statusValueToApply StatusView structuringElementRadiusSlider
        structuringElementRadiusTextField studyView subCtrlMaskID subCtrlMaskText subCtrlMinMax subCtrlMinMaxComputed
        subCtrlOffset subCtrlOnOff subCtrlPercent subCtrlSharpenButton subCtrlSum subCtrlView suvConversion suvForm
        t12BitTimer ThickIntervalWindow timer titledGantry titledGantryDegrees toolbar toolbarPanel toolsMatrix toolsView
        toset undoQueue updateTilingViews viewerView volumeData windowFrameToRestore windowsStateName windowsTiling
        windowsTilingMenu windowWillClose wl wlset wlwwPopupSet WLWWView ww wwset'''.split(),
    'AppController': 'filtersMenu roisMenu'.split(),
}
# A sample of the instance variables nothing of the application stands behind:
# each is 0 or nil, unless the application's table gives it another state.
LEGACY_IVARS_INERT = {
    'DCMView': '''fontListGL labelFontListGL pTextureName blendingTextureName textureX textureY textureWidth textureHeight
        TEXTRECTMODE maxTextureSize edgeClampParam f_ext_texture_rectangle f_arb_texture_rectangle fontListGLSize
        labelFontListGLSize lensTexture stringTextureCache loupeTextureID loupeTextureBuffer loupeMaskTextureID studyDateBox
        showDescriptionInLargeText originOffset LENSSIZE _alternateContext iChatWidth iChatHeight iChatCursorHotSpot
        iChatCursorImageSize iChatCursorTextureBuffer iChatCursorTextureName angle slab cross slicePoint slicePointO slicePointI
        sliceVector2 slicePoint2 slicePointO2 slicePointI2
        QuartzExtreme dontEnterReshape iChatDrawing crossPrev originOffsetStart iChatStringSize switchAngle
        iChatFontListGL iChatFontListGLSize resampledTempAddr _hotKeyDictionary localeDictionnary iChatFontGL
        iChatStringTextureCache mouseModifiers myImage shortDateString shortDateTimeString warningNotice'''.split(),
    'ROI': 'stringTex stringTexA stringTexB stringTexC'.split(),
    'ViewerController': '''SavedUseFloatingThumbnailsList morphoFunctionPreviewApplied convThread flipDataThread suvForm
        editedRadiopharmaceuticalStartTime editedAcquisitionTime injectionDateTime'''.split(),
}
ivar_table = Path(__file__).resolve().parents[1] / 'Horos/Scripts/Horos/legacy-plugin-ivars.json'
ivar_states = {name: entry.get('state') for name, entry in json.loads(ivar_table.read_text())['ivars'].items()} \
    if ivar_table.is_file() else {}


def legacy_ivar_statements(cls):
    touched = list(dict.fromkeys(LEGACY_IVARS_READ[cls] + LEGACY_IVARS_INERT.get(cls, [])))
    inert = [name for name in LEGACY_IVARS_INERT.get(cls, []) if ivar_states.get(f'{cls}.{name}', 'inert') == 'inert']
    return '\n'.join([f'    QA_TOUCH({name});' for name in touched] + [f'    QA_ZERO({name});' for name in inert])


# What a plugin's source saw of the SDK before its own code: the classes with
# their instance variables and the accessors above.
LEGACY_SDK_DECLARATIONS = r'''#import <Cocoa/Cocoa.h>
#import <OpenGL/gltypes.h>
#include <objc/runtime.h>
#include <string.h>
// The classes the SDK's declarations name; they are the application's, or gone.
@class BrowserController, BonjourPublisher, ColorTransferView, DCMExportPlugin, DCMPix, DCMView, DICOMExport, GLString,
       OpacityTransferView, ROI, SeriesView, SplashScreen, StringTexture, StudyView, ThickSlabController, ToolbarPanelController,
       ViewerController, XMLRPCInterface;
#define MAX4D 500
typedef NS_ENUM(short, ToolMode) {
    tWL = 0, tTranslate, tZoom, tRotate, tNext, tMesure, tROI, t3DRotate, tCross, tOval, tOPolygon, tCPolygon, tAngle, tText,
    tArrow, tPencil, t3Dpoint, t3DCut, tCamera3D, t2DPoint, tPlain, tBonesRemoval, tWLBlended, tRepulsor, tLayerROI,
    tROISelector, tAxis, tDynAngle, tCurvedROI, tTAGT
};
typedef struct QARGBColor { unsigned short red, green, blue; } QARGBColor;
#define RGBColor QARGBColor
@interface OSIWindowController : NSWindowController
@end
INTERFACES
'''.replace('INTERFACES', '\n'.join(f'@interface {cls} : {parent}\n{{\n{block.strip(chr(10))}\n}}\n{LEGACY_IVAR_METHODS[cls]}\n@end'
                                    for cls, (parent, block) in LEGACY_IVAR_BLOCKS.items()))

legacy_ivars = args.destination / 'QALegacyIvars.horosplugin'
(legacy_ivars / 'Contents/MacOS').mkdir(parents=True)
legacy_ivars_source = args.destination / 'QALegacyIvars.m'
legacy_ivars_source.write_text((LEGACY_SDK_DECLARATIONS + r'''extern NSString* const OsirixViewerControllerDidLoadImagesNotification;

static NSMutableArray *QAFailures;
static int QAChecks, QARuns;
static void QACheck(BOOL ok, NSString *what) {
    QAChecks++;
    if (!ok) [QAFailures addObject:what];
}
static void QAMark(NSString *name, NSString *text) {
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) [text writeToFile:[@(markers) stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static BOOL QAIsZero(const void *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) if (((const unsigned char *)bytes)[i]) return NO;
    return YES;
}
static BOOL QASame(id a, id b) { return a == b || [a isEqual:b]; }
#define QA(OK, ...) QACheck((OK), [NSString stringWithFormat:__VA_ARGS__])
// The variable is inside the instance, past the isa, and holds again what was
// read from it: a load and a store at the offset the application exported.
#define QA_TOUCH(IVAR) do { \
    __typeof__(IVAR) value; \
    ptrdiff_t offset = (const char *)&IVAR - (const char *)self; \
    QA(offset >= (ptrdiff_t)sizeof(void *) && offset + sizeof(IVAR) <= class_getInstanceSize(object_getClass(self)), \
       @"%@." #IVAR " is at %td, outside the %zu bytes of the instance", QAClass, offset, class_getInstanceSize(object_getClass(self))); \
    memcpy((void *)&value, (const void *)&IVAR, sizeof(IVAR)); \
    memcpy((void *)&IVAR, (const void *)&value, sizeof(IVAR)); \
} while (0)
#define QA_ZERO(IVAR) QA(QAIsZero(&IVAR, sizeof(IVAR)), @"%@." #IVAR " is not 0 or nil, and nothing of the application stands behind it", QAClass)
// Another value stored in the variable is what the accessor answers; then what was there is put back.
#define QA_STORE(IVAR, VALUE, READ, FORMAT) do { \
    __typeof__(IVAR) before = IVAR; \
    IVAR = (VALUE); \
    __typeof__(IVAR) answered = (READ); \
    IVAR = before; \
    QA(answered == (VALUE), @"%@." #IVAR " stored as " FORMAT " and the accessor answers " FORMAT, QAClass, (VALUE), answered); \
} while (0)

@implementation DCMView (QALegacyIvars)
- (void)qaLegacyIvars
{
    NSString *QAClass = @"DCMView";
DCMVIEW_STATEMENTS
    QA(curImage == [self curImage], @"DCMView.curImage is %d and -curImage answers %d", curImage, [self curImage]);
    QA(dcmPixList != nil && dcmPixList == [self dcmPixList], @"DCMView.dcmPixList is %p and -dcmPixList answers %p", dcmPixList, [self dcmPixList]);
    QA(dcmRoiList == [self dcmRoiList], @"DCMView.dcmRoiList is %p and -dcmRoiList answers %p", dcmRoiList, [self dcmRoiList]);
    QA(dcmFilesList == [self dcmFilesList], @"DCMView.dcmFilesList is %p and -dcmFilesList answers %p", dcmFilesList, [self dcmFilesList]);
    QA(curRoiList == [self curRoiList], @"DCMView.curRoiList is %p and -curRoiList answers %p", curRoiList, [self curRoiList]);
    QA(rectArray == [self rectArray], @"DCMView.rectArray is %p and -rectArray answers %p", rectArray, [self rectArray]);
    QA(_curDCM != nil && _curDCM == [self curDCM], @"DCMView._curDCM is %p and -curDCM answers %p", _curDCM, [self curDCM]);
    QA(curDCM != nil && curDCM == [self curDCM], @"DCMView.curDCM, as the older SDK named it, is %p and -curDCM answers %p", curDCM, [self curDCM]);
    QA(blendingView == [self blendingView], @"DCMView.blendingView is %p and -blendingView answers %p", blendingView, [self blendingView]);
    QA(blendingFactor == [self blendingFactor], @"DCMView.blendingFactor is %g and -blendingFactor answers %g", blendingFactor, [self blendingFactor]);
    QA(curWW == [self curWW] && curWL == [self curWL], @"DCMView.curWW and curWL are %g and %g, and the accessors answer %g and %g",
       curWW, curWL, [self curWW], [self curWL]);
    QA(scaleValue == [self scaleValue] && rotation == [self rotation], @"DCMView.scaleValue and rotation are %g and %g, and the accessors answer %g and %g",
       scaleValue, rotation, [self scaleValue], [self rotation]);
    QA(NSEqualPoints(origin, [self origin]), @"DCMView.origin is %@ and -origin answers %@", NSStringFromPoint(origin), NSStringFromPoint([self origin]));
    QA(xFlipped == [self xFlipped] && yFlipped == [self yFlipped], @"DCMView.xFlipped and yFlipped are %d and %d, and the accessors answer %d and %d",
       xFlipped, yFlipped, [self xFlipped], [self yFlipped]);
    QA(currentTool == [self currentTool], @"DCMView.currentTool is %d and -currentTool answers %d", currentTool, [self currentTool]);
    QA(QASame(stringID, [self stringID]), @"DCMView.stringID is %@ and -stringID answers %@", stringID, [self stringID]);
    QA(yearOld == nil || [yearOld isKindOfClass:[NSString class]], @"DCMView.yearOld is neither nil nor a string");
    QA(isKeyView == [self isKeyView], @"DCMView.isKeyView is %d and -isKeyView answers %d", isKeyView, [self isKeyView]);
    QA(suppress_labels == [self suppressLabels], @"DCMView.suppress_labels is %d and -suppressLabels answers %d", suppress_labels, [self suppressLabels]);
    QA(showDescriptionInLarge == [self showDescriptionInLarge], @"DCMView.showDescriptionInLarge is %d and the accessor answers %d",
       showDescriptionInLarge, [self showDescriptionInLarge]);
    QA(_imageRows == [self rows] && _imageColumns == [self columns], @"DCMView._imageRows and _imageColumns are %ld and %ld, and -rows and -columns answer %ld and %ld",
       (long)_imageRows, (long)_imageColumns, (long)[self rows], (long)[self columns]);
    QA(NSEqualRects(drawingFrameRect, [self drawingFrameRect]), @"DCMView.drawingFrameRect is %@ and the accessor answers %@",
       NSStringFromRect(drawingFrameRect), NSStringFromRect([self drawingFrameRect]));
    QA(contextualMenuInWindowPosX == [self contextualMenuInWindowPosX] && contextualMenuInWindowPosY == [self contextualMenuInWindowPosY],
       @"DCMView.contextualMenuInWindowPosX and Y are %g and %g, and the accessors answer %g and %g",
       contextualMenuInWindowPosX, contextualMenuInWindowPosY, [self contextualMenuInWindowPosX], [self contextualMenuInWindowPosY]);

    QA_STORE(scaleValue, before + 0.25f, [self scaleValue], "%g");
    QA_STORE(rotation, before + 15.0f, [self rotation], "%g");
    QA_STORE(curWW, before + 7.0f, [self curWW], "%g");
    QA_STORE(curWL, before - 3.0f, [self curWL], "%g");
    QA_STORE(xFlipped, !before, [self xFlipped], "%d");
    QA_STORE(yFlipped, !before, [self yFlipped], "%d");
    if ([dcmPixList count] > 1) QA_STORE(curImage, (short)(before == 0 ? 1 : 0), [self curImage], "%d");
    NSPoint originBefore = origin;
    origin = NSMakePoint(originBefore.x + 4, originBefore.y - 6);
    NSPoint originAnswered = [self origin];
    origin = originBefore;
    QA(NSEqualPoints(originAnswered, NSMakePoint(originBefore.x + 4, originBefore.y - 6)), @"DCMView.origin stored and -origin answers %@", NSStringFromPoint(originAnswered));
    // An object the class owns, stored as the SDK's code did: retained, with what was there kept for the way back.
    NSString *stringIDBefore = stringID;
    stringID = [[NSString alloc] initWithFormat:@"QALegacyIvars %d", QARuns];
    QA(([[self stringID] isEqualToString:[NSString stringWithFormat:@"QALegacyIvars %d", QARuns]]), @"DCMView.stringID stored and -stringID answers %@", [self stringID]);
    [stringID release];
    stringID = stringIDBefore;
    // The arrays inside the object: every byte and every float is the instance's own.
    unsigned char tableBefore[256];
    memcpy(tableBefore, redTable, 256);
    for (int i = 0; i < 256; i++) redTable[i] = 255 - i;
    BOOL tableKept = YES;
    for (int i = 0; i < 256; i++) if (redTable[i] != 255 - i) tableKept = NO;
    memcpy(redTable, tableBefore, 256);
    QA(tableKept && memcmp(redTable, tableBefore, 256) == 0, @"DCMView.redTable does not keep the 256 bytes stored in it");
    float sliceBefore[2][3];
    memcpy(sliceBefore, sliceFromTo, sizeof(sliceBefore));
    for (int row = 0; row < 2; row++) for (int column = 0; column < 3; column++) sliceFromTo[row][column] = row * 3 + column + 0.5f;
    BOOL sliceKept = sliceFromTo[1][2] == 5.5f && sliceFromTo[0][0] == 0.5f && sizeof(sliceFromTo) == 6 * sizeof(float);
    memcpy(sliceFromTo, sliceBefore, sizeof(sliceBefore));
    QA(sliceKept, @"DCMView.sliceFromTo does not keep the float[2][3] stored in it");
    long sizeBefore = fontListGLSize[255];
    fontListGLSize[255] = 0x1234;
    BOOL sizeKept = fontListGLSize[255] == 0x1234 && sizeof(fontListGLSize) == 256 * sizeof(long);
    fontListGLSize[255] = sizeBefore;
    QA(sizeKept, @"DCMView.fontListGLSize does not keep the last of its 256 values");
}
@end

@implementation ROI (QALegacyIvars)
- (void)qaLegacyIvars
{
    NSString *QAClass = @"ROI";
ROI_STATEMENTS
    QA(type == [self type], @"ROI.type is %d and -type answers %d", type, [self type]);
    QA(pixelSpacingX == [self pixelSpacingX] && pixelSpacingY == [self pixelSpacingY], @"ROI.pixelSpacingX and Y are %g and %g, and the accessors answer %g and %g",
       pixelSpacingX, pixelSpacingY, [self pixelSpacingX], [self pixelSpacingY]);
    QA(NSEqualPoints(imageOrigin, [self imageOrigin]), @"ROI.imageOrigin is %@ and -imageOrigin answers %@", NSStringFromPoint(imageOrigin), NSStringFromPoint([self imageOrigin]));
    QA(points != nil && points == [self points], @"ROI.points is %p and -points answers %p", points, [self points]);
    QA(thickness == [self thickness] && opacity == [self opacity], @"ROI.thickness and opacity are %g and %g, and the accessors answer %g and %g",
       thickness, opacity, [self thickness], [self opacity]);
    QA(QASame(name, [self name]), @"ROI.name is %@ and -name answers %@", name, [self name]);
    QA(mode == [self ROImode], @"ROI.mode is %ld and -ROImode answers %ld", mode, [self ROImode]);
    QA(NSEqualRects(rect, [self rect]), @"ROI.rect is %@ and -rect answers %@", NSStringFromRect(rect), NSStringFromRect([self rect]));
    QA(locked == [self locked] && hidden == [self hidden] && selectable == [self selectable], @"ROI.locked, hidden and selectable are not what the accessors answer");
    QA(curView == [self curView], @"ROI.curView is %p and -curView answers %p", curView, [self curView]);
    QA(parentROI == [self parentROI], @"ROI.parentROI is %p and -parentROI answers %p", parentROI, [self parentROI]);
    // -pix stores the view's image in the variable when it is empty: the accessor first, then the variable.
    DCMPix *pixAnswered = [self pix];
    QA(pix == pixAnswered, @"ROI.pix is %p after -pix answered %p", pix, pixAnswered);

    QA_STORE(pixelSpacingX, before + 0.125, [self pixelSpacingX], "%g");
    QA_STORE(pixelSpacingY, before + 0.375, [self pixelSpacingY], "%g");
    QA_STORE(thickness, before + 1.5f, [self thickness], "%g");
    QA_STORE(opacity, before * 0.5f, [self opacity], "%g");
    NSMutableArray *pointsBefore = points;
    points = [[NSMutableArray alloc] initWithObjects:@"QALegacyIvars", nil];
    NSMutableArray *pointsAnswered = [self points];
    BOOL pointsKept = pointsAnswered == points;
    [points release];
    points = pointsBefore;
    QA(pointsKept, @"ROI.points stored and -points answers another array");
}
@end

@implementation ViewerController (QALegacyIvars)
- (void)qaLegacyIvars
{
    NSString *QAClass = @"ViewerController";
VIEWER_STATEMENTS
    QA(imageView != nil && imageView == [self imageView], @"ViewerController.imageView is %p and -imageView answers %p", imageView, [self imageView]);
    QA(seriesView == [self seriesView], @"ViewerController.seriesView is %p and -seriesView answers %p", seriesView, [self seriesView]);
    QA(maxMovieIndex == [self maxMovieIndex], @"ViewerController.maxMovieIndex is %d and -maxMovieIndex answers %d", maxMovieIndex, [self maxMovieIndex]);
    QA(pixList[0] != nil && pixList[0] == [self pixList: 0] && pixList[[self curMovieIndex]] == [self pixList],
       @"ViewerController.pixList[0] is %p, -pixList: 0 answers %p and -pixList %p", pixList[0], [self pixList: 0], [self pixList]);
    QA(thickSlab == [self thickSlabController], @"ViewerController.thickSlab is %p and -thickSlabController answers %p", thickSlab, [self thickSlabController]);
    QA(blendingController == [self blendingController], @"ViewerController.blendingController is %p and the accessor answers %p", blendingController, [self blendingController]);
    QA(QASame(curCLUTMenu, [self curCLUTMenu]), @"ViewerController.curCLUTMenu is %@ and -curCLUTMenu answers %@", curCLUTMenu, [self curCLUTMenu]);
    QA(QASame(curWLWWMenu, [self curWLWWMenu]), @"ViewerController.curWLWWMenu is %@ and -curWLWWMenu answers %@", curWLWWMenu, [self curWLWWMenu]);
    QA(QASame(curOpacityMenu, [self curOpacityMenu]), @"ViewerController.curOpacityMenu is %@ and -curOpacityMenu answers %@", curOpacityMenu, [self curOpacityMenu]);
    QA((curConvMenu == nil || [curConvMenu isKindOfClass:[NSString class]]) && (backCurCLUTMenu == nil || [backCurCLUTMenu isKindOfClass:[NSString class]]),
       @"ViewerController.curConvMenu or backCurCLUTMenu is neither nil nor a string");
    for (NSPopUpButton *popup in @[clutPopup ?: (id)NSNull.null, wlwwPopup ?: (id)NSNull.null, convPopup ?: (id)NSNull.null,
                                   OpacityPopup ?: (id)NSNull.null, blendingPopupMenu ?: (id)NSNull.null])
        QA((id)popup == NSNull.null || [popup isKindOfClass:[NSPopUpButton class]], @"a pop-up button variable of ViewerController holds a %@", [popup class]);
    QA(blendingSlider == nil || [blendingSlider isKindOfClass:[NSSlider class]], @"ViewerController.blendingSlider holds a %@", [blendingSlider class]);
    QA(blendingPercentage == nil || [blendingPercentage isKindOfClass:[NSTextField class]], @"ViewerController.blendingPercentage holds a %@", [blendingPercentage class]);

    QA_STORE(maxMovieIndex, (short)(before + 1), [self maxMovieIndex], "%d");
    // The last of the MAX4D slots is the instance's own, and empty.
    ptrdiff_t last = (const char *)&pixList[MAX4D - 1] - (const char *)self;
    QA(pixList[MAX4D - 1] == nil && last + sizeof(id) <= class_getInstanceSize(object_getClass(self)),
       @"ViewerController.pixList[%d] is %p at %td of an instance of %zu bytes", MAX4D - 1, pixList[MAX4D - 1], last, class_getInstanceSize(object_getClass(self)));
    NSString *menuBefore = curCLUTMenu;
    curCLUTMenu = [[NSString alloc] initWithFormat:@"QALegacyIvars %d", QARuns];
    QA(([[self curCLUTMenu] isEqualToString:[NSString stringWithFormat:@"QALegacyIvars %d", QARuns]]), @"ViewerController.curCLUTMenu stored and -curCLUTMenu answers %@", [self curCLUTMenu]);
    [curCLUTMenu release];
    curCLUTMenu = menuBefore;
}
@end

@implementation AppController (QALegacyIvars)
- (void)qaLegacyIvars
{
    NSString *QAClass = @"AppController";
APP_STATEMENTS
    QA([filtersMenu isKindOfClass:[NSMenu class]] && filtersMenu == [self filtersMenu], @"AppController.filtersMenu is %p and -filtersMenu answers %p", filtersMenu, [self filtersMenu]);
    QA(roisMenu == nil || [roisMenu isKindOfClass:[NSMenu class]], @"AppController.roisMenu holds a %@", [roisMenu class]);
}
@end

@interface QALegacyIvars : NSObject
@end
@implementation QALegacyIvars
+ (void)viewerDidLoadImages:(NSNotification *)note
{
    @autoreleasepool {
        ViewerController *viewer = note.object;
        QARuns++;
        QAChecks = 0;
        [QAFailures release];
        QAFailures = [[NSMutableArray alloc] init];
        @try {
            if (![viewer isKindOfClass:NSClassFromString(@"ViewerController")]) {
                QA(NO, @"the notification's object is a %@, not a ViewerController", [viewer class]);
            } else {
                [viewer qaLegacyIvars];
                [[viewer imageView] qaLegacyIvars];
                // A polygon keeps its points in the variable; -points of a rectangle, an oval or a point computes them.
                ROI *roi = [viewer newROI: tCPolygon];
                QA(roi != nil, @"-newROI: answered no ROI");
                [roi qaLegacyIvars];
                [[NSClassFromString(@"AppController") sharedAppController] qaLegacyIvars];
            }
        } @catch (NSException *exception) {
            QA(NO, @"exception %@: %@", exception.name, exception.reason);
        }
        NSString *result = [NSString stringWithFormat:@"QALegacyIvars: viewer %d, %d checks, %lu failures\n%@", QARuns, QAChecks,
                            (unsigned long)QAFailures.count, [[QAFailures valueForKey:@"description"] componentsJoinedByString:@"\n"]];
        NSLog(@"PLUGINFIXTURE %@", result);
        QAMark(@"QALegacyIvars.result", result);
    }
}
+ (void)load
{
    @autoreleasepool {
        QAMark(@"QALegacyIvars.loaded", @"loaded");
        // On the main thread, where the application's own code reads and writes these variables.
        [NSNotificationCenter.defaultCenter addObserverForName:OsirixViewerControllerDidLoadImagesNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [self viewerDidLoadImages:note];
        }];
    }
}
+ (id)filter { return [[[self alloc] init] autorelease]; }
- (long)prepareFilter:(id)viewer { return 0; }
- (long)filterImage:(NSString *)menu { return 0; }
@end
''').replace('DCMVIEW_STATEMENTS', legacy_ivar_statements('DCMView')).replace('ROI_STATEMENTS', legacy_ivar_statements('ROI'))
   .replace('VIEWER_STATEMENTS', legacy_ivar_statements('ViewerController')).replace('APP_STATEMENTS', legacy_ivar_statements('AppController')))
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-bundle', '-fno-objc-arc', '-framework', 'Cocoa', '-mmacosx-version-min=15.0',
                    '-arch', 'arm64', '-arch', 'x86_64', '-undefined', 'dynamic_lookup', '-Wno-deprecated-declarations',
                    '-Wno-objc-protocol-method-implementation', str(legacy_ivars_source),
                    '-o', str(legacy_ivars / 'Contents/MacOS/QALegacyIvars')], check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(legacy_ivars / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QALegacyIvars', 'CFBundleIdentifier': 'org.horosproject.qa.QALegacyIvars', 'CFBundleName': 'QALegacyIvars',
    'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QALegacyIvars', 'pluginType': 'imageFilter',
    'MenuTitles': ['QALegacyIvars']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(legacy_ivars)], check=True, capture_output=True)

# A former plugin whose classes are Objective-C subclasses of the host's
# DCMView, ROI and ViewerController: see the module's description. Each
# override counts its calls under its own name, as -[Class selector], and
# answers what the class of the application answers.
legacy_subclasses = args.destination / 'QALegacySubclasses.horosplugin'
(legacy_subclasses / 'Contents/MacOS').mkdir(parents=True)
legacy_subclasses_source = args.destination / 'QALegacySubclasses.m'
legacy_subclasses_source.write_text(LEGACY_SDK_DECLARATIONS + r'''#include <objc/runtime.h>
#include <stdarg.h>
extern NSString* const OsirixViewerControllerDidLoadImagesNotification;
// What the SDK declared of the messages this plugin sends, beyond the accessors above.
@interface MyPoint : NSObject
+ (MyPoint*)point:(NSPoint)a;
@end
@interface DCMPix : NSObject <NSCopying>
@property(nonatomic) long pwidth, pheight;
@property(setter=setfImage:) float* fImage;
@end
@interface DCMView (QAFormerSDK)
- (id)initWithFrame:(NSRect)frame imageRows:(int)rows imageColumns:(int)columns;
- (void) setPixels: (NSMutableArray*) pixels files: (NSArray*) files rois: (NSMutableArray*) rois firstImage: (short) firstImage level: (char) level reset: (BOOL) reset;
- (void) loadTextures;
- (void) setScaleValueCentered:(float) x;
- (void) becomeMainWindow;
- (void) subDrawRect: (NSRect)aRect;
- (void) drawRectAnyway:(NSRect)aRect;
- (id)windowController;
- (BOOL)is2DViewer;
- (void) roiSet:(ROI*) aRoi;
- (IBAction) scaleToFit:(id) sender;
- (NSPoint) ConvertFromNSView2GL:(NSPoint) a;
@end
@interface ROI (QAFormerSDK)
- (id) initWithType: (ToolMode) itype :(float) ipixelSpacingx :(float) ipixelSpacingy :(NSPoint) iimageOrigin;
- (float) roiArea;
- (float) MesureLength: (float*) pixels;
- (BOOL) valid;
- (void) drawROI :(float) scaleValue :(float) offsetx :(float) offsety :(float) spacingx :(float) spacingy;
- (void) drawROIWithScaleValue:(float)scaleValue offsetX:(float)offsetx offsetY:(float)offsety pixelSpacingX:(float)spacingX pixelSpacingY:(float)spacingY highlightIfSelected:(BOOL)highlightIfSelected thickness:(float)thick prepareTextualData:(BOOL) prepareTextualData;
@end
@interface ViewerController (QAFormerSDK)
+ (NSMutableArray*) getDisplayed2DViewers;
- (id) viewCinit:(NSMutableArray*)f :(NSMutableArray*) d :(NSData*) v;
- (void) CloseViewerNotification: (NSNotification*) note;
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender;
- (void) propagateSettings;
- (void) startLoadImageThread;
- (void) showWindowTransition;
- (float*) volumePtr;
- (NSMutableArray*) fileList;
- (NSMutableArray*) roiList;
- (IBAction) roiDeleteAll:(id) sender;
@end
@interface AppController (QAFormerSDK)
- (IBAction) tileWindows:(id)sender;
@end

static NSMutableDictionary *QACounts, *QASeen;
static NSMutableArray *QALines, *QASteps;
static NSString *QAStepName;
static void QAMark(NSString *name, NSString *text) {
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) [text writeToFile:[@(markers) stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
// An override ran: counted under the name of the method, on whatever thread.
static void QAHit(const char *method) {
    @synchronized ([NSProcessInfo class]) {
        NSString *key = @(method);
        QACounts[key] = @([QACounts[key] intValue] + 1);
    }
}
#define QAHIT QAHit(__func__)
// One line of the trace, written at once: what is there after a fault is what ran before it.
static void QALine(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void QALine(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
    va_end(arguments);
    NSLog(@"PLUGINFIXTURE QALegacySubclasses %@", line);
    [QALines addObject:line];
    QAMark(@"QALegacySubclasses.trace", [[QALines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]);
}
// The overrides that ran since the last time this was asked.
static NSString *QASince(void) {
    NSMutableArray *parts = [NSMutableArray array];
    @synchronized ([NSProcessInfo class]) {
        for (NSString *key in [QACounts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            int now = [QACounts[key] intValue], before = [QASeen[key] intValue];
            if (now != before) [parts addObject:[NSString stringWithFormat:@"%@ +%d", key, now - before]];
        }
        [QASeen setDictionary:QACounts];
    }
    return parts.count ? [parts componentsJoinedByString:@", "] : @"no override ran";
}
static BOOL QASkipped(NSString *step) {
    const char *skip = getenv("HOROS_PLUGIN_SUBCLASS_SKIP");
    return skip && [[@(skip) componentsSeparatedByString:@","] containsObject:step];
}
static NSEvent *QAMouse(NSEventType type, NSWindow *window, NSPoint where, NSInteger clicks) {
    return [NSEvent mouseEventWithType:type location:where modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:clicks
                              pressure:(type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp || type == NSEventTypeMouseMoved) ? 0 : 1];
}
// A click and a drag of the left button from a point of the view, a right
// click and a move of the mouse, as the window server delivers them. The right
// click has no click count: on a counted one the application opens its
// contextual menu, which waits for a choice.
static void QAMouseEvents(NSView *view, NSPoint inView) {
    NSWindow *window = view.window;
    NSPoint where = [view convertPoint:inView toView:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:view];
    [window sendEvent:QAMouse(NSEventTypeLeftMouseDown, window, where, 1)];
    [window sendEvent:QAMouse(NSEventTypeLeftMouseDragged, window, NSMakePoint(where.x + 6, where.y + 4), 1)];
    [window sendEvent:QAMouse(NSEventTypeLeftMouseUp, window, NSMakePoint(where.x + 6, where.y + 4), 1)];
    [window sendEvent:QAMouse(NSEventTypeRightMouseDown, window, where, 0)];
    [window sendEvent:QAMouse(NSEventTypeRightMouseUp, window, where, 0)];
    window.acceptsMouseMovedEvents = YES;
    [window sendEvent:QAMouse(NSEventTypeMouseMoved, window, NSMakePoint(where.x + 3, where.y + 3), 0)];
}
// The right arrow and one line of the wheel: in a viewer, each shows another image.
static void QAKeyAndWheel(NSView *view) {
    NSWindow *window = view.window;
    NSPoint middle = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    NSString *arrow = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    [window makeFirstResponder:view];
    [window sendEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:middle modifierFlags:NSEventModifierFlagFunction
                                      timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
                                     characters:arrow charactersIgnoringModifiers:arrow isARepeat:NO keyCode:124]];
    CGEventRef wheel = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, 1);
    NSPoint onScreen = [window convertPointToScreen:middle];
    CGEventSetLocation(wheel, CGPointMake(onScreen.x, NSMaxY(NSScreen.screens[0].frame) - onScreen.y));
    [view scrollWheel:[NSEvent eventWithCGEvent:wheel]];
    CFRelease(wheel);
}

// A ROI as HipArthroplastyTemplating's HATROI and Ninety Degrees' NinetyDegreesROI
// are: instance variables of its own after the SDK's, and -valid overridden.
// -roiArea and the two drawing messages are not overridden by a known plugin:
// they say whether the application measures and draws a ROI by message.
#define QA_ROI_OVERRIDES \
- (BOOL)valid { QAHIT; return YES; } \
- (float)roiArea { QAHIT; return [super roiArea]; } \
- (void)drawROI:(float)scaleValue :(float)offsetx :(float)offsety :(float)spacingx :(float)spacingy { \
    QAHIT; \
    [super drawROI:scaleValue :offsetx :offsety :spacingx :spacingy]; \
} \
- (void)drawROIWithScaleValue:(float)scaleValue offsetX:(float)offsetx offsetY:(float)offsety pixelSpacingX:(float)spacingX pixelSpacingY:(float)spacingY \
          highlightIfSelected:(BOOL)highlightIfSelected thickness:(float)thick prepareTextualData:(BOOL)prepareTextualData { \
    QAHIT; \
    [super drawROIWithScaleValue:scaleValue offsetX:offsetx offsetY:offsety pixelSpacingX:spacingX pixelSpacingY:spacingY \
             highlightIfSelected:highlightIfSelected thickness:thick prepareTextualData:prepareTextualData]; \
}
@interface QASubROI : ROI {
    ROI *_roi1;
    int qaOwn;
}
@end
@implementation QASubROI
// Its own variables and the SDK's, read and written from the subclass as those plugins do.
- (void)qaStore:(ROI *)model { qaOwn = 0x51415243; _roi1 = model; }
- (NSString *)qaState {
    return [NSString stringWithFormat:@"own variables %@, type %d, %d points, thickness %g", qaOwn == 0x51415243 && _roi1 ? @"kept" : @"LOST",
            type, (int)[points count], thickness];
}
QA_ROI_OVERRIDES
@end

// HATROI itself has no instance variable: an instance of ROI the application
// made can be given this class, which tells whether the application reaches
// the overrides where it draws, selects and copies a ROI, whatever the
// initializer does of a plugin's instance. No plugin does that.
@interface QAPosedROI : ROI
@end
@implementation QAPosedROI
QA_ROI_OVERRIDES
@end

// A view as CMIV CTA's CMIVDCMView and PrintingLayout's PLThumbnailView are:
// instance variables of its own, made by the plugin (or by a nib of the
// plugin, which sends the same -initWithFrame:) and put in a window of the
// plugin. The overrides are theirs and those of Align's AlignDCMView.
#define QA_VIEW_OVERRIDES \
- (void)drawRect:(NSRect)rect { QAHIT; [super drawRect:rect]; } \
- (void)subDrawRect:(NSRect)rect { QAHIT; } \
- (void)drawRectAnyway:(NSRect)rect { QAHIT; } \
- (id)windowController { QAHIT; return [super windowController]; } \
- (void)becomeMainWindow { QAHIT; [super becomeMainWindow]; } \
- (void)resetCursorRects { QAHIT; [super resetCursorRects]; } \
- (void)loadTextures { QAHIT; [super loadTextures]; } \
- (void)setScaleValue:(float)x { QAHIT; [super setScaleValue:x]; } \
- (void)setScaleValueCentered:(float)x { QAHIT; [super setScaleValueCentered:x]; } \
- (void)mouseDown:(NSEvent *)event { QAHIT; [super mouseDown:event]; } \
- (void)mouseDragged:(NSEvent *)event { QAHIT; [super mouseDragged:event]; } \
- (void)mouseUp:(NSEvent *)event { QAHIT; [super mouseUp:event]; } \
- (void)mouseMoved:(NSEvent *)event { QAHIT; [super mouseMoved:event]; } \
- (void)rightMouseDown:(NSEvent *)event { QAHIT; [super rightMouseDown:event]; } \
- (void)rightMouseUp:(NSEvent *)event { QAHIT; [super rightMouseUp:event]; } \
- (void)scrollWheel:(NSEvent *)event { QAHIT; [super scrollWheel:event]; } \
- (void)keyDown:(NSEvent *)event { QAHIT; [super keyDown:event]; }
@interface QASubDCMView : DCMView {
    NSRect qaFrame;
    id qaController;
    int qaOwn;
}
@end
@implementation QASubDCMView
- (void)qaStore { qaOwn = 0x51415643; }
- (NSString *)qaState {
    return [NSString stringWithFormat:@"own variables %@, _curDCM %@, dcmPixList of %d, drawingFrameRect %@, scaleValue %g",
            qaOwn == 0x51415643 && NSEqualSizes(qaFrame.size, NSMakeSize(320, 320)) ? @"kept" : @"LOST", _curDCM ? @"set" : @"nil",
            (int)[dcmPixList count], NSStringFromRect(drawingFrameRect), scaleValue];
}
- (id)init { QAHIT; return [super init]; }
- (id)initWithFrame:(NSRect)frame { QAHIT; self = [super initWithFrame:frame]; if (self) qaFrame = frame; return self; }
- (id)initWithFrame:(NSRect)frame imageRows:(int)rows imageColumns:(int)columns { QAHIT; return [super initWithFrame:frame imageRows:rows imageColumns:columns]; }
- (void)dealloc { QAHIT; [super dealloc]; }
- (BOOL)is2DViewer { QAHIT; return NO; }
QA_VIEW_OVERRIDES
@end

// Align's AlignDCMView had no instance variable of its own, since it took the
// place of DCMView with +poseAsClass:, which the 64-bit runtime answers and
// does nothing of. The nearest the runtime allows: the class of the viewer's own view is
// changed to this one, so that the application reaches the overrides in a 2D
// viewer, those of the other two plugins included. No plugin does that; it is
// what posing meant.
@interface QAPosedDCMView : DCMView
@end
@implementation QAPosedDCMView
- (BOOL)is2DViewer { QAHIT; return [super is2DViewer]; }
QA_VIEW_OVERRIDES
@end

// A viewer as Align's AlignController is: no instance variable of its own,
// made by the plugin with -viewCinit::: on its own +alloc.
@interface QASubViewer : ViewerController
@end
@implementation QASubViewer
- (id)viewCinit:(NSMutableArray *)f :(NSMutableArray *)d :(NSData *)v { QAHIT; return [super viewCinit:f :d :v]; }
- (void)CloseViewerNotification:(NSNotification *)note { QAHIT; [super CloseViewerNotification:note]; }
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender { QAHIT; return [super performDragOperation:sender]; }
- (void)propagateSettings { QAHIT; [super propagateSettings]; }
- (void)dealloc { QAHIT; [super dealloc]; }
@end

@interface QALegacySubclasses : NSObject
@end
@implementation QALegacySubclasses
static ViewerController *QAViewer;
static QASubViewer *QAOwnViewer;
static QASubDCMView *QAOwnView;
static NSWindow *QAOwnWindow;
static QASubROI *QAAxis;
static QAPosedROI *QAPosed;

// The class object the runtime made of the plugin's class at load, and where its own instance variables went.
+ (void)describe:(NSString *)name own:(const char *)ivar
{
    Class class = NSClassFromString(name), parent = class_getSuperclass(class);
    Ivar own = ivar ? class_getInstanceVariable(class, ivar) : NULL;
    QALine(@"class %@: %@, superclass %s, instance of %zu bytes after the %zu of the superclass%@", name, class ? @"loaded" : @"ABSENT",
           parent ? class_getName(parent) : "-", class_getInstanceSize(class), class_getInstanceSize(parent),
           own ? [NSString stringWithFormat:@", %s at %td", ivar, ivar_getOffset(own)] : @"");
}
+ (void)addStep:(NSString *)name body:(void (^)(void))body
{
    [QASteps addObject:@[name, [[body copy] autorelease]]];
}
// One step, then the next a moment later: what the application draws or posts
// after a step is counted with it.
+ (void)nextStep
{
    @autoreleasepool {
        if (QAStepName) QALine(@"end %@: %@", QAStepName, QASince());
        [QAStepName release];
        QAStepName = nil;
        while (QASteps.count) {
            NSArray *step = [[QASteps[0] retain] autorelease];
            [QASteps removeObjectAtIndex:0];
            if (QASkipped(step[0])) {
                QALine(@"skip %@", step[0]);
                continue;
            }
            QAStepName = [step[0] copy];
            QALine(@"begin %@", QAStepName);
            @try {
                ((void (^)(void))step[1])();
            } @catch (NSException *exception) {
                QALine(@"exception in %@: %@: %@", QAStepName, exception.name, exception.reason);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self nextStep]; });
            return;
        }
        // Every override of the four classes, with the times it ran.
        NSMutableArray *counts = [NSMutableArray array];
        for (NSString *name in @[@"QASubROI", @"QASubDCMView", @"QASubViewer", @"QAPosedDCMView", @"QAPosedROI"]) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(NSClassFromString(name), &count);
            NSMutableArray *own = [NSMutableArray array];
            for (unsigned int index = 0; index < count; index++)
                if (strncmp(sel_getName(method_getName(methods[index])), "qa", 2) != 0)
                    [own addObject:[NSString stringWithFormat:@"-[%@ %s]", name, sel_getName(method_getName(methods[index]))]];
            free(methods);
            for (NSString *method in [own sortedArrayUsingSelector:@selector(compare:)])
                [counts addObject:[NSString stringWithFormat:@"%@ %d", method, [QACounts[method] intValue]]];
        }
        QAMark(@"QALegacySubclasses.result", [NSString stringWithFormat:@"QALegacySubclasses: all steps ended\n%@\n-- times each override ran\n%@\n",
                                               [QALines componentsJoinedByString:@"\n"], [counts componentsJoinedByString:@"\n"]]);
        NSLog(@"PLUGINFIXTURE QALegacySubclasses all steps ended");
    }
}

+ (void)viewerDidLoadImages:(ViewerController *)viewer
{
    QAViewer = [viewer retain];
    [self describe:@"QASubROI" own:"qaOwn"];
    [self describe:@"QASubDCMView" own:"qaOwn"];
    [self describe:@"QASubViewer" own:NULL];
    [self describe:@"QAPosedDCMView" own:NULL];
    [self describe:@"QAPosedROI" own:NULL];
    // Align's -initPlugin: [AlignDCMView poseAsClass:[DCMView class]].
    SEL pose = NSSelectorFromString(@"poseAsClass:");
    Class host = NSClassFromString(@"DCMView");
    BOOL answered = [QAPosedDCMView respondsToSelector:pose];
    if (answered) [QAPosedDCMView performSelector:pose withObject:host];
    QALine(@"+poseAsClass: %@; DCMView %@ the overrides of QAPosedDCMView", answered ? @"sent as Align sends it" : @"is not answered",
           class_getMethodImplementation(host, @selector(subDrawRect:)) == class_getMethodImplementation([QAPosedDCMView class], @selector(subDrawRect:))
               ? @"now has" : @"does not have");

    // HipArthroplastyTemplating's axis: made by the plugin, given to the view and added to the image's list.
    [self addStep:@"roi" body:^{
        DCMView *view = [QAViewer imageView];
        ROI *model = [QAViewer newROI:tMesure];
        QAAxis = [[QASubROI alloc] initWithType:tMesure :model.pixelSpacingX :model.pixelSpacingY :model.imageOrigin];
        QALine(@"QASubROI instance: %@, a %s, kind of ROI %d", QAAxis ? @"made" : @"NIL", object_getClassName(QAAxis), [QAAxis isKindOfClass:NSClassFromString(@"ROI")]);
        [QAAxis qaStore:model];
        [QAAxis setThickness:1];
        [QAAxis setOpacity:.5];
        [QAAxis setSelectable:NO];
        [view roiSet:QAAxis];
        [[[QAViewer roiList] objectAtIndex:[view curImage]] addObject:QAAxis];
        [QAAxis setPoints:[NSMutableArray arrayWithObjects:[MyPoint point:NSMakePoint(40, 40)], [MyPoint point:NSMakePoint(160, 120)], nil]];
        float length = [QAAxis MesureLength:NULL];
        [QAAxis setName:@"QASubROI"];
        // A closed polygon of the same class: its label holds an area.
        QASubROI *polygon = [[QASubROI alloc] initWithType:tCPolygon :model.pixelSpacingX :model.pixelSpacingY :model.imageOrigin];
        [view roiSet:polygon];
        [[[QAViewer roiList] objectAtIndex:[view curImage]] addObject:polygon];
        [polygon setPoints:[NSMutableArray arrayWithObjects:[MyPoint point:NSMakePoint(60, 150)], [MyPoint point:NSMakePoint(120, 150)],
                            [MyPoint point:NSMakePoint(120, 200)], [MyPoint point:NSMakePoint(60, 200)], nil]];
        [polygon release];
        [view setNeedsDisplay:YES];
        QALine(@"QASubROI: %@, length %g, in the image's list %d", [QAAxis qaState], length, [[view curRoiList] containsObject:QAAxis]);
    }];

    // A length drawn in the viewer with the mouse: when the button comes up the application asks every ROI of the series whether it is valid.
    [self addStep:@"roivalid" body:^{
        DCMView *view = [QAViewer imageView];
        ToolMode tool = [view currentTool];
        [view setCurrentTool:tMesure];
        QAMouseEvents(view, NSMakePoint(NSMidX(view.bounds) + 40, NSMidY(view.bounds) + 40));
        [view setCurrentTool:tool];
        QALine(@"a length drawn with the mouse; the QASubROI is still in the image's list %d", [[view curRoiList] containsObject:QAAxis]);
    }];

    // PrintingLayout's thumbnail and CMIV CTA's view: in a window of the plugin, filled from the viewer's view.
    [self addStep:@"view" body:^{
        NSRect frame = NSMakeRect(0, 0, 320, 320);
        QASubDCMView *bare = [[QASubDCMView alloc] init];
        QALine(@"QASubDCMView -init: %@, a %s", bare ? @"made" : @"NIL", object_getClassName(bare));
        [bare release];
        QASubDCMView *rows = [[QASubDCMView alloc] initWithFrame:frame imageRows:1 imageColumns:1];
        QALine(@"QASubDCMView -initWithFrame:imageRows:imageColumns: %@, a %s", rows ? @"made" : @"NIL", object_getClassName(rows));
        [rows release];
        QAOwnWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(60, 60, 320, 320) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:NO];
        QAOwnWindow.releasedWhenClosed = NO;
        QAOwnWindow.title = @"QALegacySubclasses";
        QAOwnView = [[QASubDCMView alloc] initWithFrame:frame];
        QALine(@"QASubDCMView -initWithFrame: %@, a %s, kind of DCMView %d", QAOwnView ? @"made" : @"NIL", object_getClassName(QAOwnView),
               [QAOwnView isKindOfClass:NSClassFromString(@"DCMView")]);
        [QAOwnView qaStore];
        [QAOwnWindow.contentView addSubview:QAOwnView];
        DCMView *dcm = [QAViewer imageView];
        NSMutableArray *pixels = [NSMutableArray arrayWithObject:[[dcm dcmPixList] objectAtIndex:0]];
        NSMutableArray *files = [[dcm dcmFilesList] count] ? [NSMutableArray arrayWithObject:[[dcm dcmFilesList] objectAtIndex:0]] : nil;
        NSMutableArray *rois = [[dcm dcmRoiList] count] ? [NSMutableArray arrayWithObject:[[dcm dcmRoiList] objectAtIndex:0]] : nil;
        [QAOwnView setPixels:pixels files:files rois:rois firstImage:0 level:'i' reset:YES];
        [QAOwnWindow orderFront:nil];
        [QAOwnView setNeedsDisplay:YES];
        // The instance variables of the SDK a subclass reads, with its own after them.
        QALine(@"QASubDCMView: %@, in a window %d", [QAOwnView qaState], QAOwnView.window != nil);
    }];
    [self addStep:@"viewevents" body:^{
        QAMouseEvents(QAOwnView, NSMakePoint(160, 160));
        QAKeyAndWheel(QAOwnView);
        [QAOwnView setScaleValue:[QAOwnView scaleValue] * 1.25f];
        [QAOwnView setScaleValueCentered:[QAOwnView scaleValue] * 0.8f];
        QALine(@"QASubDCMView: events sent; first responder %d, scale %g", QAOwnView.window.firstResponder == QAOwnView, [QAOwnView scaleValue]);
    }];

    // Align's window: a copy of the viewer's series in a viewer of the plugin's class.
    [self addStep:@"viewer" body:^{
        NSArray *pixList = [QAViewer pixList];
        long bytes = 0;
        for (DCMPix *pix in pixList) bytes += [pix pheight] * [pix pwidth] * 4;
        unsigned char *volume = malloc(bytes);
        memcpy(volume, [QAViewer volumePtr], bytes);
        NSData *volumeData = [[NSData alloc] initWithBytesNoCopy:volume length:bytes freeWhenDone:YES];
        NSMutableArray *newPixList = [NSMutableArray array];
        long offset = 0;
        for (DCMPix *pix in pixList) {
            DCMPix *copy = [[pix copy] autorelease];
            [copy setfImage:(float *)(volume + offset)];
            offset += [pix pheight] * [pix pwidth] * 4;
            [newPixList addObject:copy];
        }
        QALine(@"QASubViewer: %d images and %ld bytes copied", (int)newPixList.count, bytes);
        QAOwnViewer = [[QASubViewer alloc] viewCinit:newPixList :[QAViewer fileList] :volumeData];
        QALine(@"QASubViewer -viewCinit::: %@, a %s, kind of ViewerController %d", QAOwnViewer ? @"made" : @"NIL", object_getClassName(QAOwnViewer),
               [QAOwnViewer isKindOfClass:NSClassFromString(@"ViewerController")]);
        [QAOwnViewer showWindowTransition];
        [QAOwnViewer startLoadImageThread];
        [[NSClassFromString(@"AppController") sharedAppController] tileWindows:nil];
        [QAOwnViewer roiDeleteAll:nil];
        QALine(@"QASubViewer: window %@, image view a %s", [QAOwnViewer window].visible ? @"visible" : @"not visible", object_getClassName([QAOwnViewer imageView]));
    }];
    [self addStep:@"viewerreach" body:^{
        DCMView *view = [QAOwnViewer imageView];
        QALine(@"QASubViewer: among the displayed 2D viewers %d, its view answers -is2DViewer %d and -windowController a %s, %d images in the view",
               [[NSClassFromString(@"ViewerController") getDisplayed2DViewers] containsObject:QAOwnViewer], [view is2DViewer],
               object_getClassName([view windowController]), (int)[[view dcmPixList] count]);
        // The application propagates the settings of the main viewer to the others when its view is scaled to fit.
        [NSApp activateIgnoringOtherApps:YES];
        [[QAOwnViewer window] makeKeyAndOrderFront:nil];
        QALine(@"QASubViewer: its window is main %d", [QAOwnViewer window].mainWindow);
        [view scaleToFit:nil];
        QAMouseEvents(view, NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)));
    }];
    [self addStep:@"viewerclose" body:^{
        [[QAOwnViewer window] close];
    }];

    // What +poseAsClass: gave Align: the viewer's own view with the overrides of the plugin.
    [self addStep:@"pose" body:^{
        DCMView *view = [QAViewer imageView];
        if (object_getClass(view) != NSClassFromString(@"DCMView")) {
            QALine(@"the viewer's view is a %s: its class is left alone", object_getClassName(view));
            return;
        }
        object_setClass(view, [QAPosedDCMView class]);
        QALine(@"the viewer's view is now a %s", object_getClassName(view));
        [view setNeedsDisplay:YES];
        [view setScaleValue:[view scaleValue] * 1.25f];
        [view setScaleValueCentered:[view scaleValue] * 0.8f];
        QAMouseEvents(view, NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)));
        [[NSClassFromString(@"AppController") sharedAppController] tileWindows:nil];
    }];
    // Another image in the posed view: a key and the wheel.
    [self addStep:@"poseimage" body:^{
        DCMView *view = [QAViewer imageView];
        if (object_getClass(view) != [QAPosedDCMView class]) return;
        short before = [view curImage];
        QAKeyAndWheel(view);
        QALine(@"the posed view showed image %d and shows %d", before, [view curImage]);
    }];
    [self addStep:@"unpose" body:^{
        DCMView *view = [QAViewer imageView];
        if (object_getClass(view) == [QAPosedDCMView class]) object_setClass(view, NSClassFromString(@"DCMView"));
        QALine(@"the viewer's view is a %s again", object_getClassName(view));
    }];

    // ROIs the application made, given the class of the plugin: drawn with the image, then clicked and copied.
    [self addStep:@"poseroi" body:^{
        DCMView *view = [QAViewer imageView];
        NSMutableArray *list = [[QAViewer roiList] objectAtIndex:[view curImage]];
        NSPoint corner = NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds));
        for (NSNumber *kind in @[@(tMesure), @(tCPolygon)]) {
            ROI *roi = [QAViewer newROI:(ToolMode)kind.intValue];
            if (object_getClass(roi) != NSClassFromString(@"ROI")) {
                QALine(@"-newROI: answered a %s: its class is left alone", object_getClassName(roi));
                continue;
            }
            // In the image's coordinates, around the point the middle of the view shows.
            NSPoint middle = [view ConvertFromNSView2GL:corner];
            NSMutableArray *points = kind.intValue == tMesure
                ? [NSMutableArray arrayWithObjects:[MyPoint point:NSMakePoint(middle.x - 30, middle.y - 40)], [MyPoint point:NSMakePoint(middle.x + 30, middle.y - 40)], nil]
                : [NSMutableArray arrayWithObjects:[MyPoint point:NSMakePoint(middle.x - 20, middle.y - 20)], [MyPoint point:NSMakePoint(middle.x + 20, middle.y - 20)],
                   [MyPoint point:NSMakePoint(middle.x + 20, middle.y + 20)], [MyPoint point:NSMakePoint(middle.x - 20, middle.y + 20)], nil];
            [roi setPoints:points];
            object_setClass(roi, [QAPosedROI class]);
            [view roiSet:roi];
            [list addObject:roi];
            if (kind.intValue == tCPolygon) QAPosed = (QAPosedROI *)[roi retain];
        }
        [view setNeedsDisplay:YES];
        QALine(@"%d ROIs of the image are QAPosedROI; the polygon has %d points", (int)[[list filteredArrayUsingPredicate:
               [NSPredicate predicateWithBlock:^BOOL(id roi, NSDictionary *bindings) { return object_getClass(roi) == [QAPosedROI class]; }]] count],
               (int)[[QAPosed points] count]);
    }];
    [self addStep:@"poseroiclick" body:^{
        DCMView *view = [QAViewer imageView];
        if (QAPosed == nil) return;
        QAMouseEvents(view, NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)));
        QALine(@"the posed polygon after a click inside it: mode %ld", [QAPosed ROImode]);
    }];
    // What the application does of a ROI in its lists when it keeps a state to come back to, or copies and pastes it.
    [self addStep:@"poseroicopy" body:^{
        if (QAPosed == nil) return;
        ROI *copy = [[QAPosed copy] autorelease];
        QALine(@"copy of the QAPosedROI: %@, a %s", copy ? @"made" : @"NIL", object_getClassName(copy));
    }];
    [self addStep:@"roicopy" body:^{
        if (QAAxis == nil) return;
        ROI *copy = [[QAAxis copy] autorelease];
        QALine(@"copy of the QASubROI: %@, a %s", copy ? @"made" : @"NIL", object_getClassName(copy));
    }];
    [self nextStep];
}

+ (void)load
{
    @autoreleasepool {
        QACounts = [[NSMutableDictionary alloc] init];
        QASeen = [[NSMutableDictionary alloc] init];
        QALines = [[NSMutableArray alloc] init];
        QASteps = [[NSMutableArray alloc] init];
        QAMark(@"QALegacySubclasses.loaded", @"loaded");
        // The first viewer alone: the plugin's own viewer posts the same notification.
        [NSNotificationCenter.defaultCenter addObserverForName:OsirixViewerControllerDidLoadImagesNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (QAViewer == nil && [note.object isKindOfClass:NSClassFromString(@"ViewerController")]) [self viewerDidLoadImages:note.object];
        }];
    }
}
+ (id)filter { return [[[self alloc] init] autorelease]; }
- (long)prepareFilter:(id)viewer { return 0; }
- (long)filterImage:(NSString *)menu { return 0; }
@end
''')
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-bundle', '-fno-objc-arc', '-framework', 'Cocoa', '-mmacosx-version-min=15.0',
                    '-arch', 'arm64', '-arch', 'x86_64', '-undefined', 'dynamic_lookup', '-Wno-deprecated-declarations',
                    '-Wno-objc-protocol-method-implementation', str(legacy_subclasses_source),
                    '-o', str(legacy_subclasses / 'Contents/MacOS/QALegacySubclasses')], check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(legacy_subclasses / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QALegacySubclasses', 'CFBundleIdentifier': 'org.horosproject.qa.QALegacySubclasses',
    'CFBundleName': 'QALegacySubclasses', 'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL',
    'NSPrincipalClass': 'QALegacySubclasses', 'pluginType': 'imageFilter', 'MenuTitles': ['QALegacySubclasses']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(legacy_subclasses)], check=True, capture_output=True)

# A former database plugin whose command stays in a modal dialog, and that can
# ask the application to quit from inside it: see the module's description.
modal = args.destination / 'QAModalDialog.horosplugin'
(modal / 'Contents/MacOS').mkdir(parents=True)
modal_source = args.destination / 'QAModalDialog.m'
modal_source.write_text(r'''#import <AppKit/AppKit.h>
static void QAModalDialogTrace(NSString *text) {
    NSLog(@"PLUGINFIXTURE QAModalDialog %@", text);
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (!markers) return;
    NSString *path = [@(markers) stringByAppendingPathComponent:@"QAModalDialog.trace"];
    NSString *before = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    [[before stringByAppendingFormat:@"%@\n", text] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static NSMenuItem *QAModalDialogFind(NSMenu *menu, BOOL (^matches)(NSMenuItem *)) {
    for (NSMenuItem *item in menu.itemArray) {
        if (matches(item)) return item;
        NSMenuItem *found = item.submenu ? QAModalDialogFind(item.submenu, matches) : nil;
        if (found) return found;
    }
    return nil;
}
@interface QAModalDialog : NSObject
@end
@implementation QAModalDialog
+ (void)load {
    const char *delay = getenv("HOROS_PLUGIN_MODAL_AUTORUN");
    if (!delay) return;
    NSTimeInterval seconds = atof(delay);
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        [self performSelector:@selector(chooseOwnMenuItem) withObject:nil afterDelay:seconds];
    }];
}
// The item the application made for this plugin in its Plugins menu, sent as a click sends it.
+ (void)chooseOwnMenuItem {
    NSMenuItem *item = QAModalDialogFind(NSApp.mainMenu, ^BOOL(NSMenuItem *candidate) {
        return [candidate.title isEqualToString:@"QAModalDialog"] && candidate.action != NULL;
    });
    QAModalDialogTrace([NSString stringWithFormat:@"own menu item %@, action %@, target %@", item ? @"found" : @"missing",
                        item ? NSStringFromSelector(item.action) : @"-", item.target ? NSStringFromClass([item.target class]) : @"-"]);
    if (item) [NSApp sendAction:item.action to:item.target from:item];
}
+ (id)filter { return [[[self alloc] init] autorelease]; }
- (long)prepareFilter:(id)viewer { return 0; }
// The notes beside the plugins folder this bundle is in, as the application left them.
- (NSString *)notes {
    NSString *support = [[[NSBundle bundleForClass:[self class]].bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSMutableArray *notes = [NSMutableArray array];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:support error:NULL])
        if ([entry hasPrefix:@"Plugin_Loading"])
            [notes addObject:[NSString stringWithFormat:@"%@ = %@", entry,
                              [[NSString stringWithContentsOfFile:[support stringByAppendingPathComponent:entry] encoding:NSUTF8StringEncoding error:NULL]
                               stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]];
    return notes.count ? [notes componentsJoinedByString:@"; "] : @"none";
}
- (void)askToQuit:(NSString *)how {
    QAModalDialogTrace([NSString stringWithFormat:@"asking to quit by %@; modal window %@", how, NSApp.modalWindow ? @"open" : @"absent"]);
    if ([how isEqualToString:@"key"]) {
        NSMenuItem *quit = QAModalDialogFind(NSApp.mainMenu, ^BOOL(NSMenuItem *candidate) {
            return [candidate.keyEquivalent isEqualToString:@"q"] && candidate.keyEquivalentModifierMask == NSEventModifierFlagCommand;
        });
        [quit.menu update];
        QAModalDialogTrace([NSString stringWithFormat:@"Quit item %@, enabled %d, action %@, target %@", quit ? quit.title : @"missing", quit.enabled,
                            quit ? NSStringFromSelector(quit.action) : @"-", quit.target ? NSStringFromClass([quit.target class]) : @"-"]);
        for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)])
            [NSApp postEvent:[NSEvent keyEventWithType:type.unsignedIntegerValue location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
                                             timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:NSApp.keyWindow.windowNumber context:nil
                                            characters:@"q" charactersIgnoringModifiers:@"q" isARepeat:NO keyCode:12] atStart:NO];
    } else if ([how isEqualToString:@"delegate"]) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            QAModalDialogTrace(@"-terminate: to the application's delegate, from a block of the main run loop");
            [(id)NSApp.delegate performSelector:@selector(terminate:) withObject:nil];
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    } else if ([how isEqualToString:@"application"]) {
        [NSApp terminate:nil];
    }
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *timer) {
        QAModalDialogTrace([NSString stringWithFormat:@"still running 3 s after asking to quit by %@; notes: %@", how, [self notes]]);
    }].tolerance = 0;
}
- (long)filterImage:(NSString *)menu {
    QAModalDialogTrace([NSString stringWithFormat:@"command %@ started; notes: %@", menu, [self notes]]);
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Synthetic plugin dialog";
    alert.informativeText = @"QAModalDialog keeps this dialog open until it is answered.";
    [alert addButtonWithTitle:@"OK"];
    const char *quit = getenv("HOROS_PLUGIN_MODAL_QUIT");
    if (quit) {
        NSString *how = @(quit);
        NSTimer *timer = [NSTimer timerWithTimeInterval:2 repeats:NO block:^(NSTimer *fired) { [self askToQuit:how]; }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }
    [alert runModal];
    QAModalDialogTrace([NSString stringWithFormat:@"command %@ returned", menu]);
    return 0;
}
@end
''')
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-bundle', '-framework', 'AppKit', '-arch', 'arm64', '-arch', 'x86_64',
                    str(modal_source), '-o', str(modal / 'Contents/MacOS/QAModalDialog')],
                   check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(modal / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'QAModalDialog', 'CFBundleIdentifier': 'org.horosproject.qa.QAModalDialog', 'CFBundleName': 'QAModalDialog',
    'CFBundleVersion': '1.0', 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QAModalDialog', 'pluginType': 'Database',
    'MenuTitles': ['QAModalDialog']}))
subprocess.run(['codesign', '--force', '--sign', '-', str(modal)], check=True, capture_output=True)

# One plugin twice, as two installers of the same author leave it: the same
# name, class and identifier under the two former extensions, at two versions.
same_name_source = args.destination / 'QA.m'
same_name_source.write_text(r'''#import <AppKit/AppKit.h>
@interface QA : NSObject
@end
@implementation QA
+ (id)filter { return [[[self alloc] init] autorelease]; }
- (long)prepareFilter:(id)viewer { return 0; }
- (long)filterImage:(NSString *)menu {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *which = [NSString stringWithFormat:@"%@ %@", bundle.bundlePath.lastPathComponent, [bundle objectForInfoDictionaryKey:@"CFBundleVersion"]];
    const char *markers = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (markers) {
        [which writeToFile:[@(markers) stringByAppendingPathComponent:@"QA.executed"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return 0;
    }
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Synthetic plugin executed";
    alert.informativeText = which;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return 0;
}
@end
''')
for extension, version in [('horosplugin', '1.0'), ('osirixplugin', '2.0')]:
    bundle = args.destination / ('QA.' + extension)
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(['xcrun', 'clang', '-bundle', '-framework', 'AppKit', '-arch', 'arm64', '-arch', 'x86_64',
                        str(same_name_source), '-o', str(bundle / 'Contents/MacOS/QA')],
                       check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'QA', 'CFBundleIdentifier': 'org.horosproject.qa.QA', 'CFBundleName': 'QA',
        'CFBundleVersion': version, 'CFBundlePackageType': 'BNDL', 'NSPrincipalClass': 'QA', 'pluginType': 'Database',
        'MenuTitles': ['QA']}))
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)

# Version 1: a stand-in IsiXPluginKit.framework (only its install name
# matters: a plugin links it, the host provides it; a test executable reaches
# it with -rpath DEST/Kit) and bundles that link it.
kit = args.destination / 'Kit/IsiXPluginKit.framework'
kit_binary = kit / 'Versions/A/IsiXPluginKit'
kit_binary.parent.mkdir(parents=True)
kit_source = args.destination / 'IsiXPluginKitStandIn.c'
kit_source.write_text('int IsiXPluginKitStandIn(void) { return 1; }\n')
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                    '-install_name', '@rpath/IsiXPluginKit.framework/Versions/A/IsiXPluginKit',
                    str(kit_source), '-o', str(kit_binary)], check=True, env=dict(os.environ, TMPDIR=scratch + '/'))
(kit / 'Versions/Current').symlink_to('A')
(kit / 'IsiXPluginKit').symlink_to('Versions/Current/IsiXPluginKit')
subprocess.run(['codesign', '--force', '--sign', '-', str(kit_binary)], check=True, capture_output=True)
for name, architectures in [('QAVersion1', ['arm64', 'x86_64']), ('QAVersion1Intel', ['x86_64']),
                            ('QAVersion1InvalidSignature', ['arm64', 'x86_64'])]:
    bundle = args.destination / (name + '.isixplugin')
    executable = bundle / 'Contents/MacOS' / name
    executable.parent.mkdir(parents=True)
    source = args.destination / (name + '.m')
    # +load leaves a file when the code runs: installing or listing must not.
    source.write_text('''#import <Foundation/Foundation.h>
extern int IsiXPluginKitStandIn(void);
@interface CLASS : NSObject
@end
@implementation CLASS
+ (void)load {
    const char *directory = getenv("HOROS_PLUGIN_MARKER_DIR");
    if (directory) [@"loaded" writeToFile:[@(directory) stringByAppendingPathComponent:@"CLASS.ran"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    IsiXPluginKitStandIn();
}
@end
'''.replace('CLASS', name))
    command = ['xcrun', 'clang', '-bundle', '-framework', 'Foundation', '-mmacosx-version-min=15.0',
               '-F', str(args.destination / 'Kit'), '-framework', 'IsiXPluginKit']
    for architecture in architectures:
        command += ['-arch', architecture]
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(command + [str(source), '-o', str(executable)], check=True,
                       env=dict(os.environ, TMPDIR=scratch + '/'))
    info = {'CFBundleExecutable': name, 'CFBundleIdentifier': 'org.example.isix.qa.' + name,
            'CFBundleName': name, 'CFBundleVersion': '1.0', 'CFBundleShortVersionString': '1.0',
            'CFBundlePackageType': 'BNDL', 'LSMinimumSystemVersion': '15.0',
            'NSPrincipalClass': name, 'IsiXPluginAPIVersion': 1}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    resources = bundle/'Contents/Resources'
    resources.mkdir()
    (resources/'seal.txt').write_text('Original synthetic resource')
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    if name == 'QAVersion1InvalidSignature':
        (resources/'seal.txt').write_text('Modified after signing')
# A former plugin renamed to look like a version 1 bundle: the version 1
# loader refuses it by what it declares, and it is never tried as a former one.
subprocess.run(['ditto', str(args.destination / 'QAUniversal.horosplugin'), str(args.destination / 'QARenamed.isixplugin')], check=True)
print('Created synthetic plugin bundles, former and version 1, and a stand-in IsiXPluginKit; none installed.')
