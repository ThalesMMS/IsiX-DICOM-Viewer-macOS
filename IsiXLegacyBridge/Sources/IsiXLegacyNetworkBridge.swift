//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The network as the kit's Objective-C classes (DCMNetServiceDelegate,
// SendController, DCMTKStoreSCU, the query nodes) and its XML-RPC methods
// reach it: IsiXPluginKit's IsiXNetwork and the context's XML-RPC methods.
// A legacy plugin named a node by its address; the kit takes it only when it
// is the address of a node the user configured, and hands the plugin API the
// node's identifier. Sends and queries wait for the node on the calling
// thread, as they did.

import AppKit
import IsiXPluginKit

/// What the Objective-C side answers an XML-RPC call with, for a method the
/// plugin listed in its Info.plist.
@objc protocol IsiXLegacyXMLRPCAnswering: NSObjectProtocol {
    /// Posts OsirixXMLRPCMessageNotification and returns the plugin's answer
    /// in Cocoa values; nil when the plugin did not answer.
    @objc(isixAnswerXMLRPC:parameters:) func isixAnswerXMLRPC(_ method: String, parameters: [Any]) -> Any?
}

@objc final class IsiXLegacyNetworkBridge: NSObject {
    @MainActor private static weak var answering: IsiXLegacyXMLRPCAnswering?

    @objc static func setXMLRPCAnswering(_ answering: IsiXLegacyXMLRPCAnswering?) {
        IsiXLegacyOnMain { Self.answering = answering }
    }

    /// The plugin's network; a failure is recorded as the command's.
    private static func network() throws -> IsiXNetwork {
        let result: Result<IsiXNetwork, any Error> = IsiXLegacyOnMain {
            guard let context = IsiXLegacyState.shared.context else { return .failure(IsiXPluginError.pluginInactive) }
            return Result { try context.network() }
        }
        return try result.get()
    }

    private static func record(_ error: any Error) {
        IsiXLegacyOnMain { IsiXLegacyState.shared.record(error) }
    }

    // MARK: nodes

    /// The nodes the plugin may use, under the keys of Locations.
    @objc(nodeDictionariesSendOnly:queryOnly:) static func nodeDictionaries(sendOnly: Bool, queryOnly: Bool) -> [NSDictionary] {
        do {
            return try network().nodes().filter { (!sendOnly || $0.acceptsSend) && (!queryOnly || $0.acceptsQuery) }.map { node in
                ["AETitle": node.aeTitle, "Address": node.host, "Port": node.port, "Description": node.name,
                 "TLSEnabled": node.usesTLS, "Send": node.acceptsSend, "QR": node.acceptsQuery, "Activated": true,
                 "IsiXNodeID": node.id] as NSDictionary
            }
        } catch {
            record(error)
            return []
        }
    }

    /// The identifier of the configured node with this AE title, address
    /// and port; nil, with the refusal recorded, when the user configured none.
    @objc(nodeIdentifierWithAETitle:host:port:forSending:)
    static func nodeIdentifier(aeTitle: String?, host: String?, port: Int, forSending: Bool) -> String? {
        let wanted = "\(aeTitle ?? "")@\(host ?? ""):\(port)"
        do {
            let match = try network().nodes().first {
                $0.aeTitle == aeTitle?.trimmingCharacters(in: .whitespaces)
                    && $0.host.caseInsensitiveCompare(host?.trimmingCharacters(in: .whitespaces) ?? "") == .orderedSame
                    && $0.port == port && (forSending ? $0.acceptsSend : $0.acceptsQuery)
            }
            guard let match else { throw IsiXPluginError.nodeNotConfigured(wanted) }
            return match.id
        } catch {
            record(error)
            return nil
        }
    }

    // MARK: send

