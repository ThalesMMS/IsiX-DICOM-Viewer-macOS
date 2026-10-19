#import "ViewerAutounbinderDetach.h"

#import <AppKit/NSWindowController.h>
#import <objc/runtime.h>

// Viewer.xib File's Owner bindings live on NSAutounbinder (an NSProxy stored
// in NSWindowController's _moreVars). AppKit does not retain the owner
// (_isRetainingBindingTarget = 0). -unbind: empties the binding list and
// leaves _bindingTarget set, so the proxy, which can outlive the controller
// after ViewerController's extra [self autorelease] on close, would still
// point at a dead object.
//
// Once HorosViewerBindingTeardown has removed the bindings, the target is
// cleared here instead. AppKit's retainBindingTargetAndUnbind, used before,
// made the proxy retain the owner, and the proxy is only released by the
// owner's own dealloc: no closed viewer was ever freed, with its views and
// pixels (test-viewer-binding-teardown.py). Read _moreVars.autounbinder.
// Do not call -_autounbinder — that getter creates a proxy when none
// exists. Do not clear the slot here: dropping it races the extra
// autorelease (measured zombie).
void HorosDetachAutounbinder(id owner)
{
    if (![owner isKindOfClass:[NSWindowController class]])
        return;

    Ivar moreSlot = class_getInstanceVariable([NSWindowController class], "_moreVars");
    if (!moreSlot)
        return;
    id moreVars = object_getIvar(owner, moreSlot);
    if (!moreVars)
        return;

    Ivar binderSlot = class_getInstanceVariable(object_getClass(moreVars), "autounbinder");
    if (!binderSlot)
        return;
    id unbinder = object_getIvar(moreVars, binderSlot);
    if (!unbinder)
        return;

    Class binderClass = object_getClass(unbinder);
    Ivar target = class_getInstanceVariable(binderClass, "_bindingTarget");
    Ivar retaining = class_getInstanceVariable(binderClass, "_isRetainingBindingTarget");
    if (!target || !retaining)
        return;
    // A proxy that retains its target releases it in its own dealloc; leave
    // that balance to AppKit.
    if (*((BOOL *)((char *)unbinder + ivar_getOffset(retaining))))
        return;
    // NSAutounbinder declares no ivar ownership, so object_setIvar assigns
    // without retain or release: the proxy did not own the controller.
    object_setIvar(unbinder, target, nil);
}
