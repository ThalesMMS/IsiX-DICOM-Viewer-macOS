//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The "DICOMweb Nodes" area of the Locations pane.
///
/// Its table shows `DICOMWEB_SERVERS` through `DICOMwebNode`, one row per
/// node, and writes the list back after every edit. The DIMSE nodes above it
/// keep `SERVERS`; nothing here reads or writes that list.
///
/// Cells are validated as they are edited: an address that is not HTTPS (or
/// HTTP allowed by this node or to this computer), a path that is not relative, or a name another node
/// has, is refused with the reason and the previous value stays. A new node has
/// no address; it is saved, but not offered anywhere until it has one.
///
/// The Auth column opens the authentication sheet. Secrets go to the Keychain
/// through `DICOMwebNode.credentialStore`; the node keeps only the reference.
/// A node that signs in with OpenID Connect keeps its settings, which are not
/// secret, and its tokens are in the Keychain (`DICOMwebOIDC`). A client
/// certificate is a reference to a Keychain identity.
// Main actor: the DICOMweb node table of the Locations pane. The node test runs
// on a global queue and comes back to the main thread.
@MainActor
@objc(HorosDICOMwebNodesController)
public final class DICOMwebNodesController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// The columns, by identifier, in the order the xib has them.
    public enum Column {
        public static let address = "Address"
        public static let allowInsecureHTTP = "AllowInsecureHTTP"
        public static let wadoPath = "WADOPath"
        public static let qidoPath = "QIDOPath"
        public static let name = "Name"
        public static let queryRetrieve = "QR"
        public static let retrieveSyntax = "RetrieveSyntax"
        public static let auth = "Auth"
        public static let send = "Send"
        public static let sendSyntax = "SendSyntax"
        public static let maximumRequests = "MaxRequests"
        public static let seriesOrder = "SeriesOrder"
        public static let excludeSeries = "ExcludeSeries"
        public static let adaptiveRequests = "AdaptiveRequests"
        public static let trustedCertificate = "TrustedCertificateSHA256"
    }

    /// What the parallel requests setting means, for its header and cells.
    static var maximumRequestsHelp: String {
        NSLocalizedString("How many requests this node is sent at the same time, by all retrieves together. 1 sends them one after the other.", comment: "per-node request limit")
    }

    @IBOutlet public weak var tableView: NSTableView?
    @IBOutlet public weak var removeButton: NSButton?
    @IBOutlet public weak var testButton: NSButton?
    @IBOutlet public weak var testProgress: NSProgressIndicator?

    var defaults = UserDefaults.standard
    private(set) var nodes: [DICOMwebNode] = []
    /// Credential summaries by identifier, read from the Keychain once each.
    private var summaries: [String: String] = [:]
    private var testing = false

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            super.awakeFromNib()
            guard let tableView else { return }
            // Shared by every localized pane; the choice belongs to the node,
            // never to the legacy DIMSE/WADO settings.
            if tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.allowInsecureHTTP)) == nil {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Column.allowInsecureHTTP))
                column.title = NSLocalizedString("Allow Insecure HTTP", comment: "DICOMweb per-node transport choice")
                column.headerToolTip = Self.insecureHTTPWarning
                column.width = 170
                column.minWidth = 170
                let cell = NSButtonCell()
                cell.setButtonType(.switch)
                cell.title = ""
                cell.imagePosition = .imageOnly
                column.dataCell = cell
                tableView.addTableColumn(column)
                tableView.moveColumn(tableView.numberOfColumns - 1, toColumn: 1)
            }
            // Also made here, for every localized pane alike.
            if tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.maximumRequests)) == nil {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Column.maximumRequests))
                column.title = NSLocalizedString("Parallel Requests", comment: "per-node request limit")
                column.headerToolTip = Self.maximumRequestsHelp
                let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
                cell.isBordered = false
                cell.controlSize = .small
                cell.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                cell.addItems(withTitles: DICOMwebNode.maximumRequestsChoices.map(String.init))
                column.dataCell = cell
                column.width = max(70, ceil(NSAttributedString(string: column.title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).size().width) + 24)
                column.minWidth = 60
                tableView.addTableColumn(column)
            }
            if tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.adaptiveRequests)) == nil {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Column.adaptiveRequests))
                column.title = NSLocalizedString("Automatic Limit", comment: "automatic request limit")
                column.headerToolTip = NodeRequestLimiter.adaptiveHelp
                let cell = NSButtonCell()
                cell.setButtonType(.switch)
                cell.title = ""
                cell.imagePosition = .imageOnly
                column.dataCell = cell
                column.width = max(60, ceil(NSAttributedString(string: column.title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).size().width) + 24)
                column.minWidth = 50
                tableView.addTableColumn(column)
                // Beside the limit it moves under.
                if let limit = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.maximumRequests }) {
                    tableView.moveColumn(tableView.numberOfColumns - 1, toColumn: limit + 1)
                }
            }
            if tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.seriesOrder)) == nil {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Column.seriesOrder))
                column.title = NSLocalizedString("Series Order", comment: "series retrieve order")
                column.headerToolTip = RetrievePlan.orderHelp
                let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
                cell.isBordered = false
                cell.controlSize = .small
                cell.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                cell.addItems(withTitles: RetrievePlan.orderTitles)
                column.dataCell = cell
                let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                let widest = ([column.title] + RetrievePlan.orderTitles).map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0
                column.width = max(110, ceil(widest) + 28)
                column.minWidth = 90
                tableView.addTableColumn(column)
            }
            if tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.excludeSeries)) == nil {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Column.excludeSeries))
                column.title = NSLocalizedString("Exclude Series", comment: "series exclusion rules")
                column.headerToolTip = RetrievePlan.exclusionHelp
                let cell = NSTextFieldCell(textCell: "")
                cell.isEditable = true
                cell.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                cell.placeholderString = NSLocalizedString("e.g. scout, localizer", comment: "series exclusion rules example")
                column.dataCell = cell
                column.width = 150
                column.minWidth = 90
                tableView.addTableColumn(column)
            }
            if tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.trustedCertificate)) == nil {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Column.trustedCertificate))
                column.title = NSLocalizedString("Trusted Certificate (SHA-256)", comment: "DICOMweb trusted certificate")
                column.headerToolTip = DICOMwebServerTrust.help
                let cell = NSTextFieldCell(textCell: "")
                cell.isEditable = true
                cell.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                cell.lineBreakMode = .byTruncatingMiddle
                cell.placeholderString = NSLocalizedString("System trust", comment: "DICOMweb trusted certificate placeholder")
                column.dataCell = cell
                column.width = max(170, ceil(NSAttributedString(string: column.title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).size().width) + 24)
                column.minWidth = 120
                tableView.addTableColumn(column)
                // Beside the transport choice it belongs with.
                if let insecure = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.allowInsecureHTTP }) {
                    tableView.moveColumn(tableView.numberOfColumns - 1, toColumn: insecure + 1)
                }
            }
            for identifier in [Column.retrieveSyntax, Column.sendSyntax] {
                guard let cell = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.dataCell as? NSPopUpButtonCell
                else { continue }
                cell.removeAllItems()
                cell.addItems(withTitles: DICOMwebNode.transferSyntaxes.map(DICOMwebNode.title(forTransferSyntax:)))
            }
            tableView.target = self
            tableView.action = #selector(tableClicked(_:))
            addNetworkLogsSwitch(beside: tableView)
            reload()
        }
    }

    /// The network logs' switch, the Listener pane's too, at the right of the
    /// DICOMweb area's title, the same in every localized pane: a site that
    /// uses only DICOMweb has no reason to open the Listener pane, and its
    /// retrieves are logged as well.
    private func addNetworkLogsSwitch(beside tableView: NSTableView) {
        var view: NSView? = tableView
        while let current = view, !(current is NSBox) { view = current.superview }
        guard let box = view as? NSBox, let container = box.superview,
              !container.subviews.contains(where: { $0.identifier?.rawValue == "NETWORKLOGS" }) else { return }
        let logs = NSButton(checkboxWithTitle: NSLocalizedString("Network Logs", comment: ""), target: self,
                            action: #selector(networkLogsChanged(_:)))
        logs.identifier = NSUserInterfaceItemIdentifier("NETWORKLOGS")
        logs.controlSize = .small
        logs.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        logs.sizeToFit()
        // Beside the box, not in it: the box draws its title row over its
        // own subviews there.
        let title = box.convert(box.titleRect, to: container)
        let edge = box.convert(NSPoint(x: box.bounds.maxX, y: 0), to: container).x
        logs.frame.origin = NSPoint(x: edge - logs.frame.width - 8, y: title.midY - logs.frame.height / 2)
        logs.autoresizingMask = box.autoresizingMask.contains(.width) ? [.minXMargin] : []
        if !container.isFlipped { logs.autoresizingMask.insert(.minYMargin) } else { logs.autoresizingMask.insert(.maxYMargin) }
        logs.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.NETWORKLOGS", options: nil)
        container.addSubview(logs, positioned: .above, relativeTo: box)
    }

    /// The browser reads the setting once, as the Listener pane's switch has it read.
    @objc private func networkLogsChanged(_ sender: Any?) {
        BrowserController.currentBrowser()?.setNetworkLogs()
    }

    /// Reads the list again, as the pane is shown.
    @objc public func reload() {
        nodes = DICOMwebNode.nodes(in: defaults)
        tableView?.reloadData()
        updateButtons()
    }

    private func save() {
        DICOMwebNode.save(nodes, to: defaults)
        // Nothing a former address or credential opened is used again.
        DICOMwebSessionPool.shared.endIdleSessions()
    }

    private func updateButtons() {
        let selected = selectedNode != nil
        removeButton?.isEnabled = selected
        testButton?.isEnabled = selected && !testing
    }

    private var selectedNode: DICOMwebNode? {
        guard let row = tableView?.selectedRow, row >= 0, row < nodes.count else { return nil }
        return nodes[row]
    }

    // MARK: Buttons

    @IBAction public func addNode(_ sender: Any?) {
        let node = DICOMwebNode()
        node.name = DICOMwebNode.uniqueName(node.name, among: nodes)
        nodes.append(node)
        save()
        tableView?.reloadData()
        let row = nodes.count - 1
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView?.scrollRowToVisible(row)
        if let column = tableView?.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.address)), column >= 0 {
            tableView?.editColumn(column, row: row, with: nil, select: true)
        }
        updateButtons()
    }

    /// Removes the selected node and its credential. A credential that cannot
    /// be removed keeps the node, so no secret is left without a reference.
    @IBAction public func removeNode(_ sender: Any?) {
        guard let node = selectedNode, let row = tableView?.selectedRow else { return }
        do { try DICOMwebOIDC.signOut(nodeIdentifier: node.identifier) }
        catch { report(error, title: NSLocalizedString("The DICOMweb node was not removed", comment: "")); return }
        if !node.credentialIdentifier.isEmpty {
            do { try DICOMwebNode.credentialStore.remove(identifier: node.credentialIdentifier) }
            catch { report(error, title: NSLocalizedString("The DICOMweb node was not removed", comment: "")); return }
            summaries.removeValue(forKey: node.credentialIdentifier)
        }
        nodes.remove(at: row)
        save()
        tableView?.reloadData()
        updateButtons()
    }

    /// Verifies the selected node with a QIDO query (limit=1) at its QIDO
    /// path and with its own credential, off the main thread, and says how it
    /// went: network, TLS, timeout, refused credentials (401/403) and a wrong
    /// path (404) each have their message.
    @IBAction public func testNode(_ sender: Any?) {
        guard !testing, let node = selectedNode else { return }
        let configuration: DICOMwebNodeConfiguration
        do { configuration = try DICOMwebSources.configuration(for: node) } catch {
            report(error, title: NSLocalizedString("DICOMweb Verification Failed", comment: ""))
            return
        }
        let name = node.name
        testing = true
        testProgress?.startAnimation(self)
        updateButtons()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure: NSError?
            do { try DICOMwebClient(node: configuration, timeout: 30).verify(); failure = nil } catch { failure = error as NSError }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.testing = false
                self.testProgress?.stopAnimation(self)
                self.updateButtons()
                if let failure {
                    self.inform(title: NSLocalizedString("DICOMweb Verification Failed", comment: ""),
                                message: DICOMwebVerification.message(for: failure), style: .warning)
                } else {
                    self.inform(title: NSLocalizedString("DICOMweb Verification Succeeded", comment: ""),
                                message: String(format: NSLocalizedString("%@ answered a QIDO query.", comment: ""), name))
                }
            }
        }
    }

    // MARK: Messages

    private func report(_ error: Error, title: String) {
        inform(title: title, message: (error as NSError).localizedDescription, style: .warning)
    }

    private func inform(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        if let window = tableView?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

    /// The Auth summary, read once per credential; "None" without one.
    func authSummary(of node: DICOMwebNode) -> String {
        if node.usesOIDC { return "OIDC" + DICOMwebAuthentication.separator + (URL(string: node.oidcIssuer)?.host ?? node.oidcIssuer) }
        if node.credentialIdentifier.isEmpty { return NSLocalizedString("None", comment: "DICOMweb authentication") }
        if let summary = summaries[node.credentialIdentifier] { return summary }
        let summary = DICOMwebNode.credentialStore.summary(forIdentifier: node.credentialIdentifier)
        summaries[node.credentialIdentifier] = summary
        return summary
    }

    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < nodes.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let node = nodes[row]
        switch identifier {
        case Column.address: return node.address
        case Column.allowInsecureHTTP: return NSNumber(value: node.allowInsecureHTTP)
        case Column.wadoPath: return node.wadoPath
        case Column.qidoPath: return node.qidoPath
        case Column.name: return node.name
        case Column.queryRetrieve: return NSNumber(value: node.queryRetrieve)
        case Column.retrieveSyntax: return NSNumber(value: DICOMwebNode.transferSyntaxes.firstIndex(of: node.retrieveSyntax) ?? 0)
        case Column.auth:
            let certificate = node.clientIdentityReference == nil ? "" : " + " + node.clientIdentityName
            return authSummary(of: node) + certificate + " \u{2026}"
        case Column.send: return NSNumber(value: node.send)
        case Column.sendSyntax: return NSNumber(value: DICOMwebNode.transferSyntaxes.firstIndex(of: node.sendSyntax) ?? 0)
        case Column.maximumRequests: return NSNumber(value: DICOMwebNode.maximumRequestsChoices.firstIndex(of: node.maximumRequests) ?? 0)
        case Column.seriesOrder: return NSNumber(value: node.seriesOrder)
        case Column.excludeSeries: return RetrievePlan.text(forExclusionRules: node.excludedSeries)
        case Column.adaptiveRequests: return NSNumber(value: node.adaptiveRequests)
        case Column.trustedCertificate: return node.trustedCertificateSHA256
        default: return nil
        }
    }

    public func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard row >= 0, row < nodes.count, let identifier = tableColumn?.identifier.rawValue else { return }
        let node = nodes[row]
        let text = (object as? String) ?? (object as? NSNumber)?.stringValue ?? ""
        let index = (object as? NSNumber)?.intValue ?? 0
        do {
            switch identifier {
            case Column.address:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                node.address = trimmed.isEmpty ? "" : try DICOMwebNode.normalizedAddress(trimmed, allowInsecureHTTP: node.allowInsecureHTTP)
            case Column.allowInsecureHTTP:
                let enabled = (object as? NSNumber)?.boolValue ?? false
                if enabled && !node.allowInsecureHTTP {
                    confirmInsecureHTTP(for: node)
                    return
                }
                node.allowInsecureHTTP = enabled
            case Column.wadoPath: node.wadoPath = try DICOMwebNode.normalizedPath(text)
            case Column.qidoPath: node.qidoPath = try DICOMwebNode.normalizedPath(text)
            case Column.name:
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw DICOMwebNode.failure(NSLocalizedString("Enter a name for the DICOMweb node.", comment: "")) }
                guard DICOMwebNode.uniqueName(name, among: nodes, excluding: node.identifier) == name else {
                    throw DICOMwebNode.failure(String(format: NSLocalizedString("Another DICOMweb node is already named %@.", comment: ""), name))
                }
                node.name = name
            case Column.queryRetrieve: node.queryRetrieve = (object as? NSNumber)?.boolValue ?? false
            case Column.send: node.send = (object as? NSNumber)?.boolValue ?? false
            case Column.retrieveSyntax:
                guard DICOMwebNode.transferSyntaxes.indices.contains(index) else { return }
                node.retrieveSyntax = DICOMwebNode.transferSyntaxes[index]
            case Column.sendSyntax:
                guard DICOMwebNode.transferSyntaxes.indices.contains(index) else { return }
                node.sendSyntax = DICOMwebNode.transferSyntaxes[index]
            case Column.maximumRequests:
                guard DICOMwebNode.maximumRequestsChoices.indices.contains(index) else { return }
                node.maximumRequests = DICOMwebNode.maximumRequestsChoices[index]
            case Column.seriesOrder:
                guard RetrieveOrder(rawValue: index) != nil else { return }
                node.seriesOrder = index
            case Column.excludeSeries: node.excludedSeries = RetrievePlan.exclusionRules(forStoredValue: text)
            case Column.adaptiveRequests: node.adaptiveRequests = (object as? NSNumber)?.boolValue ?? false
            case Column.trustedCertificate: node.trustedCertificateSHA256 = try DICOMwebServerTrust.normalizedFingerprint(text)
            default: return
            }
            save()
        } catch {
            report(error, title: NSLocalizedString("DICOMweb Node", comment: ""))
        }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    public func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        tableColumn?.identifier.rawValue != Column.auth
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    @objc func tableClicked(_ sender: Any?) {
        guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0,
              tableView.tableColumns[tableView.clickedColumn].identifier.rawValue == Column.auth else { return }
        editAuthentication(row: tableView.clickedRow)
    }

    private static var insecureHTTPWarning: String {
        NSLocalizedString("HTTP sends DICOM data and credentials without transport encryption. Enable only for a network you trust. HTTPS certificate validation remains enabled.", comment: "DICOMweb insecure HTTP warning")
    }

    private func confirmInsecureHTTP(for node: DICOMwebNode) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Allow Insecure HTTP", comment: "DICOMweb per-node transport choice")
        alert.informativeText = Self.insecureHTTPWarning
        alert.addButton(withTitle: NSLocalizedString("Allow Insecure HTTP", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn,
               let current = self.nodes.first(where: { $0.identifier == node.identifier }) {
                current.allowInsecureHTTP = true
                self.save()
            }
            self.tableView?.reloadData()
        }
        if let window = tableView?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    public func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: UnsafeMutablePointer<NSRect>,
                          tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        switch tableColumn?.identifier.rawValue {
        case Column.allowInsecureHTTP: return Self.insecureHTTPWarning
        case Column.maximumRequests: return Self.maximumRequestsHelp
        case Column.seriesOrder: return RetrievePlan.orderHelp
        case Column.excludeSeries: return RetrievePlan.exclusionHelp
        case Column.adaptiveRequests: return NodeRequestLimiter.adaptiveHelp
        case Column.trustedCertificate: return DICOMwebServerTrust.help
        default: return ""
        }
    }

    // MARK: Authentication

    /// Opens the authentication sheet for a node and applies what it returns.
    func editAuthentication(row: Int) {
        guard row >= 0, row < nodes.count, let window = tableView?.window else { return }
        let node = nodes[row]
        let summary = node.credentialIdentifier.isEmpty ? nil : authSummary(of: node)
        let editor = DICOMwebAuthenticationEditor(node: node, existingSummary: summary)
        editor.begin(for: window) { [weak self] result in
            guard let self, let result else { return }
            // The row may have moved while the sheet was open.
            guard let current = self.nodes.first(where: { $0.identifier == node.identifier }) else { return }
            let previous = current.credentialIdentifier
            let previousSettings = current.oidcSettings
            try DICOMwebAuthentication.apply(result.change, to: current, store: DICOMwebNode.credentialStore)
            // Tokens issued for other settings, or for a node that no longer
            // signs in, are not kept.
            if current.usesOIDC, result.oidc != previousSettings {
                do { try DICOMwebOIDC.signOut(nodeIdentifier: current.identifier) }
                catch { NSLog("DICOMweb: the previous sign-in of a node could not be removed from the Keychain") }
            }
            current.oidcSettings = result.oidc
            current.clientIdentityReference = result.identity?.reference
            current.clientIdentityName = result.identity?.name ?? ""
            self.summaries.removeValue(forKey: previous)
            self.save()
            self.tableView?.reloadData()
            // Saving a node that signs in signs it in, once the sheet is closed.
            if current.usesOIDC {
                DispatchQueue.main.async { [weak self] in self?.signIn(nodeIdentifier: current.identifier, name: current.name) }
            }
        }
    }

    /// Signs a node in through the browser and says how it went; a sign-in the
    /// user cancelled says nothing.
    func signIn(nodeIdentifier: String, name: String) {
        let signIn = DICOMwebOIDCSignIn(nodeIdentifier: nodeIdentifier)
        signIn.start(window: tableView?.window) { [weak self] failure in
            guard let self else { return }
            self.tableView?.reloadData()
            if let failure {
                guard DICOMwebClient.errorKind(for: failure) != .cancelled else { return }
                self.inform(title: NSLocalizedString("DICOMweb Sign-In Failed", comment: ""), message: failure.localizedDescription, style: .warning)
            } else {
                self.inform(title: NSLocalizedString("DICOMweb Sign-In Succeeded", comment: ""),
                            message: String(format: NSLocalizedString("%@ is signed in. Its tokens are kept in the Keychain.", comment: ""), name))
            }
        }
    }
}

