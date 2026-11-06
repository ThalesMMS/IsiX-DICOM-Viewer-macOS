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

        let dialog = LegacyImportDialog(folders: folders, openFolder: openFolder)
        guard let (choice, survey) = dialog.run() else { return }
        prepareNotes(survey.contents, in: database)
        browser.droppedFiles.importFiles(survey.files.paths, options: [
            "COPYDATABASE": NSNumber(value: choice == .copy),
            "COPYDATABASEMODE": NSNumber(value: DatabaseCopyRule.always),
            "async": NSNumber(value: true),
        ])
    }

    /// What the command does without its dialog, for scripts and checks: reads
    /// the data folder at `path` and starts the import, copying or not. The
    /// number of files handed to the import, -1 when the folder holds no such
    /// database or the database shown cannot take them.
    func importFolder(atPath path: String, copying: Bool, into browser: BrowserController) -> Int {
        guard Self.canImport(into: browser), let database = browser.database,
              let legacy = LegacyDatabase.resolving(URL(fileURLWithPath: path, isDirectory: true)),
              !Self.isSame(legacy, as: database.dataDirPath() ?? ""),
              let contents = try? legacy.contents(), let files = legacy.files(linked: contents.linkedFiles) else { return -1 }
        prepareNotes(contents, in: database)
        browser.droppedFiles.importFiles(files.paths, options: [
            "COPYDATABASE": NSNumber(value: copying),
            "COPYDATABASEMODE": NSNumber(value: DatabaseCopyRule.always),
            "async": NSNumber(value: true),
        ])
        return files.paths.count
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
        guard panel.runModal() == .OK, let url = panel.url, SandboxFileAccess.remember(url) else { return nil }
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

    struct Survey: Sendable {
        let database: LegacyDatabase
        let contents: LegacyDatabase.Contents
        let files: LegacyDatabase.Files
    }

    private let alert = NSAlert()
    private let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 26), pullsDown: false)
    private let summary = NSTextField(wrappingLabelWithString: "")
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
        summary.frame = NSRect(x: 0, y: 0, width: 440, height: 72)
        summary.preferredMaxLayoutWidth = 440
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 106))
        popup.setFrameOrigin(NSPoint(x: 0, y: 80))
        accessory.addSubview(popup)
        accessory.addSubview(summary)
        alert.accessoryView = accessory
        fillPopup()
    }

    /// The choice and what was read of the chosen folder; nil when cancelled.
    func run() -> (Choice, Survey)? {
        read()
        let response = alert.runModal()
        reading?.cancel()
        guard let survey, response != .alertThirdButtonReturn else { return nil }
        return (response == .alertFirstButtonReturn ? .copy : .link, survey)
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
        summary.stringValue = NSLocalizedString("Reading the database…", comment: "")
        let database = folders[selected]
        reading = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<Survey, LegacyDatabase.Failure>
            do {
                let contents = try database.contents()
                guard let files = database.files(linked: contents.linkedFiles, isCancelled: { Task.isCancelled }) else { return }
                outcome = .success(Survey(database: database, contents: contents, files: files))
            } catch let failure as LegacyDatabase.Failure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(LegacyDatabase.Failure(description: error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.show(outcome, of: database) }
        }
    }

    private func show(_ outcome: Result<Survey, LegacyDatabase.Failure>, of database: LegacyDatabase) {
        guard folders[selected] == database else { return }
        switch outcome {
        case .failure(let failure):
            summary.stringValue = String(format: NSLocalizedString("This database could not be read: %@", comment: ""), failure.description)
        case .success(let read):
            let free = LegacyDatabase.freeSpace(at: URL(fileURLWithPath: openFolder, isDirectory: true))
            let bytes = ByteCountFormatter.string(fromByteCount: read.files.bytes, countStyle: .file)
            var text = String(format: NSLocalizedString("Studies: %@\nFiles: %@\nSpace needed to copy: %@\nFree space on the database disk: %@", comment: ""),
                              NumberFormatter.localizedString(from: NSNumber(value: read.contents.studies.count), number: .decimal),
                              NumberFormatter.localizedString(from: NSNumber(value: read.files.paths.count), number: .decimal),
                              bytes, free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
            let fits = free.map { $0 > read.files.bytes } ?? true
            if !fits {
                text += "\n" + NSLocalizedString("There is not enough free space to copy these files.", comment: "")
            }
            summary.stringValue = text
            guard !read.files.paths.isEmpty else { return }
            survey = read
            setButtons(copy: fits, link: true)
        }
    }
}
