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

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Variadic compatibility entry points format the message once, then use NSAlert.
FOUNDATION_EXPORT NSInteger HorosRunAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton,
    NSString * _Nullable otherButton, ...) NS_FORMAT_FUNCTION(2, 6);
FOUNDATION_EXPORT NSInteger HorosRunInformationalAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton,
    NSString * _Nullable otherButton, ...) NS_FORMAT_FUNCTION(2, 6);
FOUNDATION_EXPORT NSInteger HorosRunCriticalAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton,
    NSString * _Nullable otherButton, ...) NS_FORMAT_FUNCTION(2, 6);

// Historical NSRun*AlertPanel responses. They intentionally differ from
// NSAlertFirst/Second/ThirdButtonReturn and remain part of this bridge's ABI.
enum {
    HorosAlertDefaultResponse = 1,
    HorosAlertAlternateResponse = 0,
    HorosAlertOtherResponse = -1
};

/// NSRunAlertPanel, NSRunInformationalAlertPanel and NSRunCriticalAlertPanel
/// were C variadic functions, which Swift cannot call. This bridge now uses
/// NSAlert, preserving button order and the historical 1/0/-1 responses.
/// Callers format messages before passing them here.
@interface HorosAlertPanel : NSObject

@property(class, nonatomic, readonly) NSInteger defaultResponse;
@property(class, nonatomic, readonly) NSInteger alternateResponse;
@property(class, nonatomic, readonly) NSInteger otherResponse;

/// NSRunAlertPanel(title, @"%@", defaultButton, alternateButton, otherButton, message)
+ (NSInteger)runWithTitle:(nullable NSString *)title
                  message:(NSString *)message
            defaultButton:(nullable NSString *)defaultButton
          alternateButton:(nullable NSString *)alternateButton
              otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(run(title:message:defaultButton:alternateButton:otherButton:));

/// NSRunInformationalAlertPanel(title, @"%@", defaultButton, alternateButton, otherButton, message)
+ (NSInteger)runInformationalWithTitle:(nullable NSString *)title
                               message:(NSString *)message
                         defaultButton:(nullable NSString *)defaultButton
                       alternateButton:(nullable NSString *)alternateButton
                           otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(runInformational(title:message:defaultButton:alternateButton:otherButton:));

/// NSRunCriticalAlertPanel(title, @"%@", defaultButton, alternateButton, otherButton, message)
+ (NSInteger)runCriticalWithTitle:(nullable NSString *)title
                          message:(NSString *)message
                    defaultButton:(nullable NSString *)defaultButton
                  alternateButton:(nullable NSString *)alternateButton
                      otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(runCritical(title:message:defaultButton:alternateButton:otherButton:));

/// Asynchronous alert sheet with the same historical response contract.
+ (void)beginWithTitle:(nullable NSString *)title
               message:(NSString *)message
         defaultButton:(nullable NSString *)defaultButton
       alternateButton:(nullable NSString *)alternateButton
           otherButton:(nullable NSString *)otherButton
        modalForWindow:(NSWindow *)window
     completionHandler:(void (^ _Nullable)(NSInteger response))completion;

@end

NS_ASSUME_NONNULL_END
