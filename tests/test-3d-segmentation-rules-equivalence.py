#!/usr/bin/env python3
"""The rules of the calcium scoring, region growing and 3D windows decide what
the Objective-C classes decided.

CalciumScoringWindowController.m, ITKSegmentation3DController.m and
Window3DController.m became Swift window controllers, and their rules went to
the internal modules: CalciumScoring (IsiXROI), RegionGrowingParameters
(IsiXSegmentation) and ThreeDViewerPresets with ViewerPresetMenus
(IsiXImaging). This compiles, from the last revision that has the
Objective-C files, read from git:

- CalciumScoringWindowController's -initWithViewer:, -setCtType:,
  -setLowerThreshold:, -setRoiName:, -updateTotals and their setters, whole,
  on stand-in ROIs and a viewer; the colour chain and the overlap loop of
  -computeROIsWithName:addROIs:; -patientsAge on a stand-in date difference;
- the statements of ITKSegmentation3DController's -preview:, -compute: and
  -initWithViewer: that round the interval, name the previewed ROI, choose
  whether to preview, to merge and which slice, compute the resolution and
  check the parameters, and its tables of algorithms;
- Window3DController's -updateSetWLWW:, -SetWLWW: and -validateMenuItem:, on
  stand-in fields and menu items,

and runs them on the same generated cases as a Swift driver that calls the
modules as the Swift controllers call them. Both print every decision; the
outputs must be the same, in Debug (-O0 / -Onone) and Release (-Os / -O).

Exits 2 when the history does not reach a revision with the Objective-C files.

    python3 tests/test-3d-segmentation-rules-equivalence.py
"""
import json
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CALCIUM = 'Horos/Sources/CalciumScoringWindowController.m'
ITK = 'Horos/Sources/ITKSegmentation3DController.m'
WINDOW3D = 'Horos/Sources/Window3DController.m'

reference = history_reference.before_removal(CALCIUM)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{CALCIUM}'],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: no revision of this history has ' + CALCIUM, file=sys.stderr)
    raise SystemExit(2)


def old(path):
    return history_reference.show(reference, path).decode('latin1')


def method(text, signature):
    """The method whose declaration starts with `signature`, braces included."""
    at = text.index(signature)
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    raise ValueError(signature)


def braced(text, start):
    """The statement starting at `start` through its closing brace."""
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
    raise ValueError(start)


def replace_all(text, replacements):
    for before, after in replacements:
        if before not in text:
            raise SystemExit(f'FAIL: the reference no longer has {before!r}; this test needs a new look')
        text = text.replace(before, after)
    return text


calcium, itk, window3d = old(CALCIUM), old(ITK), old(WINDOW3D)

# --- the cases, shared by both programs -----------------------------------------------
rng = random.Random(1477)
VESSELS = ['Left Coronary Artery', 'Left Anterior Descending Artery', 'Left Circumflex Artery', 'Right Coronary Artery']
ROI_NAMES = VESSELS + ['left coronary artery', 'Plaque', 'Left Coronary Artery 2', 'Total', 'Right*', '']
NEW_NAMES = ['Plaque', 'Left*', '?ight Coronary Artery', 'Left Coronary Artery', 'Calcium', 'L*A*', 'Total', 'Plaque']


def real():
    return rng.choice([0.0, 1.0, 0.1, 1e-7, 3.25, 1234.5678, -2.5, rng.uniform(0, 500), rng.uniform(-50, 50)])


cases = {'calcium': [], 'colours': ROI_NAMES + ['Segmentation Preview', 'LEFT CORONARY ARTERY'], 'ages': [],
         'overlaps': [], 'intervals': [], 'names': [], 'resolutions': [], 'parameters': [],
         'wlww': [], 'menus': []}
for _ in range(60):
    rois = [{'name': rng.choice(ROI_NAMES), 'score': real(), 'mass': real(), 'volume': real()}
            for _ in range(rng.randrange(0, 12))]
    steps = [rng.choice([['ct', rng.choice([0, 1, 2, -1])], ['name', rng.choice(NEW_NAMES)], ['totals']])
             for _ in range(rng.randrange(1, 8))]
    cases['calcium'].append({'rois': rois, 'existing': rng.random() < 0.5, 'ctDefault': rng.choice([None, 0, 1, '1', 2]),
                             'steps': steps})
for years in (-1, 0, 1, 45, 2 ** 33):
    for months in (-2, 0, 3, 11):
        for days in (0, 5, 30):
            cases['ages'].append([years, months, days])
for _ in range(300):
    def pixels(n):
        values = [rng.choice([0.0, 0.0, 1.0, -3.0, 250.5]) for _ in range(n)]
        locations = [rng.choice([float(rng.randrange(0, 6)), rng.randrange(0, 6) + 0.75, -0.5, -1.25,
                                 float('nan') if rng.random() < 0.02 else 2.0, 3e9 if rng.random() < 0.02 else 4.0])
                     for _ in range(2 * n)]
        return values, locations
    a, b = pixels(rng.randrange(0, 9)), pixels(rng.randrange(0, 9))
    cases['overlaps'].append({'values': a[0], 'locations': a[1], 'newValues': b[0], 'newLocations': b[1]})
cases['intervals'] = [100.0, 1.23456, -1.23456, 0.0005, 0.0015, 2.5, 1e-9, 99999.9999, 3e6, 3e9, -3e9,
                      float('nan'), 0.1, 0.7, 1.0000001] + [rng.uniform(-1000, 1000) for _ in range(100)]
for from_viewer in (False, True):
    for tag in (0, 1, 2):
        for directly in (False, True):
            for preview in (False, True):
                for merge in (False, True):
                    for typed in ('Growing Region', '', 'Segmentation Preview'):
                        cases['names'].append({'fromViewer': from_viewer, 'tag': tag, 'directly': directly,
                                               'preview': preview, 'merge': merge, 'typed': typed,
                                               'preview3D': rng.random() < 0.5, 'current': rng.randrange(0, 40)})
