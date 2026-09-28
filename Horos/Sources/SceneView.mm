// A VTK scene presented by Metal, without VTK's OpenGL view (#733).
// See SceneView.h.

#import "SceneView.h"
#import "SceneOverlay.h"
#import "Horos-Swift.h"

#include <algorithm>
#include <cmath>
#include <vtkRenderer.h>
#include <vtkRenderWindow.h>
#include <vtkActor.h>
#include <vtkCamera.h>
#include <vtkCommand.h>
#include <vtkCallbackCommand.h>

@implementation HorosSceneView

@synthesize horosOrientationCubeShown = sceneCubeShown;

- (id) initWithFrame:(NSRect) frame
{
    if( (self = [super initWithFrame: frame]))
    {
        sceneRenderer = HorosVRRenderer::New();
        sceneWindow = HorosVRRenderWindow::New();
        sceneWindow->AddRenderer( sceneRenderer);
        sceneInteractor = HorosVRInteractor::New();
        sceneInteractor->SetRenderer( sceneRenderer);

        // The overlay after each render, as VTK drew its 2D actors last.
        vtkCallbackCommand *end = vtkCallbackCommand::New();
        end->SetClientData( self);
        end->SetCallback([](vtkObject *, unsigned long, void *context, void *) {
            [(HorosSceneView *) context horosDrawOverlay];
        });
        sceneOverlayTag = sceneRenderer->AddObserver( vtkCommand::EndEvent, end);
        end->Delete();

        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        [self prepareRenderWindow];
    }
    return self;
}

- (void) dealloc
{
    sceneStereo.turnOff = nil;
    [sceneStereo switchToMode: HorosStereoModeOff];
    [sceneStereo release];
    sceneRenderer->RemoveObserver( sceneOverlayTag);
    sceneWindow->SetEyePresenter( nil);
    sceneWindow->SetPresenter( nil);
    sceneWindow->RemoveRenderer( sceneRenderer);
    sceneInteractor->Delete();
    sceneRenderer->Delete();
    sceneWindow->Delete();
    [scenePresenter release];
    [super dealloc];
}

- (vtkRenderer *) renderer { return sceneRenderer; }
- (vtkRenderWindow *) renderWindow { return sceneWindow; }
- (vtkRenderWindow *) getVTKRenderWindow { return sceneWindow; }
- (HorosVRInteractor *) getInteractor { return sceneInteractor; }
- (HorosBoxWidget *) horosOverlayBoxWidget { return nullptr; }
- (vtkActor *) horosPickedActor { return (vtkActor *) scenePicked; }
- (void) prepareForRelease {}
- (void) removeAllActors { sceneRenderer->RemoveAllViewProps(); }

- (BOOL) acceptsFirstResponder { return YES; }
- (BOOL) mouseDownCanMoveWindow { return NO; }
- (BOOL) wantsUpdateLayer { return YES; }
- (BOOL) isOpaque { return YES; }
- (void) updateLayer { [self drawRect: self.bounds]; }

- (void) drawRect:(NSRect) rect
{
    if( [self prepareRenderWindow])
        sceneWindow->Render();
}

- (void) setHorosOrientationCubeShown:(BOOL) shown
{
    sceneCubeShown = shown;
    [self setNeedsDisplay: YES];
}

// The frame is drawn by Metal into a layer of its own, the first of the view's
// layer: the overlay's text and graphics are above it.
- (CAMetalLayer *) horosPictureLayer
{
    CALayer *host = self.layer;
    if( host == nil) return nil;
    CAMetalLayer *picture = scenePresenter.layer;
    if( picture == nil)
    {
        picture = [CAMetalLayer layer];
        picture.device = [HorosPlanarHostRenderer device];
        picture.presentsWithTransaction = YES;
        picture.opaque = YES;
        picture.anchorPoint = CGPointZero;
        picture.actions = @{ @"bounds": [NSNull null], @"position": [NSNull null], @"contents": [NSNull null] };
        scenePresenter = [[HorosVRPresenter alloc] initWithLayer: picture];
        if( scenePresenter == nil) return nil;
        sceneWindow->SetPresenter( scenePresenter);
    }
    if( picture.superlayer != host || host.sublayers.firstObject != picture)
    {
        [picture removeFromSuperlayer];
        [host insertSublayer: picture atIndex: 0];
    }
    return picture;
}

