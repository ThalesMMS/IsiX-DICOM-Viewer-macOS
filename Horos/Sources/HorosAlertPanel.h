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

/// NSRunAlertPanel, NSRunInformationalAlertPanel and NSRunCriticalAlertPanel
/// are C variadic functions, which Swift cannot call. Code migrated to Swift
/// (#711) formats the message itself and calls the same AppKit function
/// through here, with the message as the only argument of a "%@" format: the
/// panel, its buttons and the value it returns (NSAlertDefaultReturn,
/// NSAlertAlternateReturn, NSAlertOtherReturn) are those of the former call.
@interface HorosAlertPanel : NSObject

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

@end

NS_ASSUME_NONNULL_END
