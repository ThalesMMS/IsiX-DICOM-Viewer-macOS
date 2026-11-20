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
import ObjectiveC

/// The answers of what has nothing behind it, installed in the classes when
/// the application starts.
///
/// LaterPluginSDKAnswers.json, in the bundle, lists for each class the
/// selectors that only later headers of the plugin SDK declare and the
/// application has no method for, each with the types those headers give:
/// the properties a plugin can set, which are kept with the object and read
/// back, and the selectors of features the application does not have, which
/// answer nil, zero or nothing and say so in the log once; and, with their
/// types alone, the few of the viewer and of its view that have something
/// behind them, which LaterPluginSDKViewerAnswers adds. Each becomes a
/// method of its class, added by the runtime before a plugin loads, so that
/// the class answers it as it answers any other: a plugin asks whether the
/// class responds, reads the method's types and sends it, from any thread.
///
/// They are added here, not written as extensions of the classes: the viewer,
/// its view and the browser hold enough already, and a method that reads
/// nothing of its object needs nothing of its class. A selector the class, a
/// class of the application above it or the system answers when the table is
/// read is left alone: the table only answers what nothing else answers.
enum LaterPluginSDKAnswers {
    static let resourceName = "LaterPluginSDKAnswers"

    /// A property of the table: its name, on the class or on its instances, and its two accessors with their types.
    struct Kept {
        let name: String
        let onClass: Bool
        let getter: String
        let getterTypes: String
        let setter: String
        let setterTypes: String

        init?(_ fields: [String]) {
            guard fields.count == 6 else { return nil }
            (name, onClass, getter, getterTypes, setter, setterTypes) = (fields[0], fields[1] == "+", fields[2], fields[3], fields[4], fields[5])
        }
    }

    /// Adds every answer of the table of `bundle` to its class. Returns how many methods it added.
    @discardableResult
    static func install(from bundle: Bundle = .main) -> Int {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"), let data = try? Data(contentsOf: url),
              let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let classes = table["classes"] as? [String: [String: Any]] else {
            NSLog("****** the table of the selectors of later plugin SDKs is not in the bundle: a plugin built with them stops at the first it sends")
            return 0
        }
        // Those the application has something behind, of the viewer and of its view, with the types the table gives them.
        var added = LaterPluginSDKViewerAnswers.install { name, key in (classes[name]?["answered"] as? [String: String])?[key] }
        for (name, entry) in classes {
            guard let cls = NSClassFromString(name) else { continue }
            for fields in entry["kept"] as? [[String]] ?? [] {
                guard let kept = Kept(fields) else { continue }
                added += keep(kept, in: cls)
            }
            for (key, types) in entry["neutral"] as? [String: String] ?? [:] {
                added += answerNeutrally(key, types: types, of: name, in: cls)
            }
        }
        return added
    }

    /// The first type of a method's type encoding, its return type, without its qualifiers.
    static func returnType(of types: String) -> String {
        var rest = Substring(types)
        while let first = rest.first, "rnNoORV".contains(first) { rest = rest.dropFirst() }
        guard let first = rest.first else { return "" }
        if first == "{" || first == "(" {
            let close: Character = first == "{" ? "}" : ")"
            var depth = 0
            for (offset, character) in rest.enumerated() {
                if character == first { depth += 1 }
                if character == close {
                    depth -= 1
                    if depth == 0 { return String(rest.prefix(offset + 1)) }
                }
            }
            return String(rest)
        }
        return String(first)
    }

    /// The type of a setter's argument: what follows the receiver and the selector.
    static func argumentType(of setterTypes: String) -> String {
        guard let range = setterTypes.range(of: "@:") else { return "" }
        return returnType(of: String(setterTypes[range.upperBound...]))
    }

    private static func add(_ block: Any, as selector: String, types: String, to target: AnyClass) -> Int {
        class_addMethod(target, NSSelectorFromString(selector), imp_implementationWithBlock(block), types) ? 1 : 0
    }

    /// The class the method goes to: the class itself, or its class for a class method.
    private static func target(_ cls: AnyClass, onClass: Bool) -> AnyClass? {
        onClass ? object_getClass(cls) : cls
    }

    /// Whether `target` answers `selector` already, by a method of its own, of
    /// a class of the application above it, or of the system. A helper the
    /// application itself adds to a class of the system (a category of the
    /// same headers, on NSView for one) does not count: what the headers
    /// declare for this class comes before what they declare for every view.
    static func answers(_ selector: Selector, _ target: AnyClass) -> Bool {
        guard let method = class_getInstanceMethod(target, selector) else { return false }
        // The class the method is of: the last going up that still has it.
        var owner: AnyClass = target
        while let above = class_getSuperclass(owner), class_getInstanceMethod(above, selector) == method { owner = above }
        let application = Bundle.main.executablePath
        let ownerImage = class_getImageName(owner).map { String(cString: $0) }
        if ownerImage == application { return true }
        var info = Dl_info()
        let fromApplication = dladdr(unsafeBitCast(method_getImplementation(method), to: UnsafeRawPointer.self), &info) != 0
            && info.dli_fname.map { String(cString: $0) } == application
        return !fromApplication
    }

