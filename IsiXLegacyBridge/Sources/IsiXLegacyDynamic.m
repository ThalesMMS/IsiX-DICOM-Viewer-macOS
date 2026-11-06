//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting. The
// prefix header turns NSClassFromString(), objc_getClass() and
// objc_lookUpClass() into the functions of this file; here the real ones are
// called with their names in parentheses, which a function-like macro does not
// replace.

#import "IsiXLegacyDynamic.h"
#import "IsiXLegacyBridgeDefines.h"
#import <dlfcn.h>

/// The prefix of the kit's runtime class names in this plugin: IsiXLegacy<namespace>_.
static NSString *const IsiXLegacyKitPrefix = @"IsiXLegacy" ISIX_LEGACY_STRING(ISIX_LEGACY_NAMESPACE) "_";

/// The plugin's executable, which the kit is compiled into, and its bundle.
typedef struct {
    const char *path;
    void *handle;
    NSString *bundlePath;
    NSString *name;
} IsiXLegacyImage;

static const IsiXLegacyImage *IsiXLegacyOwnImage(void)
{
    static IsiXLegacyImage image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((const void *)&IsiXLegacyOwnImage, &info) && info.dli_fname) {
            image.path = strdup(info.dli_fname);
            // RTLD_FIRST: symbols of this executable only, not of the libraries it links.
            image.handle = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY | RTLD_FIRST);
        }
        NSString *path = image.path ? @(image.path) : @"";
        NSRange bundle = [path rangeOfString: @".isixplugin/"];
        image.bundlePath = bundle.location != NSNotFound ? [path substringToIndex: NSMaxRange(bundle)] : path;
        image.name = (bundle.location != NSNotFound ? image.bundlePath : path).lastPathComponent.stringByDeletingPathExtension;
        if (image.name.length == 0) image.name = @"IsiXLegacyBridge";
    });
    return &image;
}

/// The class of that runtime name in the plugin's own executable: by its
/// symbol, since the runtime's lookup by name answers with one class when two
/// images define the same name (two copies of a legacy plugin, or a plugin
/// class named as one of the application's).
static Class IsiXLegacyOwnClass(NSString *name)
{
    const IsiXLegacyImage *image = IsiXLegacyOwnImage();
    if (image->handle) {
        void *symbol = dlsym(image->handle, [@"OBJC_CLASS_$_" stringByAppendingString: name].UTF8String);
        if (symbol) return (__bridge Class)symbol;
    }
    Class found = (objc_lookUpClass)(name.UTF8String);
    const char *where = found ? class_getImageName(found) : NULL;
    return where && image->path && strcmp(where, image->path) == 0 ? found : Nil;
}

/// Whether a class may be given to the plugin: the system's, IsiXPluginKit's,
/// the plugin's bundle's, or one made at run time (which has no image).
static BOOL IsiXLegacyMayGive(Class cls)
{
    const char *where = class_getImageName(cls);
    if (where == NULL) return YES;
    NSString *path = @(where);
    for (NSString *prefix in @[@"/System/", @"/usr/lib/", @"/Library/Apple/"])
        if ([path hasPrefix: prefix]) return YES;
    if ([path containsString: @"/IsiXPluginKit.framework/"]) return YES;
    NSString *bundle = IsiXLegacyOwnImage()->bundlePath;
    return bundle.length > 0 && [path hasPrefix: bundle];
}

/// Writes each message once.
static void IsiXLegacyLogOnce(NSString *key, NSString *message)
{
    static NSMutableSet<NSString *> *written;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ written = [NSMutableSet set]; });
    BOOL first;
    @synchronized (written) {
        first = ![written containsObject: key];
        if (first) [written addObject: key];
    }
    if (first) NSLog(@"%@: %@", IsiXLegacyOwnImage()->name, message);
}

Class IsiXLegacyClassFromString(NSString *name)
{
    if (![name isKindOfClass: [NSString class]] || name.length == 0) return Nil;
    Class own = IsiXLegacyOwnClass(name);
    if (own) return own;
    Class kit = IsiXLegacyOwnClass([IsiXLegacyKitPrefix stringByAppendingString: name]);
    if (kit) return kit;
    Class found = (NSClassFromString)(name);
    if (found == Nil || IsiXLegacyMayGive(found)) return found;
    IsiXLegacyLogOnce([@"class " stringByAppendingString: name],
                      [NSString stringWithFormat: @"the class %@ is the application's, which a ported plugin cannot use, and "
                                                  @"the porting kit has no equivalent for it; looking it up by name gives nil.",
                                                  name]);
    return Nil;
}

Class IsiXLegacyObjcGetClass(const char *name)
{
    return name ? IsiXLegacyClassFromString(@(name)) : Nil;
}

#pragma mark - Selectors and keys without an equivalent

