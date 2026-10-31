//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// The letters that say which way a direction of the patient points (right or
/// left, anterior or posterior, inferior or superior), in the language the
/// viewer shows them in.
public struct OrientationLetters: Sendable, Equatable {
    public var right: String, left: String
    public var anterior: String, posterior: String
    public var inferior: String, superior: String

    public init(right: String, left: String, anterior: String, posterior: String, inferior: String, superior: String) {
        self.right = right
        self.left = left
        self.anterior = anterior
        self.posterior = posterior
        self.inferior = inferior
        self.superior = superior
    }

    /// The letters of the English catalogue, which are also its keys.
    public static let english = OrientationLetters(right: "R", left: "L", anterior: "A", posterior: "P", inferior: "I", superior: "S")

    /// The letters of `vector` (x, y, z of the patient), or of its opposite when
    /// `inverted`: the component with the largest magnitude first, then the
    /// others, each only while it is above 0.2, at most three letters. A tie
    /// goes to x, then y. Empty when no component is above 0.2.
    public func text(_ vector: (Float, Float, Float), inverted: Bool) -> String {
        let x = inverted ? -vector.0 : vector.0
        let y = inverted ? -vector.1 : vector.1
        let z = inverted ? -vector.2 : vector.2
        let letterX = x < 0 ? right : left
        let letterY = y < 0 ? anterior : posterior
        let letterZ = z < 0 ? inferior : superior

        var absX = abs(vector.0), absY = abs(vector.1), absZ = abs(vector.2)
        var text = ""
        for _ in 0 ..< 3 {
            // The float is compared with the double 0.2, as the C did.
            if Double(absX) > 0.2 && absX >= absY && absX >= absZ {
                text += letterX; absX = 0
            } else if Double(absY) > 0.2 && absY >= absX && absY >= absZ {
                text += letterY; absY = 0
            } else if Double(absZ) > 0.2 && absZ >= absX && absZ >= absY {
                text += letterZ; absZ = 0
            } else {
                break
            }
        }
        return text
    }
}
