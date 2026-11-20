#!/usr/bin/env python3
"""A plugin built with later headers of the plugin SDK sends the application
the selectors only those headers declare, and they answer.

Such a plugin stopped at the first selector the application did not have:
«-[ROI total]: unrecognized selector» in the middle of an export of the
statistics of the ROIs. The registry of the binary surface
(tests/legacy-plugin-abi.json, osirix_selectors) names every one of those
selectors the application answers, and tests/test-legacy-plugin-abi.py reads
them in the metadata of the bundle. This test sends them.

tests/fixtures/later-sdk-selector-types.json has, for each, the type encoding
the Objective-C compiler gives the declaration of those headers, and which of
them are properties the application only keeps and reads back.
tools/plugin-sdk-selector-sweep.py writes both from the headers.

QALaterSDK.osirixplugin is built here the way those plugins are: Objective-C
without ARC, a bundle linked with -undefined dynamic_lookup, its principal
class a subclass of PluginFilter, and no header of the application. The
development bundle is launched isolated (tools/native_app.py), with a database
of its own in a temporary folder, and loads it with --LoadPlugin. Three
seconds after it is loaded, on the main thread, the plugin:

- makes an object of each class: rectangle and length ROIs on an image of
  its own making, that image, an image view, a 2D viewer of that image that is
  never shown, the browser, itself for PluginFilter, and a study, a series and
  an image of the database's model that are in no database; of every other
  class of the application in the fixture, whose selectors all come from the
  table and read nothing of their object, an object that is allocated and
  never initialized; and of the classes of the system the headers add
  helpers to, an ordinary object;
- asks each whether it answers each selector, and writes the type encoding of
  the method that answers, which the test compares, without the frame offsets,
  with the one of the fixture: a method with another argument or return type
  would read its caller's registers wrongly;
- sends every selector but the initializers, with every argument zero, on the
  main thread and again on a background thread, and none may raise;
- sets each kept property and reads it back;
- measures the two ROIs through the selectors that have something behind
  them: the statistics against -computeROI::::::::, the median read and set
  as the double the former SDK declares and as the float later headers
  declare, the lengths and the areas
  against the shapes, the rectangle around each, the copy, the archive written
  to a file and read back, the point inside and the initializers.

tests/fixtures/later-sdk-type-divergences.json lists the selectors the
application answers with the types the former SDK declares where later
headers declare others, which is contract: the plugin writes the types those
methods have, and the test refuses a change of that list that the fixture
does not record.

It writes what it found as JSON to the path of QA_LATER_SDK_REPORT and the
test stops the application.

    python3 tests/test-later-plugin-sdk-selectors.py [--app BUNDLE] [--log FILE]

--app is a development bundle (by default build/Development/HorosDevelopment.app,
which script/build_and_run.sh --verify leaves). Exit status 2 without the
bundle or the compiler, with a bundle of an earlier build than the built
product, or while a development instance of this checkout runs. The test opens
the application: it needs the graphic session. --log keeps what the application
wrote, to read after a failure.
"""
import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import native_app  # noqa: E402

FIXTURE = json.loads((ROOT / 'tests/fixtures/later-sdk-selector-types.json').read_text())
TYPES, KEPT = FIXTURE['types'], FIXTURE['kept']
# The selectors answered with the types of the former SDK where later headers declare others.
DIVERGENT = json.loads((ROOT / 'tests/fixtures/later-sdk-type-divergences.json').read_text())['selectors']
REGISTRY = ROOT / 'tests/legacy-plugin-abi.json'


def without_offsets(encoding):
    """A method's type encoding without its frame offsets; the sizes of its C arrays stay."""
    return re.sub(r'\[\d+|\d+', lambda found: found.group(0) if found.group(0).startswith('[') else '', encoding)


PLUGIN = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>

