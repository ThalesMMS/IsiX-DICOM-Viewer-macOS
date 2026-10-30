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
// The ROI lists are the legacy ones: one mutable array per image, which the
// plugin may add ROIs to or remove ROIs from. Before the lists are handed out
// again, when the viewer is updated and at the end of a command, the kit
// compares them with what it handed out last: a new ROI is created in the
// application, a missing one is removed, a changed one is updated; then the
// lists are read again from the application, keeping the same objects for
// the same ROIs.

#import "IsiXLegacyBridgeInternal.h"

@interface IsiXLegacyViewerController () <IsiXLegacyControllerHooks>
@end

@implementation IsiXLegacyViewerController
{
    IsiXLegacyViewerSession *session;
    IsiXLegacyDCMView *imageView;
    NSMutableDictionary<NSNumber*, NSMutableArray*> *pixLists;
    NSMutableDictionary<NSNumber*, NSMutableArray*> *roiLists;
    /// Per phase, per image: the ROIs handed out last.
    NSMutableDictionary<NSNumber*, NSArray<NSArray*>*> *handedOut;
}

+ (IsiXLegacyViewerController*) isixControllerForSession: (IsiXLegacyViewerSession*) s
{
    if (!s) return nil;
    if ([s.legacyController isKindOfClass: [IsiXLegacyViewerController class]]) return s.legacyController;
    IsiXLegacyViewerController *controller = [[IsiXLegacyViewerController alloc] init];
    controller->session = s;
    // The pane is a view: made on the main thread, whichever thread asks for the viewer.
    __block IsiXLegacyDCMView *pane = nil;
    if ([NSThread isMainThread]) pane = [[IsiXLegacyDCMView alloc] initWithIsiXController: controller];
    else dispatch_sync(dispatch_get_main_queue(), ^{ pane = [[IsiXLegacyDCMView alloc] initWithIsiXController: controller]; });
    controller->imageView = pane;
    controller->pixLists = [NSMutableDictionary dictionary];
    controller->roiLists = [NSMutableDictionary dictionary];
    controller->handedOut = [NSMutableDictionary dictionary];
    s.legacyController = controller;
    [[IsiXLegacyNotificationCenter defaultCenter] isixAddKitObserver: controller selector: @selector(isixROIChanged:) name: OsirixROIChangeNotification object: nil];
    return controller;
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}

/// The legacy application redrew a viewer when a plugin announced a ROI with
/// "roiChange". A plugin that adds ROIs from its own window, outside a
/// command, relies on it: a ROI of one of this viewer's lists that is not in
/// the viewer yet is pushed on the next turn of the run loop, once the plugin
/// has finished setting it up.
- (void) isixROIChanged: (NSNotification*) note
{
    IsiXLegacyROI *roi = note.object;
    if (![roi isKindOfClass: [IsiXLegacyROI class]] || roi.isixHostState) return;
    for (NSArray *lists in [roiLists allValues])
        for (NSArray *list in lists)
            if ([list indexOfObjectIdenticalTo: roi] != NSNotFound)
            {
                [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(needsDisplayUpdate) object: nil];
                [self performSelector: @selector(needsDisplayUpdate) withObject: nil afterDelay: 0];
                return;
            }
}

- (IsiXLegacyViewerSession*) isixSession { return session; }

- (NSString*) description
{
    return [NSString stringWithFormat: @"<ViewerController %@ %@>", session.identifier, session.seriesDescription ?: @""];
}

#pragma mark Viewers

+ (NSMutableArray*) getDisplayed2DViewers
{
    NSMutableArray *viewers = [NSMutableArray array];
    for (IsiXLegacyViewerSession *s in [IsiXLegacyViewerSession openSessions])
        [viewers addObject: [self isixControllerForSession: s]];
    return viewers;
}

+ (NSMutableArray*) get2DViewers { return [self getDisplayed2DViewers]; }

+ (IsiXLegacyViewerController*) frontMostDisplayed2DViewer
{
    return [self isixControllerForSession: [IsiXLegacyViewerSession frontmostSession]];
}

- (NSWindow*) window { return session.window; }

- (IsiXLegacyViewerController*) blendingController { return nil; }
- (IsiXLegacyViewerController*) blendedWindow { return nil; }

