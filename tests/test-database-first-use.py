#!/usr/bin/env python3
"""First-use eligibility must never redirect configured or existing databases.

A `Horos Data` folder is Horos's database, not an installation of this
application: by itself it no longer skips first use, which then says the Horos
database was left alone and how to import its studies. One this installation
adopted still counts as its own. Choosing a Horos database asks first, and each
answer does what it says: import its studies without opening it, open it and
adopt it, or nothing.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
main=r'''
import AppKit
// The application's browser, which the choice hands an import to.
final class BrowserController: NSObject {
 static func currentBrowser() -> BrowserController? { nil }
 func subSelectFilesAndFolders(toAdd: [Any]!) {}
}
let name="horos-first-use-test-\(UUID().uuidString)"
let defaults=UserDefaults(suiteName:name)!
defer {defaults.removePersistentDomain(forName:name)}
let documents=URL(fileURLWithPath:CommandLine.arguments[1])
assert(DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents))
for key in ["DATABASELOCATION","DEFAULT_DATABASELOCATION","DATABASELOCATIONURL","DEFAULT_DATABASELOCATIONURL"] {
 defaults.setVolatileDomain([key:0],forName:UserDefaults.argumentDomain)
 assert(!DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents))
}
defaults.setVolatileDomain([:],forName:UserDefaults.argumentDomain)
defaults.set(1,forKey:"DEFAULT_DATABASELOCATION")
assert(!DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents))
defaults.set(0,forKey:"DEFAULT_DATABASELOCATION")
defaults.set(true,forKey:DatabaseFirstUse.completedKey)
assert(!DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents))
defaults.set(false,forKey:DatabaseFirstUse.completedKey)
for name in ["IsiX Data","IsiX DICOM Viewer Data","Isis DICOM Viewer Data"] {
 let folder=documents.appendingPathComponent(name)
 try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 assert(!DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents),name)
 try FileManager.default.removeItem(at:folder)
 assert(DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents),name)
}
// Horos's database alone is not an installation of this application...
let horos=documents.appendingPathComponent("Horos Data")
try FileManager.default.createDirectory(at:horos,withIntermediateDirectories:true)
assert(DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents),"Horos Data alone")
// ...unless this installation adopted it.
DatabaseLocation.adoptHorosDirectory(horos.path,defaults:defaults)
assert(!DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents),"adopted Horos Data")
defaults.removeObject(forKey:DatabaseLocation.adoptedHorosDirectoriesKey)
defaults.set(true,forKey:DatabaseFirstUse.pendingKey)
assert(DatabaseFirstUse.needsChoice(defaults:defaults,documents:documents))
defaults.set(false,forKey:DatabaseFirstUse.pendingKey)

// Where first use finds a Horos database: where Horos's preferences put it, or
// in Documents.
let elsewhere=documents.deletingLastPathComponent().appendingPathComponent("Studies")
try FileManager.default.createDirectory(at:elsewhere.appendingPathComponent("Horos Data"),withIntermediateDirectories:true)
let own=documents.deletingLastPathComponent().appendingPathComponent("Own")
try FileManager.default.createDirectory(at:own.appendingPathComponent("IsiX Data"),withIntermediateDirectories:true)
let horosPrefs:[String:Any]=["DEFAULT_DATABASELOCATION":1,"DEFAULT_DATABASELOCATIONURL":elsewhere.path]
assert(DatabaseFirstUse.horosDatabase(horosPreferences:horosPrefs,documents:documents)==elsewhere.appendingPathComponent("Horos Data").path)
assert(DatabaseFirstUse.horosDatabase(horosPreferences:nil,documents:documents)==horos.path)
assert(DatabaseFirstUse.horosDatabase(horosPreferences:["DEFAULT_DATABASELOCATION":0],documents:documents)==horos.path)
assert(DatabaseFirstUse.horosDatabase(horosPreferences:["DEFAULT_DATABASELOCATION":1,"DEFAULT_DATABASELOCATIONURL":own.path],documents:documents)==horos.path)
// Beside a database of this application, and named directly.
try FileManager.default.createDirectory(at:elsewhere.appendingPathComponent("IsiX Data"),withIntermediateDirectories:true)
assert(DatabaseFirstUse.horosDatabase(horosPreferences:horosPrefs,documents:documents)==elsewhere.appendingPathComponent("Horos Data").path)
assert(DatabaseFirstUse.horosDatabase(horosPreferences:["DEFAULT_DATABASELOCATION":1,"DEFAULT_DATABASELOCATIONURL":elsewhere.appendingPathComponent("Horos Data/Database.sql").path],documents:documents)==elsewhere.appendingPathComponent("Horos Data").path)
let empty=documents.deletingLastPathComponent().appendingPathComponent("Empty Documents")
assert(DatabaseFirstUse.horosDatabase(horosPreferences:nil,documents:empty)==nil)
// The explanation says it was left alone and how to import, only when there is one.
let plain=DatabaseFirstUse.explanation(documents:documents,horosDatabase:nil)
let told=DatabaseFirstUse.explanation(documents:documents,horosDatabase:horos.path)
assert(!plain.contains("Horos") && plain.contains(documents.path))
assert(told.hasPrefix(plain) && told.contains(horos.path) && told.contains("not opened or changed") && told.contains("File > Import > Import Files...") && told.contains("DATABASE.noindex"))

// Each answer to the question about a Horos database does what it says.
MainActor.assumeIsolated {
var imported:[String]=[]
assert(!ForeignDatabaseChoice.apply(.importStudies,horosDirectory:horos.path,defaults:defaults,startImport:{imported.append($0)}))
assert(imported==[horos.appendingPathComponent("DATABASE.noindex").path])
assert(DatabaseLocation.adoptedHorosDirectories(defaults).isEmpty,"importing adopts nothing")
assert(!ForeignDatabaseChoice.apply(.cancel,horosDirectory:horos.path,defaults:defaults,startImport:{imported.append($0)}))
assert(imported.count==1 && DatabaseLocation.adoptedHorosDirectories(defaults).isEmpty,"cancelling does nothing")
assert(ForeignDatabaseChoice.apply(.open,horosDirectory:horos.path,defaults:defaults,startImport:{imported.append($0)}))
assert(imported.count==1 && DatabaseLocation.isAdopted(horos.path,in:DatabaseLocation.adoptedHorosDirectories(defaults)),"opening adopts it")
assert(DatabaseLocation.horosDataDirectory(forChosenPath:documents.path,adopted:DatabaseLocation.adoptedHorosDirectories(defaults))==nil,"an adopted one is not asked about again")
}
print("PASS: fresh install prompts, also beside a Horos database it explains and leaves alone; configured, explicit, existing and adopted locations preserved; each answer about a Horos database does what it says")
'''
with tempfile.TemporaryDirectory(prefix='horos-first-use-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text(main)
 sources=['CloudFileAccess.swift','DatabaseLocation.swift','PreferencesContinuity.swift','ForeignDatabaseChoice.swift','DatabaseFirstUse.swift']
 subprocess.run(['xcrun','--sdk','macosx','swiftc',*[str(root/'Horos/Sources'/s) for s in sources],str(p/'main.swift'),'-o',str(p/'test')],check=True,timeout=300)
 subprocess.run([str(p/'test'),str(p/'Documents')],check=True,timeout=120)