// What the plugin uses of the SDK, declared here as its headers declare it.
@interface PluginFilter : NSObject
- (void)initPlugin;
- (long)filterImage:(NSString *)menuName;
@end
@interface QALaterSDK : PluginFilter
@end
@interface QAPoint : NSObject
+ (id)point:(NSPoint)a;
@end
@interface QAPix : NSObject
- (id)initWithData:(float *)im :(short)pixelSize :(long)xDim :(long)yDim :(float)xSpace :(float)ySpace :(float)oX :(float)oY :(float)oZ;
- (void)computeROI:(id)roi :(float *)mean :(float *)total :(float *)dev :(float *)min :(float *)max :(float *)skewness :(float *)kurtosis;
- (void)computeROI:(id)roi :(float *)mean :(float *)median :(float *)total :(float *)dev :(float *)min :(float *)max :(float *)skewness :(float *)kurtosis;
- (void)computeBallROI:(id)roi :(float *)mean :(float *)total :(float *)dev :(float *)min :(float *)max :(float *)skewness :(float *)kurtosis;
@end
@interface QAROI : NSObject
- (id)initWithType:(long)itype :(float)ipixelSpacingx :(float)ipixelSpacingy :(NSPoint)iimageOrigin;
- (id)initWithType:(long)itype inView:(id)v;
- (id)initWithType:(long)itype pixelSpacingX:(float)x pixelSpacingY:(float)y origin:(NSPoint)origin dcmPix:(id)pix dcmView:(id)view;
+ (id)roiWithType:(long)itype inView:(id)v;
- (void)setROIRect:(NSRect)rect;
- (NSRect)rect;
- (long)type;
- (void)setPix:(id)pix;
- (NSMutableArray *)points;
- (float)total;
- (float)dev;
- (float)skewness;
- (float)kurtosis;
- (float)length;
- (float)lengthPix;
- (float)area;
- (float)areaPix;
- (void)setArea:(float)area;
- (NSRect)boundRect;
- (NSPoint)upperLeftCoordinate;
- (NSPoint)lowerRightCoordinate;
- (id)duplicate;
- (BOOL)isEqualToROI:(id)r;
- (BOOL)writeToFile:(NSString *)file;
+ (id)readFromFile:(NSString *)file;
- (BOOL)isPointInside:(NSPoint)point;
- (int)pointUnderMouse;
- (void)setPointUnderMouse:(int)index;
- (unsigned long)textureBufferSize;
- (float)LengthInCm:(NSPoint)a to:(NSPoint)b;
+ (float)LengthInPixelsFrom:(NSPoint)a to:(NSPoint)b;
+ (NSNumberFormatter *)fmt2d;
@end
@interface QAView : NSObject
- (id)viewer;
- (NSArray *)arrayOfROIsNames;
- (NSArray *)roisWithName:(NSString *)name;
@end
@interface QAViewer : NSObject
- (id)initWithPix:(NSMutableArray *)pix withFiles:(NSMutableArray *)files withVolume:(NSData *)volume;
+ (int)countOf2DViewers;
@end
@interface NSObject (QALaterSDKHost)
+ (id)activeLocalDatabase;
+ (id)currentBrowser;
@end

static NSMutableDictionary *problems;
static void note(NSString *check, NSString *problem) { if (problem) [problems setObject:problem forKey:check]; }
static BOOL near(double a, double b) { return fabs(a - b) <= 1e-3 * fmax(1.0, fmax(fabs(a), fabs(b))); }

@implementation QALaterSDK

- (long)filterImage:(NSString *)menuName { return 0; }

// From the run loop, not from a block of the main queue: while such a block runs, the queue serves no
// other, and a selector sent off the main thread that does its work on the main thread would wait forever.
- (void)initPlugin {
    [self performSelector:@selector(check) withObject:nil afterDelay:3.0];
}

