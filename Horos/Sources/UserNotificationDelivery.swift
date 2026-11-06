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
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXInstallation
import UserNotifications

/// The notifications the application posts to the Notification Center:
/// imports, listeners, sends, routing and reports post them from any thread.
/// Each kind has one identifier, so a notification replaces the previous one
/// of its kind, and `NotificationBurstPolicy` groups a burst into one delivery
/// with the latest text.
@MainActor
final class UserNotificationDelivery {

    /// Hands a notification to the Notification Center: its title, its text,
    /// its kind and whether it makes a sound.
    typealias Deliver = @MainActor @Sendable (_ title: String?, _ body: String?, _ kind: String, _ sound: Bool) -> Void

    private var policy: NotificationBurstPolicy
    private let deliver: Deliver

    nonisolated init(policy: NotificationBurstPolicy = NotificationBurstPolicy(),
                     deliver: @escaping Deliver = UserNotificationDelivery.deliverToNotificationCenter) {
        self.policy = policy
        self.deliver = deliver
    }

    /// Posts a notification of the kind `name` (the application's own for
    /// none). Any thread: now on the main thread, or later on the main queue.
    nonisolated func post(title: String?, description: String?, name: String?) {
        onMainActor { self.postOnMainActor(title: title, description: description, name: name) }
    }

    private func postOnMainActor(title: String?, description: String?, name: String?) {
        let kind = NotificationBurstPolicy.kind(of: name)
        let notice = NotificationBurstPolicy.Notice(title: title, body: description)
        switch policy.post(notice, kind: kind, at: Date.timeIntervalSinceReferenceDate) {
        case .deliverNow(let sound):
            deliver(title, description, kind, sound)
        case .deliverLater(let wait):
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated {
                    if let latest = self.policy.flush(kind: kind, at: Date.timeIntervalSinceReferenceDate) {
                        self.deliver(latest.title, latest.body, kind, false)
                    }
                }
            }
        case .replacedPending:
            break
        }
    }

    /// Asks once at launch to post notifications, even when the preferences
    /// do not turn them on, since the user may turn them on while the
    /// application runs, and clears the ones earlier versions left, one per
    /// imported batch. The system grants this only to a signed, notarized
    /// application.
    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.requestAuthorization(options: [.sound, .alert]) { granted, error in
            if let error {
                NSLog("User Notification authorization request failed, error=[%@]", error.localizedDescription as NSString)
            } else {
                NSLog("User Notification authorization request succeeded")
            }
        }
    }

    /// The delivery to the Notification Center, under the one identifier of the kind.
    nonisolated static func deliverToNotificationCenter(_ title: String?, _ body: String?, _ kind: String, _ sound: Bool) {
        let notification = UNMutableNotificationContent()
        notification.title = title ?? ""
        notification.body = body ?? ""
        notification.categoryIdentifier = kind
        notification.threadIdentifier = kind
        if sound { notification.sound = UNNotificationSound.default }

        // No trigger: delivered at once.
        let request = UNNotificationRequest(identifier: "org.horosproject.notification." + kind, content: notification, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("User Notification failed for title=[%@] description=[%@] error=[%@]", (title ?? "(null)") as NSString,
                      ((body ?? "(null)") as NSString).replacingOccurrences(of: "\r", with: "\n") as NSString,
                      error.localizedDescription as NSString)
            }
        }
    }
}
