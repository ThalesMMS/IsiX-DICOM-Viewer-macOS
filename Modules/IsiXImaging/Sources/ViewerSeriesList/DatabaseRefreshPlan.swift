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

/// What a 2D viewer does when images arrive in the database: build its series
/// list again (images of its patient, or an unknown change) and reload its
/// series (images of the series it shows).
public struct DatabaseRefreshPlan: Equatable, Sendable {
    public var rebuildSeriesList: Bool
    public var reloadSeries: Bool

    public init(rebuildSeriesList: Bool, reloadSeries: Bool) {
        self.rebuildSeriesList = rebuildSeriesList
        self.reloadSeries = reloadSeries
    }

    /// The plan for `newImages` (nil: the database changed without a list).
    /// An image of the open series asks for a reload; another one, of the
    /// viewer's patient (or of any patient when the viewer shows nothing),
    /// asks for the list. The images are read until both are asked.
    public static func plan<Image>(newImages: [Image]?, showsAnImage: Bool,
                                   isOfOpenSeries: (Image) -> Bool, isOfSamePatient: (Image) -> Bool) -> DatabaseRefreshPlan {
        var plan = DatabaseRefreshPlan(rebuildSeriesList: newImages == nil, reloadSeries: false)
        for image in newImages ?? [] {
            if isOfOpenSeries(image) {
                plan.reloadSeries = true
            } else if !showsAnImage || isOfSamePatient(image) {
                plan.rebuildSeriesList = true
            }
            if plan.reloadSeries && plan.rebuildSeriesList {
                break
            }
        }
        return plan
    }
}
