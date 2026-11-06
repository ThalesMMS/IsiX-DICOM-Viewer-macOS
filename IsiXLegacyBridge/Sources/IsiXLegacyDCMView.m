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
// A view bound to a ViewerController stands for the viewer's pane and asks
// the viewer for everything; any other is a view of the plugin's own, which
// keeps its images, ROIs and window level and draws them itself.

#import "IsiXLegacyBridgeInternal.h"

@implementation IsiXLegacyDCMView
{
    __weak IsiXLegacyViewerController *controller;
    // A view of the plugin's own.
    NSMutableArray *pixList;
    NSArray *files;
    NSMutableArray *roiList;
    short current;
    float windowLevel, windowWidth;
}

@synthesize xFlipped, yFlipped;

- (instancetype) initWithIsiXController: (IsiXLegacyViewerController*) c
{
    if ((self = [super initWithFrame: NSZeroRect])) controller = c;
    return self;
}

- (id) initWithFrame: (NSRect) frame imageRows: (int) rows imageColumns: (int) columns
{
    return [self initWithFrame: frame];
}

- (IsiXLegacyViewerController*) windowController { return controller; }
- (BOOL) is2DViewer { return controller != nil; }
- (BOOL) flippedData { return NO; }

- (void) roiSet
{
    if (controller) [controller needsDisplayUpdate];
    else [self setNeedsDisplay: YES];
}

- (NSPoint) ConvertFromGL2GL: (NSPoint) a toView: (IsiXLegacyDCMView*) otherView
{
    IsiXLegacyDCMPix *from = self.curDCM, *to = otherView.curDCM;
    if (!otherView || otherView == self || !from || !to || to.pixelSpacingX == 0 || to.pixelSpacingY == 0) return a;
    double patient[3], orientation[9];
    [from convertPixDoubleX: a.x pixY: a.y toDICOMCoords: patient pixelCenter: NO];
    [to orientationDouble: orientation];
    double d[3] = { patient[0] - to.originX, patient[1] - to.originY, patient[2] - to.originZ };
    return NSMakePoint((d[0] * orientation[0] + d[1] * orientation[1] + d[2] * orientation[2]) / to.pixelSpacingX,
                       (d[0] * orientation[3] + d[1] * orientation[4] + d[2] * orientation[5]) / to.pixelSpacingY);
}

#pragma mark Images

- (void) setPixels: (NSMutableArray*) pixels files: (NSArray*) f rois: (NSMutableArray*) rois firstImage: (short) firstImage level: (char) level reset: (BOOL) reset
{
    if (controller) return;
    pixList = pixels;
    files = f;
    roiList = rois;
    current = firstImage;
    if (reset || windowWidth == 0)
    {
        IsiXLegacyDCMPix *image = self.curDCM;
        windowLevel = image.wl;
        windowWidth = image.ww;
        if (windowWidth == 0) { windowLevel = image.fullwl; windowWidth = image.fullww; }
    }
    [self setNeedsDisplay: YES];
}

- (void) setDCM: (NSMutableArray*) pixels :(NSArray*) f :(NSMutableArray*) rois :(short) firstImage :(char) type :(BOOL) reset
{
    [self setPixels: pixels files: f rois: rois firstImage: firstImage level: type reset: reset];
}

- (short) curImage
{
    return controller ? (short) controller.isixSession.currentSlice : current;
}

- (void) setIndex: (short) index
{
    if (controller) [controller.isixSession setCurrentSlice: index];
    else if (index >= 0 && index < (short) pixList.count) { current = index; [self setNeedsDisplay: YES]; }
}

- (void) setIndexWithReset: (short) index :(BOOL) sizeToFit
{
    [self setIndex: index];
}

- (NSMutableArray*) dcmPixList { return controller ? [controller pixList] : pixList; }
- (NSMutableArray*) dcmRoiList { return controller ? [controller roiList] : roiList; }
- (NSArray*) dcmFilesList { return controller ? [controller fileList] : files; }