/// What the authentication sheet returns: the credential change, the OpenID
/// Connect settings of a node that signs in, and the client certificate.
struct DICOMwebAuthenticationResult {
    var change: DICOMwebAuthChange
    var oidc: DICOMwebNode.OIDCSettings?
    var identity: (reference: Data, name: String)?
}

/// The authentication sheet: None, Username + Password (Basic), Header + API
/// Key, Bearer token, or OpenID Connect, whose settings it checks and whose
/// browser sign-in follows the save; and the client certificate, chosen among
/// the Keychain's identities.
///
/// Secret fields are always empty when it opens: leaving one empty keeps the
/// stored secret when the method and its user or header name are unchanged.
/// The fields are cleared when the sheet closes, whatever the outcome.
// Main actor: the authentication sheet of the node table.
@MainActor
final class DICOMwebAuthenticationEditor: NSObject {
    private let nodeName: String
    private let existingSummary: String?
    private let node: DICOMwebNode

    private let method = NSPopUpButton()
    private let username = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private let headerName = NSTextField(string: "")
    private let apiKey = NSSecureTextField(string: "")
    private let token = NSSecureTextField(string: "")
    private let issuer = NSTextField(string: "")
    private let clientID = NSTextField(string: "")
    private let scopes = NSTextField(string: "")
    private let audience = NSTextField(string: "")
    private let redirectURI = NSTextField(string: "")
    private let certificate = NSPopUpButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var grid: NSGridView?
    private var sheet: NSWindow?

