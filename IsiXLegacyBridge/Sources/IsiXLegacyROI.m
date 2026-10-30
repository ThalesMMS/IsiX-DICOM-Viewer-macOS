//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.
//
// The ROI keeps the legacy state the plugin reads and changes. Once in a
// viewer it is bound to the application's ROI: each setter, rotate and move
// pushes the difference at once, and the lists of the viewer controller push
// what the plugin changed directly in the points when the viewer is updated.
// The geometry follows the application's ROI class: pixel centres at half
// coordinates, a rectangle's rect is its origin and size, an oval's its centre
// and radii, rotate works in the patient's proportions.

#import "IsiXLegacyBridgeInternal.h"

static NSString *defaultROIName = nil;

@implementation IsiXLegacyROI
{
    ToolMode type;
    NSMutableArray *points;
    IsiXLegacyViewerSession *session;
    IsiXLegacyROIState *hostState;
    BOOL adopting;
    /// A brush ROI's mask, textureWidth x textureHeight bytes from its top left corner.
    NSMutableData *texture;
    int textureWidth, textureHeight, textureUpLeftCornerX, textureUpLeftCornerY;
}

@synthesize name, comments, ROImode, rect, pix, curView, displayTextualData, pixelSpacingX, pixelSpacingY, imageOrigin, locked;
@synthesize rgbcolor, sliceThickness, textureWidth, textureHeight, textureUpLeftCornerX, textureUpLeftCornerY;

+ (void) setDefaultName: (NSString*) n { defaultROIName = [n copy]; }
+ (NSString*) defaultName { return defaultROIName; }
- (void) setDefaultName: (NSString*) n { [[self class] setDefaultName: n]; }
- (NSString*) defaultName { return [[self class] defaultName]; }

- (id) initWithType: (ToolMode) itype :(float) ipixelSpacingx :(float) ipixelSpacingy :(NSPoint) iimageOrigin
{
    if (!(self = [super init])) return nil;
    type = itype;
    pixelSpacingX = ipixelSpacingx;
    pixelSpacingY = ipixelSpacingy;
    imageOrigin = iimageOrigin;
    points = [NSMutableArray array];
    name = defaultROIName ?: @"Unnamed";
    comments = @"";
    displayTextualData = YES;
    ROImode = ROI_sleep;
    return self;
}

- (id) initWithType: (ToolMode) itype :(float) ipixelSpacing :(NSPoint) iimageOrigin
{
    return [self initWithType: itype :ipixelSpacing :ipixelSpacing :iimageOrigin];
}

- (id) initWithTexture: (unsigned char*) tBuff textWidth: (int) tWidth textHeight: (int) tHeight textName: (NSString*) tName
             positionX: (int) posX positionY: (int) posY
              spacingX: (float) ipixelSpacingx spacingY: (float) ipixelSpacingy imageOrigin: (NSPoint) iimageOrigin
{
    if (!(self = [self initWithType: tPlain :ipixelSpacingx :ipixelSpacingy :iimageOrigin])) return nil;
    textureWidth = MAX(tWidth, 0);
    textureHeight = MAX(tHeight, 0);
    textureUpLeftCornerX = posX;
    textureUpLeftCornerY = posY;
    texture = [NSMutableData dataWithLength: (NSUInteger) textureWidth * (NSUInteger) textureHeight];
    if (tBuff && texture.length) memcpy(texture.mutableBytes, tBuff, texture.length);
    if (tName) name = [tName copy];
    return self;
}

- (unsigned char*) textureBuffer { return texture.mutableBytes; }
- (int) textureDownRightCornerX { return textureUpLeftCornerX + textureWidth - 1; }
- (int) textureDownRightCornerY { return textureUpLeftCornerY + textureHeight - 1; }