cases['resolutions'] = [[m, v] for m in (0.0, 1.0, 10.0, 10.9, -3.5, 1e10) for v in (0, 1, 7, 10, -2)]
cases['parameters'] = [[], [''], ['1'], ['1', ''], ['', '2'], ['2.5', '5', '2'], [' '], ['0', '0', '']]
for _ in range(200):
    def number():
        return rng.choice(['40', '400', '-160', '0', '1e3', '12.5', '-0.25', 'abc', '', '3,5', str(rng.uniform(-3000, 3000))])
    cases['wlww'].append({'tag': rng.choice([0, 1]), 'wl': number(), 'ww': number(), 'from': number(), 'to': number(),
                          'getWL': rng.uniform(-2000, 2000), 'getWW': rng.choice([0.0, 1.0, rng.uniform(0, 4000)])})
ACTIONS = ['ApplyCLUT:', 'ApplyOpacity:', 'ApplyWLWW:', 'showCLUTOpacityPanel:', 'loadAdvancedCLUTOpacity:', 'noAction:',
           'print:', None]
TITLES = ['Bone', 'Linear Table', 'No CLUT', '1 - Bone', '12 - Abdomen', 'Abd', '', 'bone', 'Other']
for _ in range(400):
    cases['menus'].append({'action': rng.choice(ACTIONS), 'title': rng.choice(TITLES),
                           'clut': rng.choice([None, 'Bone', 'No CLUT', '']), 'opacity': rng.choice([None, 'Linear Table', 'Bone']),
                           'wlww': rng.choice([None, 'Bone', 'Abdomen', 'Other', '']), 'rgb': rng.choice([None, False, True])})

# --- the Objective-C of the reference -----------------------------------------------------
calcium_methods = '\n\n'.join(method(calcium, signature) for signature in (
    '- (id)initWithViewer:', '- (int)ctType{', '- (void)setCtType:', '- (int)lowerThreshold{', '- (void)setLowerThreshold:',
    '- (void)setUpperThreshold:', '- (NSString *)roiName{', '- (void)setRoiName:', '- (void)updateTotals{',
    '- (void)setTotalCalciumScore:', '- (void)setTotalCalciumMass:', '- (void)setTotalCalciumVolume:',
    '- (NSArray *)vessels{', '- (void)setVessels:', '- (NSArray *)vesselNames{', '- (void)setVesselNames:',
    '- (NSString *)patientsAge{'))
enum = re.search(r'enum ctTypes \{[^}]*\};', calcium).group()
compute = method(calcium, '- (void)computeROIsWithName:')
colour_at = compute.index('if ([[roi name] isEqualToString:NSLocalizedString(@"Left Coronary Artery", nil)])')
colours = compute[colour_at:compute.index('[roi setColor:aColor];', colour_at)]
overlap = braced(compute, compute.index('for( long i = 0; i < n; i++)'))

preview_body, compute_body = method(itk, '-(IBAction) preview:'), method(itk, '-(IBAction) compute:')
interval = re.search(r'int fd = f \* 1000\.;\s*f = fd / 1000\.;', preview_body).group()
naming = braced(preview_body, preview_body.index('if( sender == viewer)'))
naming = replace_all(naming, [('sender == viewer', 'fromViewer'), ('[[growingMode selectedCell] tag]', 'tag'),
                              ('[[NSUserDefaults standardUserDefaults] boolForKey: @"segmentationDirectlyGenerate"]', 'directly'),
                              ('[newName stringValue]', 'typed')])
previews = re.search(r'if\( \[\[NSUserDefaults standardUserDefaults\] boolForKey: @"previewGrowingRegion"\] == NO && .*?\) return;',
                     preview_body).group()
previews = replace_all(previews, [('[[NSUserDefaults standardUserDefaults] boolForKey: @"previewGrowingRegion"]', 'previewOn'),
                                  ('[[NSUserDefaults standardUserDefaults] boolForKey: @"segmentationDirectlyGenerate"]', 'directly'),
                                  (') return;', ') return NO;')])
merge = re.search(r'\(\[name isEqualToString: NSLocalizedString\( @"Segmentation Preview", nil\)\] \? NO : .*?\)\s*//',
                  preview_body).group()[:-2]
merge = replace_all(merge, [('[[NSUserDefaults standardUserDefaults] boolForKey: @"mergeWithExistingROIs"]', 'pref')])
preview_slice = re.search(r'if\( \[\[NSUserDefaults standardUserDefaults\] boolForKey: @"preview3DGrowingRegion"\] == NO \).*?slice = -1;',
                          preview_body, re.S).group()
preview_slice = replace_all(preview_slice, [('[[NSUserDefaults standardUserDefaults] boolForKey: @"preview3DGrowingRegion"]', 'preview3D'),
                                            ('[[viewer imageView] curImage]', 'current')])
compute_slice = re.search(r'if\( \[\[growingMode selectedCell\] tag\] == 1\)\s*\{\s*slice = -1;\s*\}\s*else slice = \[\[viewer imageView\] curImage\];',
                          compute_body).group()
compute_slice = replace_all(compute_slice, [('[[growingMode selectedCell] tag]', 'tag'), ('[[viewer imageView] curImage]', 'current')])
resolution = re.search(r'\(\(long\)\[roiResolution maxValue\] \+ 1\) - \[roiResolution intValue\]', preview_body).group()
provided = braced(compute_body, compute_body.index('for(p=0;p<[params numberOfRows]; p++)'))
init_body = method(itk, '- (id) initWithViewer:')
tables = '\n'.join(re.search(r'(%s = \[NSArray arrayWithObjects:.*?nil\];)' % name, init_body, re.S).group(1)
                   for name in ('algorithms', 'parameters', 'defaultsParameters', 'urlHelp'))
