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

/// The sheet of the Listener preferences for the schemes of the links: one
/// box for each scheme the application declares, with the application that
/// opens it now, and what to do at launch when it is another one.
///
/// A box shows what the system answers, not what was last asked of it: it is
/// ticked only while the scheme is opened by the application that is running,
/// and it is read again when the sheet opens and when the application comes
/// back to the front, since another application may have taken the scheme
/// meanwhile. Ticking a box makes this application the one that opens the
/// scheme; unticking it gives the scheme back to the application it was taken
/// from, when that is known.
///
/// Built in code, and reached by a button added to the pane at runtime: the
/// pane's nib has a copy for each language and no row to spare.
@MainActor
@objc(IsiXLinkSchemeSettings)
public final class LinkSchemeSettings: NSObject {
    static let shared = LinkSchemeSettings()
    static let buttonIdentifier = NSUserInterfaceItemIdentifier("IsiXLinkSchemeSettingsButton")

    private let registry = LinkSchemeRegistry(preferences: PreferencesSource.process.preferences)
    private var sheet: NSWindow?
    private var boxes: [NSButton] = []
    private var handlerLabels: [NSTextField] = []
    private var policyPopUp: NSPopUpButton?
    private var noteLabel: NSTextField?
    private var activation: NSObjectProtocol?

    // MARK: - The button of the pane

