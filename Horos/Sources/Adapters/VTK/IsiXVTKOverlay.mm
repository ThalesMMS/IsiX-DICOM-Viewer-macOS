//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXVTKOverlay.hpp"
#import "IsiXVTKInternal.hpp"

#include <vtkActor2D.h>
#include <vtkActor2DCollection.h>
#include <vtkCallbackCommand.h>
#include <vtkCommand.h>
#include <vtkNew.h>
#include <vtkPropCollection.h>
#include <vtkRenderer.h>

@implementation IsiXVTKOverlayObserver
{
@public
    vtkRenderer *_renderer;
    unsigned long _startTag, _endTag;
    /// The 2D actors that were visible when the render started, hidden from
    /// VTK for the render and drawn by the view after it.
    std::vector<vtkActor2D *> _shown;
    void (^_draw)(const std::vector<vtkActor2D *> &shown);
}

- (instancetype)initWithRenderer:(vtkRenderer *)renderer draw:(void (^)(const std::vector<vtkActor2D *> &))draw
{
    if ((self = [super init])) {
        _renderer = renderer;
        _renderer->Register(nullptr);
        _draw = [draw copy];
    }
    return self;
}

/// Shows again what the last render hid.
- (void)restoreShown
{
    for (vtkActor2D *actor : _shown) actor->SetVisibility(1);
    _shown.clear();
}

- (void)renderStarted
{
    [self restoreShown];
    // Each prop's 2D actors, assemblies included, as the former viewport
    // GetActors2D gathered them.
    vtkNew<vtkActor2DCollection> actors;
    vtkPropCollection *props = _renderer->GetViewProps();
    vtkCollectionSimpleIterator iterator;
    props->InitTraversal(iterator);
    while (vtkProp *prop = props->GetNextProp(iterator)) prop->GetActors2D(actors);
    actors->InitTraversal();
    while (vtkActor2D *actor = actors->GetNextActor2D()) {
        if (actor->GetVisibility()) {
            _shown.push_back(actor);
            actor->SetVisibility(0);
        }
    }
}

- (void)renderEnded
{
    for (vtkActor2D *actor : _shown) actor->SetVisibility(1);
    std::vector<vtkActor2D *> shown = _shown;
    if (_draw) _draw(shown);
    [self restoreShown];
}

- (void)invalidate
{
    if (!_renderer) return;
    try {
        [self restoreShown];
        _renderer->RemoveObserver(_startTag);
        _renderer->RemoveObserver(_endTag);
    } catch (const std::exception &exception) {
        IsiXVTKErrorFromException(exception.what(), "IsiXVTKOverlayObserver invalidate");
    } catch (...) {
        IsiXVTKErrorFromException("unknown exception", "IsiXVTKOverlayObserver invalidate");
    }
    _renderer->UnRegister(nullptr);
    _renderer = nullptr;
    _draw = nil;
}

- (void)dealloc
{
    [self invalidate];
}

@end

@implementation IsiXVTKOverlayObserver (IsiXVTKRenderer)

+ (instancetype)observerOfRenderer:(vtkRenderer *)renderer draw:(void (^)(const std::vector<vtkActor2D *> &))draw
                             error:(NSError *__autoreleasing *)error
{
    if (!renderer) {
        if (error) *error = IsiXVTKFailure(IsiXVTKErrorCodeUnavailable, @"The view has no renderer.", "IsiXVTKOverlayObserver observerOfRenderer");
        return nil;
    }
    IsiXVTKOverlayObserver *observer = [[IsiXVTKOverlayObserver alloc] initWithRenderer:renderer draw:draw];
    BOOL observed = IsiXVTKGuard(error, "IsiXVTKOverlayObserver observerOfRenderer", {renderer}, [&]() -> NSError * {
        // The observers point at the observer without retaining it: it removes
        // them before it goes.
        void *context = (__bridge void *)observer;
        vtkCallbackCommand *start = vtkCallbackCommand::New();
        start->SetClientData(context);
        start->SetCallback([](vtkObject *, unsigned long, void *client, void *) {
            [(__bridge IsiXVTKOverlayObserver *)client renderStarted];
        });
        // After the view's own start observers, which place and show the
        // measurements for this render.
        observer->_startTag = renderer->AddObserver(vtkCommand::StartEvent, start, -1.0);
        start->Delete();

        vtkCallbackCommand *end = vtkCallbackCommand::New();
        end->SetClientData(context);
        end->SetCallback([](vtkObject *, unsigned long, void *client, void *) {
            [(__bridge IsiXVTKOverlayObserver *)client renderEnded];
        });
        observer->_endTag = renderer->AddObserver(vtkCommand::EndEvent, end);
        end->Delete();
        return nil;
    });
    if (!observed) {
        [observer invalidate];
        return nil;
    }
    return observer;
}

@end