#pragma mark Images

- (IsiXLegacyDCMView*) imageView { return imageView; }

- (short) maxMovieIndex { return (short) MAX(session.phaseCount, 1); }
- (short) curMovieIndex { return (short) session.currentPhase; }
- (short) getNumberOfImages { return (short) session.sliceCount; }
- (void) setImageIndex: (long) i { [session setCurrentSlice: i]; }
- (void) setMovieIndex: (short) i { [session setCurrentPhase: i]; }

- (NSMutableArray*) pixList: (long) phase
{
    NSMutableArray *list = pixLists[@(phase)];
    if (list) return list;
    list = [NSMutableArray array];
    long count = session.sliceCount;
    for (long slice = 0; slice < count; slice++)
        [list addObject: [[IsiXLegacyDCMPix alloc] initWithIsiXSession: session slice: slice phase: phase]];
    pixLists[@(phase)] = list;
    return list;
}

- (NSMutableArray*) pixList { return [self pixList: self.curMovieIndex]; }

- (NSMutableArray*) fileList: (long) phase
{
    NSMutableArray *files = [NSMutableArray array];
    long count = [self pixList: phase].count;
    for (long index = 0; index < count; index++)
    {
        NSMutableDictionary *file = [NSMutableDictionary dictionaryWithObjectsAndKeys: @(index), @"slice", @(phase), @"phase", nil];
        IsiXLegacyImageInfo *info = [session infoWithSlice: index phase: phase];
        if (info.sopInstanceUID) file[@"sopInstanceUID"] = info.sopInstanceUID;
        // The database's image when the plugin reads the database (IsiXLegacyViewerDatabase.m).
        IsiXLegacyDicomImage *image = [IsiXLegacyDicomImage isixImageWithSOPInstanceUID: info.sopInstanceUID frame: index];
        [files addObject: image ?: file];
    }
    return files;
}

- (NSMutableArray*) fileList { return [self fileList: self.curMovieIndex]; }

- (float*) volumePtr: (long) phase { return (float*) [session volumePixelsWithPhase: phase]; }
- (float*) volumePtr { return [self volumePtr: self.curMovieIndex]; }

- (BOOL) isDataVolumic
{
    NSArray *images = self.pixList;
    for (IsiXLegacyDCMPix *image in images)
        if (image.pwidth != [images[0] pwidth] || image.pheight != [images[0] pheight]) return NO;
    return images.count > 0;
}

- (float) curWW { return session.windowWidth; }
- (float) curWL { return session.windowCenter; }
- (void) setWL: (float) wl WW: (float) ww { [session setWindowWithCenter: wl width: ww]; }

- (id) startWaitWindow: (NSString*) message { return [[NSObject alloc] init]; }
- (id) startWaitProgressWindow: (NSString*) message :(long) max { return [[NSObject alloc] init]; }
- (void) waitIncrementBy: (id) waitWindow :(long) val {}
- (void) endWaitWindow: (id) waitWindow {}

#pragma mark ROI lists

/// Gives the application what the plugin changed in the lists of a phase.
- (void) isixPushROIsOfPhase: (long) phase
{
    NSArray<NSMutableArray*> *lists = roiLists[@(phase)];
    NSArray<NSArray*> *previous = handedOut[@(phase)];
    for (NSUInteger slice = 0; slice < lists.count; slice++)
    {
        NSMutableArray *list = lists[slice];
        if (slice < previous.count)
            for (IsiXLegacyROI *roi in previous[slice])
                if (roi.isixHostState && [list indexOfObjectIdenticalTo: roi] == NSNotFound)
                {
                    [session removeROI: roi.isixHostState];
                    [roi isixUnbind];
                }
        for (IsiXLegacyROI *roi in [list copy])
        {
            if (![roi isKindOfClass: [IsiXLegacyROI class]]) continue;
            if (roi.isixHostState) [roi isixPush];
            else
            {
                IsiXLegacyROIState *created = [session addROI: [roi isixWantedState] slice: slice phase: phase];
                if (created) [roi isixBindToSession: session state: created];
            }
        }
    }
}