change = method(itk, '- (IBAction) changeAlgorithm:')
bound_keys = {case: re.findall(r'withKeyPath:@"values\.(\w+)"', body)
              for case, body in re.findall(r'case (\w+SegmentationType):(.*?)break;', change, re.S)}

update_wlww = method(window3d, '- (IBAction) updateSetWLWW:')
set_wlww = method(window3d, '- (IBAction) SetWLWW:')
validate = method(window3d, '- (BOOL)validateMenuItem:')

OBJC = r'''
#import <Cocoa/Cocoa.h>
#include <math.h>
static NSMutableDictionary *harnessDefaults;
@interface HarnessDefaults : NSObject
+ (HarnessDefaults *) standardUserDefaults;
@end
@implementation HarnessDefaults
+ (HarnessDefaults *) standardUserDefaults { return (HarnessDefaults *) harnessDefaults; }
@end
#define NSUserDefaults HarnessDefaults
static NSString *const OsirixMouseDownNotification = @"OsirixMouseDown";
static NSString *const HorosDrawObjectsCanvasNotification = @"HorosDrawObjectsCanvas";
static NSString *const OsirixRemoveROINotification = @"OsirixRemoveROI";
// RGBColor is QuickDraw's, from Cocoa.

static NSString *F(float value) { return [NSString stringWithFormat: @"%a", (double) value]; }

@interface ROI : NSObject
@property (copy) NSString *name;
@property NSUInteger identifier;
@property float baseScore, baseMass, baseVolume;
@property int threshold;
@end
@implementation ROI
- (NSUInteger) hash { return self.identifier; }
- (BOOL) isEqual: (id) other { return self == other; }
- (void) setCalciumThreshold: (int) t { self.threshold = t; }
- (float) calciumScore { return self.baseScore * (float) self.threshold / 100.f; }
- (float) calciumMass { return self.baseMass + (float) self.threshold; }
- (float) calciumVolume { return self.baseVolume; }
@end

@interface Viewer : NSObject
@property (retain) NSArray *rois;
@property (retain) NSDictionary *study;
@end
@implementation Viewer
- (NSArray *) roisWithName: (NSString *) name
{
    NSMutableArray *found = [NSMutableArray array];
    for (ROI *roi in self.rois) if ([roi.name isEqualToString: name]) [found addObject: roi];
    return found;
}
- (id) currentStudy { return self.study; }
@end
typedef Viewer ViewerController;

static NSInteger ageYears, ageMonths, ageDays;
@interface Horos : NSObject
@end
@implementation Horos
+ (void):(NSDate *)date years:(NSInteger *)years months:(NSInteger *)months days:(NSInteger *)days hours:(NSInteger *)hours
  minutes:(NSInteger *)minutes seconds:(NSInteger *)seconds sinceDate:(NSDate *)sinceDate
{
    *years = ageYears; *months = ageMonths; *days = ageDays;
}
@end

ENUM

@interface OldCalcium : NSWindowController
{
    ViewerController *_viewer, *_resultsViewer;
    int _ctType, _lowerThreshold, _upperThreshold;
    NSMutableSet *_rois;
    NSString *_roiName;
    float _totalCalciumScore, _totalCalciumMass, _totalCalciumVolume;
    NSArray *_vessels, *_vesselNames;
}
- (void) updateTotals;
- (void) setLowerThreshold: (int) t;
- (void) setUpperThreshold: (int) t;
- (void) setCtType: (int) t;
- (void) setRoiName: (NSString *) n;
- (void) setVessels: (NSArray *) v;
- (void) setVesselNames: (NSArray *) v;
- (void) setTotalCalciumScore: (float) v;
- (void) setTotalCalciumMass: (float) v;
- (void) setTotalCalciumVolume: (float) v;
- (float) totalCalciumScore;
- (float) totalCalciumMass;
- (float) totalCalciumVolume;
@end
@implementation OldCalcium
CALCIUM_METHODS
- (float) totalCalciumScore { return _totalCalciumScore; }
- (float) totalCalciumMass { return _totalCalciumMass; }
- (float) totalCalciumVolume { return _totalCalciumVolume; }
- (NSString *) state
{
    NSMutableString *s = [NSMutableString stringWithFormat: @"lower=%d upper=%d ct=%d name=%@ names=%@ rows=", _lowerThreshold,
                          _upperThreshold, _ctType, _roiName, [_vesselNames componentsJoinedByString: @"|"]];
    for (NSDictionary *row in _vessels)
        [s appendFormat: @"[%@ %@ %@ %@]", row[@"vesselName"], F([row[@"score"] floatValue]), F([row[@"mass"] floatValue]),
                         F([row[@"volume"] floatValue])];
    [s appendFormat: @" totals=%@ %@ %@ defaults=%@", F(_totalCalciumScore), F(_totalCalciumMass), F(_totalCalciumVolume),
                     harnessDefaults[@"CalciumScoreCTType"]];
    return s;
}
@end

static RGBColor oldColour(ROI *roi)
{
    RGBColor aColor;
    COLOURS
    return aColor;
}

static BOOL oldOverlap(float *nRV, float *l, long n, float *newRoiValues, float *locations, long numberOfValues)
{
    BOOL intersect = NO;
    OVERLAP
    return intersect;
}

static float oldInterval(float f) { INTERVAL return f; }
static NSString *oldName(BOOL fromViewer, NSInteger tag, BOOL directly, NSString *typed)
{
    NSString *name = NSLocalizedString( @"Segmentation Preview", nil);
    NAMING
    return name;
}
static BOOL oldPreviews(BOOL previewOn, BOOL directly) { PREVIEWS return YES; }
static BOOL oldMerge(NSString *name, BOOL pref) { return MERGE; }
static long oldPreviewSlice(BOOL preview3D, short current) { long slice; PREVIEW_SLICE return slice; }
static long oldComputeSlice(NSInteger tag, short current) { long slice; COMPUTE_SLICE return slice; }
@interface Slider : NSObject { @public double max; int value; }
@end
@implementation Slider
- (double) maxValue { return max; }
- (int) intValue { return value; }
@end
static long oldResolution(Slider *roiResolution) { return RESOLUTION; }
@interface Form : NSObject { @public NSArray *values; }
@end
@implementation Form
- (NSInteger) numberOfRows { return values.count; }
- (id) cellAtRow: (NSInteger) row column: (NSInteger) column { return [[[NSTextField alloc] init] autorelease]; }
@end
@interface FormCell : NSObject { @public NSString *value; }
@end
@implementation FormCell
- (NSString *) stringValue { return value; }
@end
@interface ParamsForm : NSObject { @public NSArray *values; }
@end
@implementation ParamsForm
- (NSInteger) numberOfRows { return values.count; }
- (id) cellAtRow: (NSInteger) row column: (NSInteger) column { FormCell *c = [[[FormCell alloc] init] autorelease]; c->value = values[row]; return c; }
@end
static BOOL oldProvided(ParamsForm *params) { BOOL parametersProvided = YES; int p; PROVIDED return parametersProvided; }
static void oldTables(void)
{
    NSArray *algorithms, *parameters, *defaultsParameters, *urlHelp;
    TABLES
    for (NSUInteger i = 0; i < parameters.count; i++)
        printf("algorithm %lu count=%lu defaults=%s url=%s\n", (unsigned long) i, (unsigned long) [parameters[i] count],
               [[defaultsParameters[i] componentsJoinedByString: @"|"] UTF8String], [urlHelp[i] UTF8String]);
}

// The window level sheet's text, the same in both programs.
@interface HorosWindowLevelText : NSObject
@end
@implementation HorosWindowLevelText
+ (NSString *) stringForValue: (double) v { return [NSString stringWithFormat: @"%.9g", v]; }
+ (double) valueFromString: (NSString *) s fallback: (double) f
{
    char *end = NULL; const char *c = s.UTF8String; double v = strtod(c, &end);
    return (end == c || *end != 0 || !isfinite(v)) ? f : v;
}
+ (double) widthFromString: (NSString *) s fallback: (double) f { double v = [self valueFromString: s fallback: f]; return v == 0 ? 1 : v; }
@end
@interface Field : NSObject { @public NSString *text; }
@end
@implementation Field
- (NSString *) stringValue { return text; }
- (void) setStringValue: (NSString *) s { [text release]; text = [s copy]; }
@end
@interface Sender : NSObject { @public NSInteger tag; }
@end
@implementation Sender
- (NSInteger) tag { return tag; }
@end
@interface Pix : NSObject { @public BOOL rgb; }
@end
@implementation Pix
- (BOOL) isRGB { return rgb; }
@end
@interface OldWindow3D : NSObject
{
    Field *wlset, *wwset, *fromset, *toset;
    NSWindow *setWLWWWindow;
    NSString *curWLWWMenu, *curCLUTMenu, *curOpacityMenu;
    NSArray *pixListValue;
    float getWL, getWW;
    @public NSMutableString *log;
}
@end
@interface OldWindow3D (Selectors)
- (void) ApplyCLUT: (id) s; - (void) ApplyOpacity: (id) s; - (void) ApplyWLWW: (id) s;
- (void) showCLUTOpacityPanel: (id) s; - (void) loadAdvancedCLUTOpacity: (id) s; - (void) noAction: (id) s;
@end
static float oldsetww, oldsetwl;
@implementation OldWindow3D
- (instancetype) init
{
    self = [super init];
    wlset = [Field new]; wwset = [Field new]; fromset = [Field new]; toset = [Field new];
    log = [NSMutableString new];
    return self;
}
- (void) setWLWW: (float) wl : (float) ww { [log appendFormat: @"setWLWW %@ %@; ", F(wl), F(ww)]; }
- (void) getWLWW: (float *) wl : (float *) ww { *wl = getWL; *ww = getWW; }
- (NSWindow *) window { return nil; }
- (NSArray *) pixList { return pixListValue; }
UPDATE_WLWW
SET_WLWW
VALIDATE
- (NSString *) fields { return [NSString stringWithFormat: @"%@ %@ %@ %@", wlset->text, wwset->text, fromset->text, toset->text]; }
@end

int main(int argc, char **argv) { @autoreleasepool {
    harnessDefaults = [NSMutableDictionary dictionary];
    NSDictionary *cases = [NSJSONSerialization JSONObjectWithData: [NSData dataWithContentsOfFile: @(argv[1])] options: 0 error: NULL];

    for (NSDictionary *c in cases[@"calcium"]) {
        [harnessDefaults removeAllObjects];
        if (c[@"ctDefault"] != [NSNull null]) harnessDefaults[@"CalciumScoreCTType"] = c[@"ctDefault"];
        NSMutableArray *rois = [NSMutableArray array];
        NSUInteger identifier = 1;
        for (NSDictionary *r in c[@"rois"]) {
            ROI *roi = [[ROI new] autorelease];
            roi.name = r[@"name"]; roi.identifier = identifier++;
            roi.baseScore = [r[@"score"] floatValue]; roi.baseMass = [r[@"mass"] floatValue]; roi.baseVolume = [r[@"volume"] floatValue];
            [rois addObject: roi];
        }
        Viewer *viewer = [[Viewer new] autorelease];
        viewer.rois = [c[@"existing"] boolValue] ? rois : @[];
        OldCalcium *w = [[OldCalcium alloc] initWithViewer: (id) viewer];
        [[NSNotificationCenter defaultCenter] removeObserver: w];
        NSMutableSet *set = [w valueForKey: @"_rois"];
        if (![c[@"existing"] boolValue]) [set addObjectsFromArray: rois];
        printf("init %s\n", [w state].UTF8String);
        for (NSArray *step in c[@"steps"]) {
            if ([step[0] isEqual: @"ct"]) [w setCtType: [step[1] intValue]];
            else if ([step[0] isEqual: @"name"]) [w setRoiName: step[1]];
            else [w updateTotals];
            printf("%s %s\n", [step[0] UTF8String], [w state].UTF8String);
        }
    }
    for (NSString *name in cases[@"colours"]) {
        ROI *roi = [[ROI new] autorelease]; roi.name = name;
        RGBColor c = oldColour(roi);
        printf("colour %s %u %u %u\n", name.UTF8String, c.red, c.green, c.blue);
    }
    {
        OldCalcium *w = [[OldCalcium alloc] initWithViewer: nil];
        [[NSNotificationCenter defaultCenter] removeObserver: w];
        Viewer *viewer = [[Viewer new] autorelease];
        [w setValue: viewer forKey: @"_viewer"];
        viewer.study = @{@"dateOfBirth": [NSDate dateWithTimeIntervalSinceReferenceDate: 0], @"date": [NSDate date]};
        for (NSArray *a in cases[@"ages"]) {
            ageYears = [a[0] longLongValue]; ageMonths = [a[1] longLongValue]; ageDays = [a[2] longLongValue];
            printf("age %s\n", [[w valueForKey: @"patientsAge"] UTF8String]);
        }
        viewer.study = @{@"date": [NSDate date]};
        printf("age without birth date %s\n", [[w valueForKey: @"patientsAge"] description].UTF8String);
    }
    for (NSDictionary *o in cases[@"overlaps"]) {
        NSArray *v = o[@"values"], *l = o[@"locations"], *nv = o[@"newValues"], *nl = o[@"newLocations"];
        float a[16], b[32], c[16], d[32];
        for (NSUInteger i = 0; i < v.count; i++) a[i] = [v[i] floatValue];
        for (NSUInteger i = 0; i < l.count; i++) b[i] = [l[i] isKindOfClass: [NSNumber class]] ? [l[i] floatValue] : NAN;
        for (NSUInteger i = 0; i < nv.count; i++) c[i] = [nv[i] floatValue];
        for (NSUInteger i = 0; i < nl.count; i++) d[i] = [nl[i] isKindOfClass: [NSNumber class]] ? [nl[i] floatValue] : NAN;
        printf("overlap %d\n", oldOverlap(a, b, v.count, c, d, nv.count));
    }
    for (id value in cases[@"intervals"])
        printf("interval %s\n", F(oldInterval([value isKindOfClass: [NSNumber class]] ? [value floatValue] : NAN)).UTF8String);
    for (NSDictionary *n in cases[@"names"]) {
        NSString *name = oldName([n[@"fromViewer"] boolValue], [n[@"tag"] integerValue], [n[@"directly"] boolValue], n[@"typed"]);
        printf("name %s previews=%d merge=%d previewSlice=%ld computeSlice=%ld\n", name.UTF8String,
               oldPreviews([n[@"preview"] boolValue], [n[@"directly"] boolValue]), oldMerge(name, [n[@"merge"] boolValue]),
               oldPreviewSlice([n[@"preview3D"] boolValue], [n[@"current"] shortValue]),
               oldComputeSlice([n[@"tag"] integerValue], [n[@"current"] shortValue]));
    }
    for (NSArray *r in cases[@"resolutions"]) {
        Slider *s = [[Slider new] autorelease]; s->max = [r[0] doubleValue]; s->value = [r[1] intValue];
        printf("resolution %ld\n", oldResolution(s));
    }
    for (NSArray *p in cases[@"parameters"]) {
        ParamsForm *f = [[ParamsForm new] autorelease]; f->values = p;
        printf("provided %d\n", oldProvided(f));
    }
    oldTables();
    for (NSDictionary *w in cases[@"wlww"]) {
        OldWindow3D *o = [[OldWindow3D new] autorelease];
        [o setValue: @([w[@"getWL"] floatValue]) forKey: @"getWL"];
        [o setValue: @([w[@"getWW"] floatValue]) forKey: @"getWW"];
        [o SetWLWW: nil];
        printf("set %s | %s\n", [o fields].UTF8String, o->log.UTF8String);
        Field *f;
        f = [o valueForKey: @"wlset"]; [f setStringValue: w[@"wl"]]; f = [o valueForKey: @"wwset"]; [f setStringValue: w[@"ww"]];
        f = [o valueForKey: @"fromset"]; [f setStringValue: w[@"from"]]; f = [o valueForKey: @"toset"]; [f setStringValue: w[@"to"]];
        Sender *s = [[Sender new] autorelease]; s->tag = [w[@"tag"] integerValue];
        [o updateSetWLWW: s];
        printf("update %s | %s\n", [o fields].UTF8String, o->log.UTF8String);
    }
    for (NSDictionary *m in cases[@"menus"]) {
        OldWindow3D *o = [[OldWindow3D new] autorelease];
        if (m[@"clut"] != [NSNull null]) [o setValue: m[@"clut"] forKey: @"curCLUTMenu"];
        if (m[@"opacity"] != [NSNull null]) [o setValue: m[@"opacity"] forKey: @"curOpacityMenu"];
        if (m[@"wlww"] != [NSNull null]) [o setValue: m[@"wlww"] forKey: @"curWLWWMenu"];
        if (m[@"rgb"] != [NSNull null]) { Pix *p = [[Pix new] autorelease]; p->rgb = [m[@"rgb"] boolValue]; [o setValue: @[p] forKey: @"pixListValue"]; }
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: m[@"title"]
                                                      action: m[@"action"] == [NSNull null] ? NULL : NSSelectorFromString(m[@"action"])
                                               keyEquivalent: @""] autorelease];
        BOOL valid = [o validateMenuItem: item];
        printf("menu %d %ld\n", valid, (long) item.state);
    }
    return 0;
} }
'''

