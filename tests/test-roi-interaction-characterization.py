#!/usr/bin/env python3
"""A ROI is drawn, picked, moved, resized and labelled as it was before its
class left Objective-C.

Every kind of ROI (length, arrow, angle, dynamic angle, axis, TAGT, oval,
rectangle, open and closed polygons, pencil, text, 2D point, brush, layer and
the patient-space length) goes through what the viewer does with it: it is
created with the mouse, completed, picked by its outline, its handles and its
label, moved, dragged by a handle (with and without the constraint keys),
rotated, resized, flipped, its points added and deleted, hidden, locked and
made unselectable. After each step the probe records the ROI's state (its
mode, points, rectangle, texture, selected handle, label lines and offset),
what each call answered, the change notifications it posted, and a picture:
the ROI drawn by the canvas and its label laid out and written by the view's
text overlay, composited as captures composite them, in every mode it can be
drawn in.

Two harnesses run the same probe: the revision before the ROI became Swift,
read from git, and this checkout, both linked with the application's own
canvas, overlay and label layout (see tests/roi_harness.py). Each runs it under
two sets of preferences (spline outlines, Cobb angles, label boxes, labels
only when selected, the brush's edge, the oval's centre). Every value and
every picture must be the same; pictures are compared by a hash of their
pixels, and `--dump DIR` writes them as PPM files for a difference to be seen.

`<git revision>` compares with that revision instead. Needs a Debug build of
this checkout (HOROS_TEST_CONFIGURATION=Release for a Release one) and a
window server session, for the overlay's view; without either it is skipped.

`--harnesses DIR [revision]` only builds the two harnesses into DIR/reference
and DIR/current, for a timing campaign with tools/ab_protocol.py: `harness
bench N` prints, as JSON, N timings in milliseconds of drawing ten frames
of fifteen ROIs with their labels (draw_ms), and of dragging a handle of
five of them four hundred steps each (drag_ms).
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import roi_harness  # noqa: E402

root = roi_harness.ROOT
arguments = sys.argv[1:]
keep = dump = None
if arguments[:1] == ['--harnesses']:
    keep, arguments = Path(arguments[1]), arguments[2:]
if arguments[:1] == ['--dump']:
    dump, arguments = Path(arguments[1]), arguments[2:]
if arguments:
    reference = arguments[0]
else:
    # The revision before ROI.m was removed; while it is here, this checkout.
    reference = history_reference.before_removal(roi_harness.ROI_SOURCE) or 'HEAD'

try:
    roi_harness.objc_command()
    roi_harness.objects_dir()
except LookupError as error:
    print(f'skipped: {error}', file=sys.stderr)
    sys.exit(roi_harness.SKIPPED)

PROBE = roi_harness.PRELUDE + r'''

static NSDictionary *stateOf( ROI *roi)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"class"] = NSStringFromClass( [roi class]);
    d[@"type"] = @(roi.type);
    d[@"mode"] = @(roi.ROImode);
    d[@"name"] = roi.name ?: @"<nil>";
    d[@"points"] = pointsOf( roi.points);
    d[@"rect"] = R( roi.rect);
    d[@"thickness"] = F( roi.thickness);
    d[@"opacity"] = F( roi.opacity);
    RGBColor c = roi.rgbcolor;
    d[@"color"] = [NSString stringWithFormat: @"%d,%d,%d", c.red, c.green, c.blue];
    d[@"zPositions"] = [roi.zPositions description];
    d[@"clickInTextBox"] = @(roi.clickInTextBox);
    d[@"clickPoint"] = P( roi.clickPoint);
    d[@"spacing"] = [NSString stringWithFormat: @"%@,%@", F( roi.pixelSpacingX), F( roi.pixelSpacingY)];
    d[@"origin"] = P( roi.imageOrigin);
    for( NSString *key in @[@"selectedModifyPoint", @"PointUnderMouse", @"offsetTextBox_x", @"offsetTextBox_y", @"previousMode",
                            @"displayTextualData", @"hidden", @"locked", @"selectable", @"mousePosMeasure"])
        d[key] = [[roi valueForKey: key] description] ?: @"<nil>";
    d[@"textualBoxLines"] = @[roi.textualBoxLine1 ?: @"<nil>", roi.textualBoxLine2 ?: @"<nil>", roi.textualBoxLine3 ?: @"<nil>",
                              roi.textualBoxLine4 ?: @"<nil>", roi.textualBoxLine5 ?: @"<nil>", roi.textualBoxLine6 ?: @"<nil>"];
    d[@"valid"] = @"";
    if( roi.type == tPlain)
    {
        d[@"texture"] = [NSString stringWithFormat: @"%d x %d at %d,%d to %d,%d", roi.textureWidth, roi.textureHeight,
                         roi.textureUpLeftCornerX, roi.textureUpLeftCornerY, roi.textureDownRightCornerX, roi.textureDownRightCornerY];
        d[@"textureHash"] = roi.textureBuffer ? [NSString stringWithFormat: @"%016llx", hashBytes( roi.textureBuffer, (size_t) roi.textureWidth * roi.textureHeight)] : @"<null>";
    }
    return d;
}

static NSMutableDictionary *cases;
static NSMutableArray *trace;
static ROI *current;
static NSString *caseName;

/// Records a step: what the call answered, the ROI's state, the notifications
/// it posted, and, unless `draw` is NO, the frame drawn highlighted.
static void step( NSString *what, id answer, BOOL draw)
{
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"step"] = what;
    s[@"answer"] = answer ? [answer description] : @"";
    s[@"state"] = stateOf( current);
    s[@"notifications"] = [[notes copy] autorelease];
    [notes removeAllObjects];
    if( draw)
    {
        NSString *label = [NSString stringWithFormat: @"%@ %03lu %@", caseName, (unsigned long) trace.count, what];
        s[@"picture"] = picture( label, YES);
        s[@"stateAfterDrawing"] = stateOf( current);
    }
    [trace addObject: s];
}

static void begin( NSString *name, ROI *roi)
{
    trace = [NSMutableArray array];
    cases[ name] = trace;
    caseName = name;
    current = roi;
    roi.name = name;
    showAlone( roi);
}

/// The viewer's click on a ROI: which mode it answers, and the mode the ROI is put in.
static void click( NSString *what, NSPoint p, BOOL text)
{
    __block long m = ROI_sleep;
    id answer = ATTEMPT_VOID( m = [current clickInROI: p : kSide / 2. : kSide / 2. : gScale : text]);
    if( m != ROI_sleep) [current setROIMode: m];
    step( [NSString stringWithFormat: @"click %@ at %@%@", what, P( p), text ? @" (label)" : @""], answer ?: @(m), YES);
}

/// Clicks around the hit tolerances: off the middle of a-b, and off its end a.
static void nearMisses( NSPoint a, NSPoint b)
{
    double dx = b.x - a.x, dy = b.y - a.y, l = hypot( dx, dy);
    if( l == 0) return;
    NSPoint n = NSMakePoint( -dy / l, dx / l), mid = NSMakePoint( (a.x + b.x) / 2, (a.y + b.y) / 2);
    for( NSNumber *d in @[@0.9, @1.4, @1.6, @1.7, @2.5])
    {
        [current setROIMode: ROI_sleep];
        click( [NSString stringWithFormat: @"%@ off the outline", d], NSMakePoint( mid.x + n.x * d.doubleValue, mid.y + n.y * d.doubleValue), NO);
    }
    for( NSNumber *d in @[@0.4, @0.9, @1.2, @1.6, @2.6])
    {
        [current setROIMode: ROI_selected];
        click( [NSString stringWithFormat: @"%@ off a handle", d], NSMakePoint( a.x + d.doubleValue, a.y - d.doubleValue / 2), NO);
    }
}

static void drag( NSString *what, NSPoint p, unsigned int modifiers)
{
    id r = ATTEMPT( @([current mouseRoiDragged: p : modifiers : gScale]));
    step( [NSString stringWithFormat: @"drag %@ to %@ (%x)", what, P( p), modifiers], r, YES);
}

static void up( NSPoint p)
{
    id r = ATTEMPT( @([current mouseRoiUp: p scaleValue: gScale]));
    step( [NSString stringWithFormat: @"up at %@", P( p)], r, YES);
}

static void down( NSPoint p, int slice)
{
    id r = ATTEMPT( @([current mouseRoiDown: p : slice : gScale]));
    step( [NSString stringWithFormat: @"down at %@ slice %d", P( p), slice], r, YES);
}

static void hover( NSPoint p)
{
    [current displayPointUnderMouse: p : kSide / 2. : kSide / 2. : gScale];
    NSPoint v = [view ConvertFromGL2View: p];
    gMouse = NSMakePoint( (v.x + kFrame / 2.) / 2, (kFrame / 2. - v.y) / 2);
    step( [NSString stringWithFormat: @"hover at %@", P( p)], nil, YES);
}

/// The same ROI drawn in each mode, unhighlighted too, and its label picked.
static void modes( void)
{
    for( NSNumber *m in @[@(ROI_sleep), @(ROI_selected), @(ROI_selectedModify), @(ROI_drawing)])
    {
        [current setROIMode: m.longValue];
        step( [NSString stringWithFormat: @"mode %@", m], nil, YES);
    }
    [current setROIMode: ROI_selected];
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"step"] = @"not highlighted";
    s[@"picture"] = picture( [caseName stringByAppendingString: @" not highlighted"], NO);
    [trace addObject: s];
    // The label: picked by its box, then dragged by an offset.
    picture( [caseName stringByAppendingString: @" layout"], YES);
    NSRect box = [[current valueForKey: @"drawRect"] rectValue];
    if( !NSIsEmptyRect( box))
    {
        NSPoint centre = [view ConvertFromView2GL: NSMakePoint( NSMidX( box), NSMidY( box))];
        click( @"label", centre, YES);
        [current setTextBoxOffset: NSMakePoint( 3.5, -2.25)];
        step( @"label moved", nil, YES);
    }
}

static void common( void)
{
    [current setROIMode: ROI_selected];
    [current roiMove: NSMakePoint( 2.5, -1.75)];
    step( @"move", nil, YES);
    [current roiMove: NSMakePoint( -1, 1) :NO];
    step( @"move quietly", nil, YES);
    [current setROIMode: ROI_sleep];
    [current roiMove: NSMakePoint( 4, 4)];
    step( @"move while asleep", nil, NO);
    [current setROIMode: ROI_selected];
    [current setThickness: 3.6 globally: NO];
    [current setOpacity: 0.75 globally: NO];
    RGBColor c = { 65535, 32768, 4096 };
    [current setColor: c globally: NO];
    step( @"thickness, opacity, colour", nil, YES);
    current.hidden = YES;
    step( @"hidden", @([current clickInROI: [[current.points firstObject] point] : kSide / 2. : kSide / 2. : gScale : NO]), YES);
    current.hidden = NO;
    current.locked = YES;
    [current roiMove: NSMakePoint( 1, 1)];
    step( @"locked move", @([current mouseRoiDragged: NSMakePoint( 40, 40) : 0 : gScale]), YES);
    current.locked = NO;
    current.selectable = NO;
    step( @"unselectable", @([current clickInROI: [[current.points firstObject] point] : kSide / 2. : kSide / 2. : gScale : NO]), YES);
    current.selectable = YES;
    [current setROIMode: ROI_selected];
}

static void transform( void)
{
    NSPoint centre = NSMakePoint( 31.5, 30.25);
    [current setROIMode: ROI_selected];
    step( @"rotate", ATTEMPT_VOID( [current rotate: 33 : centre]), YES);
    step( @"resize", ATTEMPT_VOID( [current resize: 1.35 : centre]), YES);
    step( @"flip vertically", ATTEMPT_VOID( [current flipVertically: YES]), YES);
    step( @"flip horizontally", ATTEMPT_VOID( [current flipVertically: NO]), YES);
    step( @"valid", @([current valid]), NO);
}

static const unsigned int kConstrain = NSEventModifierFlagShift | NSEventModifierFlagOption;

static void twoPointTool( NSString *name, ToolMode type)
{
    begin( name, newROI( type));
    down( NSMakePoint( 20.25, 22.5), 0);
    drag( @"end", NSMakePoint( 30.5, 26.75), 0);
    drag( @"end", NSMakePoint( 42.25, 31.5), kConstrain);
    drag( @"end", NSMakePoint( 40.75, 44.5), 0);
    up( NSMakePoint( 40.75, 44.5));
    modes();
    hover( NSMakePoint( 40.75, 44.5));
    hover( NSMakePoint( 10, 10));
    click( @"outline", NSMakePoint( 30.5, 33.5), NO);
    click( @"nothing", NSMakePoint( 5, 50), NO);
    nearMisses( [current.points[ 0] point], [current.points[ 1] point]);
    click( @"first end", NSMakePoint( 20.5, 22.25), NO);
    drag( @"first end", NSMakePoint( 15.25, 18), 0);
    drag( @"first end", NSMakePoint( 14.5, 30.25), kConstrain);
    up( NSMakePoint( 14.5, 30.25));
    current.mousePosMeasure = 0.3;
    step( @"position along the length", nil, YES);
    current.mousePosMeasure = -1;
    common();
    transform();
    [current setROIMode: ROI_selectedModify];
    step( @"delete a point", ATTEMPT( @([current deleteSelectedPoint])), YES);
}

static void polygonTool( NSString *name, ToolMode type, double *xy, int count, BOOL close)
{
    begin( name, newROI( type));
    for( int i = 0; i < count; i++)
    {
        NSPoint p = NSMakePoint( xy[ 2*i], xy[ 2*i+1]);
        down( p, i % 3);
        if( type == tPencil) for( int k = 1; k < 4; k++)
            drag( @"stroke", NSMakePoint( p.x + k * 0.75, p.y + k * 0.5), 0);
        up( p);
    }
    if( close) down( NSMakePoint( xy[ 0] + 0.1, xy[ 1] - 0.1), 0);
    else down( NSMakePoint( xy[ 2*count-2], xy[ 2*count-1]), 0);
    up( NSMakePoint( 0, 0));
    modes();
    hover( NSMakePoint( xy[ 2], xy[ 3]));
    nearMisses( NSMakePoint( xy[ 2], xy[ 3]), NSMakePoint( xy[ 4], xy[ 5]));
    click( @"outline", NSMakePoint( (xy[ 0] + xy[ 2]) / 2, (xy[ 1] + xy[ 3]) / 2), NO);
    // A click on the outline where it was clicked again adds a point there.
    NSPoint onEdge = NSMakePoint( (xy[ 2] + xy[ 4]) / 2, (xy[ 3] + xy[ 5]) / 2);
    click( @"edge", onEdge, NO);
    up( onEdge);
    click( @"vertex", NSMakePoint( xy[ 4], xy[ 5]), NO);
    drag( @"vertex", NSMakePoint( xy[ 4] + 3.25, xy[ 5] - 2.5), 0);
    up( NSMakePoint( xy[ 4] + 3.25, xy[ 5] - 2.5));
    [current addPointUnderMouse: NSMakePoint( (xy[ 0] + xy[ 2]) / 2, (xy[ 1] + xy[ 3]) / 2) scale: gScale];
    step( @"add a point under the mouse", nil, YES);
    click( @"vertex", NSMakePoint( xy[ 2], xy[ 3]), NO);
    step( @"delete a point", ATTEMPT( @([current deleteSelectedPoint])), YES);
    [current setROIMode: ROI_selected];
    step( @"delete the last point", ATTEMPT( @([current deleteSelectedPoint])), YES);
    common();
    transform();
}

static void rectangleTool( NSString *name, ToolMode type)
{
    begin( name, newROI( type));
    down( NSMakePoint( 30.5, 31.25), 0);
    drag( @"corner", NSMakePoint( 38.25, 36.5), 0);
    drag( @"corner", NSMakePoint( 40.25, 37.5), kConstrain);
    drag( @"corner", NSMakePoint( 22.75, 24.5), kConstrain);
    drag( @"corner", NSMakePoint( 41.5, 39.75), 0);
    up( NSMakePoint( 41.5, 39.75));
    modes();
    NSRect r = current.rect;
    NSPoint corner = type == tOval ? NSMakePoint( r.origin.x + r.size.width, r.origin.y + r.size.height) : NSMakePoint( r.origin.x, r.origin.y);
    hover( corner);
    nearMisses( type == tOval ? NSMakePoint( r.origin.x + r.size.width, r.origin.y) : NSMakePoint( r.origin.x, r.origin.y), 
                type == tOval ? NSMakePoint( r.origin.x + r.size.width, r.origin.y + 0.01) : NSMakePoint( r.origin.x + r.size.width, r.origin.y));
    click( @"corner", corner, NO);
    drag( @"corner", NSMakePoint( corner.x - 3.5, corner.y + 2.25), 0);
    drag( @"corner", NSMakePoint( corner.x - 4.5, corner.y + 1.25), kConstrain);
    up( NSMakePoint( corner.x - 4.5, corner.y + 1.25));
    NSPoint other = type == tOval ? NSMakePoint( r.origin.x - r.size.width, r.origin.y + r.size.height) : NSMakePoint( r.origin.x + r.size.width, r.origin.y + r.size.height);
    click( @"other corner", other, NO);
    drag( @"other corner", NSMakePoint( other.x + 2, other.y + 3), 0);
    up( NSMakePoint( other.x + 2, other.y + 3));
    click( @"outline", NSMakePoint( r.origin.x + (type == tOval ? r.size.width : r.size.width / 2), r.origin.y + (type == tOval ? 0 : r.size.height)), NO);
    click( @"centre", r.origin, NO);
    click( @"nothing", NSMakePoint( 2, 2), NO);
    common();
    step( @"delete a point", ATTEMPT( @([current deleteSelectedPoint])), YES);
    begin( [name stringByAppendingString: @" transformed"], newROI( type));
    current.rect = NSMakeRect( 30.5, 28.25, 12.75, 9.5);
    [current setROIMode: ROI_selected];
    step( @"set", nil, YES);
    transform();
}

static void brushTool( void)
{
    view.currentTool = tPlain;
    ROI *brush = [[[ROI alloc] initWithType: tPlain : 0.5 : 0.625 : NSMakePoint( -30.5, 12.25)] autorelease];
    begin( @"brush", brush);
    down( NSMakePoint( 20, 22), 0);
    for( int k = 0; k < 6; k++) drag( @"paint", NSMakePoint( 20 + k * 2.5, 22 + k * 1.5), 0);
    view.eraserFlag = YES;
    drag( @"erase", NSMakePoint( 26, 25), 0);
    view.eraserFlag = NO;
    drag( @"erase with Command", NSMakePoint( 28, 24), NSEventModifierFlagCommand);
    drag( @"paint left and up", NSMakePoint( 8, 9), 0);
    up( NSMakePoint( 8, 9));
    step( @"reduce", @([current reduceTextureIfPossible]), YES);
    modes();
    click( @"painted pixel", NSMakePoint( 22, 23), NO);
    view.currentTool = tWL;
    click( @"painted pixel with another tool", NSMakePoint( 22, 23), NO);
    click( @"empty pixel", NSMakePoint( 50, 50), NO);
    down( NSMakePoint( 30, 30), 0);
    up( NSMakePoint( 30, 30));
    // Another stroke, merged.
    int w = 9, h = 7;
    unsigned char *mask = calloc( w * h, 1);
    for( int y = 0; y < h; y++) for( int x = 0; x < w; x++) mask[ y * w + x] = (x + y) % 3 ? 255 : 0;
    ROI *other = [[[ROI alloc] initWithTexture: mask textWidth: w textHeight: h textName: @"other" positionX: 40 positionY: 35
                                       spacingX: 0.5 spacingY: 0.625 imageOrigin: NSMakePoint( -30.5, 12.25)] autorelease];
    free( mask);
    [current mergeWithTexture: other];
    step( @"merge", nil, YES);
    [current addMarginToBuffer: 3];
    step( @"margin", nil, YES);
    current.textNameOnly = YES;
    step( @"name only", nil, YES);
    current.textNameOnly = NO;
    current.displayCalciumScoring = YES;
    current.calciumThreshold = 130;
    step( @"calcium", nil, YES);
    current.displayCalciumScoring = NO;
    common();
    [current setOriginAndSpacing: 0.25 : 0.3125 : NSMakePoint( -28.5, 10.25)];
    step( @"respaced", nil, YES);
    unsigned char *t = malloc( 4 * 3); memset( t, 255, 12);
    [current setTexture: t width: 4 height: 3];
    step( @"texture replaced", nil, NO);
}

static void layerTool( void)
{
    ROI *layer = [[[ROI alloc] initWithType: tLayerROI : 0.5 : 0.625 : NSZeroPoint] autorelease];
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: 8 pixelsHigh: 6 bitsPerSample: 8 samplesPerPixel: 4
                                                                       hasAlpha: YES isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 0 bitsPerPixel: 0] autorelease];
    for( int i = 0; i < rep.bytesPerRow * 6; i++) rep.bitmapData[ i] = (unsigned char)( i * 37 % 256) | ((i % 4 == 3) ? 0x80 : 0);
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize( 8, 6)] autorelease];
    [image addRepresentation: rep];
    begin( @"layer", layer);
    layer.layerImage = image;
    step( @"image", nil, YES);
    layer.canColorizeLayer = YES;
    [layer setNSColor: [NSColor colorWithCalibratedRed: 0.25 green: 0.5 blue: 0.75 alpha: 1] globally: NO];
    step( @"colour", nil, YES);
    layer.isLayerOpacityConstant = NO;
    [layer setOpacity: 0.5 globally: NO];
    step( @"opacity", nil, YES);
    double corners[] = { 22, 24, 46, 24, 46, 40, 22, 40};
    [layer setPoints: myPoints( corners, 4)];
    step( @"placed", nil, YES);
    click( @"opaque pixel", NSMakePoint( 30, 30), NO);
    click( @"outside", NSMakePoint( 5, 5), NO);
    modes();
    [layer setCanResizeLayer: YES];
    step( @"can resize", @([layer canResize]), NO);
    common();
}

static void textTool( void)
{
    ROI *text = newROI( tText);
    begin( @"text", text);
    down( NSMakePoint( 30.5, 26.25), 0);
    up( NSMakePoint( 30.5, 26.25));
    text.name = @"A text ROI";
    text.comments = @"its comment";
    text.name = @"A text ROI";
    step( @"named", nil, YES);
    modes();
    click( @"inside", NSMakePoint( 30.5, 26.25), NO);
    nearMisses( NSMakePoint( 30.5, 26.25), NSMakePoint( 34.5, 26.25));
    click( @"outside", NSMakePoint( 5, 5), NO);
    [text setThickness: 4 globally: NO];
    step( @"bigger", nil, YES);
    view.rotation = 30;
    view.origin = NSMakePoint( 12, -8);
    step( @"rotated view", nil, YES);
    view.xFlipped = YES;
    step( @"flipped view", nil, YES);
    view.xFlipped = NO; view.rotation = 0; view.origin = NSZeroPoint;
    common();
}

static void pointTool( void)
{
    begin( @"2D point", newROI( t2DPoint));
    down( NSMakePoint( 21.25, 33.5), 0);
    up( NSMakePoint( 21.25, 33.5));
    modes();
    click( @"point", NSMakePoint( 21.75, 33), NO);
    nearMisses( NSMakePoint( 21.25, 33.5), NSMakePoint( 23.25, 33.5));
    click( @"nothing", NSMakePoint( 50, 5), NO);
    common();
    step( @"delete", ATTEMPT( @([current deleteSelectedPoint])), YES);
}

static void fourPointTool( NSString *name, ToolMode type, double *xy)
{
    begin( name, newROI( type));
    [current setPoints: myPoints( xy, 4)];
    [current setROIMode: ROI_selected];
    step( @"set", nil, YES);
    modes();
    click( @"outline", NSMakePoint( (xy[ 0] + xy[ 2]) / 2, (xy[ 1] + xy[ 3]) / 2), NO);
    nearMisses( NSMakePoint( xy[ 2], xy[ 3]), NSMakePoint( xy[ 0], xy[ 1]));
    click( @"vertex", NSMakePoint( xy[ 2], xy[ 3]), NO);
    drag( @"vertex", NSMakePoint( xy[ 2] + 2, xy[ 3] - 1.5), 0);
    up( NSMakePoint( xy[ 2] + 2, xy[ 3] - 1.5));
    hover( NSMakePoint( xy[ 4], xy[ 5]));
    common();
    transform();
    // A fifth point: drawing removes what is past the fourth.
    [current.points addObject: [MyPoint point: NSMakePoint( 12, 12)]];
    [current.points addObject: [MyPoint point: NSMakePoint( 13, 14)]];
    step( @"extra points", nil, YES);
    [current setROIMode: ROI_selectedModify];
    [current setValue: @5 forKey: @"selectedModifyPoint"];
    step( @"delete", ATTEMPT( @([current deleteSelectedPoint])), YES);
}

static void tagtTool( void)
{
    begin( @"tagt", newROI( tTAGT));
    down( NSMakePoint( 18.25, 20.5), 0);
    up( NSMakePoint( 18.25, 20.5));
    modes();
    NSPoint p = [current.points[ 3] point];
    click( @"handle", p, NO);
    drag( @"handle", NSMakePoint( p.x + 2.5, p.y + 1.75), 0);
    up( NSMakePoint( p.x + 2.5, p.y + 1.75));
    hover( [current.points[ 5] point]);
    click( @"outline", NSMakePoint( 25, 20.5), NO);
    nearMisses( [current.points[ 4] point], [current.points[ 5] point]);
    common();
    transform();
}

static void angleTool( void)
{
    double xy[] = { 40.5, 12.25, 20.25, 30.5, 50.75, 45.125};
    begin( @"angle", newROI( tAngle));
    for( int i = 0; i < 3; i++)
    {
        down( NSMakePoint( xy[ 2*i], xy[ 2*i+1]), 0);
        drag( @"next", NSMakePoint( xy[ 2*i] + 1, xy[ 2*i+1] + 1), 0);
        up( NSMakePoint( xy[ 2*i] + 1, xy[ 2*i+1] + 1));
    }
    modes();
    nearMisses( NSMakePoint( 20.25, 30.5), NSMakePoint( 40.5, 12.25));
    click( @"vertex", NSMakePoint( 20.25, 30.5), NO);
    drag( @"vertex", NSMakePoint( 22.5, 28.25), 0);
    up( NSMakePoint( 22.5, 28.25));
    click( @"outline", NSMakePoint( 30.5, 21.5), NO);
    hover( NSMakePoint( 51.75, 46.125));
    common();
    transform();
}

static void cobb( void)
{
    double a[] = { 10, 12, 50, 18.5}, b[] = { 12, 40, 48, 36.25};
    ROI *first = newROI( tMesure), *second = newROI( tMesure);
    [first setPoints: myPoints( a, 2)];
    [second setPoints: myPoints( b, 2)];
    begin( @"two lengths", second);
    first.name = @"first";
    [first setCurView: (DCMView*) view];
    first.pix = view.curDCM;
    view.curRoiList = [NSMutableArray arrayWithObjects: first, second, nil];
    [second setROIMode: ROI_selected];
    step( @"both", nil, YES);
    [first setROIMode: ROI_selected];
    [second setROIMode: ROI_sleep];
    step( @"first selected", nil, YES);
    // An open polygon with three points becomes one when drawn as a length.
    double three[] = { 10, 50, 20, 55, 30, 50};
    ROI *line = newROI( tMesure);
    begin( @"length of three points", line);
    [line setPoints: myPoints( three, 3)];
    step( @"drawn", nil, YES);
}

static void ultrasound( void)
{
    DCMPix *saved = [view.curDCM retain];
    ProbeUSPix *us = (ProbeUSPix*) [ProbeUSPix pixWithSpacing: 0.5 originZ: 7];
    us.regions = @[[ProbeUSRegion format: 1 x0: 0 y0: 0 x1: 31 y1: 63 unitsX: 3 unitsY: 3],
                   [ProbeUSRegion format: 2 x0: 32 y0: 0 x1: 63 y1: 31 unitsX: 4 unitsY: 7],
                   [ProbeUSRegion format: 3 x0: 32 y0: 32 x1: 63 y1: 63 unitsX: 13 unitsY: 5]];
    ((ProbeUSRegion*) us.regions[ 1]).physicalDeltaY = -4.5;   // past a metre per second
    view.curDCM = us;
    struct { NSString *name; ToolMode type; double xy[ 4]; } shapes[] = {
        { @"US length in 2D", tMesure, { 5, 10, 25, 40}},
        { @"US length in M-mode", tMesure, { 35, 3, 60, 28}},
        { @"US length in spectral", tMesure, { 35, 35, 60, 60}},
        { @"US length across", tMesure, { 5, 10, 60, 40}},
        { @"US rectangle in 2D", tROI, { 5, 10, 20, 25}},
        { @"US rectangle across", tROI, { 25, 10, 20, 25}},
        { @"US oval in 2D", tOval, { 15, 30, 6, 8}},
        { @"US point in M-mode", t2DPoint, { 40, 20, 0, 0}},
        { @"US point in spectral", t2DPoint, { 50, 50, 0, 0}},
        { @"US point in 2D", t2DPoint, { 10, 10, 0, 0}}};
    for( int i = 0; i < 10; i++)
    {
        ROI *roi = newROI( shapes[ i].type);
        begin( shapes[ i].name, roi);
        if( shapes[ i].type == tMesure) [roi setPoints: myPoints( shapes[ i].xy, 2)];
        else roi.rect = NSMakeRect( shapes[ i].xy[ 0], shapes[ i].xy[ 1], shapes[ i].xy[ 2], shapes[ i].xy[ 3]);
        [roi setROIMode: ROI_selected];
        step( @"drawn", nil, YES);
        [roi setOriginAndSpacing: 0 : 0 : NSZeroPoint];
        roi.pixelSpacingX = 0; roi.pixelSpacingY = 0;
        step( @"uncalibrated", nil, YES);
    }
    ProbeUSRegion *reference = us.regions[ 2];
    reference.isReferencePixelX0Present = NO;
    begin( @"US point without X reference", newROI( t2DPoint));
    current.rect = NSMakeRect( 50, 50, 0, 0);
    step( @"drawn", nil, YES);
    reference.isReferencePixelY0Present = NO;
    step( @"without either reference", nil, YES);
    reference.isReferencePixelX0Present = YES;
    step( @"without Y reference", nil, YES);
    double polygon[] = { 4, 4, 20, 6, 22, 30, 6, 28};
    begin( @"US polygon in 2D", newROI( tCPolygon));
    [current setPoints: myPoints( polygon, 4)];
    step( @"drawn", nil, YES);
    begin( @"US open polygon in 2D", newROI( tOPolygon));
    [current setPoints: myPoints( polygon, 4)];
    step( @"drawn", nil, YES);
    int w = 10, h = 8;
    unsigned char *mask = calloc( w * h, 1);
    memset( mask, 255, w * h);
    ROI *brush = [[[ROI alloc] initWithTexture: mask textWidth: w textHeight: h textName: @"US brush" positionX: 5 positionY: 5
                                       spacingX: 0.5 spacingY: 0.625 imageOrigin: NSZeroPoint] autorelease];
    free( mask);
    begin( @"US brush in 2D", brush);
    step( @"drawn", nil, YES);
    view.curDCM = saved;
    [saved release];
}

static void mouseOver( void)
{
    double line[] = { 10, 40, 30, 52};
    begin( @"mouse over", newROI( tMesure));
    [current setPoints: myPoints( line, 2)];
    step( @"asleep", nil, YES);
    current.mouseOverROI = YES;
    step( @"pointer over it", nil, YES);
    current.displayCMOrPixels = YES;
    step( @"length in centimetres", nil, YES);
}

static void volumeLength( void)
{
    HorosVolumeLengthROI *volume = [[[HorosVolumeLengthROI alloc] initWithType: tMesure : 0.5 : 0.625 : NSZeroPoint] autorelease];
    volume.volumeLength = @{@"version": @1, @"id": @"V1", @"series": @"1.2.3", @"frameOfReference": @"1.2.826.0.1.3680043.2.1125.1",
                            @"a": @[@-25, @20.5, @7], @"b": @[@-12.5, @31.25, @7], @"temporalIndex": @0};
    view.is2DViewer = YES;
    view.dcmPixList = [NSMutableArray arrayWithObject: view.curDCM];
    view.curImage = 0;
    begin( @"patient-space length", volume);
    step( @"projected", nil, YES);
    modes();
    NSPoint a = NSMakePoint( (-25 + 30.5) / 0.5, (20.5 - 12.25) / 0.625);
    click( @"endpoint", a, NO);
    drag( @"endpoint", NSMakePoint( a.x + 4, a.y + 2), 0);
    up( NSMakePoint( a.x + 4, a.y + 2));
    click( @"line", NSMakePoint( a.x + 10, a.y + 6), NO);
    nearMisses( NSMakePoint( a.x + 4, a.y + 2), NSMakePoint( a.x + 29, a.y + 20));
    click( @"label", a, YES);
    [current roiMove: NSMakePoint( 3, 3)];
    step( @"move", nil, YES);
    step( @"delete", ATTEMPT( @([current deleteSelectedPoint])), YES);
    view.curDCM = [ProbePix pixWithSpacing: 0.5 originZ: 30];
    step( @"another plane", nil, YES);
    view.is2DViewer = NO;
}

static void creation( void)
{
    // What a new ROI of each kind is before it is drawn.
    trace = [NSMutableArray array];
    cases[@"new"] = trace;
    for( NSNumber *t in @[@(tMesure), @(tArrow), @(tROI), @(tOval), @(tOPolygon), @(tCPolygon), @(tAngle), @(tText), @(tPencil),
                          @(t2DPoint), @(tPlain), @(tLayerROI), @(tAxis), @(tDynAngle), @(tTAGT)])
    {
        current = newROI( (ToolMode) t.intValue);
        step( [NSString stringWithFormat: @"type %@", t], nil, NO);
        ROI *copy = [[current copy] autorelease];
        if( copy) current = copy;
        step( [NSString stringWithFormat: @"copy of type %@", t], copy ? @"copied" : @"no copy", NO);
    }
    ROI *unselectable = newROI( tCPolygon);
    unselectable.selectable = NO;
    current = unselectable;
    step( @"unselectable down", @([unselectable mouseRoiDown: NSMakePoint( 3, 3) : 0 : gScale]), NO);
    ROI *locked = newROI( tCPolygon);
    locked.locked = YES;
    current = locked;
    step( @"locked down", @([locked mouseRoiDown: NSMakePoint( 3, 3) : 0 : gScale]), NO);
    [ROI setDefaultName: @"Default"];
    step( @"default name", [ROI defaultName], NO);
    [ROI setDefaultName: nil];
    step( @"spline default", @([ROI splineForROI]), NO);
    ROI *morph = newROI( tMesure);
    morph.comments = @"morphing generated";
    current = morph;
    [morph mouseRoiDown: NSMakePoint( 3, 3) : 0 : gScale];
    step( @"morphing comment cleared", morph.comments, NO);
}

/// A frame of fifteen ROIs drawn and labelled, and a drag of handles of four
/// of them, timed `repetitions` times each, in milliseconds.
static NSDictionary *bench( int repetitions)
{
    NSMutableArray *rois = [NSMutableArray array];
    double polygon[] = { 18.5, 19.25, 40.75, 16.5, 47.125, 38.375, 30.5, 46.25, 16.25, 36.5};
    double pencil[] = { 20, 20, 24.5, 18.25, 30, 21, 33.75, 27.5, 31.5, 34, 25, 36.25, 21, 30, 19, 25};
    double line[] = { 10.25, 12.5, 40.75, 31.125}, angle[] = { 40.5, 12.25, 20.25, 30.5, 50.75, 45.125};
    double dyn[] = { 10, 10, 50, 22.5, 12.5, 40, 46.25, 48.75}, axis[] = { 15, 15, 45.5, 17.25, 47.75, 44.5, 13.25, 43};
    struct { ToolMode type; double *xy; int count; } kinds[] = {
        { tMesure, line, 2}, { tArrow, line, 2}, { tAngle, angle, 3}, { tCPolygon, polygon, 5}, { tOPolygon, polygon, 5},
        { tPencil, pencil, 8}, { tDynAngle, dyn, 4}, { tAxis, axis, 4}};
    for( int i = 0; i < 8; i++)
    {
        ROI *roi = newROI( kinds[ i].type);
        [roi setPoints: myPoints( kinds[ i].xy, kinds[ i].count)];
        [rois addObject: roi];
    }
    ROI *oval = newROI( tOval); oval.rect = NSMakeRect( 30.5, 28.25, 12.75, 9.5); [rois addObject: oval];
    ROI *rectangle = newROI( tROI); rectangle.rect = NSMakeRect( 12.5, 14.25, 20.75, 30.5); [rois addObject: rectangle];
    ROI *point = newROI( t2DPoint); point.rect = NSMakeRect( 21.25, 33.5, 0, 0); [rois addObject: point];
    ROI *text = newROI( tText); text.rect = NSMakeRect( 18, 22.5, 30, 12); text.name = @"A text"; [rois addObject: text];
    ROI *tagt = newROI( tTAGT); [tagt setCurView: (DCMView*) view]; [tagt mouseRoiDown: NSMakePoint( 18, 40) : 0 : gScale]; [rois addObject: tagt];
    int w = 21, h = 17;
    unsigned char *mask = calloc( w * h, 1);
    for( int y = 0; y < h; y++) for( int x = 0; x < w; x++) mask[ y * w + x] = (x - 10) * (x - 10) + (y - 8) * (y - 8) <= 49 ? 255 : 0;
    [rois addObject: [[[ROI alloc] initWithTexture: mask textWidth: w textHeight: h textName: @"Brush" positionX: 30 positionY: 30
                                          spacingX: 0.5 spacingY: 0.625 imageOrigin: NSMakePoint( -30.5, 12.25)] autorelease]];
    free( mask);
    ROI *pencilROI = rois[ 5];
    for( int k = 0; k < 40; k++) [pencilROI.points addObject: [MyPoint point: NSMakePoint( 30 + 10 * cos( k * 0.157), 40 + 8 * sin( k * 0.157))]];
    for( ROI *roi in rois) { [roi setCurView: (DCMView*) view]; roi.pix = view.curDCM; [roi setROIMode: ROI_selected]; }
    view.curRoiList = rois;
    HorosAnnotationOverlay *overlay = [HorosAnnotationOverlay overlayForView: view];
    NSMutableArray *draw = [NSMutableArray array], *dragTimes = [NSMutableArray array];
    for( int repetition = 0; repetition < repetitions; repetition++)
    {
        @autoreleasepool {
            NSTimeInterval start = [NSProcessInfo processInfo].systemUptime;
            for( int frame = 0; frame < 10; frame++)
            {
                [overlay beginFrameWidth: kFrame height: kFrame];
                HorosROICanvas *canvas = [HorosROICanvas current];
                [canvas setModelview: CGAffineTransformIdentity viewport: NSMakeRect( 0, 0, kFrame, kFrame)];
                [canvas resetFrameState];
                [view applyImageTransformation];
                for( ROI *r in [rois reverseObjectEnumerator])
                {
                    [r recompute];
                    [r drawROI: gScale : kSide / 2. : kSide / 2. : r.pixelSpacingX : r.pixelSpacingY];
                }
                view.rectArray = [NSMutableArray array];
                for( ROI *r in rois) [r drawTextualData];
                [overlay commitInverted: NO scale: 2];
            }
            [draw addObject: @(([NSProcessInfo processInfo].systemUptime - start) * 1000)];
        }
        @autoreleasepool {
            NSTimeInterval start = [NSProcessInfo processInfo].systemUptime;
            for( ROI *r in @[rois[ 0], rois[ 3], oval, rectangle, rois[ 5]])
            {
                NSPoint handle = r.type == tOval ? NSMakePoint( r.rect.origin.x + r.rect.size.width, r.rect.origin.y + r.rect.size.height)
                    : r.type == tROI ? r.rect.origin : [r.points[ 1] point];
                long m = [r clickInROI: handle : kSide / 2. : kSide / 2. : gScale : NO];
                [r setROIMode: m == ROI_sleep ? ROI_selectedModify : m];
                for( int k = 0; k < 400; k++)
                {
                    NSPoint p = NSMakePoint( handle.x + (k % 10) * 0.25, handle.y - (k % 7) * 0.25);
                    [r mouseRoiDragged: p : 0 : gScale];
                    [r displayPointUnderMouse: p : kSide / 2. : kSide / 2. : gScale];
                }
                [r mouseRoiDragged: handle : 0 : gScale];
                [r mouseRoiUp: handle scaleValue: gScale];
                [r setROIMode: ROI_selected];
            }
            [dragTimes addObject: @(([NSProcessInfo processInfo].systemUptime - start) * 1000)];
        }
    }
    return @{@"draw_ms": draw, @"drag_ms": dragTimes};
}

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    NSString *profile = argc > 1 ? @(argv[ 1]) : @"first";
    BOOL second = ![profile isEqualToString: @"first"];
    if( argc > 2 && strcmp( argv[ 1], "bench") != 0) dumpFolder = [@(argv[ 2]) retain];
    // The preferences the ROIs read, in the argument domain: nothing is saved.
    NSDictionary *preferences = @{
        @"ROIThickness": @2.5, @"ROIOpacity": @0.9, @"ROIColorR": @65535, @"ROIColorG": @12000, @"ROIColorB": @30000,
        @"ROITextThickness": @1, @"ROITextColorR": @60000, @"ROITextColorG": @60000, @"ROITextColorB": @0,
        @"ROIRegionThickness": @3, @"ROIRegionOpacity": @0.6, @"ROIRegionColorR": @0, @"ROIRegionColorG": @50000, @"ROIRegionColorB": @65535,
        @"ROIArrowThickness": @4, @"ROIColorRotation": @NO, @"ANNOTATIONS": @2,
        @"ROITEXTIFSELECTED": @(second), @"ROITextIfMouseIsOver": @NO, @"ROITEXTNAMEONLY": @NO,
        @"splineForROI": @(second), @"displayCobbAngle": @(!second), @"ROIDrawPlainEdge": @(second),
        @"drawROICircleCenter": @(second), @"NOINTERPOLATION": @(second), @"ROIPRIMARYMEASUREMENTONLY": @NO,
        @"ROILabelBackground": @(second), @"ROILabelBackgroundOpacity": @0.6,
        @"LabelFONTNAME": @"Helvetica", @"LabelFONTSIZE": @12, @"ROIComputeSkewnessAndKurtosis": @YES};
    NSMutableDictionary *chosen = [[preferences mutableCopy] autorelease];
    if( [profile isEqualToString: @"third"])
    {
        // The primary measurement only, some statistics hidden, labels for the ROI under the pointer.
        [chosen addEntriesFromDictionary: @{@"ROIPRIMARYMEASUREMENTONLY": @YES, @"ROITextIfMouseIsOver": @YES,
                                            @"ROILabelShowSDev": @NO, @"ROILabelShowMedian": @NO, @"ROILabelShowMin": @NO}];
    }
    if( [profile isEqualToString: @"fourth"])
        [chosen addEntriesFromDictionary: @{@"ROITEXTNAMEONLY": @YES, @"ROILabelShowMean": @NO, @"ROITEXTIFSELECTED": @NO}];
    ProbeWindow *window = setUp( chosen);

    if( argc > 2 && strcmp( argv[ 1], "bench") == 0)
    {
        NSData *json = [NSJSONSerialization dataWithJSONObject: bench( atoi( argv[ 2])) options: NSJSONWritingSortedKeys error: nil];
        fwrite( json.bytes, 1, json.length, stdout);
        return 0;
    }
    cases = [NSMutableDictionary dictionary];
    creation();
    twoPointTool( @"length", tMesure);
    twoPointTool( @"arrow", tArrow);
    double polygon[] = { 18.5, 19.25, 40.75, 16.5, 47.125, 38.375, 30.5, 46.25, 16.25, 36.5};
    polygonTool( @"closed polygon", tCPolygon, polygon, 5, YES);
    polygonTool( @"open polygon", tOPolygon, polygon, 5, NO);
    double pencil[] = { 20, 20, 24.5, 18.25, 30, 21, 33.75, 27.5, 31.5, 34, 25, 36.25};
    polygonTool( @"pencil", tPencil, pencil, 6, NO);
    angleTool();
    rectangleTool( @"oval", tOval);
    rectangleTool( @"rectangle", tROI);
    double dyn[] = { 10, 10, 50, 22.5, 12.5, 40, 46.25, 48.75};
    fourPointTool( @"dynamic angle", tDynAngle, dyn);
    double axis[] = { 15, 15, 45.5, 17.25, 47.75, 44.5, 13.25, 43};
    fourPointTool( @"axis", tAxis, axis);
    tagtTool();
    textTool();
    pointTool();
    brushTool();
    layerTool();
    cobb();
    ultrasound();
    mouseOver();
    volumeLength();
    [window release];

    NSData *json = [NSJSONSerialization dataWithJSONObject: @{@"cases": cases} options: NSJSONWritingSortedKeys error: nil];
    fwrite( json.bytes, 1, json.length, stdout);
    return 0;
}}
'''


# The sets of preferences the probe runs under (see its main()).
PROFILES = ('first', 'second', 'third', 'fourth')


def main():
    failures = []
    log = []
    with tempfile.TemporaryDirectory(prefix='horos-roi-interaction-') as tmp:
        tmp = Path(tmp)
        folders = {'reference': keep / 'reference' if keep else tmp / 'reference',
                   'current': keep / 'current' if keep else tmp / 'current'}
        harnesses = {}
        for label, revision in (('reference', reference), ('current', roi_harness.WORKTREE)):
            try:
                harnesses[label] = roi_harness.build(revision, folders[label], PROBE, log=log)
            except LookupError as error:
                print(f'skipped: {error}', file=sys.stderr)
                sys.exit(roi_harness.SKIPPED)
            except (subprocess.CalledProcessError, RuntimeError) as error:
                detail = (error.stderr.decode(errors='replace')[-4000:]
                          if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error))
                print(f'FAIL: the {label} harness ({revision}) did not build: {detail}')
                sys.exit(1)
        if keep:
            for harness in harnesses.values():
                print(harness)
            return
        outputs = {}
        for label, harness in harnesses.items():
            for profile in PROFILES:
                argv = [str(harness), profile]
                if dump:
                    (dump / label / profile).mkdir(parents=True, exist_ok=True)
                    argv.append(str(dump / label / profile))
                result = subprocess.run(argv, capture_output=True, text=True, timeout=900)
                if result.returncode:
                    if 'window' in result.stderr.lower() and 'server' in result.stderr.lower():
                        print('skipped: no window server session for the overlay view', file=sys.stderr)
                        sys.exit(roi_harness.SKIPPED)
                    print(f'FAIL: the {label} probe ({profile}) ended with {result.returncode}: {result.stderr[-3000:]}')
                    sys.exit(1)
                outputs[(label, profile)] = json.loads(result.stdout)['cases']
        steps = 0
        for profile in PROFILES:
            a, b = outputs[('reference', profile)], outputs[('current', profile)]
            steps += sum(len(v) for v in a.values())
            for problem in roi_harness.diff(a, b):
                failures.append(f'{profile} preferences: differs from the reference: {problem}')
            # The probe must have drawn something: an empty canvas proves nothing.
            lit = [s for v in b.values() for s in v if isinstance(s, dict) and s.get('picture', {}).get('lit')]
            if len(lit) < 300:
                failures.append(f'{profile} preferences: only {len(lit)} steps drew anything')
    for failure in failures[:80]:
        print('FAIL:', failure)
    if failures:
        print(f'{len(failures)} differences in all')
        sys.exit(1)
    print(f'PASS: {len(outputs[("current", "first")])} ROI scenarios, {steps} steps under four sets of preferences, '
          f'draw, pick, move, resize and label exactly as {reference} does ({"; ".join(log)})')


main()