- (BOOL) reduceTextureIfPossible
{
    if (type != tPlain) return YES;
    const unsigned char *bytes = texture.bytes;
    int minX = textureWidth, minY = textureHeight, maxX = -1, maxY = -1;
    for (int y = 0; y < textureHeight; y++)
        for (int x = 0; x < textureWidth; x++)
            if (bytes[(NSUInteger) y * textureWidth + x])
            {
                minX = MIN(minX, x); maxX = MAX(maxX, x);
                minY = MIN(minY, y); maxY = MAX(maxY, y);
            }
    if (maxX < 0) return YES;
    int width = maxX - minX + 1, height = maxY - minY + 1;
    NSMutableData *cropped = [NSMutableData dataWithLength: (NSUInteger) width * (NSUInteger) height];
    for (int y = 0; y < height; y++)
        memcpy((unsigned char*) cropped.mutableBytes + (NSUInteger) y * width, bytes + (NSUInteger) (y + minY) * textureWidth + minX, (size_t) width);
    texture = cropped;
    textureUpLeftCornerX += minX;
    textureUpLeftCornerY += minY;
    textureWidth = width;
    textureHeight = height;
    return NO;
}

- (void) setColor: (RGBColor) color { rgbcolor = color; }

- (instancetype) initWithIsiXState: (IsiXLegacyROIState*) state session: (IsiXLegacyViewerSession*) s
{
    if (!(self = [self initWithType: (ToolMode) state.toolMode :0 :0 :NSZeroPoint])) return nil;
    [self isixBindToSession: s state: state];
    return self;
}

- (NSString*) description
{
    return [NSString stringWithFormat: @"<ROI %@ type %d, %lu points>", name, (int) type, (unsigned long) points.count];
}

#pragma mark Binding to the application's ROI

- (IsiXLegacyROIState*) isixHostState { return hostState; }

- (void) isixBindToSession: (IsiXLegacyViewerSession*) s state: (IsiXLegacyROIState*) state
{
    session = s;
    [self isixAdoptHostState: state];
}

- (void) isixUnbind
{
    session = nil;
    hostState = nil;
}

/// Takes the application's state; the points array stays the same object.
- (void) isixAdoptHostState: (IsiXLegacyROIState*) state
{
    adopting = YES;
    hostState = state;
    if (state.toolMode >= 0) type = (ToolMode) state.toolMode;
    name = state.name;
    comments = state.comment;
    rect = state.rect;
    displayTextualData = state.showsTextBox;
    if (state.isSelected) { if (ROImode != ROI_selectedModify) ROImode = ROI_selected; }
    else ROImode = ROI_sleep;
    if (type != tROI && type != tOval)
    {
        [points removeAllObjects];
        for (NSValue *value in state.points) [points addObject: [IsiXLegacyMyPoint point: value.pointValue]];
    }
    adopting = NO;
}

- (IsiXLegacyROIState*) isixWantedState
{
    IsiXLegacyROIState *state = [[IsiXLegacyROIState alloc] init];
    state.toolMode = type;
    state.name = name ?: @"";
    state.comment = comments ?: @"";
    state.rect = rect;
    NSMutableArray *values = [NSMutableArray arrayWithCapacity: points.count];
    for (IsiXLegacyMyPoint *point in points) [values addObject: [NSValue valueWithPoint: point.point]];
    if (type == t2DPoint && values.count == 0) [values addObject: [NSValue valueWithPoint: rect.origin]];
    state.points = values;
    state.isSelected = ROImode == ROI_selected || ROImode == ROI_selectedModify;
    state.showsTextBox = displayTextualData;
    if (type == tPlain && texture)
    {
        state.mask = [texture copy];
        state.maskWidth = textureWidth;
        state.maskHeight = textureHeight;
        state.maskColumn = textureUpLeftCornerX;
        state.maskRow = textureUpLeftCornerY;
    }
    return state;
}

- (void) isixPush
{
    if (adopting || !session || !hostState) return;
    IsiXLegacyROIState *updated = [session updateROI: hostState to: [self isixWantedState]];
    if (updated) [self isixAdoptHostState: updated];
}

#pragma mark Properties

- (ToolMode) type { return type; }

- (void) setName: (NSString*) n { name = [n copy]; [self isixPush]; }
- (void) setComments: (NSString*) c { comments = c; [self isixPush]; }
- (void) setROIMode: (long) mode { ROImode = mode; [self isixPush]; }
- (void) setDisplayTextualData: (BOOL) d { displayTextualData = d; [self isixPush]; }