objc = OBJC
for key, value in (('ENUM', enum), ('CALCIUM_METHODS', calcium_methods), ('COLOURS', colours), ('OVERLAP', overlap),
                   ('INTERVAL', interval), ('NAMING', naming), ('PREVIEWS', previews), ('MERGE', merge),
                   ('PREVIEW_SLICE', preview_slice), ('COMPUTE_SLICE', compute_slice), ('RESOLUTION', resolution),
                   ('PROVIDED', provided), ('TABLES', tables), ('UPDATE_WLWW', update_wlww), ('SET_WLWW', set_wlww),
                   ('VALIDATE', validate)):
    objc = objc.replace(key, value, 1)
objc = objc.replace('[[NSUserDefaults standardUserDefaults] objectForKey:@"CalciumScoreCTType"]',
                    '[harnessDefaults objectForKey:@"CalciumScoreCTType"]')
objc = objc.replace('[[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInt:_ctType] forKey:@"CalciumScoreCTType"]',
                    '[harnessDefaults setObject:[NSNumber numberWithInt:_ctType] forKey:@"CalciumScoreCTType"]')
objc = objc.replace('NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];', '')
objc = objc.replace('[userDefaults objectForKey:@"CalciumScoreCTType"]', '[harnessDefaults objectForKey:@"CalciumScoreCTType"]')
objc = objc.replace('[[self window] beginSheet:setWLWWWindow completionHandler:nil];', '')

