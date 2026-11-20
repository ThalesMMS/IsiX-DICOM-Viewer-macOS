//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Tells the main actor that the preferences changed, without making the
/// thread that wrote them wait.
///
/// UserDefaults posts its change on the thread that wrote the value, before
/// the write returns. For an observer registered with the main operation
/// queue, the notification centre runs the block on the main thread and keeps
/// the writer waiting until it has run. A writer that holds what the main
/// thread is waiting for, the queue of a managed object context above all,
/// then never goes on, and neither does the main thread.
///
/// The observer made here is told on the writer's thread and only passes the
/// news on: a change made on the main thread is answered there and then, as
/// an observer of the main queue answers it, and one made on another thread
/// is answered from the main queue, later, with the writer already gone.
public enum PreferenceChangeNotice {
    /// Calls `changed` on the main actor after every change of the
    /// preferences, until the token it answers is removed from `center`.
    public static func observe(in center: NotificationCenter = .default,
                               _ changed: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated(changed)
            } else {
                DispatchQueue.main.async(execute: changed)
            }
        }
    }
}
