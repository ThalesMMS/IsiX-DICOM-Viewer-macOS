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

/// The shading values as a volume rendering window writes them beside its
/// Shading check box: three lines, the ambient coefficient, the diffuse
/// coefficient, and the specular coefficient with the specular power after a
/// slash.
///
/// The window wrote them in two ways: one decimal and «Specular :0.3-15.0»
/// when it opened and on Revert Series, two decimals and «Specular :1.17,
/// 6.98» for a shading preset or a change in the shading panel, with a point
/// in every region. Every number now has two decimals, as the presets are
/// written (0.15, 1.17, 6.98), so that the line shows a preset's values as
/// they are, and the decimal separator of the user's region («0,15» in
/// Portuguese or German). A slash rather than a comma separates the specular
/// coefficient from its power: with a decimal comma, «0,30, 15,00» would read
/// as four numbers.
public enum ShadingValuesText {

    /// The decimals of every number.
    public static let decimals = 2

    /// `values` in `template`, the catalog's text with the four numbers as
    /// `%1$@` (ambient), `%2$@` (diffuse), `%3$@` (specular) and `%4$@`
    /// (specular power), each written by `number(_:locale:)`.
    public static func string(_ values: VolumeRenderingOpening.ShadingValues, template: String,
                              locale: Locale = .current) -> String {
        String(format: template, number(values.ambient, locale: locale), number(values.diffuse, locale: locale),
               number(values.specular, locale: locale), number(values.specularPower, locale: locale))
    }

    /// `value` with `decimals` decimals and the decimal separator of `locale`.
    public static func number(_ value: Float, locale: Locale = .current) -> String {
        String(format: "%.\(decimals)f", locale: locale, Double(value))
    }
}