- (IsiXLegacyDCMPix*) curDCM
{
    NSArray *list = self.dcmPixList;
    long index = self.curImage;
    return index >= 0 && index < (long) list.count ? list[index] : nil;
}

- (NSMutableArray*) curRoiList
{
    NSArray *lists = self.dcmRoiList;
    long index = self.curImage;
    return index >= 0 && index < (long) lists.count ? lists[index] : nil;
}

- (void) getWLWW: (float*) wl :(float*) ww
{
    IsiXLegacyViewerSession *session = controller.isixSession;
    if (wl) *wl = controller ? session.windowCenter : windowLevel;
    if (ww) *ww = controller ? session.windowWidth : windowWidth;
}

- (void) setWLWW: (float) wl :(float) ww
{
    if (controller) [controller.isixSession setWindowWithCenter: wl width: ww];
    else { windowLevel = wl; windowWidth = ww; [self setNeedsDisplay: YES]; }
}

- (double) pixelSpacingX { return self.curDCM.pixelSpacingX; }
- (double) pixelSpacingY { return self.curDCM.pixelSpacingY; }

- (IBAction) selectAll: (id) sender
{
    for (IsiXLegacyROI *roi in self.curRoiList)
        if ([roi isKindOfClass: [IsiXLegacyROI class]]) roi.ROImode = ROI_selected;
    if (!controller) [self setNeedsDisplay: YES];
}

- (void) setXFlipped: (BOOL) flipped { xFlipped = flipped; [self setNeedsDisplay: YES]; }
- (void) setYFlipped: (BOOL) flipped { yFlipped = flipped; [self setNeedsDisplay: YES]; }

/// The viewer's pane has nothing of its own to redraw: the viewer is redrawn.
- (void) setNeedsDisplay: (BOOL) flag
{
    if (controller) [controller.isixSession redraw];
    else [super setNeedsDisplay: flag];
}

#pragma mark Drawing a view of the plugin's own

/// The image's pixels to the view's points: the image fitted in the view,
/// kept in proportion with the pixels' spacing, rows down from the top.
- (NSAffineTransform*) isixImageToView
{
    IsiXLegacyDCMPix *image = self.curDCM;
    NSAffineTransform *transform = [NSAffineTransform transform];
    if (!image || image.pwidth <= 0 || image.pheight <= 0) return transform;
    double ratio = image.pixelRatio > 0 ? image.pixelRatio : 1;
    double width = image.pwidth, height = image.pheight * ratio;
    NSRect bounds = self.bounds;
    double scale = MIN(bounds.size.width / width, bounds.size.height / height);
    [transform translateXBy: NSMidX(bounds) yBy: NSMidY(bounds)];
    [transform scaleXBy: (xFlipped ? -scale : scale) yBy: (yFlipped ? scale : -scale) * ratio];
    [transform translateXBy: -image.pwidth / 2.0 yBy: -image.pheight / 2.0];
    return transform;
}

- (NSPoint) ConvertFromNSView2GL: (NSPoint) a
{
    NSAffineTransform *transform = [self isixImageToView];
    [transform invert];
    return [transform transformPoint: a];
}

- (NSPoint) ConvertFromGL2NSView: (NSPoint) a
{
    return [[self isixImageToView] transformPoint: a];
}