- (void) setROIRect: (NSRect) r
{
    rect = r;
    if (type == t2DPoint) [points setArray: @[[IsiXLegacyMyPoint point: r.origin]]];
    [self isixPush];
}

/// A rectangle's and an oval's outline; the points of the others, which the plugin may change.
- (NSMutableArray*) points
{
    if (type == tROI)
    {
        NSRect r = NSRectFromCGRect(CGRectStandardize(NSRectToCGRect(rect)));
        // The application's order: from the origin along the height first.
        return [NSMutableArray arrayWithObjects: [IsiXLegacyMyPoint point: NSMakePoint(NSMinX(r), NSMinY(r))],
                [IsiXLegacyMyPoint point: NSMakePoint(NSMinX(r), NSMaxY(r))], [IsiXLegacyMyPoint point: NSMakePoint(NSMaxX(r), NSMaxY(r))],
                [IsiXLegacyMyPoint point: NSMakePoint(NSMaxX(r), NSMinY(r))], nil];
    }
    if (type == tOval)
    {
        NSMutableArray *outline = [NSMutableArray array];
        for (int i = 0; i < 36; i++)
        {
            double angle = 2 * M_PI * i / 36;
            [outline addObject: [IsiXLegacyMyPoint point: NSMakePoint(rect.origin.x + rect.size.width * cos(angle),
                                                                       rect.origin.y + rect.size.height * sin(angle))]];
        }
        return outline;
    }
    return points;
}

- (void) setPoints: (NSMutableArray*) newPoints
{
    if (type == tROI || type == tOval || type == t2DPoint || locked) return;
    NSArray *copy = [newPoints copy];
    [points setArray: copy];
    [self isixPush];
}

/// The outline as the application smooths it: an open or closed polygon or a
/// pencil stroke of three points or more, while the viewer preference for
/// smoothing is on; the points otherwise. A polygon being drawn is smoothed open.
- (NSMutableArray*) splinePoints
{
    if (type != tOPolygon && type != tCPolygon && type != tPencil) return self.points;
    if (points.count < 3 || ![IsiXLegacySplineBridge smoothsOutlines]) return self.points;
    NSMutableArray<NSValue*> *outline = [NSMutableArray arrayWithCapacity: points.count + 1];
    for (IsiXLegacyMyPoint *p in points) [outline addObject: [NSValue valueWithPoint: p.point]];
    if (type != tOPolygon && ROImode != ROI_drawing) [outline addObject: outline[0]];
    NSArray<NSValue*> *smoothed = [IsiXLegacySplineBridge smooth: outline scale: 5];
    if (smoothed.count == 0) return self.points;
    NSMutableArray *result = [NSMutableArray arrayWithCapacity: smoothed.count];
    for (NSValue *v in smoothed) [result addObject: [IsiXLegacyMyPoint point: v.pointValue]];
    return result;
}

- (NSPoint) pointAtIndex: (NSUInteger) index
{
    return [(IsiXLegacyMyPoint*) self.points[index] point];
}

- (void) setPoint: (NSPoint) point atIndex: (NSUInteger) index
{
    if (index >= points.count) return;
    [(IsiXLegacyMyPoint*) points[index] setPoint: point];
    [self isixPush];
}

- (void) addPoint: (NSPoint) point
{
    [points addObject: [IsiXLegacyMyPoint point: point]];
    [self isixPush];
}

#pragma mark Measurements

- (float) LengthFrom: (NSPoint) a to: (NSPoint) b inPixel: (BOOL) inPixel
{
    double dx = b.x - a.x, dy = b.y - a.y;
    if (inPixel || pixelSpacingX == 0 || pixelSpacingY == 0) return sqrt(dx * dx + dy * dy);
    dx *= pixelSpacingX;
    dy *= pixelSpacingY;
    return sqrt(dx * dx + dy * dy) / 10.0;
}

- (float) Length: (NSPoint) a :(NSPoint) b
{
    return [self LengthFrom: a to: b inPixel: NO];
}

- (float) MesureLength: (float*) pixels
{
    if (points.count < 2) { if (pixels) *pixels = 0; return 0; }
    NSPoint a = [(IsiXLegacyMyPoint*) points[0] point], b = [(IsiXLegacyMyPoint*) points[1] point];
    if (pixels) *pixels = [self LengthFrom: a to: b inPixel: YES];
    return [self LengthFrom: a to: b inPixel: NO];
}