/// The legacy name of a kit class (ViewerController for IsiXLegacy<namespace>_ViewerController).
static NSString *IsiXLegacyNameOf(Class cls)
{
    NSString *name = NSStringFromClass(cls);
    return [name hasPrefix: IsiXLegacyKitPrefix] ? [name substringFromIndex: IsiXLegacyKitPrefix.length] : name;
}

static IMP IsiXLegacySuperSignature;
static IMP IsiXLegacySuperClassSignature;

/// A method the kit does not have still has a signature, so that the runtime
/// forwards the message instead of raising: an object result, object arguments.
static NSMethodSignature *IsiXLegacySignature(id self, SEL _cmd, SEL selector)
{
    IMP original = object_isClass(self) ? IsiXLegacySuperClassSignature : IsiXLegacySuperSignature;
    NSMethodSignature *signature = ((NSMethodSignature * (*)(id, SEL, SEL))original)(self, _cmd, selector);
    if (signature || selector == NULL) return signature;
    NSString *name = NSStringFromSelector(selector);
    NSUInteger arguments = [name componentsSeparatedByString: @":"].count - 1;
    NSMutableString *types = [NSMutableString stringWithString: @"@@:"];
    for (NSUInteger i = 0; i < arguments; i++) [types appendString: @"@"];
    return [NSMethodSignature signatureWithObjCTypes: types.UTF8String];
}

static void IsiXLegacyForward(id self, SEL _cmd, NSInvocation *invocation)
{
    BOOL isClass = object_isClass(self);
    NSString *legacy = IsiXLegacyNameOf(isClass ? (Class)self : object_getClass(self));
    NSString *method = [NSString stringWithFormat: @"%c[%@ %@]", isClass ? '+' : '-', legacy,
                                                   NSStringFromSelector(invocation.selector)];
    IsiXLegacyLogOnce(method, [NSString stringWithFormat: @"%@ has no equivalent in the porting kit; it gives nil.", method]);
    NSUInteger length = invocation.methodSignature.methodReturnLength;
    if (length > 0) {
        void *zero = calloc(1, length);
        [invocation setReturnValue: zero];
        free(zero);
    }
}

static id IsiXLegacyValueForUndefinedKey(id self, SEL _cmd, NSString *key)
{
    NSString *legacy = IsiXLegacyNameOf(object_getClass(self));
    IsiXLegacyLogOnce([NSString stringWithFormat: @"get %@.%@", legacy, key],
                      [NSString stringWithFormat: @"the key %@ of %@ has no equivalent in the porting kit; it gives nil.",
                                                  key, legacy]);
    return nil;
}

static void IsiXLegacySetValueForUndefinedKey(id self, SEL _cmd, id value, NSString *key)
{
    NSString *legacy = IsiXLegacyNameOf(object_getClass(self));
    IsiXLegacyLogOnce([NSString stringWithFormat: @"set %@.%@", legacy, key],
                      [NSString stringWithFormat: @"the key %@ of %@ has no equivalent in the porting kit; the value is "
                                                  @"not kept.", key, legacy]);
}

/// Gives the kit's classes made directly on NSObject (PluginFilter,
/// ViewerController, DCMView, DCMPix, ROI, MyPoint and the ones added later)
/// the answers above; their subclasses, the plugin's filter among them,
/// inherit them. Classes made on other Foundation or AppKit classes keep their
/// own behaviour. Runs when the plugin's executable is loaded.
__attribute__((constructor)) static void IsiXLegacyInstallDynamicAnswers(void)
{
    const IsiXLegacyImage *image = IsiXLegacyOwnImage();
    if (image->path == NULL) return;
    Class root = [NSObject class];
    SEL signature = @selector(methodSignatureForSelector:);
    IsiXLegacySuperSignature = class_getMethodImplementation(root, signature);
    IsiXLegacySuperClassSignature = class_getMethodImplementation(object_getClass(root), signature);
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(image->path, &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = @(names[i]);
        if (![name hasPrefix: IsiXLegacyKitPrefix]) continue;
        Class cls = IsiXLegacyOwnClass(name);
        if (cls == Nil || class_getSuperclass(cls) != root) continue;
        for (Class target in @[cls, object_getClass(cls)]) {
            class_addMethod(target, signature, (IMP)IsiXLegacySignature, "@@::");
            class_addMethod(target, @selector(forwardInvocation:), (IMP)IsiXLegacyForward, "v@:@");
        }
        class_addMethod(cls, @selector(valueForUndefinedKey:), (IMP)IsiXLegacyValueForUndefinedKey, "@@:@");
        class_addMethod(cls, @selector(setValue:forUndefinedKey:), (IMP)IsiXLegacySetValueForUndefinedKey, "v@:@@");
    }
    free(names);
}