/// Reads the ROIs of a phase again, keeping the objects of known ROIs.
- (void) isixPullROIsOfPhase: (long) phase
{
    NSMutableArray<NSMutableArray*> *lists = roiLists[@(phase)];
    if (!lists)
    {
        lists = [NSMutableArray array];
        roiLists[@(phase)] = lists;
    }
    NSArray *images = [self pixList: phase];
    long count = images.count;
    while ((long) lists.count < count) [lists addObject: [NSMutableArray array]];
    while ((long) lists.count > count) [lists removeLastObject];
    NSMutableArray *known = [NSMutableArray array];
    for (NSArray *list in lists) [known addObjectsFromArray: list];
    for (NSArray *list in handedOut[@(phase)]) [known addObjectsFromArray: list];
    NSMutableArray *handed = [NSMutableArray arrayWithCapacity: count];
    for (long slice = 0; slice < count; slice++)
    {
        NSMutableArray *list = [NSMutableArray array];
        for (IsiXLegacyROIState *state in [session roisWithSlice: slice phase: phase])
        {
            IsiXLegacyROI *roi = nil;
            for (IsiXLegacyROI *candidate in known)
                if ([candidate isKindOfClass: [IsiXLegacyROI class]] && [state isSameROIAs: candidate.isixHostState]) { roi = candidate; break; }
            if (roi) [roi isixAdoptHostState: state];
            else roi = [[IsiXLegacyROI alloc] initWithIsiXState: state session: session];
            IsiXLegacyDCMPix *image = images[slice];
            roi.pix = image;
            roi.curView = imageView;
            roi.pixelSpacingX = image.pixelSpacingX;
            roi.pixelSpacingY = image.pixelSpacingY;
            roi.imageOrigin = [IsiXLegacyDCMPix originCorrectedAccordingToOrientation: image];
            [list addObject: roi];
        }
        [lists[slice] setArray: list];
        [handed addObject: [list copy]];
    }
    handedOut[@(phase)] = handed;
}

- (NSMutableArray*) roiList: (long) phase
{
    [self isixPushROIsOfPhase: phase];
    [self isixPullROIsOfPhase: phase];
    return roiLists[@(phase)];
}

- (NSMutableArray*) roiList { return [self roiList: self.curMovieIndex]; }

- (void) isixLegacyFlush
{
    for (NSNumber *phase in [roiLists allKeys])
    {
        [self isixPushROIsOfPhase: phase.longValue];
        [self isixPullROIsOfPhase: phase.longValue];
    }
    (void) [session commitChangedPixels];
}

- (void) isixLegacySeriesReplaced
{
    [pixLists removeAllObjects];
    [roiLists removeAllObjects];
    [handedOut removeAllObjects];
}

- (void) needsDisplayUpdate
{
    [self isixLegacyFlush];
}

/// Every ROI of the phase shown, as the lists hold them now.
- (NSArray*) isixAllROIs
{
    NSMutableArray *all = [NSMutableArray array];
    for (NSArray *list in self.roiList) [all addObjectsFromArray: list];
    return all;
}

#pragma mark ROIs

- (IsiXLegacyMyPoint*) newPoint: (float) x :(float) y
{
    return [IsiXLegacyMyPoint point: NSMakePoint(x, y)];
}

- (IsiXLegacyROI*) newROI: (ToolMode) type
{
    IsiXLegacyDCMPix *image = imageView.curDCM;
    IsiXLegacyROI *roi = [[IsiXLegacyROI alloc] initWithType: type :image.pixelSpacingX :image.pixelSpacingY
                                                            :[IsiXLegacyDCMPix originCorrectedAccordingToOrientation: image]];
    roi.pix = image;
    roi.curView = imageView;
    return roi;
}

- (void) selectROI: (IsiXLegacyROI*) roi deselectingOther: (BOOL) deselectOther
{
    if (deselectOther)
        for (IsiXLegacyROI *other in [self isixAllROIs])
            if (other != roi && other.ROImode != ROI_sleep) other.ROImode = ROI_sleep;
    roi.ROImode = ROI_selected;
}

- (void) deselectAllROIs
{
    for (IsiXLegacyROI *roi in [self isixAllROIs])
        if (roi.ROImode != ROI_sleep) roi.ROImode = ROI_sleep;
}

