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
import IsiXHTTPServer
import IsiXPreferences

/// The hosts whose download links are carried out without asking, as the
/// preferences keep them. Only the user adds to the list: in the sheet of the
/// Listener preferences, or from the alert of a link. No request does.
enum LinkTrustedHosts {
    static func list(in preferences: any PreferenceStore) -> [XMLRPCLinkTrustedHost] {
        XMLRPCLinkTrustedHost.list(stored: preferences[NetworkPreferences.linkDownloadTrustedHosts]?.map(\.object))
    }

    static func save(_ list: [XMLRPCLinkTrustedHost], in preferences: any PreferenceStore) {
        let stored = XMLRPCLinkTrustedHost.stored(list).compactMap { PropertyListValue($0) }
        preferences.set(stored.isEmpty ? nil : stored, for: NetworkPreferences.linkDownloadTrustedHosts)
    }

    static func add(_ host: XMLRPCLinkTrustedHost, in preferences: any PreferenceStore) {
        save(XMLRPCLinkTrustedHost.adding(host, to: list(in: preferences)), in: preferences)
    }
}

/// The part of the sheet of the links that shows the trusted hosts: the list,
/// a mark for each host that is also accepted without encryption, a field to
/// add one and a button to remove the selected ones.
@MainActor
final class LinkTrustedHostsEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let hostColumn = NSUserInterfaceItemIdentifier("IsiXLinkTrustedHost")
    static let httpColumn = NSUserInterfaceItemIdentifier("IsiXLinkTrustedHostHTTP")

    private let preferences: any PreferenceStore
    private(set) var hosts: [XMLRPCLinkTrustedHost] = []
    /// Called when the height of the views may have changed.
    var layoutChanged: () -> Void = {}

    let table = NSTableView()
    let field = NSTextField()
    let note = NSTextField(wrappingLabelWithString: "")
    private(set) var removeButton: NSButton?

    init(preferences: any PreferenceStore = PreferencesSource.process.preferences) {
        self.preferences = preferences
    }

    /// The views of the editor, from top to bottom.
    func makeViews(width: CGFloat) -> [NSView] {
        let heading = NSTextField(labelWithString: NSLocalizedString("Trusted hosts for download links", comment: "Link schemes: title of the list of hosts whose DownloadURL links run without asking"))
        heading.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let explanation = NSTextField(wrappingLabelWithString: NSLocalizedString("A download link (DownloadURL) to a host listed here is carried out without asking. A host is matched exactly, with its port: a subdomain is another host. List only hosts you trust, such as the portal of your institution.", comment: "Link schemes: explanation of the list of trusted hosts"))
        explanation.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = width
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let http = NSTableColumn(identifier: Self.httpColumn)
        http.title = NSLocalizedString("Allow HTTP", comment: "Link schemes: column of the trusted hosts, a link that is not encrypted is accepted too")
        http.width = max(90, (http.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width + 16)
        http.resizingMask = []
        let host = NSTableColumn(identifier: Self.hostColumn)
        host.title = NSLocalizedString("Host", comment: "")
        host.width = width - http.width - 24
        host.resizingMask = .autoresizingMask
        table.addTableColumn(host)
        table.addTableColumn(http)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        field.placeholderString = "pacs.example.com"
        field.target = self
        field.action = #selector(add(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let add = NSButton(title: NSLocalizedString("Add", comment: ""), target: self, action: #selector(add(_:)))
        let remove = NSButton(title: NSLocalizedString("Remove", comment: ""), target: self, action: #selector(remove(_:)))
        removeButton = remove
        let row = NSStackView(views: [field, add, remove])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true

        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .systemRed
        note.preferredMaxLayoutWidth = width
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.isHidden = true

        reload()
        return [heading, explanation, scroll, row, note]
    }

    /// Reads the list again from the preferences.
    func reload() {
        hosts = LinkTrustedHosts.list(in: preferences)
        table.reloadData()
        removeButton?.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    private func say(_ text: String) {
        note.stringValue = text
        note.isHidden = text.isEmpty
        layoutChanged()
    }

    /// Adds the host typed in the field. A URL typed there gives its host,
    /// and an http one marks the host as accepted without encryption.
    @objc func add(_ sender: Any?) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let host = XMLRPCLinkTrustedHost(entry: text, allowsHTTP: text.lowercased().hasPrefix("http://")) else {
            say(String(format: NSLocalizedString("%@ is not a host name. Type a host, with its port when it is not the usual one: pacs.example.com or pacs.example.com:8443.", comment: "Link schemes: the text typed for a trusted host names no host; %@ is the text"), text))
            return
        }
        LinkTrustedHosts.add(host, in: preferences)
        field.stringValue = ""
        reload()
        say("")
    }

    @objc func remove(_ sender: Any?) {
        let selected = table.selectedRowIndexes
        guard !selected.isEmpty else { return }
        LinkTrustedHosts.save(hosts.enumerated().filter { !selected.contains($0.offset) }.map(\.element), in: preferences)
        table.deselectAll(nil)
        reload()
    }

    @objc func httpChanged(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard hosts.indices.contains(row) else { return }
        hosts[row].allowsHTTP = sender.state == .on
        LinkTrustedHosts.save(hosts, in: preferences)
    }

    // MARK: The table

    func numberOfRows(in tableView: NSTableView) -> Int {
        hosts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hosts.indices.contains(row), let column = tableColumn else { return nil }
        if column.identifier == Self.httpColumn {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(httpChanged(_:)))
            box.state = hosts[row].allowsHTTP ? .on : .off
            box.controlSize = .small
            box.setAccessibilityLabel(column.title)
            return box
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: hosts[row].entry)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton?.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}
