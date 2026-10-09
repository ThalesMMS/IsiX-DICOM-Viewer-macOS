#!/usr/bin/env python3
"""Report templates kept in subfolders are listed, offered as submenus and found.

Only the first level of the templates folder was read, so a template in a
subfolder (RX/RX TÓRAX.pages, as a radiologist with one template per exam keeps
them) was never offered. The production ReportTemplateMenu is compiled here and
run on a templates folder made below; the wiring in the report code is checked
in its source.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
reports = (root / 'Horos/Sources/Reports.swift').read_text()
browser = (root / 'Horos/Sources/BrowserController+Reports.swift').read_text()
viewer = (root / 'Horos/Sources/ViewerController.m').read_text()
for source, needle, reason in (
    (reports, 'ReportTemplateMenu.templates(in: templateDirectory', 'the Pages list does not go into subfolders'),
    (reports, 'ReportTemplateMenu.templates(in: directory, isTemplate:', 'the Word list does not go into subfolders'),
    (reports, 'ReportTemplateMenu.path(of: name, in: templateDirectory', 'a Pages template in a subfolder is not resolved'),
    (reports, 'ReportTemplateMenu.path(of: name, in: $0, isTemplate:', 'a Word template in a subfolder is not resolved'),
    (browser, 'ReportTemplateMenu.populate(menu, templates: templates, folder: folder', 'the browser menu has no submenus'),
    (browser, 'sender is NSMenuItem, let template = ReportTemplateMenu.templateName(for: sender)', 'an item of a submenu does not choose its template'),
    (viewer, '[HorosReportTemplateMenu populateMenu:reportTemplatesListPopUpButton.menu', 'the viewer menu has no submenus'),
):
    if needle not in source:
        failures.append(reason)
for lproj in sorted((root / 'Horos/Resources').glob('*.lproj')):
    strings = lproj / 'Localizable.strings'
    raw = strings.read_bytes()
    text = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8')
    if '"Show the Report Templates Folder in the Finder" =' not in text:
        failures.append('%s has no text for the templates folder item' % lproj.name)

program = r'''
import AppKit

func check(_ value: Bool, _ what: String, line: Int = #line) {
    if !value { print("FAIL: \(what) (line \(line))"); exit(1) }
}
let folder = CommandLine.arguments[1]
let isPages: (String, Bool) -> Bool = { name, _ in ["pages", "template"].contains((name as NSString).pathExtension.lowercased()) }

let found = ReportTemplateMenu.templates(in: folder, isTemplate: isPages)
// Folder by folder, folders among the files in the Finder's order ("RX 2" before "RX 10").
check(found == ["ASSINATURA.pages", "HR/HR M\u{c3}O.pages", "Package.pages", "RX/Infantil/RX T\u{d3}RAX INFANTIL.template",
                "RX/RX 2.pages", "RX/RX 10.pages", "RX/RX T\u{d3}RAX.pages", "TC CRANIO.pages", "USG/USG ABDOME.pages"],
      "listed: \(found)")

// A template in a subfolder is found by its path; nothing outside the folder is.
check(ReportTemplateMenu.path(of: "RX/RX T\u{d3}RAX.pages", in: folder, isTemplate: isPages) == folder + "/RX/RX T\u{d3}RAX.pages", "nested path")
check(ReportTemplateMenu.path(of: "RX/Infantil/RX T\u{d3}RAX INFANTIL.template", in: folder, isTemplate: isPages) != nil, "deeper path")
for refused in ["../outside.pages", "RX/../../outside.pages", "/etc/hosts", "RX//RX 2.pages", "./RX/RX 2.pages", "RX/notes.txt", "RX", "RX/missing.pages", ""] {
    check(ReportTemplateMenu.path(of: refused, in: folder, isTemplate: isPages) == nil, "refused \(refused)")
}

// The menu: first-level templates as they were, a submenu a folder. Menus are
// the main thread's, which is where this runs.
final class Target: NSObject { @objc func generateReport(_ sender: Any?) {} }
MainActor.assumeIsolated {
let target = Target()
let menu = NSMenu()
menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
ReportTemplateMenu.populate(menu, templates: found, folder: folder, target: target, action: #selector(Target.generateReport(_:)))
let titles = menu.items.map(\.title)
check(titles == ["", "ASSINATURA.pages", "HR", "Package.pages", "RX", "TC CRANIO.pages", "USG", "",
                 "Show the Report Templates Folder in the Finder"], "titles: \(titles)")
check(menu.items[1].representedObject as? String == "ASSINATURA.pages" && menu.items[1].action == nil, "a first-level item is the pop-up's")
let rx = menu.items[4].submenu!
check(rx.items.map(\.title) == ["Infantil", "RX 2.pages", "RX 10.pages", "RX T\u{d3}RAX.pages"], "RX submenu: \(rx.items.map(\.title))")
let thorax = rx.items[3]
check(thorax.representedObject as? String == "RX/RX T\u{d3}RAX.pages" && thorax.action == #selector(Target.generateReport(_:))
      && thorax.target === target, "a submenu item sends the action itself")
check(rx.items[0].submenu?.items.first?.representedObject as? String == "RX/Infantil/RX T\u{d3}RAX INFANTIL.template", "nested submenu")
check(menu.items[7].isSeparatorItem, "separator before the folder item")
let show = menu.items[8]
check(show.representedObject as? String == folder && show.target != nil && show.action != nil, "folder item")

// The template a report is made from.
check(ReportTemplateMenu.templateName(for: thorax) == "RX/RX T\u{d3}RAX.pages", "from a submenu item")
let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
popUp.menu = menu
popUp.select(menu.items[1])
check(ReportTemplateMenu.templateName(for: popUp) == "ASSINATURA.pages", "from the pop-up")
let legacy = NSMenuItem(title: "Old Name.pages", action: nil, keyEquivalent: "")
check(ReportTemplateMenu.templateName(for: legacy) == "Old Name.pages", "an item without a path gives its title")

// No folder given (OpenDocument templates): no folder item.
let plain = NSMenu()
ReportTemplateMenu.populate(plain, templates: ["A.odt"], folder: nil, target: target, action: #selector(Target.generateReport(_:)))
check(plain.items.map(\.title) == ["A.odt"], "no folder item without a folder")
}
print("PASS")
'''

with tempfile.TemporaryDirectory(prefix='horos-template-folders-') as work:
    w = Path(work)
    t = w / 'PAGES TEMPLATES'
    for name in ('ASSINATURA.pages', 'TC CRANIO.pages', 'HR/HR MÃO.pages', 'RX/RX TÓRAX.pages', 'RX/RX 10.pages',
                 'RX/RX 2.pages', 'RX/notes.txt', 'RX/Infantil/RX TÓRAX INFANTIL.template', 'USG/USG ABDOME.pages',
                 '.hidden/Secret.pages', 'RX/.DS_Store', 'Empty folder/readme.txt'):
        (t / name).parent.mkdir(parents=True, exist_ok=True)
        (t / name).write_bytes(b'PK')
    # A template saved as a package is a directory, and still a template.
    (t / 'Package.pages/Index').mkdir(parents=True)
    (t / 'Package.pages/Index/Document.iwa').write_bytes(b'')
    (w / 'outside.pages').write_bytes(b'PK')
    (w / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/ReportTemplateMenu.swift'), str(w / 'main.swift'),
                            '-o', str(w / 'menu')], timeout=600)
    if built.returncode:
        failures.append('the production ReportTemplateMenu did not compile')
    else:
        run = subprocess.run([str(w / 'menu'), str(t)], capture_output=True, text=True, timeout=120)
        if run.returncode or 'PASS' not in run.stdout:
            failures.append('the template folders are wrong: %s%s' % (run.stdout, run.stderr[-2000:]))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: report templates in subfolders are listed, offered as submenus and found by their path')