- (void) deleteROI: (IsiXLegacyROI*) roi
{
    for (NSMutableArray *lists in [roiLists allValues])
        for (NSMutableArray *list in lists) [list removeObjectIdenticalTo: roi];
    if (roi.isixHostState) [session removeROI: roi.isixHostState];
    [roi isixUnbind];
}

- (BOOL) containsROI: (IsiXLegacyROI*) roi
{
    return [[self isixAllROIs] indexOfObjectIdenticalTo: roi] != NSNotFound;
}

- (NSMutableArray*) roisWithName: (NSString*) roiName
{
    NSMutableArray *found = [NSMutableArray array];
    for (IsiXLegacyROI *roi in [self isixAllROIs])
        if ([roi.name isEqualToString: roiName]) [found addObject: roi];
    return found;
}

- (void) deleteSeriesROIwithName: (NSString*) roiName
{
    for (IsiXLegacyROI *roi in [self roisWithName: roiName]) [self deleteROI: roi];
}

- (void) renameSeriesROIwithName: (NSString*) oldName newName: (NSString*) newName
{
    for (IsiXLegacyROI *roi in [self roisWithName: oldName]) roi.name = newName;
}

#pragma mark Events of the viewer

/// The kit's ROI of the application's ROI `identifier`, among the lists read.
- (IsiXLegacyROI*) isixKnownROI: (NSString*) identifier
{
    for (NSArray *lists in [roiLists allValues])
        for (NSArray *list in lists)
            for (IsiXLegacyROI *roi in list)
                if ([roi isKindOfClass: [IsiXLegacyROI class]] && [roi.isixHostState.hostIdentifier isEqualToString: identifier]) return roi;
    return nil;
}

- (void) isixROIEvent: (NSString*) identifier change: (NSString*) change
{
    IsiXLegacyNotificationCenter *center = [IsiXLegacyNotificationCenter defaultCenter];
    IsiXLegacyROI *roi = [self isixKnownROI: identifier];
    if ([change isEqualToString: @"removed"])
    {
        // Gone from the application: unbound first, so that the next push
        // does not ask the application to remove it again.
        if (!roi) return;
        [roi isixUnbind];
        for (NSMutableArray *lists in [roiLists allValues])
            for (NSMutableArray *list in lists) [list removeObjectIdenticalTo: roi];
        [center postNotificationName: OsirixRemoveROINotification object: roi];
        return;
    }
    if (roi)
    {
        // Only the ROI's own image is read again.
        IsiXLegacyROIState *known = roi.isixHostState;
        for (IsiXLegacyROIState *state in [session roisWithSlice: known.hostSlice phase: known.hostPhase])
            if ([state isSameROIAs: known]) { [roi isixAdoptHostState: state]; break; }
    }
    else
    {
        [self isixPullROIsOfPhase: self.curMovieIndex];
        roi = [self isixKnownROI: identifier];
    }
    if (!roi) return;
    if ([change isEqualToString: @"added"])
    {
        long slice = roi.isixHostState.hostSlice;
        [center postNotificationName: OsirixAddROINotification object: imageView
                            userInfo: @{@"ROI": roi, @"sliceNumber": @(slice)}];
    }
    else if ([change isEqualToString: @"selected"])
        [center postNotificationName: OsirixROISelectedNotification object: roi];
    else
        [center postNotificationName: OsirixROIChangeNotification object: roi];
}

#pragma mark New viewers

- (IsiXLegacyViewerController*) newWindow: (NSMutableArray*) newPixList :(NSMutableArray*) newFileList :(NSData*) volumeData
{
    NSMutableArray *slices = [NSMutableArray array], *phases = [NSMutableArray array], *pixels = [NSMutableArray array];
    for (IsiXLegacyDCMPix *image in newPixList)
    {
        if (![image isKindOfClass: [IsiXLegacyDCMPix class]] || image.isixSourceSession != session || !image.fImage) return nil;
        [slices addObject: @(image.isixSourceSlice)];
        [phases addObject: @(image.isixSourcePhase)];
        [pixels addObject: [NSValue valueWithPointer: image.fImage]];
    }
    return [IsiXLegacyViewerController isixControllerForSession:
            [session openDerivedSeriesWithSlices: slices phases: phases pixels: pixels]];
}

@end
