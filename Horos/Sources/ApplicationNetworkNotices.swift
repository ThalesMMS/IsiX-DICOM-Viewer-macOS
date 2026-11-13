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
import IsiXPreferences

/// What the listeners and the nodes of the network tell the person using the
/// application: a port a listener could not open, a listener that failed once
/// open, and a query that failed where no window shows it.
///
/// Made from the process graph and handed to the listeners and the nodes,
/// which reached the application controller's singleton for these before.
/// Sendable: it keeps only the graph, so any thread may hold it and call it.
struct ApplicationNetworkNotices: Sendable {
    let processGraph: ProcessGraph

    /// The notices of the process, made from the graph that the composition
    /// point of the single entry of DICOM hands out.
    static let process = ApplicationNetworkNotices(processGraph: DatabaseIngest.process.processGraph)

    /// A listener could not open `port`: the log says so, the Listener
    /// preferences say it every time for a DICOM listener, and the person is
    /// told once per service and port, unless the DICOM notices are hidden.
    /// Any thread, before it returns: the listener thread that failed reports
    /// before anything starts the listener again.
    func listenBindFailed(service: String, port: Int, errno code: Int32) {
        let line = ListenBindFailure.logLine(service: service, port: port, errno: code)
        NSLog("%@", line as NSString)
        let dicom = service.hasPrefix("DICOM")
        // The Listener preferences say it every time, whatever notice is shown.
        if dicom {
            ListenerStatus.setNotListening(reason: ListenerStatus.bindFailureReason(port: port, errno: code),
                                           tls: service != ListenBindFailure.dicomService)
        }
        // Read through the catalog: work that hides the notices for as long as
        // it lasts gives the key a value UserDefaults itself does not hold.
        if dicom && processGraph.preferences[NetworkPreferences.hidesListenerErrors] {
            return
        }
        if !ListenBindFailure.consumeUserNotice(service: service, port: port) {
            return
        }
        let message = service == ListenBindFailure.webPortalService
            ? ListenBindFailure.webPortalUserMessage(port: port)
            : ListenBindFailure.userMessage(service: service, port: port, errno: code)
        ListenBindFailure.presentUserNotice(message)
    }

    /// A listener failed after opening its port: said in the notices panel by
    /// the application controller, whose method a plugin may replace. Any
    /// thread; shown later, from the main run loop.
    func listenerFailed(_ message: String) {
        let graph = processGraph
        onMainRunLoop { graph.appController?.displayListenerError(message) }
    }

    /// A system notification of the kind `name`, for a failure no window
    /// shows, such as an automatic query's. Any thread; delivered later on the
    /// main actor, at most one of a kind in the controller's interval.
    func notify(title: String, description: String, name: String) {
        let graph = processGraph
        onMainActor { graph.appController?.notificationTitle(title, description: description, name: name) }
    }
}
