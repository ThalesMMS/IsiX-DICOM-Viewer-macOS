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

#import "IsiXLegacyPortSupport.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// AppKit runs alerts, sheets and panels on the main thread only; a legacy
// plugin sometimes called them from its own threads.
static void IsiXLegacyOnMainThread(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

// The legacy delegate callback: - (void)didEnd:(id)sheet returnCode:(NSInteger)code contextInfo:(void *)info.
static void IsiXLegacySendDidEnd(id delegate, SEL selector, id sheet, NSInteger returnCode, void *contextInfo)
{
    if (delegate == nil || selector == NULL) return;
    void (*didEnd)(id, SEL, id, NSInteger, void *) = (void (*)(id, SEL, id, NSInteger, void *))[delegate methodForSelector: selector];
    didEnd(delegate, selector, sheet, returnCode, contextInfo);
}

// An alert with the legacy buttons, and the legacy return code of each button
// in the order NSAlert numbers them from NSAlertFirstButtonReturn.
static NSAlert *IsiXLegacyMakeAlert(NSAlertStyle style, NSString *title, NSString *message, NSString *defaultButton,
                                    NSString *alternateButton, NSString *otherButton, NSArray<NSNumber *> **codes)
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = style;
    alert.messageText = title ?: @"Alert";
    alert.informativeText = message ?: @"";
    NSMutableArray<NSNumber *> *returns = [NSMutableArray array];
    [alert addButtonWithTitle: defaultButton ?: @"OK"];
    [returns addObject: @(IsiXLegacyAlertDefaultReturn)];
    if (alternateButton) {
        [alert addButtonWithTitle: alternateButton];
        [returns addObject: @(IsiXLegacyAlertAlternateReturn)];
    }
    if (otherButton) {
        [alert addButtonWithTitle: otherButton];
        [returns addObject: @(IsiXLegacyAlertOtherReturn)];
    }
    *codes = returns;
    return alert;
}

static NSInteger IsiXLegacyCode(NSModalResponse response, NSArray<NSNumber *> *codes)
{
    NSInteger index = response - NSAlertFirstButtonReturn;
    return index >= 0 && index < (NSInteger)codes.count ? codes[index].integerValue : IsiXLegacyAlertErrorReturn;
}

static NSInteger IsiXLegacyRunAlert(NSAlertStyle style, NSString *title, NSString *message, NSString *defaultButton,
                                    NSString *alternateButton, NSString *otherButton)
{
    __block NSInteger code = IsiXLegacyAlertErrorReturn;
    IsiXLegacyOnMainThread(^{
        NSArray<NSNumber *> *codes = nil;
        NSAlert *alert = IsiXLegacyMakeAlert(style, title, message, defaultButton, alternateButton, otherButton, &codes);
        code = IsiXLegacyCode([alert runModal], codes);
    });
    return code;
}

static NSString *IsiXLegacyFormat(NSString *format, va_list arguments)
{
    return format ? [[NSString alloc] initWithFormat: format arguments: arguments] : @"";
}

NSInteger IsiXLegacyRunAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton,
                                  NSString *otherButton, ...)
{
    va_list arguments;
    va_start(arguments, otherButton);
    NSString *message = IsiXLegacyFormat(format, arguments);
    va_end(arguments);
    return IsiXLegacyRunAlert(NSAlertStyleWarning, title, message, defaultButton, alternateButton, otherButton);
}

NSInteger IsiXLegacyRunCriticalAlertPanel(NSString *title, NSString *format, NSString *defaultButton,
                                          NSString *alternateButton, NSString *otherButton, ...)
{
    va_list arguments;
    va_start(arguments, otherButton);
    NSString *message = IsiXLegacyFormat(format, arguments);
    va_end(arguments);
    return IsiXLegacyRunAlert(NSAlertStyleCritical, title, message, defaultButton, alternateButton, otherButton);
}

NSInteger IsiXLegacyRunInformationalAlertPanel(NSString *title, NSString *format, NSString *defaultButton,
                                               NSString *alternateButton, NSString *otherButton, ...)
{
    va_list arguments;
    va_start(arguments, otherButton);
    NSString *message = IsiXLegacyFormat(format, arguments);
    va_end(arguments);
    return IsiXLegacyRunAlert(NSAlertStyleInformational, title, message, defaultButton, alternateButton, otherButton);
}

