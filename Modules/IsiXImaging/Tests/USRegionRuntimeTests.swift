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
import ObjectiveC
import Testing
@testable import IsiXImaging

/// An ultrasound region as a plugin built for the Horos or OsiriX SDK reaches
/// it: a class the runtime names DCMUSRegion, whose selectors it sends by name
/// with the types that SDK's header declared.
@Suite struct USRegionRuntimeTests {

    /// The properties of the SDK's header with the type each was declared
    /// with, as the runtime encodes it: i for int, d for double, B (or c,
    /// where BOOL is a signed char) for BOOL.
    private static let properties: [(name: String, type: String)] = [
        ("regionSpatialFormat", "i"), ("regionDataType", "i"), ("regionFlags", "i"),
        ("regionLocationMinX0", "i"), ("regionLocationMinY0", "i"), ("regionLocationMaxX1", "i"), ("regionLocationMaxY1", "i"),
        ("referencePixelX0", "i"), ("referencePixelY0", "i"),
        ("physicalUnitsXDirection", "i"), ("physicalUnitsYDirection", "i"),
        ("refPixelPhysicalValueX", "d"), ("refPixelPhysicalValueY", "d"),
        ("physicalDeltaX", "d"), ("physicalDeltaY", "d"),
        ("dopplerCorrectionAngle", "d"),
        ("isReferencePixelX0Present", "B"), ("isReferencePixelY0Present", "B"),
    ]

    private static func setter(_ name: String) -> String {
        "set" + name.prefix(1).uppercased() + name.dropFirst() + ":"
    }

    /// The type a method of `type` returns or takes as its first argument.
    private static func encoding(_ type: AnyClass, _ selector: String, argument: Bool) -> String? {
        guard let method = class_getInstanceMethod(type, NSSelectorFromString(selector)) else { return nil }
        let text: UnsafeMutablePointer<CChar>?
        if argument {
            guard method_getNumberOfArguments(method) == 3 else { return nil }
            text = method_copyArgumentType(method, 2)
        } else {
            guard method_getNumberOfArguments(method) == 2 else { return nil }
            text = Optional(method_copyReturnType(method))
        }
        guard let text else { return nil }
        defer { free(text) }
        return String(cString: text)
    }

    private static func matches(_ encoding: String?, _ expected: String) -> Bool {
        encoding == expected || (expected == "B" && encoding == "c")
    }

    @Test func theRuntimeNamesTheClassAsTheSDKDid() throws {
        let named: AnyClass = try #require(NSClassFromString("DCMUSRegion"))
        #expect(ObjectIdentifier(named) == ObjectIdentifier(USRegion.self))
        #expect(NSStringFromClass(USRegion.self) == "DCMUSRegion")
        #expect(class_getSuperclass(named).map { ObjectIdentifier($0) } == ObjectIdentifier(NSObject.self))
        // The name the module gave the class before is not a class any more.
        #expect(NSClassFromString("IsiXUSRegion") == nil)
        #expect(USRegion().isMember(of: named))
    }

    // The 37 selectors of the SDK's class: a getter and a setter for each of
    // the 18 properties, and -toString.
    @Test func everySelectorOfTheSDKAnswersWithItsType() {
        var selectors = 0
        for property in Self.properties {
            let getter = Self.encoding(USRegion.self, property.name, argument: false)
            #expect(Self.matches(getter, property.type), "\(property.name) returns \(getter ?? "nothing")")
            let setter = Self.encoding(USRegion.self, Self.setter(property.name), argument: true)
            #expect(Self.matches(setter, property.type), "\(Self.setter(property.name)) takes \(setter ?? "nothing")")
            selectors += 2
        }
        #expect(Self.encoding(USRegion.self, "toString", argument: false) == "@")
        selectors += 1
        #expect(selectors == 37)
    }

    // Sent by name with the types of the SDK's header, as a plugin's binary
    // sends them: what a setter is given is what the getter and the Swift
    // property answer.
    @Test func theSelectorsReadAndWriteTheProperties() throws {
        let region = USRegion()
        func implementation(_ name: String) throws -> (IMP, Selector) {
            let selector = NSSelectorFromString(name)
            return (try #require(class_getMethodImplementation(USRegion.self, selector)), selector)
        }
        // A method as Objective-C calls it: the receiver, the selector, and
        // the value a setter takes or a getter returns.
        for (index, property) in Self.properties.enumerated() {
            let (set, setSelector) = try implementation(Self.setter(property.name)), (get, getSelector) = try implementation(property.name)
            switch property.type {
            case "i":
                let value = Int32(-1000 - index)
                unsafeBitCast(set, to: (@convention(c) (AnyObject, Selector, Int32) -> Void).self)(region, setSelector, value)
                #expect(unsafeBitCast(get, to: (@convention(c) (AnyObject, Selector) -> Int32).self)(region, getSelector) == value)
            case "d":
                let value = 0.125 * Double(index + 1)
                unsafeBitCast(set, to: (@convention(c) (AnyObject, Selector, Double) -> Void).self)(region, setSelector, value)
                #expect(unsafeBitCast(get, to: (@convention(c) (AnyObject, Selector) -> Double).self)(region, getSelector) == value)
            default:
                unsafeBitCast(set, to: (@convention(c) (AnyObject, Selector, ObjCBool) -> Void).self)(region, setSelector, true)
                #expect(unsafeBitCast(get, to: (@convention(c) (AnyObject, Selector) -> ObjCBool).self)(region, getSelector).boolValue)
            }
        }
        #expect(region.regionSpatialFormat == -1000 && region.regionLocationMaxY1 == -1006)
        #expect(region.refPixelPhysicalValueX == 1.5 && region.dopplerCorrectionAngle == 2.0)
        #expect(region.isReferencePixelX0Present && region.isReferencePixelY0Present)

        let (toString, selector) = try implementation("toString")
        let text = unsafeBitCast(toString, to: (@convention(c) (AnyObject, Selector) -> NSString).self)(region, selector) as String
        #expect(text == region.toString())
        #expect(text.hasPrefix("regionSpatialFormat=-1000 regionDataType=-1001 "))
        #expect(text.hasSuffix("dopplerCorrectionAngle=2 "))
    }
}
