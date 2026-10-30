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
// From a viewer's image to the database: the image whose SOP Instance UID the
// plugin API gives for it, its series and its study.

#import "IsiXLegacyBridgeInternal.h"

@implementation IsiXLegacyDCMPix (IsiXLegacyDatabase)

- (IsiXLegacyDicomImage*) imageObj
{
    IsiXLegacyImageInfo *info = [[self isixSourceSession] infoWithSlice: [self isixSourceSlice] phase: [self isixSourcePhase]];
    return [IsiXLegacyDicomImage isixImageWithSOPInstanceUID: info.sopInstanceUID frame: self.frameNo];
}

- (IsiXLegacyDicomSeries*) seriesObj { return self.imageObj.series; }
- (NSString*) sourceFile { return self.imageObj.completePath; }
- (NSString*) srcFile { return self.sourceFile; }

@end

@implementation IsiXLegacyViewerController (IsiXLegacyDatabase)

- (IsiXLegacyDicomSeries*) currentSeries
{
    NSArray *images = self.pixList;
    if (!images.count) return nil;
    return [images[(NSUInteger) MIN(MAX(self.imageView.curImage, 0), (long) images.count - 1)] seriesObj];
}

- (IsiXLegacyDicomStudy*) currentStudy { return self.currentSeries.study; }

@end
