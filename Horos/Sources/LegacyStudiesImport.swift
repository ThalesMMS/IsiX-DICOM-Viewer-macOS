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
import IsiXDatabase
import IsiXStorage

// File > Import > Import Studies from Horos or OsiriX…: the studies of the
// data folder an earlier application left ("Horos Data", "OsiriX Data") come
// into the database that is open. The folder is found in the documents folder
// or chosen; its database is only read (LegacyDatabase), to say how many
// studies there are and how much room their files take, and to carry over
// what the earlier application recorded apart from the files: albums,
// comments and states. The files go through the import every dropped file
// goes through (DroppedFilesImport), copied or indexed where they are, on a
// thread of the Activity list.
//
// A database that indexed its files where they were lists them by their full
// path, on another disk as a rule. Those that cannot be read (the disk is not
// connected, or the application has no leave to read there) are counted, with
// the folders they were expected in, and the dialog asks for those folders.
//
// The files of the earlier image folder that its database no longer lists
// (LegacyFileIndex) are what that application took out of its list and left
// on disk, the studies deleted there among them: they are left out, counted,
// and imported too only when asked. A database that cannot be read, or that
// does not say where its files are, leaves no file out, and that is said.

/// The import of the studies of an earlier application's data folder.
@MainActor final class LegacyStudiesImport: NSObject {
    static let shared = LegacyStudiesImport()

    /// The notes of the studies still to arrive, by study identifier, and the
    /// database they are for. Kept for the run of the application: an import
    /// cut short by quitting is started again from the command, which reads
    /// them again.
    private var pending: [String: LegacyDatabase.Study] = [:]
    private weak var pendingDatabase: DicomDatabase?
    private var isObserving = false

    // MARK: - The command

    /// Whether the database shown can take the studies.
    static func canImport(into browser: BrowserController?) -> Bool {
        guard let database = browser?.database else { return false }
        return database.isLocal() && !database.isReadOnly
    }

    /// Asks which folder and how, then starts the import.
    func run(in browser: BrowserController) {
        guard Self.canImport(into: browser), let database = browser.database else {
            NSSound.beep()
            return
        }
        let openFolder = database.dataDirPath() ?? ""
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        var folders = documents.map { LegacyDatabase.found(inDocuments: $0) } ?? []
        folders.removeAll { Self.isSame($0, as: openFolder) }
        if folders.isEmpty {
            guard let chosen = Self.chooseFolder(openFolder: openFolder) else { return }
            folders = [chosen]
        }
        ask(folders, openFolder: openFolder, database: database, browser: browser)
    }

    /// The dialog of the import on `folders`, and the import it asks for.
    private func ask(_ folders: [LegacyDatabase], openFolder: String, database: DicomDatabase, browser: BrowserController) {
        let dialog = LegacyImportDialog(folders: folders, openFolder: openFolder)
        guard let (choice, survey, files) = dialog.run() else { return }
        prepareNotes(survey.contents, in: database)
        browser.droppedFiles.importFiles(files, options: [
            "COPYDATABASE": NSNumber(value: choice == .copy),
            "COPYDATABASEMODE": NSNumber(value: DatabaseCopyRule.always),
            "async": NSNumber(value: true),
        ])
    }

    /// What the command does without its dialog, for scripts and checks: reads
    /// the data folder at `path` and starts the import, copying or not, the
    /// files its database no longer lists left out. The number of files handed
    /// to the import, -1 when the folder holds no such database or the
    /// database shown cannot take them.
    func importFolder(atPath path: String, copying: Bool, into browser: BrowserController) -> Int {
        importFolder(atPath: path, copying: copying, includingUnlisted: false, into: browser)
    }

