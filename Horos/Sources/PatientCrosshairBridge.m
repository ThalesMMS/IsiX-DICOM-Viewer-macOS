#import "PatientCrosshairBridge.h"
#import "ViewerVolumeSession.h"
#import "OrthogonalMPRViewer.h"
#import "Horos-Swift.h"

BOOL HorosPublishPatientCrosshair(const float point[3], ViewerController *viewer, id owner)
{
    if (!viewer || viewer.windowWillClose) return NO;
    HorosPatientCrosshairController *crosshair = [HorosPatientCrosshairController shared];
    HorosVolumeSession *session = [viewer horosVolumeSession];
    if (session)
        return [crosshair publishX:point[0] y:point[1] z:point[2] session:session owner:owner];
    // A second window on a series another viewer holds has no session of its own.
    HorosVolumeIdentity *identity = [viewer horosVolumeIdentity];
    return identity && [crosshair publishX:point[0] y:point[1] z:point[2] identity:identity owner:owner];
}

HorosPatientCrosshairPoint *HorosPatientCrosshairForViewer(ViewerController *viewer)
{
    if (!viewer || viewer.windowWillClose) return nil;
    HorosPatientCrosshairController *crosshair = [HorosPatientCrosshairController shared];
    if (!crosshair.currentPoint) return nil;
    id owner = crosshair.sourceOwner;
    ViewerController *source = nil;
    if ([owner isKindOfClass:[ViewerController class]]) source = owner;
    else if ([owner isKindOfClass:[OrthogonalMPRViewer class]]) source = [owner viewerController];
    BOOL registered = source && (viewer.registeredViewer == source || source.registeredViewer == viewer);
    BOOL useFrame = [[NSUserDefaults standardUserDefaults] boolForKey:HorosViewerReferenceLines.frameOfReferencePreferenceKey];
    HorosVolumeSession *session = [viewer horosVolumeSession];
    if (session)
        return [crosshair pointForSession:session registered:registered useFrameOfReference:useFrame];
    HorosVolumeIdentity *identity = [viewer horosVolumeIdentity];
    return identity ? [crosshair pointForIdentity:identity registered:registered useFrameOfReference:useFrame] : nil;
}