- (BOOL) prepareRenderWindow
{
    if( sceneWindow == nullptr) return NO;
    CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1;
    NSSize size = self.window ? [self convertSizeToBacking: self.bounds.size] : self.bounds.size;
    // The two eyes side by side render at half the width each (#734).
    if( sceneStereo) size = [sceneStereo renderSizeForBacking: size];
    int width = MAX( 1, (int) lround( size.width)), height = MAX( 1, (int) lround( size.height));
    int *current = sceneWindow->GetSize();
    if( current[0] != width || current[1] != height)
        sceneWindow->SetSize( width, height);
    // For text actors, as vtkCocoaGLView set it.
    if( sceneWindow->GetDPI() != lround( 72.0 * scale))
        sceneWindow->SetDPI( lround( 72.0 * scale));
    if( self.window == nil) return NO;

    CAMetalLayer *picture = [self horosPictureLayer];
    if( picture)
    {
        [CATransaction begin];
        [CATransaction setDisableActions: YES];
        picture.contentsScale = scale;
        picture.frame = self.bounds;
        CGColorSpaceRef space = self.window.colorSpace.CGColorSpace;
        if( space && picture.colorspace != space)
            picture.colorspace = space;
        [CATransaction commit];
        if( CGSizeEqualToSize( picture.drawableSize, CGSizeMake( width, height)) == NO)
            picture.drawableSize = CGSizeMake( width, height);
        if( sceneStereo)
            [sceneStereo layoutPicture: picture bounds: self.bounds scale: scale renderSize: CGSizeMake( width, height)];
    }
    return YES;
}

#pragma mark - Stereo (#734)

- (void) horosSetStereoMode:(NSInteger) requested
{
    if( sceneStereo == nil)
    {
        sceneStereo = [[HorosStereoPresentation alloc] initWithView: self];
        __block HorosSceneView *view = self;
        sceneStereo.turnOff = ^{ [view horosSetStereoMode: HorosStereoModeOff]; };
    }
    BOOL was = sceneStereo.mode != HorosStereoModeOff;
    HorosStereoMode mode = [sceneStereo switchToMode: (HorosStereoMode) requested];
    HorosSetStereoMode( sceneWindow, mode, sceneStereo.eyePresenter);
    if( was != ( mode != HorosStereoModeOff))
        [self horosStereoDidChange: mode != HorosStereoModeOff];
    [self prepareRenderWindow];
    [self setNeedsDisplay: YES];
}

- (NSInteger) horosStereoMode { return sceneStereo ? sceneStereo.mode : HorosStereoModeOff; }

- (void) horosStereoDidChange:(BOOL) on {}

- (IBAction) SwitchStereoMode:(id) sender
{
    HorosStereoMode mode = self.horosStereoMode == HorosStereoModeOff ? HorosStereoModeRedBlue : HorosStereoModeOff;
    if( [sender isKindOfClass: [NSMenuItem class]])
        mode = (HorosStereoMode) [sender tag];
    [self horosSetStereoMode: mode];
    if( [sender isKindOfClass: [NSMenuItem class]])
        for( NSMenuItem *item in [[sender menu] itemArray])
            if( item.tag >= HorosStereoModeOff && item.tag <= HorosStereoModeOneScreen)
                item.state = item.tag == self.horosStereoMode ? NSControlStateValueOn : NSControlStateValueOff;
}

