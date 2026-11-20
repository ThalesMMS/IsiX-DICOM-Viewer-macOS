#!/usr/bin/env python3
"""Which selectors a plugin SDK's headers declare that the application does not answer.

A plugin built with the headers of an SDK sends the application what those
headers declare. One the application's classes do not answer raises
«unrecognized selector» in the middle of the plugin's work, and the plugin's
author sees one such selector at a time. This tool asks about all of them at
once.

It reads a folder of text headers for names only (the classes, the methods and
the properties, with getter=, setter= and readonly), and asks the Objective-C
runtime of the running application, not its sources, whether each class
answers each selector: a class answers what it inherits, what a category adds
and what Core Data generates for its entity, and none of that is in one source
file. The runtime is asked from inside the application, by a small plugin of
the former SDK the tool builds and the development copy loads.

  declared --headers DIR --out declared.json
      the selectors the headers declare, by class
  ask --declared declared.json --out answers.json [--work DIR] [--database DIR]
      starts the development copy on the test database with the plugin, waits
      for its answers and ends the copy; the preferences of the development
      copy are saved before and put back after
  report --declared declared.json --answers answers.json [--classes A,B] [--list] [--json FILE]
      per class: declared, unanswered; with --list, each unanswered selector
  table --headers DIR --declared declared.json --answers answers.json [--classes A,B] [--skip FILE] [--answered FILE] [--table FILE]
      adds to the table the application reads when it starts
      (Horos/Resources/LaterPluginSDKAnswers.json) an answer for every
      unanswered selector of the classes (all of them when none is given)
      that FILE does not list ("Class -selector" per line, those answered by
      hand in the sources). A property a plugin can set, neither accessor
      answered, is kept with the object and read back; anything else answers
      nil, zero or nothing and says so in the log once. Nothing leaves the
      table. The selectors of --answered, in the same form, are those the
      sources add to a class themselves when the application starts: the
      table takes their types alone, under "answered". Prints what it added:
      the entries of the registry, each with the header that declares it,
      which of them are kept, and their types.
  types --headers DIR --declared declared.json --answers answers.json [--classes A,B] [--list]
      the selectors the application answers with other argument or return
      types than the headers declare: a method that reads its caller's
      registers as another type gives or takes a wrong value without raising
  encodings --headers DIR --entries entries.json --out types.json
      the type encoding the Objective-C compiler gives each "Class -selector"
      of entries.json for the declaration of the headers, on arm64 and
      without the frame offsets: what the method that answers must have

Nothing of the headers is written out but the names of classes and selectors
and the header and line each comes from.
"""
import argparse
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

DOMAIN = "thalesmms.isis.workstation.local-development"