NSAlert *IsiXLegacyAlertWithMessageText(NSString *message, NSString *defaultButton, NSString *alternateButton,
                                        NSString *otherButton, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *text = IsiXLegacyFormat(format, arguments);
    va_end(arguments);
    __block NSAlert *alert = nil;
    IsiXLegacyOnMainThread(^{
        NSArray<NSNumber *> *codes = nil;
        alert = IsiXLegacyMakeAlert(NSAlertStyleWarning, message ?: @"", text, defaultButton, alternateButton,
                                    otherButton, &codes);
        // NSAlert returns the tag of the button the user chose.
        [alert.buttons enumerateObjectsUsingBlock: ^(NSButton *button, NSUInteger index, BOOL *stop) {
            button.tag = codes[index].integerValue;
        }];
    });
    return alert;
}

static void IsiXLegacyAlertSheet(NSAlertStyle style, NSString *title, NSString *defaultButton, NSString *alternateButton,
                                 NSString *otherButton, NSWindow *window, id delegate, SEL didEndSelector,
                                 SEL didDismissSelector, void *contextInfo, NSString *message)
{
    IsiXLegacyOnMainThread(^{
        NSArray<NSNumber *> *codes = nil;
        NSAlert *alert = IsiXLegacyMakeAlert(style, title, message, defaultButton, alternateButton, otherButton, &codes);
        void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
            NSInteger code = IsiXLegacyCode(response, codes);
            IsiXLegacySendDidEnd(delegate, didEndSelector, alert.window, code, contextInfo);
            IsiXLegacySendDidEnd(delegate, didDismissSelector, alert.window, code, contextInfo);
        };
        if (window) [alert beginSheetModalForWindow: window completionHandler: finish];
        else finish([alert runModal]);
    });
}

void IsiXLegacyBeginAlertSheet(NSString *title, NSString *defaultButton, NSString *alternateButton, NSString *otherButton,
                               NSWindow *window, id delegate, SEL didEndSelector, SEL didDismissSelector,
                               void *contextInfo, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = IsiXLegacyFormat(format, arguments);
    va_end(arguments);
    IsiXLegacyAlertSheet(NSAlertStyleWarning, title, defaultButton, alternateButton, otherButton, window, delegate,
                         didEndSelector, didDismissSelector, contextInfo, message);
}

void IsiXLegacyBeginCriticalAlertSheet(NSString *title, NSString *defaultButton, NSString *alternateButton,
                                       NSString *otherButton, NSWindow *window, id delegate, SEL didEndSelector,
                                       SEL didDismissSelector, void *contextInfo, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = IsiXLegacyFormat(format, arguments);
    va_end(arguments);
    IsiXLegacyAlertSheet(NSAlertStyleCritical, title, defaultButton, alternateButton, otherButton, window, delegate,
                         didEndSelector, didDismissSelector, contextInfo, message);
}

void IsiXLegacyBeginInformationalAlertSheet(NSString *title, NSString *defaultButton, NSString *alternateButton,
                                            NSString *otherButton, NSWindow *window, id delegate, SEL didEndSelector,
                                            SEL didDismissSelector, void *contextInfo, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = IsiXLegacyFormat(format, arguments);
    va_end(arguments);
    IsiXLegacyAlertSheet(NSAlertStyleInformational, title, defaultButton, alternateButton, otherButton, window, delegate,
                         didEndSelector, didDismissSelector, contextInfo, message);
}

void IsiXLegacyAlertBeginSheet(NSAlert *alert, NSWindow *window, id delegate, SEL didEndSelector, void *contextInfo)
{
    IsiXLegacyOnMainThread(^{
        void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
            IsiXLegacySendDidEnd(delegate, didEndSelector, alert, response, contextInfo);
        };
        if (window) [alert beginSheetModalForWindow: window completionHandler: finish];
        else finish([alert runModal]);
    });
}

void IsiXLegacyBeginSheet(NSWindow *sheet, NSWindow *window, id delegate, SEL didEndSelector, void *contextInfo)
{
    IsiXLegacyOnMainThread(^{
        if (window == nil) {
            // Without a window to attach the sheet to, AppKit's legacy call
            // decides, as it did for the legacy plugin.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [NSApp beginSheet: sheet modalForWindow: window modalDelegate: delegate didEndSelector: didEndSelector
                  contextInfo: contextInfo];
#pragma clang diagnostic pop
            return;
        }
        [window beginSheet: sheet completionHandler: ^(NSModalResponse response) {
            IsiXLegacySendDidEnd(delegate, didEndSelector, sheet, response, contextInfo);
        }];
    });
}