// The eyes change sides: VTK's eye angle changes sign.
- (IBAction) invertedSides:(id) sender
{
    vtkCamera *camera = sceneRenderer->GetActiveCamera();
    BOOL inverted = camera->GetEyeAngle() >= 0;
    camera->SetEyeAngle( ( inverted ? -1 : 1) * fabs( camera->GetEyeAngle()));
    if( [sender respondsToSelector: @selector(setState:)])
        [sender setState: inverted ? NSControlStateValueOn : NSControlStateValueOff];
    [self setNeedsDisplay: YES];
}

- (void) horosSetStereoScreenHeight:(double) height distance:(double) distance eyeSeparation:(double) separation
{
    vtkCamera *camera = sceneRenderer->GetActiveCamera();
    double sign = camera->GetEyeAngle() < 0 ? -1 : 1;
    camera->SetViewAngle( [HorosStereoPresentation viewAngleForScreenHeight: height distance: distance]);
    camera->SetEyeAngle( sign * [HorosStereoPresentation eyeAngleForSeparation: separation distance: distance]);
    [self setNeedsDisplay: YES];
}

// The right eye's half of the view is the left eye's scene too.
- (NSPoint) horosEyePoint:(NSPoint) backing
{
    int width = sceneWindow->GetSize()[0];
    if( self.horosStereoMode == HorosStereoModeOneScreen && backing.x >= width) backing.x -= width;
    return backing;
}

- (void) setFrameSize:(NSSize) newSize
{
    [super setFrameSize: newSize];
    [self prepareRenderWindow];
}

- (void) viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self prepareRenderWindow];
}

- (void) viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self prepareRenderWindow];
    [self setNeedsDisplay: YES];
}

// Mouse moves reach the view whether or not it has the focus, as with
// vtkCocoaGLView's tracking area.
- (void) updateTrackingAreas
{
    for( NSTrackingArea *area in [[self.trackingAreas copy] autorelease])
        if( area.owner == self && ( area.options & NSTrackingMouseMoved))
            [self removeTrackingArea: area];
    NSTrackingArea *moves = [[[NSTrackingArea alloc] initWithRect: NSZeroRect
                                                          options: NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                            owner: self userInfo: nil] autorelease];
    [self addTrackingArea: moves];
    [super updateTrackingAreas];
}

#pragma mark - Events, as vtkCocoaGLView handed them to VTK

- (void) horosInvokeVTKEvent:(unsigned long) eventId forEvent:(NSEvent *) event
{
    NSPoint backing = [self horosEyePoint: [self convertPointToBacking: [self convertPoint: [event locationInWindow] fromView: nil]]];
    NSUInteger flags = [event modifierFlags];
    int shift = ( flags & NSEventModifierFlagShift) != 0;
    int control = ( flags & ( NSEventModifierFlagControl | NSEventModifierFlagCommand)) != 0;
    int repeat = 0;
    if( event.type != NSEventTypeScrollWheel && event.type != NSEventTypeMouseMoved)
        repeat = event.clickCount > 1 ? (int) event.clickCount - 1 : 0;
    sceneInteractor->SetEventInformation( (int) backing.x, (int) backing.y, control, shift, 0, repeat);
    sceneInteractor->SetAltKey( ( flags & NSEventModifierFlagOption) != 0);
    sceneInteractor->InvokeEvent( eventId, nullptr);
}

- (void) mouseDown:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::LeftButtonPressEvent forEvent: event]; }
- (void) mouseUp:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::LeftButtonReleaseEvent forEvent: event]; }
- (void) rightMouseDown:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::RightButtonPressEvent forEvent: event]; }
- (void) rightMouseUp:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::RightButtonReleaseEvent forEvent: event]; }
- (void) otherMouseDown:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::MiddleButtonPressEvent forEvent: event]; }
- (void) otherMouseUp:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::MiddleButtonReleaseEvent forEvent: event]; }
- (void) mouseMoved:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::MouseMoveEvent forEvent: event]; }
- (void) mouseDragged:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::MouseMoveEvent forEvent: event]; }
- (void) rightMouseDragged:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::MouseMoveEvent forEvent: event]; }
- (void) otherMouseDragged:(NSEvent *) event { [self horosInvokeVTKEvent: vtkCommand::MouseMoveEvent forEvent: event]; }