# The plugin that answers. It waits for the database window, so that Core Data
# has generated the accessors of the entities, and asks each class of the list.
PLUGIN_SOURCE = r"""
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>

@interface PluginFilter : NSObject
- (void)initPlugin;
- (long)filterImage:(NSString *)menuName;
@end
@interface IsiXSelectorSweep : PluginFilter
@end
@interface NSObject (IsiXSelectorSweepHost)
+ (id)activeLocalDatabase;
+ (id)defaultWebPortal;
- (id)database;
@end

@implementation IsiXSelectorSweep
- (void)answer {
    const char *declaredPath = getenv("ISIX_SELECTOR_SWEEP_DECLARED"), *answersPath = getenv("ISIX_SELECTOR_SWEEP_ANSWERS");
    if (!declaredPath || !answersPath) return;
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:declaredPath]];
    NSDictionary *declared = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableDictionary *answers = [NSMutableDictionary dictionary];
    // The entities of the two models of the application, by the class of their objects.
    NSMutableDictionary *entities = [NSMutableDictionary dictionary];
    NSMutableArray *models = [NSMutableArray array];
    @try {
        id database = [NSClassFromString(@"DicomDatabase") performSelector:@selector(activeLocalDatabase)];
        id model = [database performSelector:@selector(managedObjectModel)];
        if (model) [models addObject:model];
        id portal = [NSClassFromString(@"WebPortal") performSelector:@selector(defaultWebPortal)];
        model = [[portal performSelector:@selector(database)] performSelector:@selector(managedObjectModel)];
        if (model) [models addObject:model];
    } @catch (id exception) {}
    for (NSManagedObjectModel *model in models)
        for (NSEntityDescription *entity in [model entities])
            if ([entity managedObjectClassName]) entities[[entity managedObjectClassName]] = entity;
    for (NSString *name in declared) {
        Class cls = NSClassFromString(name);
        if (!cls) { answers[name] = @{@"absent": @YES}; continue; }
        NSMutableArray *instance = [NSMutableArray array], *classMethods = [NSMutableArray array], *chain = [NSMutableArray array];
        // The accessors of an entity's attributes and relationships are in a
        // subclass Core Data makes for the entity, which an object has and
        // the class does not: an object of the entity, in no context, answers.
        Class asked = cls;
        id object = nil;
        if ([cls isSubclassOfClass:[NSManagedObject class]] && cls != [NSManagedObject class]) {
            @try {
                NSEntityDescription *entity = entities[name];
                if (entity) object = [[cls alloc] initWithEntity:entity insertIntoManagedObjectContext:nil];
                if (object) asked = object_getClass(object);
            } @catch (id exception) {}
        }
        NSMutableDictionary *types = [NSMutableDictionary dictionary];
        for (NSString *selector in declared[name][@"instance"]) {
            Method method = class_getInstanceMethod(asked, NSSelectorFromString(selector));
            if (![asked instancesRespondToSelector:NSSelectorFromString(selector)]) [instance addObject:selector];
            else if (method && method_getTypeEncoding(method)) types[[@"-" stringByAppendingString:selector]] = @(method_getTypeEncoding(method));
        }
        [object release];
        for (NSString *selector in declared[name][@"class"]) {
            Method method = class_getClassMethod(cls, NSSelectorFromString(selector));
            if (![cls respondsToSelector:NSSelectorFromString(selector)]) [classMethods addObject:selector];
            else if (method && method_getTypeEncoding(method)) types[[@"+" stringByAppendingString:selector]] = @(method_getTypeEncoding(method));
        }
        for (Class up = class_getSuperclass(cls); up; up = class_getSuperclass(up)) [chain addObject:NSStringFromClass(up)];
        answers[name] = @{@"instance": instance, @"class": classMethods, @"superclasses": chain,
                          @"asked": NSStringFromClass(asked), @"types": types};
    }
    NSData *written = [NSJSONSerialization dataWithJSONObject:answers options:NSJSONWritingSortedKeys error:NULL];
    [written writeToFile:[NSString stringWithUTF8String:answersPath] atomically:YES];
}
- (void)initPlugin {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self answer]; });
}
- (long)filterImage:(NSString *)menuName { return 0; }
@end
"""

INFO_PLIST = {
    "CFBundleExecutable": "IsiXSelectorSweep", "CFBundleIdentifier": "isix.selector-sweep",
    "CFBundleName": "IsiXSelectorSweep", "CFBundlePackageType": "BNDL", "CFBundleVersion": "1",
    "NSPrincipalClass": "IsiXSelectorSweep", "pluginType": "Database", "MenuTitles": ["Selector Sweep"],
}


