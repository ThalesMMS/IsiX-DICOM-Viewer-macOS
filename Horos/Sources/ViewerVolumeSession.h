#import "ViewerController.h"
@class HorosVolumeSession;

/// Shared by planar, MPR and SEG consumers. Main-thread access only; the host
/// viewer owns the session, while consumers own cancellable load tokens.
///
/// The ViewerController (HorosVolumeSession) category is implemented in Swift
/// since #722 (ViewerVolumeSession.swift). This header keeps
/// <Horos/ViewerVolumeSession.h>: the generated interface declares
/// -horosVolumeSession in a category of ViewerController.

#ifndef HOROS_BRIDGING_HEADER
#import "Horos-Swift.h"
#endif
