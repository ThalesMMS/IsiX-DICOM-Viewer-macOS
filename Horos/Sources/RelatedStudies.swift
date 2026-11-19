//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation

/// The other studies of a study's patient in a database.
enum RelatedStudies {
    /// The studies of `database` whose patient UID begins as that of `study`,
    /// newest first and without `study` itself; as fetched, when `study` is
    /// not one of them. An exception of the fetch is raised on the caller,
    /// after the context's queue is left.
    static func of(_ study: Any?, in database: DicomDatabase?) -> [Any]? {
        guard let context = database?.managedObjectContext else { return nil }
        var studies: [NSManagedObject]? = nil
        var raised: NSException? = nil
        N2ManagedObjectContextPerformAndWait(context) {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
            request.predicate = patientPredicate((study as? NSObject)?.value(forKey: "patientUID"))
            raised = HorosObjCException.caught {
                studies = try? context.fetch(request)
                // A failure to order them leaves the studies as fetched.
                if let exception = HorosObjCException.caught({
                    guard let fetched = studies, let study = study as? NSManagedObject, fetched.contains(study) else { return }
                    let newestFirst = NSSortDescriptor(key: "date", ascending: false)
                    studies = fetched.filter { $0 != study }.sorted { newestFirst.compare($0, to: $1) == .orderedAscending }
                }) {
                    _N2LogExceptionImpl(exception, true, "-[BrowserController relatedStudiesForStudy:]")
                }
            }
        }
        if let raised { raised.raise() }
        return studies
    }

    /// `patientUID BEGINSWITH[cd] %@`, with a nil UID passed as nil.
    private static func patientPredicate(_ patientUID: Any?) -> NSPredicate {
        let argument: CVarArg = (patientUID as? NSObject) ?? NilArgument()
        return withVaList([argument]) { NSPredicate(format: "(patientUID BEGINSWITH[cd] %@)", arguments: $0) }
    }

    /// A nil `%@` argument for a format taking a C variable argument list.
    private struct NilArgument: CVarArg {
        var _cVarArgEncoding: [Int] { [0] }
    }
}
