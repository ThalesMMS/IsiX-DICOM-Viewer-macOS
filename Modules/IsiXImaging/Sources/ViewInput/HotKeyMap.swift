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

/// The hot keys of the 2D views: each key the HOTKEYS preference names, and
/// the action it runs (the HotKeyActions of DefaultsOsiriX.h). The app reads
/// the preference through its typed key and hands the stored dictionary over;
/// a view looks a key up in lower case. Any thread reads it.
public struct HotKeyMap: Sendable, Equatable {

    /// The action of each key, as stored.
    public let actions: [String: Int32]

    public init(actions: [String: Int32]) {
        self.actions = actions
    }

    /// The map of the stored dictionary: each value read as -intValue reads a
    /// number or a string; anything else is the action 0.
    public init(stored: [String: Any]?) {
        var actions: [String: Int32] = [:]
        for (key, value) in stored ?? [:] {
            if let number = value as? NSNumber {
                actions[key] = number.int32Value
            } else if let string = value as? NSString {
                actions[key] = string.intValue
            } else {
                actions[key] = 0
            }
        }
        self.actions = actions
    }

    /// The action of the key typed, looked up in lower case; nil when no key is it.
    public func action(forTyped key: String) -> Int32? {
        actions[key.lowercased()]
    }

    /// The command the key typed runs; nil when it is no hot key or its
    /// action is unknown.
    public func command(forTyped key: String) -> ViewerKeyCommand.HotKey? {
        action(forTyped: key).flatMap(ViewerKeyCommand.HotKey.init(action:))
    }
}

extension ViewerKeyCommand {

    /// The commands of the hot keys, by the HotKeyActions of DefaultsOsiriX.h.
    public enum HotKey: Sendable, Equatable {
        /// The image's own window level.
        case defaultWindowLevel
        /// The full dynamic window level.
        case fullDynamic
        /// The window level preset at this position (0 to 8) of the presets in the order of their names.
        case windowLevelPreset(Int)
        /// The opacity table preset 1 to 9: 1 is the linear table, the others
        /// the stored tables in the order of their names.
        case opacityPreset(Int)
        case flipVertical
        case flipHorizontal
        /// A mouse tool, by its hot key action.
        case tool(action: Int32)
        /// The study's status, from Empty (0) to Validated (4).
        case status(Int32)
        case fullScreen
        case sync3DPosition
        /// Reslice the series: axial (0), coronal (1) or sagittal (2).
        case reslice(Int32)
        case setKeyImage

        // DefaultsOsiriX.h's HotKeyActions.
        static let defaultWindowLevelAction: Int32 = 0
        static let fullDynamicAction: Int32 = 1
        static let preset1WindowLevelAction: Int32 = 2
        static let flipVerticalAction: Int32 = 11
        static let flipHorizontalAction: Int32 = 12
        static let emptyStatusAction: Int32 = 35
        static let validatedStatusAction: Int32 = 39
        static let orthoMPRCrossAction: Int32 = 40
        static let preset1OpacityAction: Int32 = 41
        static let fullScreenAction: Int32 = 50
        static let sync3DAction: Int32 = 51
        static let setKeyImageAction: Int32 = 52
        static let resliceAxialAction: Int32 = 53
        static let resliceSagittalAction: Int32 = 55
        /// The tools a 2D view's hot keys choose: the window level to the plain
        /// brush, the repulsor, the selector and the orthogonal MPR's cross.
        static let toolActions: Set<Int32> = Set(13...28).union([33, 34, orthoMPRCrossAction])

        /// The command of a hot key action; nil for an action a 2D view does
        /// not run (the bone removal, the 3D rotation, camera and scissors).
        public init?(action: Int32) {
            switch action {
            case Self.defaultWindowLevelAction: self = .defaultWindowLevel
            case Self.fullDynamicAction: self = .fullDynamic
            case Self.preset1WindowLevelAction...(Self.preset1WindowLevelAction + 8):
                self = .windowLevelPreset(Int(action - Self.preset1WindowLevelAction))
            case Self.preset1OpacityAction...(Self.preset1OpacityAction + 8):
                self = .opacityPreset(Int(action - Self.preset1OpacityAction) + 1)
            case Self.flipVerticalAction: self = .flipVertical
            case Self.flipHorizontalAction: self = .flipHorizontal
            case Self.emptyStatusAction...Self.validatedStatusAction: self = .status(action - Self.emptyStatusAction)
            case Self.fullScreenAction: self = .fullScreen
            case Self.sync3DAction: self = .sync3DPosition
            case Self.resliceAxialAction...Self.resliceSagittalAction: self = .reslice(action - Self.resliceAxialAction)
            case Self.setKeyImageAction: self = .setKeyImage
            default:
                guard Self.toolActions.contains(action) else { return nil }
                self = .tool(action: action)
            }
        }
    }

    /// What an opacity preset hot key applies.
    public enum OpacityChoice: Sendable, Equatable {
        /// The linear table.
        case linear
        /// The stored table at this position of `names`.
        case stored(index: Int)
    }

    /// The table opacity preset `preset` (1 to 9) applies among `count`
    /// stored tables in menu order: 1 is the linear table, n the stored table
    /// at position n - 2; nil when there are fewer than n - 1 stored tables.
    public static func opacityChoice(preset: Int, storedTableCount count: Int) -> OpacityChoice? {
        guard count >= preset - 1 else { return nil }
        return preset <= 1 ? .linear : .stored(index: preset - 2)
    }
}
