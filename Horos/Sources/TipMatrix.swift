//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// A matrix whose cells keep the tooltips their nib gives them.
///
/// A nib keeps the tooltip of a cell in a connection to the cell, and the
/// loader hands it to the view the cell says it is in. A cell just read from
/// a nib is in no view yet - a matrix tells its cells so when it first draws
/// them - and the tooltip went nowhere: no cell of a matrix ever showed one.
/// This matrix tells its cells where they are as soon as it is read, before
/// the connections of the nib are made.
@objc(IsiXTipMatrix)
final class TipMatrix: NSMatrix {
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        for cell in cells { cell.controlView = self }
    }
}