/// The signed area of the outline in pixels, by the shoelace formula.
static double outlineArea(NSArray *outline)
{
    double area = 0;
    NSUInteger count = outline.count;
    for (NSUInteger i = 0; i < count; i++)
    {
        NSPoint p = [(IsiXLegacyMyPoint*) outline[i] point], q = [(IsiXLegacyMyPoint*) outline[(i + 1) % count] point];
        area += p.x * q.y - q.x * p.y;
    }
    return area / 2;
}

- (float) roiArea
{
    if (pixelSpacingX == 0 && pixelSpacingY == 0) return 0;
    double pixels;
    switch (type)
    {
        case tROI: pixels = fabs(rect.size.width * rect.size.height); break;
        case tOval: pixels = M_PI * fabs(rect.size.width * rect.size.height); break;
        case tCPolygon: case tOPolygon: case tPencil: pixels = fabs(outlineArea(points)); break;
        default: return 0;
    }
    return pixels * pixelSpacingX * pixelSpacingY / 100.0;
}

- (NSPoint) centroid
{
    if (type == tROI || type == tOval) return rect.origin;
    NSUInteger count = points.count;
    if (count == 0) return NSZeroPoint;
    double area = outlineArea(points), cx = 0, cy = 0;
    if (fabs(area) > 1e-9)
    {
        for (NSUInteger i = 0; i < count; i++)
        {
            NSPoint p = [(IsiXLegacyMyPoint*) points[i] point], q = [(IsiXLegacyMyPoint*) points[(i + 1) % count] point];
            double cross = p.x * q.y - q.x * p.y;
            cx += (p.x + q.x) * cross;
            cy += (p.y + q.y) * cross;
        }
        return NSMakePoint(cx / (6 * area), cy / (6 * area));
    }
    for (IsiXLegacyMyPoint *point in points) { cx += point.x; cy += point.y; }
    return NSMakePoint(cx / count, cy / count);
}

- (IsiXLegacyROIStatistics*) isixStatistics
{
    if (!session || !hostState) return nil;
    return [session statisticsOf: hostState slice: hostState.slice phase: hostState.phase];
}

- (float) mean { return [self isixStatistics].mean; }
- (float) min { return [self isixStatistics].minimum; }
- (float) max { return [self isixStatistics].maximum; }

- (BOOL) valid
{
    switch (type)
    {
        case t2DPoint: return YES;
        case tROI: case tOval: return rect.size.width != 0 && rect.size.height != 0;
        case tMesure: case tOPolygon: return points.count >= 2;
        case tCPolygon: return points.count >= 3;
        default: return points.count > 0;
    }
}

#pragma mark Moving

- (void) roiMove: (NSPoint) offsetBy :(BOOL) sendNotification
{
    if (locked) return;
    if (type == tROI || type == tOval || type == t2DPoint)
    {
        rect.origin.x += offsetBy.x;
        rect.origin.y += offsetBy.y;
    }
    for (IsiXLegacyMyPoint *point in points) [point move: offsetBy.x :offsetBy.y];
    [self isixPush];
}

- (void) roiMove: (NSPoint) offsetBy
{
    [self roiMove: offsetBy :YES];
}

- (void) rotate: (float) angle :(NSPoint) center
{
    if (locked) return;
    NSArray *outline = self.points;
    if (outline.count == 0) return;
    if (type == tROI || type == tOval)
    {
        // A rotated rectangle or oval becomes the polygon of its outline.
        type = tCPolygon;
        [points setArray: outline];
    }
    double theta = angle * M_PI / 180.0;
    double ratio = (pix && pix.pixelRatio != 0) ? pix.pixelRatio : 1.0;
    double c = cos(theta), s = sin(theta);
    for (IsiXLegacyMyPoint *point in points)
    {
        double dx = point.x - center.x, dy = point.y - center.y;
        double newX = c * dx - s * dy * ratio;
        double newY = c * dy * ratio + s * dx;
        point.point = NSMakePoint(newX + center.x, newY / ratio + center.y);
    }
    [self isixPush];
}

@end
