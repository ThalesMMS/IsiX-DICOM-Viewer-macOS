//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy plugin written the way Horos plugins were, for the kit's test: it
// goes through the core of IsiXLegacyBridge and writes what it saw to the
// property list named by ISIX_LEGACY_PROBE_OUTPUT. The test compiles it with
// manual reference counting and with ARC.

#import <Foundation/Foundation.h>
#import "PluginFilter.h"

@interface KitProbeFilter : PluginFilter
@end

@implementation KitProbeFilter

#if __has_feature(objc_arc)
#define PROBE_RELEASE(object)
#else
#define PROBE_RELEASE(object) [object release]
#endif

- (long) filterImage: (NSString*) menuName
{
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    report[@"menu"] = menuName;
    report[@"arc"] = @(__has_feature(objc_arc) ? YES : NO);

    NSArray *pixList = [viewerController pixList];
    DCMPix *pix = [pixList objectAtIndex: 1];
    report[@"images"] = @(pixList.count);
    report[@"size"] = @[@([pix pwidth]), @([pix pheight])];
    report[@"spacing"] = @[@([pix pixelSpacingX]), @([pix pixelSpacingY])];
    report[@"current"] = @([[viewerController imageView] curImage]);
    report[@"phases"] = @([viewerController maxMovieIndex]);
    float d[3];
    [pix convertPixX: 2.5 pixY: 1.5 toDICOMCoords: d];
    report[@"patient"] = @[@(d[0]), @(d[1]), @(d[2])];

    // Pixels: slice 1 doubled, then an update with nothing changed.
    float *pixels = [pix fImage];
    for (long i = 0; i < [pix pwidth] * [pix pheight]; i++) pixels[i] *= 2;
    report[@"volumeIsFirstImage"] = @([viewerController volumePtr] == [[pixList objectAtIndex: 0] fImage]);
    [viewerController needsDisplayUpdate];
    [viewerController needsDisplayUpdate];

    // Window level.
    [[viewerController imageView] setWLWW: 123 :456];
    float wl, ww;
    [[viewerController imageView] getWLWW: &wl :&ww];
    report[@"windowLevel"] = @[@(wl), @(ww)];

    // A rectangle made by the plugin joins the viewer when the lists are updated.
    long current = [[viewerController imageView] curImage];
    ROI *rectangle = [[ROI alloc] initWithType: tROI :[pix pixelSpacingX] :[pix pixelSpacingY] :NSMakePoint(0, 0)];
    [rectangle setROIRect: NSMakeRect(1.5, 1.5, 3, 2)];
    [rectangle setName: @"probe rectangle"];
    [[[viewerController roiList] objectAtIndex: current] addObject: rectangle];
    PROBE_RELEASE(rectangle);
    [viewerController needsDisplayUpdate];
    report[@"rectangleMean"] = @([rectangle mean]);
    report[@"rectangleArea"] = @([rectangle roiArea]);

    // A polygon from newROI:, points added one by one.
    ROI *polygon = [viewerController newROI: tCPolygon];
    [polygon addPoint: NSMakePoint(1.5, 1.5)];
    [polygon addPoint: NSMakePoint(4.5, 1.5)];
    [polygon addPoint: NSMakePoint(1.5, 3.5)];
    [polygon setName: @"probe polygon"];
    [[[viewerController roiList] objectAtIndex: current] addObject: polygon];
    [viewerController needsDisplayUpdate];
    NSMutableArray *roisAfterAdd = [NSMutableArray array];
    for (ROI *roi in [[viewerController roiList] objectAtIndex: current]) [roisAfterAdd addObject: [roi name]];
    report[@"roisAfterAdd"] = roisAfterAdd;
    report[@"sameObjectAfterRead"] = @([[[viewerController roiList] objectAtIndex: current] indexOfObjectIdenticalTo: polygon] != NSNotFound);

    // A ROI in the viewer changes at once.
    [rectangle setName: @"renamed rectangle"];
    [viewerController selectROI: polygon deselectingOther: YES];
    report[@"polygonCentroid"] = @[@([polygon centroid].x), @([polygon centroid].y)];

    // Removed through deleteROI:, and by taking it out of its list.
    [viewerController deleteROI: rectangle];
    [[[viewerController roiList] objectAtIndex: current] removeObjectIdenticalTo: polygon];
    [viewerController needsDisplayUpdate];
    report[@"roisAtEnd"] = @([[[viewerController roiList] objectAtIndex: current] count]);

    NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey: @"ISIX_LEGACY_PROBE_OUTPUT"];
    if (path) [report writeToFile: [path stringByAppendingFormat: @"-%@.plist", report[@"arc"]] atomically: YES];
    return 0;
}

@end
