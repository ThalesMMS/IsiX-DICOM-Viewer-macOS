//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The AppKit calls legacy plugins made that macOS deprecated, rebuilt on the
// current API with the legacy behaviour: the same return values, the same
// delegate callback with the same arguments. The converter
// (tools/port-legacy-plugin.py) rewrites the legacy calls into these; the
// project's prefix header (IsiXLegacyPrefix.h) declares them to every file.

#ifndef ISIX_LEGACY_PORT_SUPPORT_H
#define ISIX_LEGACY_PORT_SUPPORT_H

#import <Cocoa/Cocoa.h>

/// Each ported plugin compiles its own copy; none is exported from the bundle.
/// C functions, called from Objective-C and Objective-C++ alike.
#ifdef __cplusplus
#define ISIX_LEGACY_PORT_EXTERN extern "C" __attribute__((visibility("hidden")))
#else
#define ISIX_LEGACY_PORT_EXTERN extern __attribute__((visibility("hidden")))
#endif

/// The values NSRunAlertPanel() and the legacy alert sheets returned, for the
/// default, alternate and other buttons.
enum {
    IsiXLegacyAlertDefaultReturn = 1,
    IsiXLegacyAlertAlternateReturn = 0,
    IsiXLegacyAlertOtherReturn = -1,
    IsiXLegacyAlertErrorReturn = -2
};

/// NSRunAlertPanel(), NSRunCriticalAlertPanel(), NSRunInformationalAlertPanel():
/// an NSAlert run modally. A nil title is "Alert" and a nil default button
/// "OK"; the alternate and other buttons are shown when not nil. Returns
/// IsiXLegacyAlertDefaultReturn, IsiXLegacyAlertAlternateReturn or
/// IsiXLegacyAlertOtherReturn.
ISIX_LEGACY_PORT_EXTERN NSInteger IsiXLegacyRunAlertPanel(NSString *title, NSString *format, NSString *defaultButton,
                                                          NSString *alternateButton, NSString *otherButton, ...)
    NS_FORMAT_FUNCTION(2, 6);
ISIX_LEGACY_PORT_EXTERN NSInteger IsiXLegacyRunCriticalAlertPanel(NSString *title, NSString *format, NSString *defaultButton,
                                                                  NSString *alternateButton, NSString *otherButton, ...)
    NS_FORMAT_FUNCTION(2, 6);
ISIX_LEGACY_PORT_EXTERN NSInteger IsiXLegacyRunInformationalAlertPanel(NSString *title, NSString *format,
                                                                       NSString *defaultButton, NSString *alternateButton,
                                                                       NSString *otherButton, ...)
    NS_FORMAT_FUNCTION(2, 6);

/// +[NSAlert alertWithMessageText:defaultButton:alternateButton:otherButton:informativeTextWithFormat:]:
/// an alert whose buttons return IsiXLegacyAlertDefaultReturn,
/// IsiXLegacyAlertAlternateReturn and IsiXLegacyAlertOtherReturn from -runModal
/// and to a sheet's completion, as the legacy alert's did. A nil default button is "OK".
ISIX_LEGACY_PORT_EXTERN NSAlert *IsiXLegacyAlertWithMessageText(NSString *message, NSString *defaultButton,
                                                                NSString *alternateButton, NSString *otherButton,
                                                                NSString *format, ...) NS_FORMAT_FUNCTION(5, 6);

/// NSBeginAlertSheet() and its critical and informational forms: the alert as
/// a sheet on `window` (run modally when `window` is nil). When it ends,
/// `didEndSelector` and then `didDismissSelector` are sent to `delegate` with
/// the alert's window, the legacy return code and `contextInfo`:
/// - (void)sheetDidEnd:(NSWindow *)sheet returnCode:(NSInteger)code contextInfo:(void *)info.
ISIX_LEGACY_PORT_EXTERN void IsiXLegacyBeginAlertSheet(NSString *title, NSString *defaultButton, NSString *alternateButton,
                                                       NSString *otherButton, NSWindow *window, id delegate,
                                                       SEL didEndSelector, SEL didDismissSelector, void *contextInfo,
                                                       NSString *format, ...) NS_FORMAT_FUNCTION(10, 11);