    private static func keep(_ kept: Kept, in cls: AnyClass) -> Int {
        guard let target = target(cls, onClass: kept.onClass),
              !answers(NSSelectorFromString(kept.getter), target),
              !answers(NSSelectorFromString(kept.setter), target),
              let blocks = accessors(of: kept.name, type: returnType(of: kept.getterTypes)),
              argumentType(of: kept.setterTypes) == returnType(of: kept.getterTypes) else { return 0 }
        return add(blocks.get, as: kept.getter, types: kept.getterTypes, to: target) + add(blocks.set, as: kept.setter, types: kept.setterTypes, to: target)
    }

    private static func answerNeutrally(_ key: String, types: String, of name: String, in cls: AnyClass) -> Int {
        let selector = String(key.dropFirst())
        guard let target = target(cls, onClass: key.hasPrefix("+")), !answers(NSSelectorFromString(selector), target),
              let block = neutralAnswer(returning: returnType(of: types), of: name, key) else { return 0 }
        return add(block, as: selector, types: types, to: target)
    }

    /// A method that answers the neutral value of `type` whatever its arguments, which it does not read.
    private static func neutralAnswer(returning type: String, of name: String, _ key: String) -> Any? {
        let said = { FormerSDKFacade.inert(name, key, because: LaterPluginSDK.noFeature) }
        switch type {
        case "v":
            return { _ in said() } as @convention(block) (AnyObject) -> Void
        case "@", "#", ":", "*", "^":
            // An initializer among them answers nil and leaves the object it was sent to as it was allocated.
            return { _ in said(); return nil } as @convention(block) (AnyObject) -> UnsafeRawPointer?
        case "B", "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
            return { _ in said(); return 0 } as @convention(block) (AnyObject) -> Int
        case "f", "d":
            // A float is read in the low half of the register a double is answered in: zero in both.
            return { _ in said(); return 0 } as @convention(block) (AnyObject) -> Double
        case "{CGPoint=dd}":
            return { _ in said(); return .zero } as @convention(block) (AnyObject) -> NSPoint
        case "{CGSize=dd}":
            return { _ in said(); return .zero } as @convention(block) (AnyObject) -> NSSize
        case "{CGRect={CGPoint=dd}{CGSize=dd}}":
            return { _ in said(); return .zero } as @convention(block) (AnyObject) -> NSRect
        case "{_NSRange=QQ}":
            return { _ in said(); return NSRange(location: 0, length: 0) } as @convention(block) (AnyObject) -> NSRange
        default:
            return nil
        }
    }

    /// The getter and the setter of a property of `type` kept under `name` with the object.
    private static func accessors(of name: String, type: String) -> (get: Any, set: Any)? {
        func kept<Value>(_ owner: AnyObject, or unset: Value) -> Value { LaterPluginSDK.kept(name, of: owner, or: unset) }
        func keep(_ value: Any?, _ owner: AnyObject) { LaterPluginSDK.keep(value, name, of: owner) }
        switch type {
        case "@":
            return ({ LaterPluginSDK.kept(name, of: $0, or: nil) } as @convention(block) (AnyObject) -> AnyObject?,
                    { keep($1, $0) } as @convention(block) (AnyObject, AnyObject?) -> Void)
        case "B":
            return ({ kept($0, or: false) } as @convention(block) (AnyObject) -> Bool, { keep($1, $0) } as @convention(block) (AnyObject, Bool) -> Void)
        case "c":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> Int8, { keep($1, $0) } as @convention(block) (AnyObject, Int8) -> Void)
        case "C":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> UInt8, { keep($1, $0) } as @convention(block) (AnyObject, UInt8) -> Void)
        case "s":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> Int16, { keep($1, $0) } as @convention(block) (AnyObject, Int16) -> Void)
        case "S":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> UInt16, { keep($1, $0) } as @convention(block) (AnyObject, UInt16) -> Void)
        case "i":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> Int32, { keep($1, $0) } as @convention(block) (AnyObject, Int32) -> Void)
        case "I":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> UInt32, { keep($1, $0) } as @convention(block) (AnyObject, UInt32) -> Void)
        case "q", "l":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> Int, { keep($1, $0) } as @convention(block) (AnyObject, Int) -> Void)
        case "Q", "L":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> UInt, { keep($1, $0) } as @convention(block) (AnyObject, UInt) -> Void)
        case "f":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> Float, { keep($1, $0) } as @convention(block) (AnyObject, Float) -> Void)
        case "d":
            return ({ kept($0, or: 0) } as @convention(block) (AnyObject) -> Double, { keep($1, $0) } as @convention(block) (AnyObject, Double) -> Void)
        case "^", "*":
            return ({ kept($0, or: nil) } as @convention(block) (AnyObject) -> UnsafeMutableRawPointer?,
                    { keep($1, $0) } as @convention(block) (AnyObject, UnsafeMutableRawPointer?) -> Void)
        case "{CGPoint=dd}":
            return ({ kept($0, or: .zero) } as @convention(block) (AnyObject) -> NSPoint, { keep($1, $0) } as @convention(block) (AnyObject, NSPoint) -> Void)
        case "{CGSize=dd}":
            return ({ kept($0, or: .zero) } as @convention(block) (AnyObject) -> NSSize, { keep($1, $0) } as @convention(block) (AnyObject, NSSize) -> Void)
        case "{CGRect={CGPoint=dd}{CGSize=dd}}":
            return ({ kept($0, or: .zero) } as @convention(block) (AnyObject) -> NSRect, { keep($1, $0) } as @convention(block) (AnyObject, NSRect) -> Void)
        default:
            return nil
        }
    }
}