    /// Adds the button that opens the sheet to the pane whose content is
    /// `view`, at the end of the title line of the box that holds the port of
    /// the XML-RPC server, or returns the one already there. `nil` when that
    /// box is not in this tree or its title leaves no room: a pane that was
    /// rearranged loses the button rather than have it drawn over something.
    @objc(installButtonInView:)
    @discardableResult
    public static func installButton(in view: NSView) -> NSButton? {
        guard let box = linkBox(in: view), let host = box.superview else { return nil }
        if let existing = host.subviews.first(where: { $0.identifier == buttonIdentifier }) as? NSButton {
            return existing
        }
        let button = NSButton(title: NSLocalizedString("Open Links with IsiX…", comment: "Listener preferences: opens the sheet of the link schemes"),
                              target: shared, action: #selector(openFromButton(_:)))
        button.identifier = buttonIdentifier
        button.bezelStyle = .roundRect
        button.controlSize = .mini
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        button.sizeToFit()

        // The title line of the box: its text at the leading edge, the button
        // at the other one, with the room the text leaves.
        let title = host.convert(box.titleRect, from: box)
        let rightToLeft = host.userInterfaceLayoutDirection == .rightToLeft
        let room = rightToLeft ? title.minX - 12 - (box.frame.minX + 8) : box.frame.maxX - 8 - (title.maxX + 12)
        let width = min(button.frame.width, room)
        guard width >= 60 else { return nil }
        let height = min(button.frame.height, 16)
        button.frame = NSRect(x: rightToLeft ? box.frame.minX + 8 : box.frame.maxX - 8 - width,
                              y: (title.midY - height / 2).rounded(), width: width, height: height)
        button.autoresizingMask = rightToLeft ? [.maxXMargin, .minYMargin] : [.minXMargin, .minYMargin]
        host.addSubview(button, positioned: .above, relativeTo: box)
        return button
    }

    /// The box around the field bound to the port of the XML-RPC server.
    static func linkBox(in view: NSView) -> NSBox? {
        if let field = view as? NSTextField,
           let observed = field.infoForBinding(.value)?[NSBindingInfoKey.observedKeyPath] as? String,
           observed == NetworkPreferences.controllerKeyPath(NetworkPreferences.xmlrpcServerPort) {
            var parent = field.superview
            while let current = parent {
                if let box = current as? NSBox { return box }
                parent = current.superview
            }
            return nil
        }
        for child in view.subviews {
            if let box = linkBox(in: child) { return box }
        }
        return nil
    }

    @objc private func openFromButton(_ sender: NSButton) {
        guard let window = sender.window else { return }
        open(attachedTo: window)
    }

    // MARK: - The sheet

    /// Opens the sheet on `window`, with what the system answers now.
    @objc(openAttachedToWindow:)
    public func open(attachedTo window: NSWindow) {
        guard sheet == nil else { return }
        let sheet = makeSheet()
        self.sheet = sheet
        refresh()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        window.beginSheet(sheet) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
    }

    private func closed() {
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        sheet = nil
        boxes = []
        handlerLabels = []
        policyPopUp = nil
        noteLabel = nil
    }

    func makeSheet() -> NSWindow {
        let heading = NSTextField(labelWithString: NSLocalizedString("Open links with IsiX", comment: "Link schemes: title of the sheet of the Listener preferences"))
        heading.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let explanation = Self.wrapping(NSLocalizedString("A ticked scheme is opened by this copy of IsiX DICOM Viewer. An application that also declares a scheme can take it again later; isix:// links are declared by IsiX DICOM Viewer alone.", comment: "Link schemes: explanation in the sheet of the Listener preferences"))

        var rows: [NSView] = []
        boxes = []
        handlerLabels = []
        for (index, scheme) in LinkSchemeHandlers.declared.enumerated() {
            let box = NSButton(checkboxWithTitle: scheme + "://", target: self, action: #selector(boxChanged(_:)))
            box.tag = index
            let label = Self.wrapping("")
            boxes.append(box)
            handlerLabels.append(label)
            label.preferredMaxLayoutWidth = 440
            // The application's line under the title of the box, not under its square.
            let indented = NSStackView(views: [label])
            indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            let row = NSStackView(views: [box, indented])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            rows.append(row)
        }

        let policyLabel = NSTextField(labelWithString: NSLocalizedString("At startup, when another application opens these links:", comment: "Link schemes: label of the choice of what is done at launch"))
        let policy = NSPopUpButton(frame: .zero, pullsDown: false)
        policy.addItems(withTitles: [
            NSLocalizedString("Ask", comment: "Link schemes at launch: tell the user and let them choose"),
            NSLocalizedString("Make IsiX the default without asking", comment: "Link schemes at launch: take the schemes back"),
            NSLocalizedString("Do nothing", comment: "Link schemes at launch: neither tell nor change"),
        ])
        for (item, value) in zip(policy.itemArray, LinkSchemeHandlers.StartupPolicy.allCases) { item.tag = value.rawValue }
        policy.target = self
        policy.action = #selector(policyChanged(_:))
        policyPopUp = policy

        let note = Self.wrapping("")
        note.textColor = .systemRed
        noteLabel = note

        let done = NSButton(title: NSLocalizedString("Done", comment: ""), target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, done])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill

        let column = NSStackView(views: [heading, explanation] + rows + [policyLabel, policy, note, buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        column.setCustomSpacing(4, after: policyLabel)
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: 520),
            buttonRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -20),
        ])

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.contentView = content
        sheet.isReleasedWhenClosed = false
        return sheet
    }

    /// A small label that wraps within the sheet.
    private static func wrapping(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 460
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Reads from the system which application opens each scheme, and from
    /// the preferences what is done at launch.
    func refresh() {
        guard let sheet else { return }
        for (index, scheme) in LinkSchemeHandlers.declared.enumerated() where index < boxes.count {
            let handler = LinkSchemeRegistry.handler(of: scheme)
            boxes[index].state = LinkSchemeRegistry.isRunning(handler) ? .on : .off
            handlerLabels[index].stringValue = String(format: NSLocalizedString("Opened by %@", comment: "Link schemes: %@ is an application's name and path, or the text for no application"),
                                                      LinkSchemeRegistry.describe(handler))
        }
        let policy = LinkSchemeHandlers.StartupPolicy(stored: registry.preferences[NetworkPreferences.linkSchemeStartupPolicy])
        policyPopUp?.selectItem(withTag: policy.rawValue)
        resize(sheet)
    }

    /// The sheet as tall as its texts, which change with what the system answers.
    private func resize(_ sheet: NSWindow) {
        guard let content = sheet.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = sheet.frame
        let height = sheet.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize)).height
        frame.origin.y += frame.height - height
        frame.size.height = height
        sheet.setFrame(frame, display: true)
    }

    /// A box was clicked: the change is asked of the system, and the box then
    /// shows what the system answers, with the reason when it is not what
    /// was asked.
    @objc private func boxChanged(_ sender: NSButton) {
        guard sender.tag < LinkSchemeHandlers.declared.count else { return }
        let scheme = LinkSchemeHandlers.declared[sender.tag]
        let take = sender.state == .on
        let registry = self.registry
        boxes.forEach { $0.isEnabled = false }
        Task { @MainActor in
            var note = ""
            if take {
                note = await registry.take(scheme) ?? ""
            } else {
                switch await registry.giveBack(scheme) {
                case .done:
                    break
                case .kept:
                    note = String(format: NSLocalizedString("IsiX DICOM Viewer does not know which application opened %@:// links before it, so they stay with it. To have another application open them, make it the default in that application's own settings.", comment: "Link schemes: unticking a scheme whose former application is unknown or gone; %@ is a scheme"), scheme)
                case .failed(let reason):
                    note = reason
                }
            }
            self.boxes.forEach { $0.isEnabled = true }
            self.noteLabel?.stringValue = note
            self.refresh()
        }
    }

    @objc private func policyChanged(_ sender: NSPopUpButton) {
        let policy = LinkSchemeHandlers.StartupPolicy(stored: sender.selectedTag())
        registry.preferences.set(policy.rawValue, for: NetworkPreferences.linkSchemeStartupPolicy)
    }

    @objc private func done(_ sender: Any?) {
        guard let sheet, let host = sheet.sheetParent else { return }
        host.endSheet(sheet)
    }
}