- (void) scrollWheel:(NSEvent *) event
{
    if( event.deltaY > 0) [self horosInvokeVTKEvent: vtkCommand::MouseWheelForwardEvent forEvent: event];
    else if( event.deltaY < 0) [self horosInvokeVTKEvent: vtkCommand::MouseWheelBackwardEvent forEvent: event];
}

// The keys VTK's trackball style answered with something the scene shows:
// 'r' resets the camera and 'p' picks. The others changed nothing shown.
- (void) keyDown:(NSEvent *) event
{
    if( [[event characters] length] == 0) return;
    unichar c = [[event characters] characterAtIndex: 0];
    if( c == 27 && self.horosStereoMode == HorosStereoModeTwoScreens)
        [self horosSetStereoMode: HorosStereoModeOff];
    else if( c == 'r' || c == 'R')
    {
        sceneRenderer->ResetCamera();
        [self setNeedsDisplay: YES];
    }
    else if( c == 'p' || c == 'P')
    {
        NSPoint where = [self horosEyePoint: [self convertPointToBacking: [self convertPoint: [event locationInWindow] fromView: nil]]];
        [self horosPickAtX: where.x y: where.y];
    }
}

- (void) keyUp:(NSEvent *) event {}

#pragma mark - Pick and overlay

- (NSArray *) horosPickableActors { return nil; }

- (void) horosClearPick
{
    scenePicked = nullptr;
    [self setNeedsDisplay: YES];
}

- (void) horosPickAtX:(double) x y:(double) y
{
    scenePicked = nullptr;
    double nearest = INFINITY, from[4], to[4];
    HorosVRInteractor::ComputeDisplayToWorld( sceneRenderer, x, y, 0, from);
    HorosVRInteractor::ComputeDisplayToWorld( sceneRenderer, x, y, 1, to);
    double ray[3] = { to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    double length2 = ray[0]*ray[0] + ray[1]*ray[1] + ray[2]*ray[2];
    for( NSValue *value in [self horosPickableActors])
    {
        vtkActor *actor = (vtkActor *) [value pointerValue];
        if( length2 <= 0 || actor == nullptr || actor->GetVisibility() == 0 || actor->GetPickable() == 0) continue;
        double *bounds = actor->GetBounds();
        double centre[3] = { (bounds[0] + bounds[1]) / 2, (bounds[2] + bounds[3]) / 2, (bounds[4] + bounds[5]) / 2 };
        double radius = std::max( bounds[1] - bounds[0], std::max( bounds[3] - bounds[2], bounds[5] - bounds[4])) / 2;
        double offset[3] = { from[0] - centre[0], from[1] - centre[1], from[2] - centre[2] };
        double b = offset[0]*ray[0] + offset[1]*ray[1] + offset[2]*ray[2];
        double c = offset[0]*offset[0] + offset[1]*offset[1] + offset[2]*offset[2] - radius * radius;
        double discriminant = b * b - length2 * c;
        if( discriminant < 0) continue;
        double t = ( -b - sqrt( discriminant)) / length2;
        if( t < 0) t = ( -b + sqrt( discriminant)) / length2;
        if( t >= 0 && t < nearest) { nearest = t; scenePicked = actor; }
    }
    [self setNeedsDisplay: YES];
}

- (void) horosDrawOverlay
{
    HorosSceneOverlayExtras extras;
    // The original took the cube away in stereo.
    extras.cube = sceneCubeShown && self.horosStereoMode == HorosStereoModeOff;
    extras.box = [self horosOverlayBoxWidget];
    extras.picked = (vtkActor *) scenePicked;
    HorosDrawSceneOverlay( self, sceneRenderer, HorosVisibleActors2D( sceneRenderer), extras);
}

@end