static CGImageRef IsiXCreateImage(IsiXLegacyDCMPix *image, float wl, float ww)
{
    long width = image.pwidth, height = image.pheight;
    if (width <= 0 || height <= 0 || !image.fImage) return NULL;
    CGColorSpaceRef space;
    NSMutableData *bytes;
    size_t bytesPerPixel;
    CGBitmapInfo info;
    if (image.isRGB)
    {
        bytes = [NSMutableData dataWithBytes: image.fImage length: width * height * 4];
        space = CGColorSpaceCreateDeviceRGB();
        bytesPerPixel = 4;
        info = (CGBitmapInfo) kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big;
    }
    else
    {
        // The window level's grays as sRGB grays, as the application shows
        // them: a gray colour space would be converted with another curve.
        bytes = [NSMutableData dataWithLength: width * height * 4];
        unsigned char *rgb = bytes.mutableBytes;
        float low = wl - ww / 2, range = ww > 0 ? ww : 1;
        for (long index = 0; index < width * height; index++)
        {
            float value = (image.fImage[index] - low) * 255.f / range;
            unsigned char gray = value <= 0 ? 0 : value >= 255 ? 255 : (unsigned char) value;
            rgb[index * 4] = 255;
            rgb[index * 4 + 1] = rgb[index * 4 + 2] = rgb[index * 4 + 3] = gray;
        }
        space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        bytesPerPixel = 4;
        info = (CGBitmapInfo) kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef) bytes);
    CGImageRef result = CGImageCreate(width, height, 8, bytesPerPixel * 8, width * bytesPerPixel, space, info, provider,
                                      NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return result;
}

- (void) drawRect: (NSRect) dirtyRect
{
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
    IsiXLegacyDCMPix *image = self.curDCM;
    if (controller || !image) return;
    CGContextRef context = [NSGraphicsContext currentContext].CGContext;
    CGContextSaveGState(context);
    NSAffineTransform *transform = [self isixImageToView];
    [transform concat];
    CGImageRef picture = IsiXCreateImage(image, windowLevel, windowWidth);
    if (picture)
    {
        // Core Graphics draws an image upright in its rectangle: the
        // transform puts row 0 at the top, so the image is drawn flipped back.
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 0, image.pheight);
        CGContextScaleCTM(context, 1, -1);
        CGContextSetInterpolationQuality(context, kCGInterpolationNone);
        CGContextDrawImage(context, CGRectMake(0, 0, image.pwidth, image.pheight), picture);
        CGContextRestoreGState(context);
        CGImageRelease(picture);
    }
    double point = 1 / MAX(fabs(transform.transformStruct.m11), 1e-6);
    for (IsiXLegacyROI *roi in self.curRoiList)
    {
        if (![roi isKindOfClass: [IsiXLegacyROI class]]) continue;
        NSArray<IsiXLegacyMyPoint*> *outline = roi.points;
        if (outline.count == 0) continue;
        RGBColor color = roi.rgbcolor;
        BOOL black = color.red == 0 && color.green == 0 && color.blue == 0;
        CGContextSetRGBStrokeColor(context, black ? 1 : color.red / 65535.0, black ? 1 : color.green / 65535.0, black ? 0 : color.blue / 65535.0, 1);
        CGContextSetLineWidth(context, 1.5 * point);
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, outline[0].x, outline[0].y);
        for (NSUInteger index = 1; index < outline.count; index++) CGContextAddLineToPoint(context, outline[index].x, outline[index].y);
        if (roi.type != tMesure && roi.type != tOPolygon && roi.type != tAngle && outline.count > 2) CGContextClosePath(context);
        CGContextStrokePath(context);
    }
    [self subDrawRect: dirtyRect];
    CGContextRestoreGState(context);
}

- (void) subDrawRect: (NSRect) aRect {}

- (NSImage*) nsimage: (BOOL) originalSize
{
    NSRect bounds = self.bounds;
    if (NSIsEmptyRect(bounds)) return nil;
    NSBitmapImageRep *bitmap = [self bitmapImageRepForCachingDisplayInRect: bounds];
    if (!bitmap) return nil;
    [self cacheDisplayInRect: bounds toBitmapImageRep: bitmap];
    NSImage *picture = [[NSImage alloc] initWithSize: bounds.size];
    [picture addRepresentation: bitmap];
    return picture;
}

- (NSImage*) nsimage { return [self nsimage: NO]; }

@end
