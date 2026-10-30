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
// -[ViewerController exportDICOMFileInt:withName:allViewers:]: the image shown,
// as the plugin's copy of its pixels holds it, written by the kit's DICOMExport
// as an image of a derived series of its study. The file is the kit's, as
// DICOMExport's are: +[BrowserController addFiles:...] and the other imports of
// the kit put it in the database.

#import "IsiXLegacyBridgeInternal.h"
#import <objc/runtime.h>

static const void *IsiXLegacyExportersKey = &IsiXLegacyExportersKey;

@implementation IsiXLegacyViewerController (IsiXLegacyExport)

/// The exporter of the series named `name` for this viewer: the images a
/// plugin exports under one name go to one series, numbered from 1.
- (IsiXLegacyDICOMExport*) isixExporterNamed: (NSString*) name
{
    NSMutableDictionary *exporters = objc_getAssociatedObject(self, IsiXLegacyExportersKey);
    if (!exporters)
    {
        exporters = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, IsiXLegacyExportersKey, exporters, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    IsiXLegacyDICOMExport *exporter = exporters[name];
    if (!exporter)
    {
        exporter = [[IsiXLegacyDICOMExport alloc] init];
        [exporter setSeriesDescription: name];
        [exporter beginSeriesWithNumber: 5000 + (long) exporters.count];
        exporters[name] = exporter;
    }
    return exporter;
}

- (NSDictionary*) exportDICOMFileInt: (int) screenCapture withName: (NSString*) name allViewers: (BOOL) allViewers
{
    // 1 and 2 captured the viewer as it was drawn, annotations and ROIs
    // included, and allViewers joined every viewer in one picture: the plugin
    // API gives the images, not the viewer's drawing.
    if (screenCapture != 0 || allViewers)
    {
        [[IsiXLegacyDatabaseBridge shared] fail: @"exportDICOMFileInt: only the image in memory (0) can be exported; a capture of the viewer as drawn is not part of the porting kit."];
        return nil;
    }
    NSArray *images = self.pixList;
    if (!images.count) return nil;
    IsiXLegacyDCMPix *pix = images[(NSUInteger) MIN(MAX(self.imageView.curImage, 0), (long) images.count - 1)];
    NSString *source = pix.sourceFile;
    if (!source)
    {
        [[IsiXLegacyDatabaseBridge shared] fail: @"exportDICOMFileInt: the image shown has no file in the database to export from."];
        return nil;
    }
    IsiXLegacyDICOMExport *exporter = [self isixExporterNamed: name.length ? name : @"IsiX export"];
    [exporter setSourceFile: source];
    long width = pix.pwidth, height = pix.pheight;
    NSMutableData *rgb = nil;
    if (pix.isRGB)
    {
        // The plugin's copy is ARGB; DICOM takes RGB.
        rgb = [NSMutableData dataWithLength: (NSUInteger) (width * height * 3)];
        const unsigned char *argb = (const unsigned char*) pix.fImage;
        unsigned char *out = rgb.mutableBytes;
        for (long i = 0; i < width * height; i++)
        {
            out[i * 3] = argb[i * 4 + 1];
            out[i * 3 + 1] = argb[i * 4 + 2];
            out[i * 3 + 2] = argb[i * 4 + 3];
        }
        [exporter setPixelData: rgb.mutableBytes samplesPerPixel: 3 bitsPerSample: 8 width: width height: height];
    }
    else
        [exporter setPixelData: (unsigned char*) pix.fImage samplesPerPixel: 1 bitsPerSample: 32 width: width height: height];
    float orientation[9] = {0}, position[3] = {(float) pix.originX, (float) pix.originY, (float) pix.originZ};
    [pix orientation: orientation];
    [exporter setPixelSpacing: (float) pix.pixelSpacingX :(float) pix.pixelSpacingY];
    [exporter setSliceThickness: pix.sliceThickness];
    [exporter setOrientation: orientation];
    [exporter setPosition: position];
    [exporter setSlicePosition: (float) pix.sliceLocation];
    float wl = 0, ww = 0;
    [self.imageView getWLWW: &wl :&ww];
    if (ww > 0) [exporter setDefaultWWWL: (long) ww :(long) wl];
    NSString *file = [exporter writeDCMFile: nil];
    return file ? @{@"file": file} : nil;
}

- (NSDictionary*) exportDICOMFileInt: (int) screenCapture withName: (NSString*) name
{
    return [self exportDICOMFileInt: screenCapture withName: name allViewers: NO];
}

- (void) adjustSlider
{
    // The application's viewer keeps its own slider in step with the series.
}

@end