    /// The same, with the files the earlier database no longer lists when
    /// `includingUnlisted` says so.
    func importFolder(atPath path: String, copying: Bool, includingUnlisted: Bool, into browser: BrowserController) -> Int {
        guard Self.canImport(into: browser), let database = browser.database,
              let legacy = LegacyDatabase.resolving(URL(fileURLWithPath: path, isDirectory: true)),
              !Self.isSame(legacy, as: database.dataDirPath() ?? ""), let survey = legacy.survey() else { return -1 }
        let files = survey.files.paths + (includingUnlisted ? survey.files.unlisted : [])
        Self.log(survey, imported: files.count)
        prepareNotes(survey.contents, in: database)
        browser.droppedFiles.importFiles(files, options: [
            "COPYDATABASE": NSNumber(value: copying),
            "COPYDATABASEMODE": NSNumber(value: DatabaseCopyRule.always),
            "async": NSNumber(value: true),
        ])
        return files.count
    }

    // MARK: - An image folder chosen on the way to a database

    /// Imports the image folder of an earlier application's database, as
    /// choosing that database at first use or as the database location asks.
    /// When its database lies beside the folder, the import is the command's
    /// own: the same dialog, on that folder, with the same choice between
    /// copying the files and indexing them where they are, the same count of
    /// what the database no longer lists and of what could not be read. A
    /// folder without a database beside it is imported whole.
    func importImagesFolder(_ folder: String, into browser: BrowserController) {
        guard let legacy = LegacyDatabase.holding(imagesFolder: URL(fileURLWithPath: folder, isDirectory: true)) else {
            browser.subSelectFilesAndFolders(toAdd: [folder])
            return
        }
        // From the main run loop, where a modal holds neither the main queue
        // nor the main actor.
        onMainRunLoop { self.askForChosenFolder(legacy, in: browser) }
    }