SWIFT = r'''
import Cocoa

func F(_ value: Float) -> String { String(format: "%a", Double(value)) }

final class ROI: NSObject {
    @objc dynamic var name: String?
    var identifier = 0
    var baseScore: Float = 0, baseMass: Float = 0, baseVolume: Float = 0
    var threshold: Int32 = 0
    override var hash: Int { identifier }
    override func isEqual(_ object: Any?) -> Bool { self === (object as AnyObject?) }
    func calciumScore() -> Float { baseScore * Float(threshold) / 100 }
    func calciumMass() -> Float { baseMass + Float(threshold) }
    func calciumVolume() -> Float { baseVolume }
}

/// The window's state and the calls the Swift controller makes, on the modules.
final class Calcium {
    var defaults: NSMutableDictionary
    var ctType: Int32 = 0, lowerThreshold: Int32 = 0, upperThreshold: Int32 = 0
    var rois = NSMutableSet()
    var roiName: String?
    var vessels: NSArray = NSMutableArray(), vesselNames: NSArray = NSArray()
    var totals = CalciumScoreSums.zero

    init(viewerROIs: [ROI]?, defaults: NSMutableDictionary) {
        self.defaults = defaults
        upperThreshold = CalciumScoringScanner.defaultUpperThreshold
        setCtType(objcIntValue(defaults[CalciumScoringScanner.defaultsKey]))
        let names = ["Left Coronary Artery", "Left Anterior Descending Artery", "Left Circumflex Artery", "Right Coronary Artery"]
        vesselNames = names as NSArray
        let rows = NSMutableArray()
        vessels = rows
        for name in names {
            rows.add(CalciumScoringVessels.row(name: name))
            rois.addObjects(from: (viewerROIs ?? []).filter { ($0.name as NSString?)?.isEqual(to: name) ?? false })
        }
        rows.add(CalciumScoringVessels.row(name: "Total"))
        setRoiName("Left Coronary Artery")
    }

    func setCtType(_ value: Int32) {
        ctType = value
        if let lower = CalciumScoringScanner.lowerThreshold(ctType: value) { lowerThreshold = lower }
        defaults[CalciumScoringScanner.defaultsKey] = NSNumber(value: value)
        updateTotals()
    }

    func setRoiName(_ name: String) {
        roiName = name
        if !CalciumScoringVessels.contains(vesselNames as? [String] ?? [], name: name) {
            vesselNames = vesselNames.adding(name) as NSArray
            let rowNames = vessels.compactMap { ($0 as AnyObject).value(forKey: "vesselName") as? String }
            if let index = CalciumScoringVessels.insertionIndex(forName: name, rowNames: rowNames) {
                let copy = NSMutableArray(array: vessels)
                copy.insert(CalciumScoringVessels.row(name: name), at: index)
                vessels = copy
            }
        }
    }

    func updateTotals() {
        let rows = (vessels as? [NSMutableDictionary]) ?? []
        let rowNames = rows.map { $0.object(forKey: "vesselName") as? String ?? "" }
        let allROIs = rois.allObjects as NSArray
        let threshold = lowerThreshold
        let result = CalciumScoreTotals.compute(rowNames: rowNames, totalName: "Total") { vesselName in
            allROIs.filtered(using: NSPredicate(format: "name like %@", vesselName)).compactMap { $0 as? ROI }.map { roi in
                roi.threshold = threshold
                return CalciumScoreSums(score: roi.calciumScore(), mass: roi.calciumMass(), volume: roi.calciumVolume())
            }
        }
        for (row, sums) in zip(rows, result.rows) {
            guard let sums else { continue }
            row.setValue(NSNumber(value: sums.score), forKey: "score")
            row.setValue(NSNumber(value: sums.mass), forKey: "mass")
            row.setValue(NSNumber(value: sums.volume), forKey: "volume")
        }
        if let total = result.total { totals = total }
    }

    var state: String {
        var s = "lower=\(lowerThreshold) upper=\(upperThreshold) ct=\(ctType) name=\(roiName ?? "(null)") names=\((vesselNames as? [String] ?? []).joined(separator: "|")) rows="
        for case let row as NSDictionary in vessels {
            s += "[\(row["vesselName"] as? String ?? "") \(F((row["score"] as? NSNumber)?.floatValue ?? 0)) \(F((row["mass"] as? NSNumber)?.floatValue ?? 0)) \(F((row["volume"] as? NSNumber)?.floatValue ?? 0))]"
        }
        s += " totals=\(F(totals.score)) \(F(totals.mass)) \(F(totals.volume)) defaults=\(defaults[CalciumScoringScanner.defaultsKey].map { "\($0)" } ?? "(null)")"
        return s
    }
}

func objcIntValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    return (value as? NSString)?.intValue ?? 0
}

func text(_ v: Double) -> String { String(format: "%.9g", v) }
func strtodValue(_ s: String) -> Double? {
    return s.withCString { c -> Double? in
        var end: UnsafeMutablePointer<CChar>?
        let v = strtod(c, &end)
        if end == UnsafeMutablePointer(mutating: c) || end?.pointee != 0 || !v.isFinite { return nil }
        return v
    }
}
func width(_ s: String, _ fallback: Double) -> Double { let v = strtodValue(s) ?? fallback; return v == 0 ? 1 : v }

let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! NSDictionary

for case let c as NSDictionary in cases["calcium"] as! NSArray {
    let defaults = NSMutableDictionary()
    if !(c["ctDefault"] is NSNull) { defaults["CalciumScoreCTType"] = c["ctDefault"] }
    var rois: [ROI] = []
    for case let r as NSDictionary in c["rois"] as! NSArray {
        let roi = ROI()
        roi.name = r["name"] as? String
        roi.identifier = rois.count + 1
        roi.baseScore = (r["score"] as! NSNumber).floatValue
        roi.baseMass = (r["mass"] as! NSNumber).floatValue
        roi.baseVolume = (r["volume"] as! NSNumber).floatValue
        rois.append(roi)
    }
    let existing = (c["existing"] as! NSNumber).boolValue
    let w = Calcium(viewerROIs: existing ? rois : [], defaults: defaults)
    if !existing { w.rois.addObjects(from: rois) }
    print("init \(w.state)")
    for case let step as NSArray in c["steps"] as! NSArray {
        switch step[0] as! String {
        case "ct": w.setCtType((step[1] as! NSNumber).int32Value)
        case "name": w.setRoiName(step[1] as! String)
        default: w.updateTotals()
        }
        print("\(step[0]) \(w.state)")
    }
}
for case let name as String in cases["colours"] as! NSArray {
    let c = CalciumScoringColor.color(roiName: name, leftCoronary: "Left Coronary Artery", leftAnteriorDescending: "Left Anterior Descending Artery",
                                      leftCircumflex: "Left Circumflex Artery", rightCoronary: "Right Coronary Artery")
    print("colour \(name) \(c.red) \(c.green) \(c.blue)")
}
for case let a as NSArray in cases["ages"] as! NSArray {
    print("age \(CalciumScoringReport.age(years: (a[0] as! NSNumber).intValue, months: (a[1] as! NSNumber).intValue, days: (a[2] as! NSNumber).intValue))")
}
print("age without birth date (null)")
func floats(_ value: Any?) -> [Float] {
    (value as! NSArray).map { ($0 as? NSNumber)?.floatValue ?? .nan }
}
for case let o as NSDictionary in cases["overlaps"] as! NSArray {
    let v = floats(o["values"]), l = floats(o["locations"]), nv = floats(o["newValues"]), nl = floats(o["newLocations"])
    let result = v.withUnsafeBufferPointer { v in l.withUnsafeBufferPointer { l in nv.withUnsafeBufferPointer { nv in
        nl.withUnsafeBufferPointer { nl in CalciumScoringOverlap.intersects(values: v, locations: l, newValues: nv, newLocations: nl) } } } }
    print("overlap \(result ? 1 : 0)")
}
for value in cases["intervals"] as! NSArray {
    print("interval \(F(RegionGrowingRules.roundedInterval((value as? NSNumber)?.floatValue ?? .nan)))")
}
for case let n as NSDictionary in cases["names"] as! NSArray {
    let b = { (key: String) in (n[key] as! NSNumber).boolValue }
    let tag = (n["tag"] as! NSNumber).intValue, current = (n["current"] as! NSNumber).intValue
    let name = RegionGrowingRules.previewROIName(fromViewerClick: b("fromViewer"), growingModeTag: tag, directlyGenerate: b("directly"),
                                                 typedName: n["typed"] as! String, previewName: "Segmentation Preview")
    let previews = RegionGrowingRules.previews(previewGrowingRegion: b("preview"), directlyGenerate: b("directly"))
    let merge = RegionGrowingRules.mergesExistingROIs(name: name, previewName: "Segmentation Preview", preference: b("merge"))
    print("name \(name) previews=\(previews ? 1 : 0) merge=\(merge ? 1 : 0) previewSlice=\(RegionGrowingRules.previewSlice(preview3D: b("preview3D"), currentImage: current)) computeSlice=\(RegionGrowingRules.computeSlice(growingModeTag: tag, currentImage: current))")
}
for case let r as NSArray in cases["resolutions"] as! NSArray {
    print("resolution \(RegionGrowingRules.roiResolution(sliderMaxValue: (r[0] as! NSNumber).doubleValue, sliderValue: (r[1] as! NSNumber).int32Value))")
}
for case let p as [String] in cases["parameters"] as! NSArray {
    print("provided \(RegionGrowingRules.parametersProvided(p) ? 1 : 0)")
}
for algorithm in RegionGrowingAlgorithm.allCases {
    print("algorithm \(algorithm.rawValue) count=\(algorithm.parameterCount) defaults=\(algorithm.defaultValues.joined(separator: "|")) url=\(algorithm.helpURL)")
}
for case let w as NSDictionary in cases["wlww"] as! NSArray {
    var log = ""
    let getWL = (w["getWL"] as! NSNumber).floatValue, getWW = (w["getWW"] as! NSNumber).floatValue
    var range = ThreeDWindowLevelSheet.range(level: getWL, width: getWW)
    var fields = [text(Double(getWL)), text(Double(getWW)), text(Double(range.from)), text(Double(range.to))]
    print("set \(fields.joined(separator: " ")) | \(log)")
    fields = [w["wl"] as! String, w["ww"] as! String, w["from"] as! String, w["to"] as! String]
    if (w["tag"] as! NSNumber).intValue == 0 {
        let level = Float(strtodValue(fields[0]) ?? 0), wid = Float(width(fields[1], 1))
        log += "setWLWW \(F(level)) \(F(wid)); "
        range = ThreeDWindowLevelSheet.range(level: level, width: wid)
        fields[2] = text(Double(range.from)); fields[3] = text(Double(range.to))
    } else {
        let from = Float(strtodValue(fields[2]) ?? 0), to = Float(strtodValue(fields[3]) ?? 0)
        let lw = ThreeDWindowLevelSheet.levelAndWidth(from: from, to: to)
        log += "setWLWW \(F(lw.level)) \(F(lw.width)); "
        fields[0] = text(Double(lw.level)); fields[1] = text(Double(lw.width))
    }
    print("update \(fields.joined(separator: " ")) | \(log)")
}
for case let m as NSDictionary in cases["menus"] as! NSArray {
    let clut = m["clut"] as? String, opacity = m["opacity"] as? String, wlww = m["wlww"] as? String
    let title = m["title"] as! String
    var state = 0
    let valid: Bool
    switch m["action"] as? String {
    case "ApplyCLUT:": state = ThreeDPresetMenus.checksItem(title: title, current: clut) ? 1 : 0; valid = true
    case "ApplyOpacity:": state = ThreeDPresetMenus.checksItem(title: title, current: opacity) ? 1 : 0; valid = true
    case "ApplyWLWW:": state = ViewerPresetMenus.checksWLWWItem(title: title, current: wlww) ? 1 : 0; valid = true
    case "showCLUTOpacityPanel:", "loadAdvancedCLUTOpacity:": valid = !((m["rgb"] as? NSNumber)?.boolValue ?? false)
    case "noAction:": valid = false
    default: valid = true
    }
    print("menu \(valid ? 1 : 0) \(state)")
}
'''