// File extensions or type identifiers as content types; unknown ones are left out.
static NSArray<UTType *> *IsiXLegacyContentTypes(NSArray *types)
{
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];
    for (id type in types) {
        if (![type isKindOfClass: [NSString class]] || [type length] == 0) continue;
        NSString *name = [type hasPrefix: @"."] ? [type substringFromIndex: 1] : type;
        UTType *contentType = [name containsString: @"."] ? [UTType typeWithIdentifier: name] : nil;
        contentType = contentType ?: [UTType typeWithFilenameExtension: name];
        if (contentType) [contentTypes addObject: contentType];
    }
    return contentTypes;
}

static void IsiXLegacyPreparePanel(NSSavePanel *panel, NSString *directory, NSString *file, NSArray *types)
{
    if (directory.length) panel.directoryURL = [NSURL fileURLWithPath: directory isDirectory: YES];
    if (file.length) {
        if ([panel isKindOfClass: [NSOpenPanel class]]) {
            // The legacy open panel selected `file` in `directory`.
            NSString *folder = directory.length ? directory : panel.directoryURL.path;
            if (folder) panel.directoryURL = [NSURL fileURLWithPath: [folder stringByAppendingPathComponent: file]];
        } else {
            panel.nameFieldStringValue = file;
        }
    }
    if (types) {
        NSArray<UTType *> *contentTypes = IsiXLegacyContentTypes(types);
        if (contentTypes.count) panel.allowedContentTypes = contentTypes;
    }
}

void IsiXLegacyPanelBeginSheet(NSSavePanel *panel, NSString *directory, NSString *file, NSArray *types,
                               NSWindow *window, id delegate, SEL didEndSelector, void *contextInfo)
{
    IsiXLegacyOnMainThread(^{
        IsiXLegacyPreparePanel(panel, directory, file, types);
        void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
            IsiXLegacySendDidEnd(delegate, didEndSelector, panel, response, contextInfo);
        };
        if (window) [panel beginSheetModalForWindow: window completionHandler: finish];
        else finish([panel runModal]);
    });
}

NSInteger IsiXLegacyPanelRunModal(NSSavePanel *panel, NSString *directory, NSString *file, NSArray *types)
{
    __block NSInteger response = NSModalResponseCancel;
    IsiXLegacyOnMainThread(^{
        IsiXLegacyPreparePanel(panel, directory, file, types);
        response = [panel runModal];
    });
    return response;
}

void IsiXLegacyPanelSetRequiredFileType(NSSavePanel *panel, NSString *type)
{
    panel.allowedContentTypes = type.length ? IsiXLegacyContentTypes(@[type]) : @[];
}

NSArray *IsiXLegacyPanelFilenames(id panel)
{
    if ([panel isKindOfClass: [NSOpenPanel class]]) return [[(NSOpenPanel *)panel URLs] valueForKey: @"path"];
    SEL filenames = @selector(filenames);
    if (![panel respondsToSelector: filenames]) return nil;
    NSArray *(*send)(id, SEL) = (NSArray *(*)(id, SEL))[panel methodForSelector: filenames];
    return send(panel, filenames);
}

BOOL IsiXLegacyLoadNibNamed(NSString *name, id owner)
{
    __block BOOL loaded = NO;
    IsiXLegacyOnMainThread(^{
        NSArray *objects = nil;
        NSBundle *bundle = owner ? [NSBundle bundleForClass: [owner class]] : [NSBundle mainBundle];
        loaded = [bundle loadNibNamed: name owner: owner topLevelObjects: &objects];
        if (!loaded && bundle != [NSBundle mainBundle])
            loaded = [[NSBundle mainBundle] loadNibNamed: name owner: owner topLevelObjects: &objects];
        // The legacy call handed the top-level objects to the owner retained;
        // the plugin releases them, or keeps them, as it always did.
        for (id object in objects) (void)CFBridgingRetain(object);
    });
    return loaded;
}