    /// The order of the method pop-up.
    private let kinds: [DICOMwebAuthKind] = [.none, .basic, .apiKey, .bearer, .oidc]

    init(node: DICOMwebNode, existingSummary: String?) {
        self.node = node
        self.nodeName = node.name
        self.existingSummary = existingSummary
        super.init()
    }

    /// Shows the sheet. `apply` receives the change, or nil when cancelled; an
    /// error it throws is shown in the sheet, which stays open.
    func begin(for window: NSWindow, apply: @escaping (DICOMwebAuthenticationResult?) throws -> Void) {
        method.addItems(withTitles: [
            NSLocalizedString("None", comment: "DICOMweb authentication"),
            NSLocalizedString("Username + Password (Basic)", comment: ""),
            NSLocalizedString("Header + API Key", comment: ""),
            NSLocalizedString("Bearer token", comment: ""),
            NSLocalizedString("OpenID Connect (browser sign-in)", comment: "DICOMweb authentication"),
        ])
        method.target = self
        method.action = #selector(methodChanged(_:))
        method.setAccessibilityLabel(NSLocalizedString("Authentication", comment: ""))
        headerName.placeholderString = "X-Api-Key"
        let fields: [(NSTextField, String)] = [
            (username, NSLocalizedString("Username:", comment: "")), (password, NSLocalizedString("Password:", comment: "")),
            (headerName, NSLocalizedString("Header:", comment: "")), (apiKey, NSLocalizedString("API Key:", comment: "")),
            (token, NSLocalizedString("Bearer token:", comment: "")),
            (issuer, NSLocalizedString("Issuer:", comment: "OpenID Connect issuer")),
            (clientID, NSLocalizedString("Client ID:", comment: "OpenID Connect client")),
            (scopes, NSLocalizedString("Scopes:", comment: "OpenID Connect scopes")),
            (audience, NSLocalizedString("Audience:", comment: "OpenID Connect audience")),
            (redirectURI, NSLocalizedString("Redirect URI:", comment: "OpenID Connect redirect URI")),
        ]
        for (field, label) in fields {
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        issuer.placeholderString = "https://idp.example/realms/pacs"
        scopes.placeholderString = DICOMwebNode.defaultOIDCScopes
        redirectURI.placeholderString = DICOMwebNode.defaultOIDCRedirectURI
        if let settings = node.oidcSettings {
            issuer.stringValue = settings.issuer; clientID.stringValue = settings.clientID
            scopes.stringValue = settings.scopes; audience.stringValue = settings.audience
            redirectURI.stringValue = settings.redirectURI
        }
        if node.usesOIDC {
            method.selectItem(at: kinds.firstIndex(of: .oidc) ?? 0)
        } else if let existing = existingSummary.flatMap(DICOMwebAuthentication.parse(summary:)) {
            method.selectItem(at: kinds.firstIndex(of: existing.kind) ?? 0)
            if existing.kind == .basic { username.stringValue = existing.detail }
            if existing.kind == .apiKey { headerName.stringValue = existing.detail }
        } else {
            method.selectItem(at: existingSummary == nil ? 0 : 1)
        }
        // The Keychain's identities; one the node names that is no longer
        // there stays listed, so saving does not drop it unasked.
        certificate.addItem(withTitle: NSLocalizedString("No client certificate", comment: "DICOMweb client certificate"))
        var identities = DICOMwebCredentials.clientIdentities()
        if let reference = node.clientIdentityReference, !identities.contains(where: { $0.reference == reference }) {
            identities.append((node.clientIdentityName, reference))
        }
        for identity in identities {
            certificate.addItem(withTitle: identity.name)
            certificate.lastItem?.representedObject = identity.reference
            if identity.reference == node.clientIdentityReference { certificate.select(certificate.lastItem) }
        }
        certificate.setAccessibilityLabel(NSLocalizedString("Client certificate:", comment: "DICOMweb client certificate"))
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 400

        let title = NSTextField(labelWithString: String(format: NSLocalizedString("Authentication for %@", comment: ""), nodeName))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let note = NSTextField(wrappingLabelWithString: NSLocalizedString("Secrets are stored in the Keychain. Leave a secret empty to keep the one stored.", comment: ""))
        note.preferredMaxLayoutWidth = 400
        note.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: NSLocalizedString("Method:", comment: "")), method],
            [NSTextField(labelWithString: NSLocalizedString("Username:", comment: "")), username],
            [NSTextField(labelWithString: NSLocalizedString("Password:", comment: "")), password],
            [NSTextField(labelWithString: NSLocalizedString("Header:", comment: "")), headerName],
            [NSTextField(labelWithString: NSLocalizedString("API Key:", comment: "")), apiKey],
            [NSTextField(labelWithString: NSLocalizedString("Bearer token:", comment: "")), token],
            [NSTextField(labelWithString: NSLocalizedString("Issuer:", comment: "OpenID Connect issuer")), issuer],
            [NSTextField(labelWithString: NSLocalizedString("Client ID:", comment: "OpenID Connect client")), clientID],
            [NSTextField(labelWithString: NSLocalizedString("Scopes:", comment: "OpenID Connect scopes")), scopes],
            [NSTextField(labelWithString: NSLocalizedString("Audience:", comment: "OpenID Connect audience")), audience],
            [NSTextField(labelWithString: NSLocalizedString("Redirect URI:", comment: "OpenID Connect redirect URI")), redirectURI],
            [NSTextField(labelWithString: NSLocalizedString("Client certificate:", comment: "DICOMweb client certificate")), certificate],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        self.grid = grid

        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, note, grid, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: message)
        buttons.setHuggingPriority(.defaultHigh, for: .horizontal)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.contentView = stack
        sheet.isReleasedWhenClosed = false
        self.sheet = sheet
        self.apply = apply
        methodChanged(nil)
        window.beginSheet(sheet) { [self] _ in clearSecrets() }
    }

    private var apply: ((DICOMwebAuthenticationResult?) throws -> Void)?

    private var selectedKind: DICOMwebAuthKind {
        let index = method.indexOfSelectedItem
        return kinds.indices.contains(index) ? kinds[index] : .none
    }

    @objc private func methodChanged(_ sender: Any?) {
        guard let grid else { return }
        let kind = selectedKind
        grid.row(at: 1).isHidden = kind != .basic
        grid.row(at: 2).isHidden = kind != .basic
        grid.row(at: 3).isHidden = kind != .apiKey
        grid.row(at: 4).isHidden = kind != .apiKey
        grid.row(at: 5).isHidden = kind != .bearer
        for row in 6...10 { grid.row(at: row).isHidden = kind != .oidc }
        message.stringValue = kind == .oidc ? DICOMwebOIDC.settingsHelp : ""
    }

    private func clearSecrets() {
        password.stringValue = ""
        apiKey.stringValue = ""
        token.stringValue = ""
    }

    private func end() {
        clearSecrets()
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        self.sheet = nil
        apply = nil
    }

    @objc private func cancel(_ sender: Any?) {
        try? apply?(nil)
        end()
    }

    @objc private func save(_ sender: Any?) {
        let kind = selectedKind
        let secret: String
        switch kind {
        case .basic: secret = password.stringValue
        case .apiKey: secret = apiKey.stringValue
        case .bearer: secret = token.stringValue
        case .none, .oidc: secret = ""
        }
        do {
            var settings: DICOMwebNode.OIDCSettings?
            if kind == .oidc {
                let value = { (field: NSTextField) in field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                let entered = DICOMwebNode.OIDCSettings(issuer: value(issuer), clientID: value(clientID), scopes: value(scopes),
                                                        audience: value(audience), redirectURI: value(redirectURI))
                try DICOMwebOIDC.validate(issuer: entered.issuer, clientID: entered.clientID, scopes: entered.scopes,
                                          audience: entered.audience, redirectURI: entered.redirectURI)
                settings = entered
            }
            let change = try DICOMwebAuthentication.resolve(existingSummary: existingSummary, kind: kind,
                                                            username: username.stringValue, secret: secret,
                                                            headerName: headerName.stringValue)
            let identity = (certificate.selectedItem?.representedObject as? Data).map { ($0, certificate.titleOfSelectedItem ?? "") }
            try apply?(DICOMwebAuthenticationResult(change: change, oidc: settings, identity: identity))
            end()
        } catch {
            message.textColor = .systemRed
            message.stringValue = (error as NSError).localizedDescription
        }
    }
}