    /// Sends DICOM files and images of the database (by SOP Instance UID) to
    /// the node; the number of files the node took, or nil with `error`.
    @objc(sendFiles:sopInstanceUIDs:toNode:error:)
    static func send(files: [String], sopInstanceUIDs: [String], toNode id: String) throws -> NSNumber {
        do {
            let request = IsiXSendRequest(sopInstanceUIDs: sopInstanceUIDs, files: files.map { URL(fileURLWithPath: $0) })
            let result = try network().send(request, to: id)
            if result.failed > 0 {
                NSLog("%@: %ld of %ld files were not sent to %@: %@", IsiXLegacyOnMain { IsiXLegacyState.shared.context?.info.name } ?? "",
                      result.failed, result.failed + result.sent, id, result.failureReason ?? "")
            }
            return NSNumber(value: result.sent)
        } catch {
            record(error)
            throw error
        }
    }

    // MARK: query

    /// The matches of a C-FIND, each a dictionary of DICOM keywords. `level`:
    /// study, series or worklist; `filters`: patientName, patientID,
    /// accessionNumber, studyInstanceUID, modality, description (strings),
    /// dateFrom, dateTo (NSDate).
    @objc(findLevel:filters:onNode:error:)
    static func find(level: String, filters: [String: Any], onNode id: String) throws -> [NSDictionary] {
        do {
            guard let level = IsiXQueryLevel(rawValue: level) else { throw IsiXPluginError.invalidValue("No query level \(level).") }
            let query = IsiXNetworkQuery(level: level, patientName: filters["patientName"] as? String, patientID: filters["patientID"] as? String,
                                         accessionNumber: filters["accessionNumber"] as? String,
                                         studyInstanceUID: filters["studyInstanceUID"] as? String, modality: filters["modality"] as? String,
                                         description: filters["description"] as? String, dateFrom: filters["dateFrom"] as? Date,
                                         dateTo: filters["dateTo"] as? Date)
            return try network().find(query, on: id).map { $0.values as NSDictionary }
        } catch {
            record(error)
            throw error
        }
    }

    // MARK: XML-RPC

    /// Registers the methods the plugin lists under IsiXLegacyXMLRPCMethods:
    /// each call is posted as OsirixXMLRPCMessageNotification. A name the
    /// application or another plugin answers is left out and logged: the
    /// legacy plugin saw every call, and answered those it knew.
    @MainActor static func registerXMLRPCMethods(_ context: IsiXPluginContext) throws {
        let names = (context.bundle.infoDictionary?[IsiXLegacyInfoKey.xmlRPCMethods] as? [String]) ?? []
        for name in names {
            do {
                try register(name, in: context)
            } catch {
                NSLog("%@: the XML-RPC method %@ is not answered: %@", context.info.name, name,
                      (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    @MainActor private static func register(_ name: String, in context: IsiXPluginContext) throws {
        try context.registerXMLRPCMethod(named: name) { parameters in
            guard let answering = IsiXLegacyNetworkBridge.answering else {
                throw IsiXLegacyError("The plugin does not answer \(name).")
            }
            guard let answer = answering.isixAnswerXMLRPC(name, parameters: parameters.map(Self.object(of:))) else {
                throw IsiXLegacyError("The plugin did not answer \(name).")
            }
            return Self.value(of: answer)
        }
    }

    nonisolated static func object(of value: IsiXXMLRPCValue) -> Any {
        switch value {
        case .string(let string): return string as NSString
        case .int(let int): return NSNumber(value: int)
        case .double(let double): return NSNumber(value: double)
        case .bool(let bool): return NSNumber(value: bool)
        case .date(let date): return date as NSDate
        case .data(let data): return data as NSData
        case .array(let array): return array.map(object(of:)) as NSArray
        case .structure(let members): return members.mapValues(object(of:)) as NSDictionary
        @unknown default: return NSNull()
        }
    }

    nonisolated static func value(of object: Any) -> IsiXXMLRPCValue {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            return type == "d" || type == "f" ? .double(number.doubleValue) : .int(number.intValue)
        case let string as String: return .string(string)
        case let date as Date: return .date(date)
        case let data as Data: return .data(data)
        case let array as [Any]: return .array(array.map(value(of:)))
        case let dictionary as [AnyHashable: Any]:
            return .structure(Dictionary(dictionary.map { ("\($0.key)", value(of: $0.value)) }, uniquingKeysWith: { first, _ in first }))
        default: return .string(String(describing: object))
        }
    }
}