def inventory():
    spec = importlib.util.spec_from_file_location("inventory_plugin_api", ROOT / "tools/inventory-plugin-api.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["inventory_plugin_api"] = module
    spec.loader.exec_module(module)
    return module


def declared_selectors(headers):
    """{class: {super, header, instance: {selector: [header, line]}, class: {...}}} of the headers in the folder."""
    sdk = inventory().load_sdk([headers])
    declared = {}
    for name, info in sorted(sdk.classes.items()):
        sides = {"instance": {}, "class": {}}
        for selector, method in sorted(info["methods"].items()):
            sides["class" if method["class_method"] else "instance"][selector] = [method["header"], method["line"]]
        if sides["instance"] or sides["class"]:
            declared[name] = {"super": info["super"], "header": info["header"], **sides}
    return declared


# ---------------------------------------------------------------- the answers of what has no feature behind it

SCALARS = {
    "BOOL": "Bool", "bool": "Bool", "char": "CChar", "unsigned char": "UInt8", "short": "Int16", "unsigned short": "UInt16",
    "int": "Int32", "unsigned": "UInt32", "unsigned int": "UInt32", "long": "Int", "unsigned long": "UInt",
    "long long": "Int64", "unsigned long long": "UInt64", "float": "Float", "double": "Double", "CGFloat": "CGFloat",
    "NSInteger": "Int", "NSUInteger": "UInt", "NSTimeInterval": "TimeInterval", "int32_t": "Int32", "uint32_t": "UInt32",
    "int64_t": "Int64", "uint64_t": "UInt64", "int16_t": "Int16", "uint16_t": "UInt16", "unichar": "unichar",
    "GLuint": "UInt32", "GLint": "Int32", "GLfloat": "Float", "OSType": "UInt32", "vImagePixelCount": "UInt",
}
STRUCTS = {"NSPoint": "NSPoint", "NSRect": "NSRect", "NSSize": "NSSize", "NSRange": "NSRange", "CGPoint": "CGPoint",
           "CGRect": "CGRect", "CGSize": "CGSize"}
# The return types the application has a neutral answer for, and the types of
# a property it keeps: those of LaterPluginSDKAnswers.swift.
STRUCT_ENCODINGS = ("{CGPoint=dd}", "{CGSize=dd}", "{CGRect={CGPoint=dd}{CGSize=dd}}")
NEUTRAL_RETURNS = set("v@#:*^BcCsSiIlLqQfd") | set(STRUCT_ENCODINGS) | {"{_NSRange=QQ}"}
KEPT_TYPES = set("@BcCsSiIqlQLfd^*") | set(STRUCT_ENCODINGS)


def first_type(types):
    """The first type of a method's type encoding, without its qualifiers: its return type."""
    types = types.lstrip("rnNoORV")
    if types[:1] in "{(":
        close, depth = {"{": "}", "(": ")"}[types[0]], 0
        for index, character in enumerate(types):
            depth += (character == types[0]) - (character == close)
            if depth == 0:
                return types[:index + 1]
        return types
    return types[:1]


def argument_type(setter_types):
    """The type of a setter's argument: what follows the receiver and the selector."""
    return first_type(setter_types.partition("@:")[2])


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def clean_type(text):
    text = re.sub(r"\b(__\w+|_Nonnull|_Nullable|_Null_unspecified|nullable|nonnull|oneway|inout|IBOutlet|in|out|bycopy|byref)\b",
                  " ", " " + text + " ")
    text = re.sub(r"<[^<>]*(?:<[^<>]*>[^<>]*)*>", "", text)         # generics and protocols
    return re.sub(r"\s*\*\s*", "*", re.sub(r"\s+", " ", text).strip())


def declarations(headers):
    """{(class, sign, selector): {ret, args: [type...], property, readonly}} with the types the headers give."""
    found, enums, classes = {}, {}, set()
    for path in sorted(Path(headers).glob("*.h")):
        code = strip_comments(path.read_text(errors="replace"))
        # A C enumeration is an unsigned int, or an int when one of its values is negative.
        for body, name in re.findall(r"typedef\s+enum\b[^{;]*\{([^}]*)\}\s*(\w+)\s*;", code):
            enums[name] = "int" if re.search(r"=\s*-", body) else "unsigned int"
        for underlying, name in re.findall(r"typedef\s+NS_(?:ENUM|OPTIONS)\s*\(\s*([\w ]+?)\s*,\s*(\w+)\s*\)", code):
            enums[name] = underlying
        classes |= set(re.findall(r"@interface\s+([A-Za-z_]\w*)", code))
        for names in re.findall(r"@class\s+([^;]+);", code):
            classes |= set(re.findall(r"[A-Za-z_]\w*", names))
        for block in re.finditer(r"@interface\s+([A-Za-z_]\w*)", code):
            end = code.find("@end", block.start())
            body = code[block.end():end if end > 0 else len(code)]
            name = block.group(1)
            opening = re.match(r"[^{@;]*?\{", body)
            if opening and not re.match(r"\s*(?:<[^>]*>)?\s*\(", body):
                depth, index = 1, opening.end()
                while index < len(body) and depth:
                    depth += {"{": 1, "}": -1}.get(body[index], 0)
                    index += 1
                body = body[index:]
            for prop in re.finditer(r"@property\s*(\([^)]*\))?\s*([^;]+);", body):
                attrs = prop.group(1) or ""
                text = re.sub(r"\b(DEPRECATED_ATTRIBUTE|__deprecated|NS_UNAVAILABLE|IBOutlet)\b", " ", prop.group(2))
                parts = [part.strip() for part in text.split(",")]
                first = re.search(r"([A-Za-z_]\w*)\s*$", parts[0])
                if not first:
                    continue
                base = parts[0][:first.start()].strip()
                root = re.sub(r"[\s\*]+$", "", base)
                each = [(first.group(1), base)]
                for part in parts[1:]:
                    more = re.search(r"([A-Za-z_]\w*)\s*$", part)
                    if more:
                        each.append((more.group(1), root + (" *" if "*" in part else "")))
                getter, setter = re.search(r"getter\s*=\s*(\w+)", attrs), re.search(r"setter\s*=\s*(\w+:)", attrs)
                sign = "+" if re.search(r"\bclass\b", attrs) else "-"
                readonly = "readonly" in attrs
                for prop_name, prop_type in each:
                    prop_type = clean_type(prop_type)
                    get = getter.group(1) if getter and len(each) == 1 else prop_name
                    found[(name, sign, get)] = {"ret": prop_type, "args": [], "property": prop_name, "readonly": readonly}
                    if not readonly:
                        put = setter.group(1) if setter and len(each) == 1 else "set" + prop_name[:1].upper() + prop_name[1:] + ":"
                        found[(name, sign, put)] = {"ret": "void", "args": [prop_type], "property": prop_name, "readonly": False}
            for method in re.finditer(r"(?m)^\s*([-+])\s*\(((?:[^()]|\([^()]*\))*)\)\s*([^;{]+?)\s*[;{]", body):
                rest = method.group(3)
                pieces = list(re.finditer(r"([A-Za-z_]\w*)?\s*:\s*(?:\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\))?\s*([A-Za-z_]\w*)?", rest))
                selector = "".join((piece.group(1) or "") + ":" for piece in pieces) if pieces else (rest.split() or [""])[0]
                if selector:
                    found.setdefault((name, method.group(1), selector), {
                        "ret": clean_type(method.group(2)), "args": [clean_type(piece.group(2) or "id") for piece in pieces],
                        "property": None, "readonly": False, "variadic": "..." in rest})
    return found, enums, classes


def answers_of(cls, wanted, found, encodings):
    """What the table gives `cls` for `wanted` ({(sign, selector)}): the kept properties, [name, sign, getter,
    its types, setter, its types]; the neutral answers, {"-selector": types}; and those it cannot give, with why."""
    kept, neutral, refused = [], {}, []
    # A property is kept when neither its getter nor its setter is answered:
    # one of them answered is the application's own, and what the other kept
    # would never be what the application's reads or writes.
    accessors = {}
    for sign, selector in wanted:
        info = found.get((cls, sign, selector))
        if info and info["property"]:
            accessors.setdefault((sign, info["property"]), {})[bool(info["args"])] = selector
    paired = set()
    for (sign, name), sides in sorted(accessors.items()):
        if set(sides) != {True, False}:
            continue
        getter, setter = sides[False], sides[True]
        get_types, set_types = (encodings.get("%s %s%s" % (cls, sign, selector)) for selector in (getter, setter))
        if get_types and set_types and first_type(get_types) in KEPT_TYPES and argument_type(set_types) == first_type(get_types):
            kept.append([name, sign, getter, get_types, setter, set_types])
            paired |= {(sign, getter), (sign, setter)}
    for sign, selector in sorted(wanted - paired, key=lambda item: (item[1].lower(), item[0])):
        types = encodings.get("%s %s%s" % (cls, sign, selector))
        if not types:
            refused.append((sign, selector, "no declaration the compiler takes"))
        elif first_type(types) not in NEUTRAL_RETURNS:
            refused.append((sign, selector, "answers a %s, which has no neutral answer" % first_type(types)))
        else:
            neutral[sign + selector] = types
    return kept, neutral, refused


def type_encodings(headers, entries, work):
    """{entry: encoding} of "Class -selector" entries: the type encoding the Objective-C compiler gives the
    declaration of the headers on arm64, without the frame offsets; None for one it cannot declare."""
    found, enums, classes = declarations(headers)
    by_class, lost = {}, {}
    for entry in entries:
        cls, rest = entry.split(" ", 1)
        info = found.get((cls, rest[0], rest[1:]))
        if info is None or info.get("variadic"):
            lost[entry] = None
        else:
            by_class.setdefault(cls, []).append((entry, rest[0], rest[1:], info))
    used = " ".join(text for methods in by_class.values() for _, _, _, info in methods for text in [info["ret"]] + info["args"])
    words = set(re.findall(r"[A-Za-z_]\w*", used))
    lines = ["#import <Cocoa/Cocoa.h>", "#import <objc/runtime.h>", "#import <compression.h>", "#import <stdio.h>"]
    lines += ["typedef %s %s;" % (underlying, name) for name, underlying in sorted(enums.items()) if name in words]
    # The classes the declarations name: those of the headers, and those of frameworks this program does not import.
    pointed = set(re.findall(r"\b((?:NS|CI|CN|VN|WK|AV|PDF|CA|UN)[A-Z]\w*)\s*\*", used)) - set(SCALARS) - set(STRUCTS)
    lines += ["@class %s;" % name for name in sorted((words & classes) | pointed) if name not in enums]
    for index, (cls, methods) in enumerate(sorted(by_class.items())):
        lines.append("@protocol IsiXSweep%d" % index)
        for _, sign, selector, info in methods:
            parts = selector.split(":")
            ret = "void" if info["ret"] == "IBAction" else info["ret"]
            if info["args"]:
                body = " ".join("%s:(%s)a%d" % (part, arg, position) for position, (part, arg) in enumerate(zip(parts, info["args"])))
            else:
                body = selector
            lines.append("%s (%s)%s;" % (sign, ret, body))
        lines.append("@end")
    lines.append("int main(void) {")
    for index, (cls, methods) in enumerate(sorted(by_class.items())):
        for position, (entry, sign, selector, _) in enumerate(methods):
            lines.append('    printf("%%s\\t%%s\\n", "%s", protocol_getMethodDescription(@protocol(IsiXSweep%d), @selector(%s), YES, %s).types ?: "");'
                         % (entry, index, selector, "YES" if sign == "-" else "NO"))
    lines += ["    return 0;", "}"]
    work.mkdir(parents=True, exist_ok=True)
    source, program = work / "encodings.m", work / "encodings"
    source.write_text("\n".join(lines) + "\n")
    command = ["xcrun", "clang", "-fno-objc-arc", "-arch", "arm64", "-Wno-everything", "-ferror-limit=0", "-framework", "Cocoa",
               str(source), "-o", str(program)]
    built = subprocess.run(command, capture_output=True, text=True)
    for _ in range(8):
        if not built.returncode:
            break
        # A declaration that names a type plain Objective-C cannot declare (a C++ class, a structure of
        # another library) is left out, with its line of main(), and answers None.
        refused = {int(number) for number in re.findall(r"encodings\.m:(\d+):\d+: error", built.stderr)}
        # A name this program declared as a class that the system declares as another kind of type.
        forward = {lines[number - 1] for number in refused if number <= len(lines) and lines[number - 1].startswith("@class ")}
        dropped = {lines[number - 1] for number in refused if number <= len(lines) and re.match(r"[-+] \(", lines[number - 1])}
        if not dropped and not forward:
            sys.exit("the declarations do not compile:\n" + built.stderr[-3000:])
        lines = [line for line in lines if line not in forward]
        selectors = {re.sub(r"\([^()]*(?:\([^()]*\)[^()]*)*\)|\ba\d+\b|[-+ ;]", "", line) for line in dropped}
        lines = [line for line in lines if line not in dropped
                 and not (line.startswith("    printf") and re.search(r"@selector\(([^)]*)\)", line).group(1) in selectors)]
        source.write_text("\n".join(lines) + "\n")
        built = subprocess.run(command, capture_output=True, text=True)
    if built.returncode:
        sys.exit("the declarations do not compile:\n" + built.stderr[-3000:])
    answers = dict(lost)
    answers.update({entry: None for entry in entries if entry not in answers})
    for line in subprocess.run([str(program)], capture_output=True, text=True, check=True).stdout.splitlines():
        entry, _, encoding = line.partition("\t")
        answers[entry] = re.sub(r"\[\d+|\d+", lambda digits: digits.group(0) if digits.group(0).startswith("[") else "", encoding) or None
    return answers


TABLE_ABOUT = ("The selectors that only later headers of the plugin SDK declare and the application has no method for, by "
               "class, each with the type encoding the Objective-C compiler gives the declaration of those headers. kept: the "
               "properties a plugin can set, [name, - or + for a class property, getter, its types, setter, its types], which "
               "the application keeps with the object and reads back. neutral: the selectors of features the application "
               "does not have, which answer nil, zero or nothing. answered: the selectors of the viewer and of its view that "
               "the application has something behind, which LaterPluginSDKViewerAnswers adds with these types. "
               "LaterPluginSDKAnswers adds each to its class when the application starts; "
               "tools/plugin-sdk-selector-sweep.py table writes this file.")


def build_plugin(work):
    bundle = work / "IsiXSelectorSweep.osirixplugin"
    subprocess.run(["rm", "-rf", str(bundle)], check=True)
    (bundle / "Contents/MacOS").mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(INFO_PLIST))
    source = work / "IsiXSelectorSweep.m"
    source.write_text(PLUGIN_SOURCE)
    subprocess.run(["xcrun", "clang", "-fno-objc-arc", "-bundle", "-undefined", "dynamic_lookup", "-arch", "arm64",
                    "-mmacosx-version-min=15.0", "-framework", "Cocoa", str(source),
                    "-o", str(bundle / "Contents/MacOS/IsiXSelectorSweep")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)
    return bundle


def ask(declared_path, answers_path, work, database, extra_plugins=(), environment=None, wait=90):
    """Runs the development copy with the plugin and returns once the answers are written.

    A copy started without its database arguments opens the default database
    of the user: the preferences of the development copy name the test
    database for as long as it runs, and are put back as they were.
    """
    import native_app
    if native_app.running_development_pids(native_app.DEVELOPMENT_APP):
        sys.exit("a development instance is running")
    outdated = native_app.outdated_bundle()
    if outdated:
        sys.exit(outdated)
    work.mkdir(parents=True, exist_ok=True)
    bundle = build_plugin(work)
    answers_path.unlink(missing_ok=True)
    backup = work / "development-preferences.plist"
    subprocess.run(["defaults", "export", DOMAIN, str(backup)], check=True)
    saved = plistlib.loads(backup.read_bytes())
    try:
        for key in ("DATABASELOCATION", "DEFAULT_DATABASELOCATION"):
            subprocess.run(["defaults", "write", DOMAIN, key, "-int", "1"], check=True)
        for key in ("DATABASELOCATIONURL", "DEFAULT_DATABASELOCATIONURL"):
            subprocess.run(["defaults", "write", DOMAIN, key, "-string", str(database)], check=True)
        arguments = ["--LoadPlugin", str(bundle)]
        for plugin in extra_plugins:
            arguments += ["--LoadPlugin", str(plugin)]
        process = native_app.launch(database, work / "app.log", arguments,
                                    environment=dict(environment or {}, ISIX_SELECTOR_SWEEP_DECLARED=str(declared_path),
                                                     ISIX_SELECTOR_SWEEP_ANSWERS=str(answers_path)))
        deadline = time.monotonic() + wait
        while not answers_path.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.5)
        ended = process.poll()
        native_app.stop(process)
        native_app.stop_all(native_app.DEVELOPMENT_APP)
    finally:
        if saved:
            subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
            subprocess.run(["defaults", "import", DOMAIN, str(backup)], check=True)
    if not answers_path.exists():
        sys.exit(f"the application wrote no answers (ended: {ended}); see {work / 'app.log'}")
    return json.loads(answers_path.read_text())


