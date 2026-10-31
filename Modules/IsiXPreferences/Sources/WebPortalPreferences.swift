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

/// The preferences of the web portal, its WADO-only server and its emails that NetworkPreferences does not
/// declare. The portal's switch, port, timeouts, movie sizes and WADO keys are there and are read from there.
/// None of these keys has a registered value: absent, each reads as false, 0 or nil, as the accessor the portal
/// always used read it. Several are also the keys of the exported `Osirix…DefaultsKey` constants and of the
/// `+[NSUserDefaults webPortal…]` selectors, which keep the same text.
public enum WebPortalPreferences {
    /// The address the portal gives in its links and emails (`OsirixWebPortalAddressDefaultsKey`); empty means
    /// this computer's host name, as `+webPortalAddress` reads it.
    public static let address = PreferenceKey<String?>("webServerAddress")
    /// The portal answers over HTTPS (`OsirixWebPortalUsesSSLDefaultsKey`).
    public static let usesSSL = PreferenceKey<Bool>("encryptedWebServer")
    /// The portal serves the pages of the user's folder before its own (`OsirixWebPortalPrefersCustomWebPagesKey`).
    public static let prefersCustomWebPages = PreferenceKey<Bool>("customWebPages")
    /// The portal asks for an account (`OsirixWebPortalRequiresAuthenticationDefaultsKey`). Without it there
    /// are no users, so no notification emails either.
    public static let requiresAuthentication = PreferenceKey<Bool>("passwordWebServer")
    /// The title of the portal's pages; empty means the application's.
    public static let title = PreferenceKey<String?>("WebPortalTitle")
    /// Each study the portal shows or sends is written to the study's log.
    public static let logsActivity = PreferenceKey<Bool>("logWebServer")
    /// An administrator may delete studies from the portal.
    public static let adminCanDeleteStudies = PreferenceKey<Bool>("webPortalAdminCanDeleteStudies")

    /// The sender of the portal's emails. One reader took the stored object as it was and put it in the Sender
    /// header, the Mail account lookup took it only when it was text: the text reading is the one kept, which
    /// is what the Web Sharing pane's field writes and what the Mail and SMTP senders use; a number stored by
    /// hand reads as its text.
    public static let notificationsEmailsSender = PreferenceKey<String?>("notificationsEmailsSender")
    /// When the notification emails last looked for new studies, in seconds since the reference date. Written
    /// as the text "%lf" of that number, as always; read as `double(forKey:)` reads text. Absent until the
    /// first check, which only writes it. The studies a user is sent through the portal are dated with it.
    public static let lastNotificationsDate = PreferenceKey<Double>("lastNotificationsDate")

    /// A separate server that answers WADO alone, without the portal's pages or accounts.
    public static let wadoOnlyServer = PreferenceKey<Bool>("wadoOnlyServer")
    public static let wadoOnlyServerPort = PreferenceKey<Int>("wadoOnlyServerPort")
    public static let wadoOnlyServerURL = PreferenceKey<String?>("wadoOnlyServerURL")

    /// The portal's study list also asks the comparative DICOM nodes (PACS On Demand), with
    /// `NetworkPreferences.searchesComparativeStudiesOnDICOMNodes` on: in a search, beside a study, in an album.
    public static let pacsOnDemandForSearch = PreferenceKey<Bool>("ActivatePACSOnDemandForWebPortalSearch")
    public static let pacsOnDemandForOtherStudies = PreferenceKey<Bool>("ActivatePACSOnDemandForWebPortalOtherStudies")
    public static let pacsOnDemandForAlbums = PreferenceKey<Bool>("ActivatePACSOnDemandForWebPortalAlbums")
    /// A study found both here and on a node is shown from the node when the node has more images.
    public static let prefersStudyWithMoreImages = PreferenceKey<Bool>("preferStudyWithMoreImages")
    /// The query filters of each smart album on the comparative nodes: dictionaries with the album's `name`,
    /// `activated` and the filters, as the album editor stores them.
    public static let smartAlbumStudiesDICOMNodes = PreferenceKey<[PropertyListValue]?>("smartAlbumStudiesDICOMNodes")

    /// Every key of this file.
    static let catalog: [any CataloguedPreference] = [
        address, usesSSL, prefersCustomWebPages, requiresAuthentication, title, logsActivity, adminCanDeleteStudies,
        notificationsEmailsSender, lastNotificationsDate, wadoOnlyServer, wadoOnlyServerPort, wadoOnlyServerURL,
        pacsOnDemandForSearch, pacsOnDemandForOtherStudies, pacsOnDemandForAlbums, prefersStudyWithMoreImages,
        smartAlbumStudiesDICOMNodes,
    ]
}
