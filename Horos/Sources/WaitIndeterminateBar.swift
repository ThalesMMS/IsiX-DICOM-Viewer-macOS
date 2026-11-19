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

/// The bar of the wait panel that sweeps while the amount of work is unknown.
///
/// It is a second bar, over the determinate one, and the two take turns by
/// being hidden. One bar is never switched between the two modes: a bar that
/// started indeterminate and is made determinate goes on sweeping.
///
/// The bar is made here, hidden, the first time it is asked for, in the place
/// of the determinate bar: the localized copies of the panel's nib declare
/// one bar only, and stay as they are.
@MainActor
struct WaitIndeterminateBar {
    private var bar: NSProgressIndicator?
    /// Whether the bar that sweeps is the one on screen.
    private(set) var isShown = false

    /// The bar that sweeps, made if there is none yet and put over
    /// `determinate` when that one is in a view.
    mutating func indicator(over determinate: NSProgressIndicator?) -> NSProgressIndicator {
        let sweeping: NSProgressIndicator
        if let bar {
            sweeping = bar
        } else {
            sweeping = NSProgressIndicator(frame: determinate?.frame ?? .zero)
            sweeping.style = .bar
            sweeping.isIndeterminate = true
            sweeping.controlSize = determinate?.controlSize ?? .regular
            sweeping.isHidden = true
            bar = sweeping
        }

        if sweeping.superview == nil, let determinate, let parent = determinate.superview {
            sweeping.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(sweeping, positioned: .above, relativeTo: determinate)
            NSLayoutConstraint.activate([
                sweeping.leadingAnchor.constraint(equalTo: determinate.leadingAnchor),
                sweeping.trailingAnchor.constraint(equalTo: determinate.trailingAnchor),
                sweeping.topAnchor.constraint(equalTo: determinate.topAnchor),
                sweeping.bottomAnchor.constraint(equalTo: determinate.bottomAnchor),
            ])
        }
        return sweeping
    }

    /// Shows the bar that sweeps, animated, in place of `determinate`, or
    /// stops and hides it and shows `determinate` again, which kept its
    /// value meanwhile. Without a turn of the sweeping bar before, asking for
    /// the determinate one changes nothing.
    mutating func show(_ indeterminate: Bool, over determinate: NSProgressIndicator?) {
        if indeterminate {
            let sweeping = indicator(over: determinate)
            determinate?.isHidden = true
            sweeping.isHidden = false
            sweeping.startAnimation(nil)
            isShown = true
            sweeping.display()
            // The caller may go on to work that gives the run loop no turn:
            // the bars change places on screen now.
            CATransaction.flush()
        } else if isShown {
            bar?.stopAnimation(nil)
            bar?.isHidden = true
            determinate?.isHidden = false
            isShown = false
            determinate?.display()
            CATransaction.flush()
        }
    }
}