def unanswered(declared, answers):
    """{class: {absent, declared, instance: [...], class: [...]}} for the classes of the headers."""
    rows = {}
    for name, info in declared.items():
        answer = answers.get(name, {"absent": True})
        rows[name] = {"absent": bool(answer.get("absent")), "declared": len(info["instance"]) + len(info["class"]),
                      "instance": sorted(answer.get("instance", [])), "class": sorted(answer.get("class", []))}
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    one = commands.add_parser("declared")
    one.add_argument("--headers", required=True, type=Path)
    one.add_argument("--out", required=True, type=Path)
    two = commands.add_parser("ask")
    two.add_argument("--declared", required=True, type=Path)
    two.add_argument("--out", required=True, type=Path)
    two.add_argument("--work", type=Path, default=ROOT / "local-validation/selector-sweep")
    two.add_argument("--database", type=Path, default=ROOT / "local-validation/runtime-private")
    three = commands.add_parser("report")
    three.add_argument("--declared", required=True, type=Path)
    three.add_argument("--answers", required=True, type=Path)
    three.add_argument("--classes", default="")
    three.add_argument("--list", action="store_true")
    three.add_argument("--json", type=Path)
    four = commands.add_parser("table")
    four.add_argument("--headers", required=True, type=Path)
    four.add_argument("--declared", required=True, type=Path)
    four.add_argument("--answers", required=True, type=Path)
    four.add_argument("--classes", default="")
    four.add_argument("--skip", type=Path)
    four.add_argument("--answered", type=Path)
    four.add_argument("--table", type=Path, default=ROOT / "Horos/Resources/LaterPluginSDKAnswers.json")
    four.add_argument("--work", type=Path, default=ROOT / "local-validation/selector-sweep")
    six = commands.add_parser("types")
    six.add_argument("--headers", required=True, type=Path)
    six.add_argument("--declared", required=True, type=Path)
    six.add_argument("--answers", required=True, type=Path)
    six.add_argument("--classes", default="")
    six.add_argument("--work", type=Path, default=ROOT / "local-validation/selector-sweep")
    six.add_argument("--list", action="store_true")
    five = commands.add_parser("encodings")
    five.add_argument("--headers", required=True, type=Path)
    five.add_argument("--entries", required=True, type=Path)
    five.add_argument("--work", type=Path, default=ROOT / "local-validation/selector-sweep")
    five.add_argument("--out", required=True, type=Path)
    options = parser.parse_args(argv)

    if options.command == "declared":
        declared = declared_selectors(options.headers)
        options.out.write_text(json.dumps(declared, indent=1, sort_keys=True))
        print(f"{len(declared)} classes, {sum(len(c['instance']) + len(c['class']) for c in declared.values())} selectors")
    elif options.command == "ask":
        answers = ask(options.declared.resolve(), options.out.resolve(), options.work.resolve(), options.database.resolve())
        print(f"{len(answers)} classes answered")
    elif options.command == "types":
        answers = json.loads(options.answers.read_text())
        only = set(filter(None, options.classes.split(",")))
        answered = {"%s %s" % (cls, key): encoding for cls, answer in answers.items() if not only or cls in only
                    for key, encoding in answer.get("types", {}).items()}
        declared = type_encodings(options.headers, sorted(answered), options.work.resolve())
        strip = lambda encoding: re.sub(r"\[\d+|\d+", lambda digits: digits.group(0) if digits.group(0).startswith("[") else "", encoding)
        other = {entry: (strip(answered[entry]), declared[entry]) for entry in answered
                 if declared.get(entry) is not None and strip(answered[entry]) != declared[entry]}
        print("%d answered selectors, %d the compiler could not declare, %d answered with other types than the headers declare"
              % (len(answered), sum(1 for entry in answered if declared.get(entry) is None), len(other)))
        counts = {}
        for entry in other:
            counts[entry.split(" ")[0]] = counts.get(entry.split(" ")[0], 0) + 1
        for cls, count in sorted(counts.items(), key=lambda item: -item[1]):
            print("  %s: %d" % (cls, count))
            if options.list:
                for entry in sorted(other):
                    if entry.split(" ")[0] == cls:
                        print("      %s  answers %s, declared %s" % (entry.split(" ", 1)[1], other[entry][0], other[entry][1]))
    elif options.command == "encodings":
        entries = json.loads(options.entries.read_text())
        encodings = type_encodings(options.headers, sorted(entries), options.work.resolve())
        options.out.write_text(json.dumps(encodings, indent=1, sort_keys=True) + "\n")
        print("%d encodings, %d the compiler was not asked for" % (len(encodings), sum(1 for value in encodings.values() if value is None)))
    elif options.command == "table":
        declared = json.loads(options.declared.read_text())
        rows = unanswered(declared, json.loads(options.answers.read_text()))
        skipped = set(options.skip.read_text().split("\n")) if options.skip else set()
        found, _, _ = declarations(options.headers)
        table = json.loads(options.table.read_text()) if options.table.exists() else {"classes": {}}
        table["about"] = TABLE_ABOUT
        names = [name for name in options.classes.split(",") if name] or sorted(name for name, row in rows.items() if not row["absent"])
        wanted = {cls: {(sign, selector) for side, sign in (("instance", "-"), ("class", "+")) for selector in rows[cls][side]
                        if "%s %s%s" % (cls, sign, selector) not in skipped} for cls in names}
        encodings = type_encodings(options.headers, sorted("%s %s%s" % (cls, sign, selector) for cls, items in wanted.items()
                                                           for sign, selector in items), options.work.resolve())
        entries, kept_entries = {}, []
        for cls in names:
            kept, neutral, refused = answers_of(cls, wanted[cls], found, encodings)
            for sign, selector, why in refused:
                print("not in the table: %s %s%s (%s)" % (cls, sign, selector, why), file=sys.stderr)
            if not kept and not neutral:
                continue
            entry = table["classes"].setdefault(cls, {"kept": [], "neutral": {}})
            entry["kept"] = sorted({tuple(item) for item in entry["kept"]} | {tuple(item) for item in kept})
            entry["neutral"].update(neutral)
            for name, sign, getter, _, setter, _ in kept:
                kept_entries += ["%s %s%s" % (cls, sign, getter), "%s %s%s" % (cls, sign, setter)]
            for sign, selector in [(sign, selector) for _, sign, getter, _, setter, _ in kept for selector in (getter, setter)] + \
                    [(key[0], key[1:]) for key in neutral]:
                entries["%s %s%s" % (cls, sign, selector)] = declared[cls]["class" if sign == "+" else "instance"][selector][0]
            print("%s: %d kept, %d neutral, %d not in the table" % (cls, len(kept), len(neutral), len(refused)), file=sys.stderr)
        # Those the sources add to a class when the application starts, with something behind them:
        # the table gives their types, and says to whoever reads the bundle that the class answers them.
        answered = [line for line in options.answered.read_text().split("\n") if line] if options.answered else []
        for entry, types in type_encodings(options.headers, answered, options.work.resolve()).items():
            cls, key = entry.split(" ", 1)
            if types is None:
                sys.exit("%s: no declaration the compiler takes" % entry)
            table["classes"].setdefault(cls, {"kept": [], "neutral": {}}).setdefault("answered", {})[key] = types
        options.table.write_text(json.dumps(table, indent=1, sort_keys=True) + "\n")
        print(json.dumps({"entries": entries, "kept": sorted(kept_entries),
                          "types": {entry: encodings[entry] for entry in entries}}, indent=1, sort_keys=True))
    else:
        rows = unanswered(json.loads(options.declared.read_text()), json.loads(options.answers.read_text()))
        only = set(filter(None, options.classes.split(",")))
        if options.json:
            options.json.write_text(json.dumps(rows, indent=1, sort_keys=True))
        absent = sorted(name for name, row in rows.items() if row["absent"])
        present = {name: row for name, row in rows.items() if not row["absent"] and (not only or name in only)}
        total = sum(len(row["instance"]) + len(row["class"]) for row in present.values())
        print(f"{len(present)} classes of the headers are in the application; {total} of "
              f"{sum(row['declared'] for row in present.values())} declared selectors are not answered")
        for name, row in sorted(present.items(), key=lambda item: -(len(item[1]["instance"]) + len(item[1]["class"]))):
            missing = len(row["instance"]) + len(row["class"])
            if missing:
                print(f"  {name}: {missing} of {row['declared']}")
                if options.list:
                    for selector in row["instance"]:
                        print(f"      -{selector}")
                    for selector in row["class"]:
                        print(f"      +{selector}")
        if not only:
            print(f"{len(absent)} classes of the headers are not in the application: {', '.join(absent)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
