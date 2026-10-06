#!/usr/bin/env python3
"""A portal user is made with the attributes it has and named only when that is safe.

- -awakeFromInsert set `dateAdded`, which the User entity does not have (its
  studies do). Core Data resolves an unknown key to the slot of another
  attribute: the read found the default of `address`, so the write was
  skipped, and without that default it wrote a date into `address`, which
  raised. The key is gone.
- -validateName:error: made an exception of a failed fetch but never raised
  it, so a name it could not check was accepted. The failure is now the
  "Internal database error." the method already answers for an exception.

-awakeFromInsert and -validateName:error: are taken as they are from
WebPortalUser.swift, with the helpers they use and the real
WebPortalUserLookup.swift, and compiled into a WebPortalUser whose primitive
accessors note the keys they are asked for. The User entity comes from the
WebPortalDB model, compiled with momc. A store that fails every fetch stands
for an unreadable WebUsers database; nothing touches the real one.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control (the model is read from the working tree).
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text()


def between(text, start, end, name):
    at = text.find(start)
    stop = text.find(end, at + len(start)) if at >= 0 else -1
    if at < 0 or stop < 0:
        print(f'FAIL: {name} is not where the test expects it')
        sys.exit(1)
    return text[at:stop + len(end)]


user = read('Horos/Sources/WebPortalUser.swift')
helpers = '\n'.join(between(user, signature, '\n}\n', signature) for signature in (
    'fileprivate func webPortalUserEntity(', 'fileprivate func webPortalUserCaught('))
awake = between(user, '    public override func awakeFromInsert() {', '\n    }\n', 'awakeFromInsert')
validate = between(user, '    @objc(validateName:error:)', '\n    }\n', 'validateName')

MAIN = r'''
import CoreData
import Foundation

extension NSError {
    class func osirixError(withCode code: Int, localizedDescription: String) -> NSError {
        NSError(domain: "OsiriXDomain", code: code, userInfo: [NSLocalizedDescriptionKey: localizedDescription])
    }
}
HELPERS

/// Notes every key its primitive accessors are asked for.
class NotingUser: NSManagedObject {
    static var keys = Set<String>()
    override func primitiveValue(forKey key: String) -> Any? {
        NotingUser.keys.insert(key)
        return super.primitiveValue(forKey: key)
    }
    override func setPrimitiveValue(_ value: Any?, forKey key: String) {
        NotingUser.keys.insert(key)
        super.setPrimitiveValue(value, forKey: key)
    }
}

@objc(WebPortalUser)
final class WebPortalUser: NotingUser {
    func generatePassword() {}
AWAKE
VALIDATE
}

/// A store every fetch of which fails, as an unreadable WebUsers database does.
final class FailingStore: NSIncrementalStore {
    override func loadMetadata() throws {
        metadata = [NSStoreTypeKey: NSStringFromClass(FailingStore.self), NSStoreUUIDKey: UUID().uuidString]
    }
    override func execute(_ request: NSPersistentStoreRequest, with context: NSManagedObjectContext?) throws -> Any {
        throw NSError(domain: "FailingStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "the store cannot be read"])
    }
}

let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let userEntity = model.entitiesByName["User"]!
print("User has dateAdded: \(userEntity.propertiesByName["dateAdded"] != nil)")

func context(_ model: NSManagedObjectModel, failing: Bool) -> NSManagedObjectContext {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    if failing {
        NSPersistentStoreCoordinator.registerStoreClass(FailingStore.self, forStoreType: NSStringFromClass(FailingStore.self))
        try! coordinator.addPersistentStore(ofType: NSStringFromClass(FailingStore.self), configurationName: nil,
                                            at: URL(fileURLWithPath: "/nonexistent/WebUsers.sql"), options: nil)
    } else {
        try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
    }
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return context
}

func insert(into context: NSManagedObjectContext) -> (WebPortalUser?, String?) {
    var made: WebPortalUser? = nil
    do {
        try HorosObjCException.perform {
            made = NSEntityDescription.insertNewObject(forEntityName: "User", into: context) as? WebPortalUser
        }
    } catch {
        return (nil, ((error as NSError).userInfo[HorosObjCExceptionKey] as? NSException)?.reason)
    }
    return (made, nil)
}

// The keys a new user's -awakeFromInsert touches, against the entity.
// The contexts are kept: a managed object does not keep its own.
let plain = context(model, failing: false)
let (inserted, insertRaised) = insert(into: plain)
print("insert raised: \(insertRaised ?? "nothing")")
let unknown = NotingUser.keys.subtracting(userEntity.propertiesByName.keys).sorted()
print("unknown keys: \(unknown.isEmpty ? "none" : unknown.joined(separator: ","))")
print("address of a new user: \(inserted?.value(forKey: "address") ?? "nil")")

// The same entity with no default for address, which the unknown key reads.
let bare = model.copy() as! NSManagedObjectModel
(bare.entitiesByName["User"]!.propertiesByName["address"] as! NSAttributeDescription).defaultValue = nil
let bareContext = context(bare, failing: false)
let (bareUser, raised) = insert(into: bareContext)
print("without a default address: \(raised.map { "raised \($0)" } ?? "address \(bareUser?.value(forKey: "address") ?? "nil")")")

func validate(_ user: WebPortalUser, _ name: String) -> String {
    var value: NSString? = name as NSString
    do {
        try user.validateName(&value)
        return "accepted"
    } catch {
        return "refused: \(error.localizedDescription)"
    }
}

// A name that cannot be checked is refused.
let failing = context(model, failing: true)
let (unreadable, _) = insert(into: failing)
print("name with an unreadable database: \(validate(unreadable!, "alice"))")

// A readable database still decides by the names it holds.
let readable = context(model, failing: false)
let alice = insert(into: readable).0!
alice.setPrimitiveValue("alice", forKey: "name")
let other = insert(into: readable).0!
print("own name: \(validate(alice, "alice"))")
print("taken name: \(validate(other, "alice"))")
print("free name: \(validate(other, "bob"))")
'''.replace('HELPERS', helpers).replace('AWAKE', awake).replace('VALIDATE', validate)

with tempfile.TemporaryDirectory(prefix='horos-portal-user-') as tmp:
    p = Path(tmp)
    subprocess.run(['xcrun', 'momc', str(root / 'Horos/Models/WebPortalDB.xcdatamodeld'), str(p / 'WebPortalDB.momd')],
                   check=True, capture_output=True)
    current = re.search(r'<string>(.*)\.xcdatamodel</string>',
                        (root / 'Horos/Models/WebPortalDB.xcdatamodeld/.xccurrentversion').read_text()).group(1)
    (p / 'bridging.h').write_text('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'HorosObjCException.o')], check=True)
    (p / 'main.swift').write_text(MAIN)
    build = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(p / 'bridging.h'),
                            '-Xcc', '-I' + str(root / 'Horos/Sources'), str(p / 'main.swift'),
                            str(root / 'Horos/Sources/WebPortalUserLookup.swift'),
                            str(p / 'HorosObjCException.o'), '-o', str(p / 'user')], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        print('FAIL: the user harness did not compile')
        sys.exit(1)
    run = subprocess.run([str(p / 'user'), str(p / 'WebPortalDB.momd' / f'{current}.mom')],
                         capture_output=True, text=True, timeout=120)
print(run.stdout.strip())
print(run.stderr.strip())


def value(key):
    found = re.search(rf'^{re.escape(key)}: (.*)$', run.stdout, re.M)
    return found.group(1) if found else None


failures = []
if run.returncode != 0:
    failures.append(f'the harness ended with {run.returncode}: {run.stderr[-500:]}')
checks = [
    ('User has dateAdded', 'false', 'the User entity is expected to have no dateAdded'),
    ('insert raised', 'nothing', 'inserting a user raised'),
    ('unknown keys', 'none', '-awakeFromInsert touches keys the User entity does not have'),
    ('without a default address', 'address nil', 'the unknown key writes into another attribute'),
    ('name with an unreadable database', 'refused: Internal database error.',
     'a name the database could not check was accepted'),
    ('own name', 'accepted', 'a user\'s own name is refused'),
    ('taken name', 'refused: A user with that name already exists. Two users cannot have the same name.',
     'a taken name is accepted'),
    ('free name', 'accepted', 'a free name is refused'),
]
for key, expected, message in checks:
    found = value(key)
    if found != expected:
        failures.append(f'{message} ({key}: {found})')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: a new user touches only its own attributes; a name is refused when the database cannot check it')
