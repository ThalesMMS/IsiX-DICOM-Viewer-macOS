/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 ============================================================================*/

#import "HorosAlertPanel.h"

@implementation HorosAlertPanel

+ (NSInteger)defaultResponse { return HorosAlertDefaultResponse; }
+ (NSInteger)alternateResponse { return HorosAlertAlternateResponse; }
+ (NSInteger)otherResponse { return HorosAlertOtherResponse; }

+ (NSAlert *)alertWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton style:(NSAlertStyle)style
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = title ?: @"";
    alert.informativeText = message ?: @"";
    alert.alertStyle = style;
    [alert addButtonWithTitle:defaultButton ?: NSLocalizedString(@"OK", nil)].tag = NSAlertFirstButtonReturn;
    if (alternateButton)
        [alert addButtonWithTitle:alternateButton].tag = NSAlertSecondButtonReturn;
    if (otherButton)
        [alert addButtonWithTitle:otherButton].tag = NSAlertThirdButtonReturn;
    return alert;
}

+ (NSInteger)historicalResponse:(NSModalResponse)response alert:(NSAlert *)alert
{
    // AppKit returns the clicked button's tag, including custom tags. Keep
    // those tags in the SDK response domain and translate only at this boundary.
    for (NSButton *button in alert.buttons) {
        if (button.tag != response) continue;
        switch (response) {
            case NSAlertFirstButtonReturn: return HorosAlertDefaultResponse;
            case NSAlertSecondButtonReturn: return HorosAlertAlternateResponse;
            case NSAlertThirdButtonReturn: return HorosAlertOtherResponse;
        }
    }
    return HorosAlertAlternateResponse;
}

+ (NSInteger)runAlertWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton style:(NSAlertStyle)style
{
    NSAlert *alert = [self alertWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton style:style];
    return [self historicalResponse:[alert runModal] alert:alert];
}

+ (void)beginWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton modalForWindow:(NSWindow *)window completionHandler:(void (^)(NSInteger))completion
{
    NSAlert *alert = [self alertWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton style:NSAlertStyleWarning];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (completion) completion([self historicalResponse:response alert:alert]);
    }];
}

+ (NSInteger)runWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton
{
    return [self runAlertWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton style:NSAlertStyleWarning];
}

+ (NSInteger)runInformationalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton
{
    return [self runAlertWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton style:NSAlertStyleInformational];
}

+ (NSInteger)runCriticalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton
{
    return [self runAlertWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton style:NSAlertStyleCritical];
}

@end

// The legacy C functions accept a format string and retain their historical responses.
NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...)
{
    va_list arguments;
    va_start(arguments, otherButton);
    NSString *message = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
    va_end(arguments);
    return [HorosAlertPanel runWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton];
}

NSInteger HorosRunInformationalAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...)
{
    va_list arguments;
    va_start(arguments, otherButton);
    NSString *message = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
    va_end(arguments);
    return [HorosAlertPanel runInformationalWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton];
}

NSInteger HorosRunCriticalAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...)
{
    va_list arguments;
    va_start(arguments, otherButton);
    NSString *message = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
    va_end(arguments);
    return [HorosAlertPanel runCriticalWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton otherButton:otherButton];
}