CONFIGURATIONS = {'Debug': (['-O0'], ['-Onone']), 'Release': (['-Os'], ['-O'])}
MODULE_SOURCES = ['Modules/IsiXROI/Sources/CalciumScoring.swift',
                  'Modules/IsiXSegmentation/Sources/RegionGrowingParameters.swift',
                  'Modules/IsiXImaging/Sources/ViewerReconstruction/ThreeDViewerPresets.swift',
                  'Modules/IsiXImaging/Sources/ViewerMenus/ViewerMenus.swift']

failures = []
lines = 0
with tempfile.TemporaryDirectory(prefix='horos-3d-segmentation-rules-') as name:
    work = Path(name)
    # NaN goes as null, which both programs read as NaN.
    def plain(value):
        if isinstance(value, float) and value != value:
            return None
        if isinstance(value, list):
            return [plain(v) for v in value]
        if isinstance(value, dict):
            return {k: plain(v) for k, v in value.items()}
        return value
    (work / 'cases.json').write_text(json.dumps(plain(cases), allow_nan=False))
    (work / 'old.m').write_text(objc, encoding='latin1')
    (work / 'main.swift').write_text(SWIFT)
    for configuration, (clang_flags, swift_flags) in CONFIGURATIONS.items():
        built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-w', *clang_flags, str(work / 'old.m'),
                                '-framework', 'Cocoa', '-o', str(work / f'old-{configuration}')], capture_output=True, text=True)
        if built.returncode:
            sys.stderr.write(built.stderr[-4000:])
            raise SystemExit(f'FAIL: the reference code of {reference[:12]} does not compile')
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *swift_flags, str(work / 'main.swift'),
                                *[str(ROOT / source) for source in MODULE_SOURCES], '-o', str(work / f'new-{configuration}')],
                               capture_output=True, text=True)
        if built.returncode:
            sys.stderr.write(built.stderr[-4000:])
            raise SystemExit('FAIL: the modules do not compile with the driver')
        former = subprocess.run([str(work / f'old-{configuration}'), str(work / 'cases.json')], capture_output=True,
                                text=True, timeout=60)
        current = subprocess.run([str(work / f'new-{configuration}'), str(work / 'cases.json')], capture_output=True,
                                 text=True, timeout=60)
        if former.returncode or current.returncode:
            for label, run in (('Objective-C', former), ('Swift', current)):
                quiet = '\n'.join(line for line in run.stderr.splitlines() if 'set Lower Threshold' not in line)
                sys.stderr.write(f'{label} exit {run.returncode}:\n{quiet[-2000:]}\n{run.stdout[-500:]}\n')
            raise SystemExit(f'FAIL: a {configuration} program stopped')
        lines = len(former.stdout.splitlines())
        if former.stdout != current.stdout:
            for a, b in zip(former.stdout.splitlines(), current.stdout.splitlines()):
                if a != b:
                    print(f'{configuration} Objective-C:', a)
                    print(f'{configuration} Swift:      ', b)
                    break
            failures.append(f'{configuration}: the modules do not decide what the Objective-C of {reference[:12]} decided')

# The preferences each algorithm's fields are bound to.
CASES = {'intervalSegmentationType': 'interval', 'thresholdSegmentationType': 'threshold',
         'neighborhoodSegmentationType': 'neighborhood', 'confidenceSegmentationType': 'confidence'}
module = (ROOT / 'Modules/IsiXSegmentation/Sources/RegionGrowingParameters.swift').read_text()
for case, keys in bound_keys.items():
    swift_keys = re.search(r'case \.%s: return \[(.*?)\]' % CASES[case], module[module.index('parameterDefaultsKeys'):])
    if swift_keys is None or re.findall(r'"(\w+)"', swift_keys.group(1)) != keys:
        failures.append(f'the fields of {case} are not bound to {keys}')
if len(bound_keys) != 4:
    failures.append('the reference does not bind four algorithms; this test needs a new look')

for failure in failures:
    print('FAIL:', failure)
if failures:
    raise SystemExit(1)
print(f'PASS: calcium scoring, region growing and 3D window rules decide as the Objective-C of {reference[:12]} '
      f'({lines} decisions, Debug and Release)')