// The object of each class the selectors are sent to. None is released: the application ends with the test.
- (NSDictionary *)objects {
    NSMutableDictionary *objects = [NSMutableDictionary dictionary];
    static float pixels[64 * 64];
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) pixels[y * 64 + x] = x;
    id pix = [(QAPix *)[NSClassFromString(@"DCMPix") alloc] initWithData:pixels :32 :64 :64 :0.5 :0.5 :0 :0 :0];
    if (pix) objects[@"DCMPix"] = pix;
    // Two rectangles: every selector is sent to the first, which then holds
    // what they set, and the second is measured.
    for (NSString *name in @[@"ROI", @"measured ROI"]) {
        QAROI *rectangle = [(QAROI *)[NSClassFromString(@"ROI") alloc] initWithType:6 :0.5 :0.5 :NSZeroPoint];
        [rectangle setROIRect:NSMakeRect(10, 20, 30, 40)];
        [rectangle setPix:pix];
        if (rectangle) objects[name] = rectangle;
    }
    QAROI *length = [(QAROI *)[NSClassFromString(@"ROI") alloc] initWithType:5 :0.5 :0.5 :NSZeroPoint];
    [[length points] addObject:[(Class)NSClassFromString(@"MyPoint") point:NSMakePoint(0, 0)]];
    [[length points] addObject:[(Class)NSClassFromString(@"MyPoint") point:NSMakePoint(30, 40)]];
    [length setPix:pix];
    if (length) objects[@"length ROI"] = length;
    id view = [(NSView *)[NSClassFromString(@"DCMView") alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    if (view) objects[@"DCMView"] = view;
    objects[@"PluginFilter"] = self;
    id browser = [NSClassFromString(@"BrowserController") currentBrowser];
    if (browser) objects[@"BrowserController"] = browser;
    NSManagedObjectModel *model = [[NSClassFromString(@"DicomDatabase") activeLocalDatabase] managedObjectModel];
    for (NSEntityDescription *entity in [model entities]) {
        NSString *name = [entity managedObjectClassName];
        if ([name isEqualToString:@"DicomStudy"] || [name isEqualToString:@"DicomSeries"] || [name isEqualToString:@"DicomImage"]) {
            id object = [[NSClassFromString(name) alloc] initWithEntity:entity insertIntoManagedObjectContext:nil];
            if (object) objects[name] = object;
        }
    }
    // The classes of the system the headers add helpers to: an object of each.
    objects[@"NSObject"] = [[NSObject alloc] init];
    objects[@"NSString"] = @"a string of the test";
    objects[@"NSArray"] = @[@3, @1, @2];
    objects[@"NSMutableArray"] = [NSMutableArray arrayWithObjects:@"a", @"b", nil];
    objects[@"NSDictionary"] = @{@"Key": @"value"};
    objects[@"NSMutableDictionary"] = [NSMutableDictionary dictionaryWithObject:@"value" forKey:@"key"];
    objects[@"NSSet"] = [NSSet setWithObject:@1];
    objects[@"NSOrderedSet"] = [NSOrderedSet orderedSetWithObject:@1];
    objects[@"NSData"] = [@"data of the test" dataUsingEncoding:NSUTF8StringEncoding];
    objects[@"NSDate"] = [NSDate date];
    objects[@"NSNumber"] = @1;
    objects[@"NSURL"] = [NSURL URLWithString:@"https://example.org/a?b=c"];
    objects[@"NSValue"] = [NSValue valueWithPoint:NSZeroPoint];
    objects[@"NSNotificationCenter"] = [[NSNotificationCenter alloc] init];
    objects[@"NSThread"] = [NSThread mainThread];
    objects[@"NSFileManager"] = [[NSFileManager alloc] init];
    objects[@"NSUserDefaults"] = [[NSUserDefaults alloc] initWithSuiteName:@"qa.later.sdk"];
    objects[@"NSImage"] = [NSImage imageWithSize:NSMakeSize(4, 4) flipped:NO drawingHandler:^BOOL(NSRect rect) { [[NSColor redColor] setFill]; NSRectFill(rect); return YES; }];
    objects[@"NSColor"] = [NSColor redColor];
    objects[@"NSFont"] = [NSFont systemFontOfSize:12];
    objects[@"NSCursor"] = [NSCursor arrowCursor];
    objects[@"NSMenu"] = [[NSMenu alloc] initWithTitle:@"test"];
    objects[@"NSView"] = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    objects[@"NSWindow"] = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    if ([objects[@"DicomStudy"] respondsToSelector:@selector(objectID)]) objects[@"NSManagedObjectID"] = [objects[@"DicomStudy"] objectID];
    @try {
        NSData *volume = [NSData dataWithBytesNoCopy:pixels length:sizeof(pixels) freeWhenDone:NO];
        id viewer = [(QAViewer *)[NSClassFromString(@"ViewerController") alloc]
            initWithPix:[NSMutableArray arrayWithObject:pix] withFiles:[NSMutableArray arrayWithObject:objects[@"DicomImage"]] withVolume:volume];
        if (viewer) objects[@"ViewerController"] = viewer;
    } @catch (NSException *exception) {
        note(@"a 2D viewer of an image of the plugin's making", [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
    }
    return objects;
}

// Sends each selector of `entries` that is no initializer, every argument zero, and says which raised.
- (void)send:(NSArray *)entries to:(NSDictionary *)objects where:(NSString *)where {
    static char zeros[512];
    for (NSArray *entry in entries) {
        NSString *cls = entry[0], *sign = entry[1], *selector = entry[2];
        if ([selector hasPrefix:@"init"]) continue;
        id target = [sign isEqualToString:@"+"] ? (id)NSClassFromString(cls) : objects[cls];
        NSString *check = [NSString stringWithFormat:@"%@ %@%@ sent %@", cls, sign, selector, where];
        @try {
            NSMethodSignature *signature = [target methodSignatureForSelector:NSSelectorFromString(selector)];
            if (!signature) { note(check, @"no method signature"); continue; }
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setSelector:NSSelectorFromString(selector)];
            for (NSUInteger index = 2; index < signature.numberOfArguments; index++) [invocation setArgument:zeros atIndex:index];
            [invocation invokeWithTarget:target];
        } @catch (NSException *exception) {
            note(check, [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
        }
    }
}

// Sets each kept property to a value of its type and reads it back.
- (void)keep:(NSArray *)kept in:(NSDictionary *)objects {
    static char buffer[64];
    for (NSArray *entry in kept) {
        NSString *cls = entry[0], *sign = entry[1], *getter = entry[2];
        if ([getter hasSuffix:@":"]) continue;
        NSString *setter = [NSString stringWithFormat:@"set%@%@:", [[getter substringToIndex:1] uppercaseString], [getter substringFromIndex:1]];
        id target = [sign isEqualToString:@"+"] ? (id)NSClassFromString(cls) : objects[cls];
        NSString *check = [NSString stringWithFormat:@"%@ %@%@ kept", cls, sign, getter];
        @try {
            NSMethodSignature *reads = [target methodSignatureForSelector:NSSelectorFromString(getter)];
            NSMethodSignature *writes = [target methodSignatureForSelector:NSSelectorFromString(setter)];
            if (!reads || !writes) { note(check, @"no getter or no setter"); continue; }
            const char *type = [writes getArgumentTypeAtIndex:2];
            NSUInteger size = 0;
            NSGetSizeAndAlignment(type, &size, NULL);
            unsigned char given[64] = {0}, read[64] = {0};
            if (size > sizeof(given) || size != reads.methodReturnLength) { note(check, [NSString stringWithFormat:@"%s of %lu bytes", type, (unsigned long)size]); continue; }
            id object = @"kept by the plugin";
            switch (type[0]) {
                case '@': memcpy(given, &object, sizeof(object)); break;
                case 'B': case 'c': case 'C': given[0] = 1; break;
                case 'f': { float value = 1.5; memcpy(given, &value, sizeof(value)); break; }
                case 'd': { double value = 2.5; memcpy(given, &value, sizeof(value)); break; }
                case '^': case '*': { void *value = buffer; memcpy(given, &value, sizeof(value)); break; }
                case '{': { for (NSUInteger index = 0; index < size / sizeof(double); index++) { double value = index + 1; memcpy(given + index * sizeof(double), &value, sizeof(value)); } break; }
                default: given[0] = 7; break;
            }
            NSInvocation *write = [NSInvocation invocationWithMethodSignature:writes];
            [write setSelector:NSSelectorFromString(setter)];
            [write setArgument:given atIndex:2];
            [write invokeWithTarget:target];
            NSInvocation *get = [NSInvocation invocationWithMethodSignature:reads];
            [get setSelector:NSSelectorFromString(getter)];
            [get invokeWithTarget:target];
            [get getReturnValue:read];
            if (memcmp(given, read, size) != 0) note(check, [NSString stringWithFormat:@"a value of type %s did not come back", type]);
        } @catch (NSException *exception) {
            note(check, [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
        }
    }
}

// The selectors that have something behind them, by what they answer.
- (void)measure:(NSDictionary *)objects work:(NSString *)work {
    QAPix *pix = objects[@"DCMPix"];
    QAROI *rectangle = objects[@"measured ROI"], *length = objects[@"length ROI"];
    float mean = -5, total = -5, dev = -5, min = -5, max = -5, skewness = -5, kurtosis = -5, median = -5;
    [pix computeROI:rectangle :&mean :&total :&dev :&min :&max :&skewness :&kurtosis];
    note(@"the image of the plugin's making measures the rectangle", (mean > 10 && mean < 40 && total > 0) ? nil
         : [NSString stringWithFormat:@"mean %f, total %f", mean, total]);
    note(@"-total, -dev, -skewness and -kurtosis answer what -computeROI:::::::: measures",
         (near([rectangle total], total) && near([rectangle dev], dev) && near([rectangle skewness], skewness) && near([rectangle kurtosis], kurtosis)) ? nil
         : [NSString stringWithFormat:@"%f %f %f %f for %f %f %f %f", [rectangle total], [rectangle dev], [rectangle skewness], [rectangle kurtosis],
            total, dev, skewness, kurtosis]);
    float mean9 = -5, total9 = -5, dev9 = -5, min9 = -5, max9 = -5, skewness9 = -5, kurtosis9 = -5;
    [pix computeROI:rectangle :&mean9 :&median :&total9 :&dev9 :&min9 :&max9 :&skewness9 :&kurtosis9];
    note(@"-computeROI::::::::: measures the same with the median after the mean",
         (near(mean9, mean) && near(total9, total) && near(dev9, dev) && near(min9, min) && near(max9, max) && median >= min && median <= max) ? nil
         : [NSString stringWithFormat:@"mean %f median %f total %f dev %f min %f max %f", mean9, median, total9, dev9, min9, max9]);
    // The median, which the former SDK declares a double and later headers a float: a plugin of either reads it.
    double (*asDouble)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
    float (*asFloat)(id, SEL) = (float (*)(id, SEL))objc_msgSend;
    void (*setDouble)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
    void (*setFloat)(id, SEL, float) = (void (*)(id, SEL, float))objc_msgSend;
    SEL getMedian = NSSelectorFromString(@"median"), setMedian = NSSelectorFromString(@"setMedian:");
    note(@"-median read as a double and as a float after the image measured the rectangle",
         (near(asDouble(rectangle, getMedian), median) && asFloat(rectangle, getMedian) == median) ? nil
         : [NSString stringWithFormat:@"%f as a double, %f as a float, for %f", asDouble(rectangle, getMedian), asFloat(rectangle, getMedian), median]);
    QAROI *held = [(QAROI *)[NSClassFromString(@"ROI") alloc] initWithType:6 :0.5 :0.5 :NSZeroPoint];
    setDouble(held, setMedian, 33.25);
    note(@"-setMedian: given a double", (near(asDouble(held, getMedian), 33.25) && asFloat(held, getMedian) == 33.25f) ? nil
         : [NSString stringWithFormat:@"%f as a double, %f as a float", asDouble(held, getMedian), asFloat(held, getMedian)]);
#if defined(__arm64__)
    setFloat(held, setMedian, 12.5f);
    note(@"-setMedian: given a float", (near(asDouble(held, getMedian), 12.5) && asFloat(held, getMedian) == 12.5f) ? nil
         : [NSString stringWithFormat:@"%f as a double, %f as a float", asDouble(held, getMedian), asFloat(held, getMedian)]);
#endif
    setDouble(held, setMedian, NAN);
    note(@"-median of a ROI without one", (isnan(asDouble(held, getMedian)) && isnan(asFloat(held, getMedian))) ? nil : @"a number");
    note(@"-median by key-value coding", near([[rectangle valueForKey:@"median"] doubleValue], median) ? nil
         : [NSString stringWithFormat:@"%@", [rectangle valueForKey:@"median"]]);

    float ball[7] = {-5, -5, -5, -5, -5, -5, -5};
    [pix computeBallROI:rectangle :&ball[0] :&ball[1] :&ball[2] :&ball[3] :&ball[4] :&ball[5] :&ball[6]];
    BOOL zeroed = YES;
    for (int index = 0; index < 7; index++) zeroed = zeroed && ball[index] == 0;
    note(@"-computeBallROI:::::::: leaves no measure unset", zeroed ? nil : @"a measure kept the value it had");

    note(@"-area and -areaPix of the rectangle", (near([rectangle area], 3.0) && near([rectangle areaPix], 1200)) ? nil
         : [NSString stringWithFormat:@"%f cm2, %f pixels", [rectangle area], [rectangle areaPix]]);
    NSRect around = [rectangle boundRect];
    NSPoint low = [rectangle upperLeftCoordinate], high = [rectangle lowerRightCoordinate];
    note(@"-boundRect and its corners, of the rectangle",
         (NSEqualRects(around, NSMakeRect(10, 20, 30, 40)) && NSEqualPoints(low, NSMakePoint(10, 20)) && NSEqualPoints(high, NSMakePoint(40, 60))) ? nil
         : [NSString stringWithFormat:@"%@ %@ %@", NSStringFromRect(around), NSStringFromPoint(low), NSStringFromPoint(high)]);
    note(@"-length and -lengthPix of the length ROI", (near([length length], 2.5) && near([length lengthPix], 50)) ? nil
         : [NSString stringWithFormat:@"%f cm, %f pixels", [length length], [length lengthPix]]);
    note(@"-boundRect of the length ROI", NSEqualRects([length boundRect], NSMakeRect(0, 0, 30, 40)) ? nil : NSStringFromRect([length boundRect]));
    note(@"-LengthInCm:to: and +LengthInPixelsFrom:to:",
         (near([rectangle LengthInCm:NSMakePoint(0, 0) to:NSMakePoint(30, 40)], 2.5)
          && near([(Class)NSClassFromString(@"ROI") LengthInPixelsFrom:NSMakePoint(0, 0) to:NSMakePoint(30, 40)], 50)) ? nil : @"another length");
    note(@"-isPointInside:", ([rectangle isPointInside:NSMakePoint(20, 30)] && ![rectangle isPointInside:NSMakePoint(2, 2)]) ? nil : @"another answer");

    QAROI *copy = [rectangle duplicate];
    note(@"-duplicate answers another ROI that -isEqualToROI: the first", (copy && copy != rectangle && [copy isEqualToROI:rectangle]) ? nil
         : [NSString stringWithFormat:@"%p for %p", copy, rectangle]);
    [copy setROIRect:NSMakeRect(1, 2, 3, 4)];
    note(@"-isEqualToROI: tells a ROI of another shape", [copy isEqualToROI:rectangle] ? @"equal" : nil);
    [copy setArea:7];
    note(@"-setArea: sets what -area then answers", near([copy area], 7) ? nil : [NSString stringWithFormat:@"%f", [copy area]]);

    NSString *file = [work stringByAppendingPathComponent:@"rectangle.roi"];
    BOOL written = [rectangle writeToFile:file];
    QAROI *read = [(Class)NSClassFromString(@"ROI") readFromFile:file];
    note(@"-writeToFile: and +readFromFile: write and read the ROI", (written && read && NSEqualRects([read rect], NSMakeRect(10, 20, 30, 40)) && [read type] == 6) ? nil
         : [NSString stringWithFormat:@"written %d, read %@", written, read]);
    note(@"+readFromFile: answers nil for a file that is no archive", [(Class)NSClassFromString(@"ROI") readFromFile:@"/nonexistent/none.roi"] ? @"an object" : nil);

    QAROI *made = [(Class)NSClassFromString(@"ROI") roiWithType:6 inView:nil];
    note(@"+roiWithType:inView: makes a ROI of that kind", (made && [made type] == 6) ? nil : [NSString stringWithFormat:@"%@", made]);
    QAROI *spaced = [(QAROI *)[NSClassFromString(@"ROI") alloc] initWithType:5 pixelSpacingX:0.5 pixelSpacingY:0.5 origin:NSZeroPoint dcmPix:pix dcmView:nil];
    note(@"-initWithType:pixelSpacingX:pixelSpacingY:origin:dcmPix:dcmView: makes a ROI with that spacing",
         (spaced && [spaced type] == 5 && near([spaced LengthInCm:NSMakePoint(0, 0) to:NSMakePoint(30, 40)], 2.5)) ? nil : [NSString stringWithFormat:@"%@", spaced]);
    [rectangle setPointUnderMouse:3];
    note(@"-pointUnderMouse answers what -setPointUnderMouse: set", [rectangle pointUnderMouse] == 3 ? nil : @"another index");
    [rectangle setPointUnderMouse:-1];
    note(@"-textureBufferSize of a ROI that is no brush", [rectangle textureBufferSize] == 0 ? nil : @"not zero");
    note(@"+fmt2d writes two fraction digits", [[[(Class)NSClassFromString(@"ROI") fmt2d] stringFromNumber:@1.5] length] == 4 ? nil : @"another format");

    QAView *view = objects[@"DCMView"];
    note(@"-viewer of a view in no window", [view viewer] ? @"an object" : nil);
    note(@"-arrayOfROIsNames and -roisWithName: of a view without ROIs", ([view arrayOfROIsNames] && [[view arrayOfROIsNames] count] == 0 && [[view roisWithName:@"none"] count] == 0)
         ? nil : @"not empty");
    note(@"+countOf2DViewers", [(Class)NSClassFromString(@"ViewerController") countOf2DViewers] >= 0 ? nil : @"negative");
}

- (void)check {
    problems = [NSMutableDictionary dictionary];
    NSMutableDictionary *types = [NSMutableDictionary dictionary];
    NSDictionary *counts = @{};
    @try {
        NSArray *entries = [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:getenv("QA_LATER_SDK_LIST")]];
        NSArray *kept = [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:getenv("QA_LATER_SDK_KEPT")]];
        NSMutableDictionary *objects = [[[self objects] mutableCopy] autorelease];
        NSUInteger sent = 0;
        for (NSArray *entry in entries) {
            NSString *cls = entry[0], *sign = entry[1], *selector = entry[2];
            NSString *check = [NSString stringWithFormat:@"%@ %@%@", cls, sign, selector];
            Class class = NSClassFromString(cls);
            if (!class) { note(check, @"the class is absent"); continue; }
            Method method;
            // A class the plugin makes no object of: one that is allocated and never
            // initialized nor released. What the table adds reads nothing of its object.
            if (!objects[cls] && ![sign isEqualToString:@"+"]) {
                id allocated = class_createInstance(class, 0);
                if (allocated) objects[cls] = allocated;
            }
            if ([sign isEqualToString:@"+"]) method = class_getClassMethod(class, NSSelectorFromString(selector));
            else if (!objects[cls]) { note(check, @"no object of the class to send it to"); continue; }
            else method = class_getInstanceMethod(object_getClass(objects[cls]), NSSelectorFromString(selector));
            if (!method) { note(check, @"does not answer"); continue; }
            [types setObject:[NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""] forKey:check];
            if (![selector hasPrefix:@"init"]) sent++;
        }
        NSMutableArray *answered = [NSMutableArray array];
        for (NSArray *entry in entries)
            if ([types objectForKey:[NSString stringWithFormat:@"%@ %@%@", entry[0], entry[1], entry[2]]]) [answered addObject:entry];
        [self send:answered to:objects where:@"on the main thread"];
        __block BOOL done = NO;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self send:answered to:objects where:@"off the main thread"];
            done = YES;
        });
        // Some of them do their work on the main thread, which goes on serving its run loop.
        while (!done) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        [self keep:kept in:objects];
        [self measure:objects work:[NSString stringWithUTF8String:getenv("QA_LATER_SDK_WORK")]];
        counts = @{@"sent": @(sent), @"kept": @(kept.count / 2), @"objects": [[objects allKeys] sortedArrayUsingSelector:@selector(compare:)]};
    } @catch (NSException *exception) {
        note(@"the checks", [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
    }
    // The types of the methods that answer with those of the former SDK, as the classes have them.
    NSMutableDictionary *former = [NSMutableDictionary dictionary];
    for (NSArray *entry in [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:getenv("QA_LATER_SDK_DIVERGENT")]]) {
        Class class = NSClassFromString(entry[0]);
        Method method = [entry[1] isEqualToString:@"+"] ? class_getClassMethod(class, NSSelectorFromString(entry[2]))
                                                         : class_getInstanceMethod(class, NSSelectorFromString(entry[2]));
        if (method && method_getTypeEncoding(method))
            former[[NSString stringWithFormat:@"%@ %@%@", entry[0], entry[1], entry[2]]] = [NSString stringWithUTF8String:method_getTypeEncoding(method)];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"problems": problems, @"types": types, @"counts": counts, @"former": former}
                                                   options:NSJSONWritingSortedKeys error:NULL];
    [json writeToFile:[NSString stringWithUTF8String:getenv("QA_LATER_SDK_REPORT")] atomically:YES];
}

@end
'''


def build_plugin(folder):
    """QALaterSDK.osirixplugin in `folder`, built as a plugin of the SDK is."""
    bundle = folder / 'QALaterSDK.osirixplugin'
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    with open(bundle / 'Contents/Info.plist', 'wb') as handle:
        plistlib.dump({'CFBundleExecutable': 'QALaterSDK', 'CFBundleIdentifier': 'qa.later.sdk', 'CFBundleName': 'QALaterSDK',
                       'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1', 'NSPrincipalClass': 'QALaterSDK',
                       'pluginType': 'Database', 'MenuTitles': ['QA Later SDK']}, handle)
    source = folder / 'QALaterSDK.m'
    source.write_text(PLUGIN)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-bundle', '-undefined', 'dynamic_lookup', '-arch', 'arm64',
                            '-arch', 'x86_64', '-mmacosx-version-min=11.0', '-Wno-deprecated-declarations',
                            '-framework', 'Cocoa', '-framework', 'CoreData', str(source),
                            '-o', str(bundle / 'Contents/MacOS/QALaterSDK')], capture_output=True, text=True)
    if built.returncode:
        raise SystemExit('FAIL: the plugin does not build: ' + built.stderr[-2000:])
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], capture_output=True, check=True)
    return bundle


def entry_parts(entry):
    cls, rest = entry.split(' ', 1)
    return [cls, rest[0], rest[1:]]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--app', type=Path, default=native_app.DEVELOPMENT_APP)
    parser.add_argument('--log', type=Path, help='keep what the application wrote in this file')
    args = parser.parse_args()
    failures = []
    registered = json.loads(REGISTRY.read_text())['osirix_selectors']
    failures += [f'{entry}: in the fixture and not in osirix_selectors of the registry' for entry in sorted(set(TYPES) - set(registered))]
    failures += [f'{entry}: kept, and not among the types of the fixture' for entry in sorted(set(KEPT) - set(TYPES))]
    for failure in failures:
        print('FAIL: ' + failure)
    if failures:
        return 1
    if shutil.which('xcrun') is None or not (args.app / 'Contents/MacOS/IsiX DICOM Viewer').is_file():
        print(f'skipped: needs xcrun and a development bundle (script/build_and_run.sh --verify): --app {args.app}',
              file=sys.stderr)
        return 2
    outdated = native_app.outdated_bundle(args.app)
    if outdated:
        print(f'skipped: {outdated}', file=sys.stderr)
        return 2
    if native_app.running_development_pids(args.app):
        print(f'skipped: a development instance of {args.app} is running', file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='isix-later-sdk-') as folder:
        folder = Path(folder).resolve()
        bundle = build_plugin(folder)
        test_root, work, report = folder / 'root', folder / 'work', folder / 'report.json'
        work.mkdir()
        entries, kept, divergent = folder / 'entries.plist', folder / 'kept.plist', folder / 'divergent.plist'
        with open(divergent, 'wb') as handle:
            plistlib.dump([entry_parts(entry) for entry in sorted(DIVERGENT)], handle)
        with open(entries, 'wb') as handle:
            plistlib.dump([entry_parts(entry) for entry in sorted(TYPES)], handle)
        with open(kept, 'wb') as handle:
            plistlib.dump([entry_parts(entry) for entry in sorted(KEPT)], handle)
        log = folder / 'app.log'
        process = native_app.launch(test_root, log, ['--LoadPlugin', str(bundle)], app=args.app, environment={
            'QA_LATER_SDK_REPORT': str(report), 'QA_LATER_SDK_LIST': str(entries), 'QA_LATER_SDK_KEPT': str(kept),
            'QA_LATER_SDK_WORK': str(work), 'QA_LATER_SDK_DIVERGENT': str(divergent)})
        try:
            deadline = time.monotonic() + 180
            while not report.is_file() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.5)
            time.sleep(1)
        finally:
            ended = process.poll()
            native_app.stop(process)
        text = log.read_text(errors='replace')
        if args.log:
            args.log.write_text(text)
        if not report.is_file():
            lines = [line for line in text.splitlines() if 'QALaterSDK' in line or 'Plugin' in line
                     or 'unrecognized selector' in line or 'xception' in line or 'Fatal' in line]
            print(f'FAIL: the plugin wrote no report (the application ended: {ended}); the application said:\n  '
                  + '\n  '.join(lines[-12:])[-3000:])
            return 1
        found = json.loads(report.read_text())
    failures = [f'{check}: {problem}' for check, problem in sorted(found['problems'].items())]
    for entry, declared in sorted(TYPES.items()):
        answered = found['types'].get(entry)
        if answered is not None and declared is not None and without_offsets(answered) != declared:
            failures.append(f'{entry}: answers with the types {without_offsets(answered)}, the headers declare {declared}')
    for entry, recorded in sorted(DIVERGENT.items()):
        answered = found['former'].get(entry)
        if answered is None:
            failures.append(f'{entry}: recorded as answered with other types than later headers declare, and not answered')
        elif without_offsets(answered) != recorded['answers']:
            failures.append(f"{entry}: answers with the types {without_offsets(answered)}, recorded as {recorded['answers']} "
                            f"(later headers declare {recorded['declares']}): record the change in "
                            'tests/fixtures/later-sdk-type-divergences.json')
    if 'unrecognized selector' in text:
        failures.append('the application logged an unrecognized selector')
    for failure in failures:
        print('FAIL: ' + failure)
    if failures:
        return 1
    counts = found['counts']
    print(f"PASS: a plugin built with later headers of the plugin SDK is answered by the {len(found['types'])} selectors of "
          f"{len(counts['objects'])} objects it asks for, each with the argument and return types those headers declare; "
          f"{counts['sent']} of them were sent on the main thread and on a background thread, {counts['kept']} kept properties "
          f"came back as set, the measures of the ROIs are those of their shapes and of their image, and the "
          f"{len(DIVERGENT)} selectors the former SDK declares with other types keep those types")
    return 0


if __name__ == '__main__':
    sys.exit(main())