ISIX_LEGACY_PORT_EXTERN void IsiXLegacyBeginCriticalAlertSheet(NSString *title, NSString *defaultButton,
                                                               NSString *alternateButton, NSString *otherButton,
                                                               NSWindow *window, id delegate, SEL didEndSelector,
                                                               SEL didDismissSelector, void *contextInfo,
                                                               NSString *format, ...) NS_FORMAT_FUNCTION(10, 11);
ISIX_LEGACY_PORT_EXTERN void IsiXLegacyBeginInformationalAlertSheet(NSString *title, NSString *defaultButton,
                                                                    NSString *alternateButton, NSString *otherButton,
                                                                    NSWindow *window, id delegate, SEL didEndSelector,
                                                                    SEL didDismissSelector, void *contextInfo,
                                                                    NSString *format, ...) NS_FORMAT_FUNCTION(10, 11);

/// -[NSAlert beginSheetModalForWindow:modalDelegate:didEndSelector:contextInfo:]:
/// the alert as a sheet (run modally when `window` is nil); then
/// - (void)alertDidEnd:(NSAlert *)alert returnCode:(NSInteger)code contextInfo:(void *)info.
ISIX_LEGACY_PORT_EXTERN void IsiXLegacyAlertBeginSheet(NSAlert *alert, NSWindow *window, id delegate, SEL didEndSelector,
                                                       void *contextInfo);

/// -[NSApplication beginSheet:modalForWindow:modalDelegate:didEndSelector:contextInfo:]:
/// -[NSWindow beginSheet:completionHandler:], ended as before by
/// -[NSApplication endSheet:returnCode:]; then
/// - (void)sheetDidEnd:(NSWindow *)sheet returnCode:(NSInteger)code contextInfo:(void *)info.
/// With a nil window the legacy call itself runs, as AppKit still offers it.
ISIX_LEGACY_PORT_EXTERN void IsiXLegacyBeginSheet(NSWindow *sheet, NSWindow *window, id delegate, SEL didEndSelector,
                                                  void *contextInfo);

/// -[NSSavePanel beginSheetForDirectory:file:modalForWindow:modalDelegate:didEndSelector:contextInfo:]
/// and -[NSOpenPanel beginSheetForDirectory:file:types:modalForWindow:...]: the
/// panel opened in `directory`, on `file`, limited to `types` (file extensions
/// or type identifiers; nil for any), as a sheet (run modally when `window`
/// is nil); then
/// - (void)panelDidEnd:(NSSavePanel *)panel returnCode:(int)code contextInfo:(void *)info,
/// with NSModalResponseOK (the legacy NSOKButton) or NSModalResponseCancel.
ISIX_LEGACY_PORT_EXTERN void IsiXLegacyPanelBeginSheet(NSSavePanel *panel, NSString *directory, NSString *file,
                                                       NSArray *types, NSWindow *window, id delegate,
                                                       SEL didEndSelector, void *contextInfo);

/// -[NSSavePanel runModalForDirectory:file:], -[NSOpenPanel runModalForDirectory:file:types:]
/// and -[NSOpenPanel runModalForTypes:]: NSModalResponseOK or NSModalResponseCancel.
ISIX_LEGACY_PORT_EXTERN NSInteger IsiXLegacyPanelRunModal(NSSavePanel *panel, NSString *directory, NSString *file,
                                                          NSArray *types);

/// -[NSSavePanel setRequiredFileType:]: the panel's only file type, or any
/// type when `type` is nil or empty.
ISIX_LEGACY_PORT_EXTERN void IsiXLegacyPanelSetRequiredFileType(NSSavePanel *panel, NSString *type);

/// -[NSOpenPanel filenames]: the paths of the panel's URLs. Any other object
/// that answers -filenames is asked as before.
ISIX_LEGACY_PORT_EXTERN NSArray *IsiXLegacyPanelFilenames(id panel);

/// +[NSBundle loadNibNamed:owner:]: the nib of the owner's bundle (or of the
/// main bundle), its top-level objects retained for the owner as the legacy
/// call left them. Returns NO when the nib is not found.
ISIX_LEGACY_PORT_EXTERN BOOL IsiXLegacyLoadNibNamed(NSString *name, id owner);

#endif