    private func askForChosenFolder(_ legacy: LegacyDatabase, in browser: BrowserController) {
        let title = NSLocalizedString("Import Studies from Horos or OsiriX", comment: "")
        guard Self.canImport(into: browser), let database = browser.database else {
            NSLog("Database: the database shown cannot take the studies of an earlier database")
            NSSound.beep()
            return
        }
        let openFolder = database.dataDirPath() ?? ""
        guard !Self.isSame(legacy, as: openFolder) else {
            _ = HorosAlertPanel.runCritical(title: title, message: NSLocalizedString("This folder is the database that is open.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        ask([legacy], openFolder: openFolder, database: database, browser: browser)
    }

    /// How many files the database links to could not be read, and where
    /// they were expected.
    fileprivate static func unreadLinkedText(_ files: LegacyDatabase.Files) -> String {
        String(format: NSLocalizedString("Files the database links to that could not be read: %@, in %@. They are left out. Check that their disk is connected, or choose Allow Access… and select that folder.", comment: ""),
               NumberFormatter.localizedString(from: NSNumber(value: files.unreadLinked.count), number: .decimal),
               LegacyDatabase.foldersHolding(files.unreadLinked).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
    }

    /// How many files of the folder the database no longer lists, and what
    /// becomes of them: imported too when `imported` says they were asked
    /// for, else left out unless asked for.
    fileprivate static func unlistedText(_ files: LegacyDatabase.Files, imported: Bool = false) -> String {
        let format = imported
            ? NSLocalizedString("Files in the folder that the database no longer lists, such as those of deleted studies: %@ (%@). They are imported too.", comment: "")
            : NSLocalizedString("Files in the folder that the database no longer lists, such as those of deleted studies: %@ (%@). They are left out unless you choose to import them too.", comment: "")
        return String(format: format,
                      NumberFormatter.localizedString(from: NSNumber(value: files.unlisted.count), number: .decimal),
                      ByteCountFormatter.string(fromByteCount: files.unlistedBytes, countStyle: .file))
    }

    /// Why no file of the folder is left out, when the database did not say
    /// which it lists; nil when it did.
    fileprivate static func unreadText(_ listing: LegacyDatabase.Survey.Listing) -> String? {
        let everything = NSLocalizedString("Every file in the folder is imported, including those of studies deleted in the earlier application.", comment: "")
        switch listing {
        case .read:
            return nil
        case .unreadable(let failure):
            return String(format: NSLocalizedString("This database could not be read: %@", comment: ""), failure.description) + "\n" + everything
        case .unknown:
            return NSLocalizedString("This database does not record where its files are.", comment: "") + " " + everything
        }
    }

    /// The counts of an import, without a path or a name.
    fileprivate static func log(_ survey: LegacyDatabase.Survey, imported: Int) {
        let listing: String
        switch survey.listing {
        case .read: listing = "read"
        case .unreadable: listing = "unreadable"
        case .unknown: listing = "without file paths"
        }
        NSLog("Database: importing %ld files of an earlier database (index %@); %ld files it no longer lists, %ld listed or linked, %ld linked that could not be read",
              imported, listing, survey.files.unlisted.count, survey.files.paths.count, survey.files.unreadLinked.count)
    }

    /// Whether a data folder is the one of the database that is open.
    fileprivate static func isSame(_ legacy: LegacyDatabase, as openFolder: String) -> Bool {
        !openFolder.isEmpty && legacy.imagesFolder.resolvingSymlinksInPath().path == URL(fileURLWithPath: openFolder).resolvingSymlinksInPath().path
    }

    /// The open panel of the data folder; nil when cancelled or when the
    /// folder holds no database of an earlier application, which is said.
    fileprivate static func chooseFolder(openFolder: String) -> LegacyDatabase? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.message = NSLocalizedString("Choose the Horos Data or OsiriX Data folder", comment: "")
        guard panel.runModal() == .OK, let url = panel.url, keepAccess(to: url) else { return nil }
        guard let legacy = LegacyDatabase.resolving(url) else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Import Studies from Horos or OsiriX", comment: ""),
                                            message: NSLocalizedString("No Horos or OsiriX database was found in this folder.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }
        guard !isSame(legacy, as: openFolder) else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Import Studies from Horos or OsiriX", comment: ""),
                                            message: NSLocalizedString("This folder is the database that is open.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }
        return legacy
    }

    /// Keeps the access the user gave to a chosen folder, and says why when
    /// it cannot be kept: without it nothing of the folder can be read.
    fileprivate static func keepAccess(to url: URL) -> Bool {
        do {
            try SandboxFileAccess.retain(url)
            return true
        } catch {
            NSLog("Unable to retain folder access: %@", error.localizedDescription)
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Import Studies from Horos or OsiriX", comment: ""),
                                            message: String(format: NSLocalizedString("Access to this folder could not be kept: %@", comment: ""), error.localizedDescription),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }
    }

    /// Asks for the folder of files the database links to, so that the
    /// application may read them: the open panel starts at `folder`, or at
    /// the nearest folder above it that exists. Whether access was given.
    fileprivate static func allowAccess(toLinkedFolder folder: String) -> Bool {
        var start = URL(fileURLWithPath: folder, isDirectory: true)
        while start.path != "/" && !FileManager.default.fileExists(atPath: start.path) { start.deleteLastPathComponent() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.prompt = NSLocalizedString("Allow Access", comment: "")
        panel.message = String(format: NSLocalizedString("Select the folder of the files the database links to, to let the application read them: %@", comment: ""),
                               (folder as NSString).abbreviatingWithTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return keepAccess(to: url)
    }

    // MARK: - Albums, comments and states

    /// Makes the albums the database lacks and keeps the notes of the
    /// studies, to give each as it arrives. The studies already here get
    /// theirs now.
    private func prepareNotes(_ contents: LegacyDatabase.Contents, in database: DicomDatabase) {
        createAlbums(contents.albums, in: database)
        pending = Dictionary(contents.studies.filter(\.hasNotes).map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        pendingDatabase = database
        if !isObserving {
            isObserving = true
            NotificationCenter.default.addObserver(self, selector: #selector(studiesAdded(_:)), name: .OsirixAddToDB, object: nil)
        }
        applyNotes(to: nil)
    }

    /// An album of the same name is the same album: it is left as it is.
    private func createAlbums(_ albums: [LegacyDatabase.Album], in database: DicomDatabase) {
        guard let context = database.managedObjectContext else { return }
        let existing = (database.objects(forEntity: database.albumEntity()) ?? []).compactMap { $0 as? DicomAlbum }
        var names = Set(existing.compactMap(\.name)), count = existing.count
        for album in albums where names.insert(album.name).inserted {
            guard let created = NSEntityDescription.insertNewObject(forEntityName: DicomDatabaseAlbumEntityName, into: context) as? DicomAlbum else { continue }
            created.name = album.name
            created.smartAlbum = NSNumber(value: album.predicate != nil)
            created.predicateString = album.predicate
            created.index = NSNumber(value: count)
            count += 1
        }
        if count != existing.count {
            _ = database.save()
            BrowserDatabaseSource.process.processGraph.currentBrowser?.refreshAlbums()
        }
    }

    /// Images were added to a database: the studies among them that have
    /// notes waiting get them.
    @objc private func studiesAdded(_ notification: Notification) {
        guard !pending.isEmpty, let database = pendingDatabase, notification.object as AnyObject? === database else { return }
        let images = notification.userInfo?[OsirixAddToDBNotificationImagesArray] as? [Any]
        let identifiers = images?.compactMap { ($0 as? DicomImage)?.series?.study?.studyInstanceUID }
        applyNotes(to: identifiers.map { Array(Set($0)) })
    }

    /// Gives the studies of `identifiers` (every study still waiting, when
    /// nil) the notes they lack. A study that got its notes waits no more.
    private func applyNotes(to identifiers: [String]?) {
        guard let database = pendingDatabase, !pending.isEmpty else { return }
        let wanted = (identifiers ?? Array(pending.keys)).filter { pending[$0] != nil }
        guard !wanted.isEmpty else { return }
        let albums = Dictionary((database.objects(forEntity: database.albumEntity()) ?? []).compactMap { $0 as? DicomAlbum }
            .filter { $0.smartAlbum?.boolValue != true }.compactMap { album in album.name.map { ($0, album) } }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for start in stride(from: 0, to: wanted.count, by: 400) {
            let slice = Array(wanted[start..<min(start + 400, wanted.count)])
            let found = database.objects(forEntity: DicomDatabaseStudyEntityName, predicate: NSPredicate(format: "studyInstanceUID IN %@", slice)) ?? []
            for case let study as DicomStudy in found {
                guard let uid = study.studyInstanceUID, let notes = pending.removeValue(forKey: uid) else { continue }
                changed = Self.apply(notes, to: study, albums: albums) || changed
            }
        }
        if changed {
            _ = database.save()
            let browser = BrowserDatabaseSource.process.processGraph.currentBrowser
            browser?.refreshAlbums()
            _ = browser?.outlineViewRefresh()
        }
    }

    private static let commentKeys = ["comment", "comment2", "comment3", "comment4"]

    /// Writes what the study lacks, as the annotations of a study's files are
    /// applied: the values are stored without rewriting its files.
    private static func apply(_ notes: LegacyDatabase.Study, to study: DicomStudy, albums: [String: DicomAlbum]) -> Bool {
        let current = commentKeys.map { study.primitiveValue(forKey: $0) as? String ?? "" }
        let member = Set(albums.filter { $0.value.studies?.contains(study) == true }.keys)
        let missing = notes.notesMissing(comments: current, state: (study.primitiveValue(forKey: "stateText") as? NSNumber)?.intValue ?? 0, albums: member)
        guard !missing.isEmpty else { return false }
        for (place, comment) in missing.comments where place < commentKeys.count {
            study.willChangeValue(forKey: commentKeys[place])
            study.setPrimitiveValue(comment, forKey: commentKeys[place])
            study.didChangeValue(forKey: commentKeys[place])
        }
        if let state = missing.state {
            study.willChangeValue(forKey: "stateText")
            study.setPrimitiveValue(NSNumber(value: state), forKey: "stateText")
            study.didChangeValue(forKey: "stateText")
        }
        for name in missing.albums {
            albums[name]?.addStudiesObject(study)
        }
        return true
    }
}

/// The dialog of the import: the data folder, what it holds, and the choice
/// between copying the files and indexing them where they are. The folder is
/// read on a thread of its own; the buttons wait for it.
@MainActor private final class LegacyImportDialog: NSObject {
    enum Choice { case copy, link }

    typealias Survey = LegacyDatabase.Survey

    private let alert = NSAlert()
    private let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 26), pullsDown: false)
    private let summary = NSTextField(wrappingLabelWithString: "")
    /// Shown when the folder holds files its database no longer lists.
    private let unlisted = NSButton(checkboxWithTitle: NSLocalizedString("Also import the files the database no longer lists", comment: ""), target: nil, action: nil)
    /// Shown when the database links to files that could not be read.
    private let access = NSButton(title: NSLocalizedString("Allow Access…", comment: ""), target: nil, action: nil)
    private let accessory = NSView(frame: NSRect(x: 0, y: 0, width: LegacyImportDialog.width, height: 188))
    private static let width: CGFloat = 440
    private var folders: [LegacyDatabase]
    private var selected = 0
    private let openFolder: String
    private var reading: Task<Void, Never>?
    private var survey: Survey?

    init(folders: [LegacyDatabase], openFolder: String) {
        self.folders = folders
        self.openFolder = openFolder
        super.init()
        alert.messageText = NSLocalizedString("Import Studies from Horos or OsiriX", comment: "")
        alert.informativeText = NSLocalizedString("The studies are imported into the database that is open. The earlier database is only read: nothing in it is changed. Albums, comments and states come with the studies.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Copy Files", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Copy Links", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "")).keyEquivalent = "\u{1b}"

        popup.target = self
        popup.action = #selector(folderChosen(_:))
        summary.preferredMaxLayoutWidth = Self.width
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        unlisted.target = self
        unlisted.action = #selector(unlistedChosen(_:))
        unlisted.isHidden = true
        access.bezelStyle = .rounded
        access.controlSize = .small
        access.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        access.sizeToFit()
        access.target = self
        access.action = #selector(allowAccess(_:))
        access.isHidden = true
        for view in [popup, summary, unlisted, access] as [NSView] { accessory.addSubview(view) }
        layOut()
        alert.accessoryView = accessory
        fillPopup()
    }

    /// The choice, what was read of the chosen folder and the files to
    /// import; nil when cancelled.
    func run() -> (Choice, Survey, [String])? {
        read()
        let response = alert.runModal()
        reading?.cancel()
        guard let survey, response != .alertThirdButtonReturn else { return nil }
        LegacyStudiesImport.log(survey, imported: chosenFiles(of: survey).count)
        return (response == .alertFirstButtonReturn ? .copy : .link, survey, chosenFiles(of: survey))
    }

    /// The files the database lists, and with the box checked the files of
    /// its folder it no longer lists.
    private func chosenFiles(of survey: Survey) -> [String] {
        survey.files.paths + (unlisted.state == .on ? survey.files.unlisted : [])
    }

    @objc private func unlistedChosen(_ sender: Any?) {
        if let survey { show(survey) }
    }

    /// Asks for each folder of the files that could not be read, one per
    /// disk, until one is refused, then reads the database again.
    @objc private func allowAccess(_ sender: Any?) {
        guard let survey else { return }
        var allowed = false
        for folder in LegacyDatabase.foldersHolding(survey.files.unreadLinked) {
            guard LegacyStudiesImport.allowAccess(toLinkedFolder: folder) else { break }
            allowed = true
        }
        if allowed { read() }
    }

    /// The popup at the top, the summary under it at the height of its text,
    /// then the box and the button that are shown. The alert is laid out
    /// again when the height changes while it is on screen.
    private func layOut() {
        let text = max(128, ceil(summary.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.width, height: 10_000)).height ?? 128))
        var y: CGFloat = 0
        if !access.isHidden {
            access.setFrameOrigin(NSPoint(x: 0, y: y))
            y += access.frame.height + 6
        }
        // The box keeps its place when hidden, as before it had a button under it.
        unlisted.frame = NSRect(x: 0, y: y, width: Self.width, height: 18)
        y += 26
        summary.frame = NSRect(x: 0, y: y, width: Self.width, height: text)
        y += text + 8
        popup.setFrameOrigin(NSPoint(x: 0, y: y))
        y += 26
        guard accessory.frame.height != y else { return }
        accessory.setFrameSize(NSSize(width: Self.width, height: y))
        if alert.window.isVisible { alert.layout() }
    }

    private func fillPopup() {
        popup.removeAllItems()
        for folder in folders {
            popup.addItem(withTitle: (folder.folder.path as NSString).abbreviatingWithTildeInPath)
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: NSLocalizedString("Choose Folder…", comment: ""))
        popup.selectItem(at: selected)
    }

    @objc private func folderChosen(_ sender: Any?) {
        if popup.indexOfSelectedItem >= folders.count {
            if let chosen = LegacyStudiesImport.chooseFolder(openFolder: openFolder) {
                selected = folders.firstIndex(of: chosen) ?? folders.count
                if selected == folders.count { folders.append(chosen) }
            }
            fillPopup()
        } else {
            selected = popup.indexOfSelectedItem
        }
        read()
    }

    private func setButtons(copy: Bool, link: Bool) {
        alert.buttons[0].isEnabled = copy
        alert.buttons[1].isEnabled = link
    }

    /// Reads the selected folder, the buttons off until it is read.
    private func read() {
        reading?.cancel()
        survey = nil
        setButtons(copy: false, link: false)
        unlisted.isHidden = true
        unlisted.state = .off
        access.isHidden = true
        summary.stringValue = NSLocalizedString("Reading the database…", comment: "")
        layOut()
        let database = folders[selected]
        reading = Task.detached(priority: .userInitiated) { [weak self] in
            guard let read = database.survey(isCancelled: { Task.isCancelled }), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.folders[self.selected] == database else { return }
                self.survey = read
                self.show(read)
            }
        }
    }

    /// The summary of what was read, for the files chosen now, and the
    /// buttons that can import them.
    private func show(_ read: Survey) {
        let files = chosenFiles(of: read).count
        let needed = read.files.bytes + (unlisted.state == .on ? read.files.unlistedBytes : 0)
        let free = LegacyDatabase.freeSpace(at: URL(fileURLWithPath: openFolder, isDirectory: true))
        var studies = NumberFormatter.localizedString(from: NSNumber(value: read.contents.studies.count), number: .decimal)
        var text = ""
        if let unread = LegacyStudiesImport.unreadText(read.listing) {
            // Nothing of the database came, when it could not be read at all.
            if case .unreadable = read.listing {
                studies = "—"
                text = unread + " " + NSLocalizedString("Albums, comments and states do not come with them.", comment: "") + "\n"
            } else {
                text = unread + "\n"
            }
        }
        text += String(format: NSLocalizedString("Studies: %@\nFiles: %@\nSpace needed to copy: %@\nFree space on the database disk: %@", comment: ""),
                       studies, NumberFormatter.localizedString(from: NSNumber(value: files), number: .decimal),
                       ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
                       free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
        if !read.files.unlisted.isEmpty {
            // Shown again whenever the box changes: the line says what the box asks for now.
            text += "\n" + LegacyStudiesImport.unlistedText(read.files, imported: unlisted.state == .on)
        }
        if !read.files.unreadLinked.isEmpty {
            text += "\n" + LegacyStudiesImport.unreadLinkedText(read.files)
        }
        let fits = free.map { $0 > needed } ?? true
        if files == 0 {
            // Said, where the buttons alone were left off.
            text += "\n" + NSLocalizedString("No file of this database was found to import.", comment: "")
        } else if !fits {
            text += "\n" + NSLocalizedString("There is not enough free space to copy these files.", comment: "")
        }
        summary.stringValue = text
        unlisted.isHidden = read.files.unlisted.isEmpty
        access.isHidden = read.files.unreadLinked.isEmpty
        layOut()
        setButtons(copy: fits && files > 0, link: files > 0)
    }
}
