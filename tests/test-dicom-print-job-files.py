#!/usr/bin/env python3
"""The files of a DICOM print job: what the printer's settings put in the
script, the bytes its paths are written in, and what bash makes of them.

A print job is three files in a folder of its own: print.sh, which /bin/bash
runs, and print.cfg and logger.cfg, which the DCMTK tools read. The statements
of AYDicomPrintWindowController that compose and write them are compiled here
as they are, on a stand-in for the selected printer, the job folder, the log
folder and the application's resources, and the script they wrote is run with
tools that record their arguments.

- A printer whose settings have no Configuration Information (the key missing,
  a null, an empty or a blank value) asks for none: the script has no
  --configinfo, and no argument of it reads "(null)". The film box of such a
  job once carried the Configuration Information "(null)". A printer that has
  one passes it on.
- The files are UTF-8, the encoding of the names in the file system: bash and
  the tools read the paths in them as bytes. With the application, the job or
  the log in a folder whose name has an accented or a non-Latin letter, the
  script finds every file it names and ends with status 0. In Windows-1250 an
  accented letter named a file that does not exist, and a letter outside that
  code page left the job unwritten.
- A printer without an AE title, an address or a port is refused with a
  sentence that names what it lacks, and nothing is written. Composing its
  job once raised an exception. A line break in one of them does not add a
  setting to print.cfg.
- Nothing the script names is read by bash as anything but itself: a
  Configuration Information or a folder with quotes, a dollar sign, a
  backquote or a backslash reaches the tools as it is written, and a command
  substitution in one is not run. Between double quotes it was.
- With a print log that cannot be written the job still runs, and whether it
  ends well or not the script says on its output which step it was at, the
  line the app reads. The trap once stopped at the log, before that line.

--resources DIR --scp-python PYTHON runs the job for real as well: dcmpsprt,
HorosStoredPrint and dicom.dic of the Resources folder of an application
bundle, copied into a folder with such a name, send one synthetic image to the
loopback print SCP of tools/validate-dicom-print-scp.py (PYTHON has pydicom
and pynetdicom). The film box the printer receives has no Configuration
Information, or the one the printer's settings give, character for character;
the job also prints from folders named with what bash reads, and with a print
log that cannot be written.
"""
import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from sources import source_text

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('--resources', type=Path,
                    help='Resources folder of an application bundle: its dcmpsprt, HorosStoredPrint and dicom.dic')
parser.add_argument('--scp-python', type=Path,
                    help='an interpreter with pydicom and pynetdicom, for the loopback print SCP')
args = parser.parse_args()
if bool(args.resources) != bool(args.scp_python):
    parser.error('--resources and --scp-python go together')
root = Path(__file__).resolve().parent.parent
source = source_text('AYDicomPrintWindowController')


def between(start, end, inclusive=False):
    begin = source.index(start)
    finish = source.index(end, begin)
    if inclusive:
        finish = source.index('\n', finish) + 1
    return source[begin:finish]


templates = '\n'.join(re.search(r'^private let %s = """\n.*?^"""' % name, source, re.M | re.S).group(0)
                      for name in ('DCMTK_PRINTER_CONFIG_TEMPLATE', 'DCMTK_LOGGER_CONFIG_TEMPLATE'))
constants = between('// MARK: Tables', '// MARK: End of tables')
replace = between('private func ayReplace(', '\n}\n') + '\n}\n'
# From the paths of the three files to the number of images of a page: the two
# configurations and the head of the script.
head = between('                let loggerConfigPath = String(format:', '                let ipp =', inclusive=True)
# A dcmpsprt for each page, then HorosStoredPrint.
commands = between('                    // i <= ([images count] - 1) / ipp', '                    if (try? loggerConfig.write(')
# The condition under which the job is given up: one of the files not written.
unwritten = between('                    if (try? loggerConfig.write(', ' == nil {\n') + ' == nil {\n'
assert unwritten.count('.write(toFile:') == 3, unwritten
# A printer that lacks its address is refused before the files are composed.
refusal = source.index('        } else if let incomplete = ayIncompletePrinter(dict) {')
assert source.index('    func _createPrintjobDCMTK() {') < refusal < source.index('                let loggerConfigPath = String(format:')

PROGRAM = r'''
import Foundation
TEMPLATES
CONSTANTS
REPLACE
extension UserDefaults { static func defaultAETitle() -> String? { "ISIXQA" } }
// generate <resources> <job folder> <log folder> <host> <port> <configuration information> [<settings as JSON>]
let arguments = CommandLine.arguments
let resources: String? = arguments[1]
let printJobDir = arguments[2]
let logPath = arguments[3]
let printJobID = NSMutableString(string: "synthetic-QA")
let printer = NSMutableDictionary(dictionary: [
    "aeTitle": "PRINTQA", "host": arguments[4], "port": arguments[5], "copies": "1", "imageDisplayFormatTag": "0",
    "filmSizeTag": "7", "magnificationTypeTag": "1", "borderDensityTag": "0", "emptyImageDensityTag": "0", "trimTag": "0",
    "filmOrientationTag": "0", "priorityTag": "1", "filmDestinationTag": "0", "mediumTag": "2"])
switch arguments[6] {
case "missing": break
case "null": printer["configurationInformation"] = NSNull()
case "empty": printer["configurationInformation"] = ""
case "blank": printer["configurationInformation"] = "  "
default: printer["configurationInformation"] = arguments[6]
}
// Other settings of the printer: a null takes the key away.
if arguments.count > 7, let changes = try? JSONSerialization.jsonObject(with: Data(arguments[7].utf8)) as? [String: Any] {
    for (key, value) in changes {
        if value is NSNull { printer.removeObject(forKey: key) } else { printer[key] = value }
    }
}
let dict: AnyObject? = printer
// As -_createPrintjobDCMTK does before it prepares anything.
if let incomplete = ayIncompletePrinter(dict) {
    print("refused: " + incomplete)
    exit(4)
}
let images = NSMutableArray()
for name in ((try? FileManager.default.contentsOfDirectory(atPath: printJobDir)) ?? []).sorted() where name.hasSuffix(".dcm") {
    images.add((printJobDir as NSString).appendingPathComponent(name))
}
HEAD
COMMANDS
UNWRITTEN
    exit(3)
}
'''
program = (PROGRAM.replace('TEMPLATES', templates).replace('CONSTANTS', constants).replace('REPLACE', replace)
           .replace('HEAD', head).replace('COMMANDS', commands).replace('UNWRITTEN', unwritten)
           .replace('Bundle.main.resourcePath', 'resources'))

# Each tool appends its name and its arguments, one a line; dcmpsprt leaves the
# Stored Print the script then hands to HorosStoredPrint.
RECORDER = r'''#!/bin/sh
name=$(basename "$0")
{ printf '== %s\n' "$name"; for argument in "$@"; do printf '%s\n' "$argument"; done; } >> "$QA_TRACE"
if [ "$QA_FAIL" = "$name" ]; then echo "$name: asked to fail" >&2; exit 3; fi
if [ "$name" = dcmpsprt ]; then : > "database/SP_recorded"; fi
'''

# One synthetic 8-bit secondary capture, written by the interpreter of the SCP.
IMAGE = r'''
import sys
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, generate_uid
ds = Dataset(); ds.file_meta = FileMetaDataset()
ds.SOPClassUID = '1.2.840.10008.5.1.4.1.1.7'; ds.SOPInstanceUID = generate_uid()
ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID; ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
ds.PatientName = 'QA^Print'; ds.PatientID = 'LOCAL-PRINT-QA'; ds.Modality = 'SC'
ds.StudyInstanceUID = generate_uid(); ds.SeriesInstanceUID = generate_uid()
ds.Rows = 32; ds.Columns = 64; ds.SamplesPerPixel = 1; ds.PhotometricInterpretation = 'MONOCHROME2'
ds.BitsAllocated = 8; ds.BitsStored = 8; ds.HighBit = 7; ds.PixelRepresentation = 0
ds.PixelData = bytes([0] * 32 + [255] * 32) * 32
ds.save_as(sys.argv[1], enforce_file_format=True)
'''


def calls(trace):
    """What each tool was given: [(name, [argument, ...]), ...]."""
    found = []
    for line in trace.read_text(encoding='utf-8', errors='replace').splitlines() if trace.is_file() else []:
        if line.startswith('== '):
            found.append((line[3:], []))
        else:
            found[-1][1].append(line)
    return found


def job(generate, base, names, configuration, tools, host='127.0.0.1', port='1', image=None, settings=None,
        before_run=None, environment=None):
    """Compose, write and run one job in the folders `names` of `base`.
    `settings` changes the printer's (None takes a key away); `before_run`
    is called on the log folder once the job is written. Returns what
    happened and the files, for the caller to judge."""
    resources, folder, logs = (base / name for name in names)
    for path in (folder, logs):
        path.mkdir(parents=True)
    if not resources.is_dir():
        resources.mkdir(parents=True)
        for name, content in tools.items():
            if isinstance(content, Path):
                shutil.copy2(content, resources / name)
            else:
                (resources / name).write_text(content)
                (resources / name).chmod(0o755)
    if image:
        image(folder / 'image-01.dcm')
    else:
        (folder / 'image-01.dcm').write_bytes(b'not read by the recording tools')
    trace = base / (names[1] + ' calls')
    result = {'folder': folder, 'logs': logs, 'resources': resources, 'trace': trace}
    written = subprocess.run([str(generate), str(resources), str(folder), str(logs), host, str(port), configuration,
                              *([json.dumps(settings)] if settings else [])], capture_output=True, text=True, timeout=60)
    result['written'] = written.returncode
    result['said'] = written.stdout
    if written.returncode:
        result['output'] = written.stdout + written.stderr
        return result
    result['bytes'] = {name: (folder / name).read_bytes() for name in ('print.sh', 'print.cfg', 'logger.cfg')}
    # A script in another encoding answers in it: what it wrote is read leniently.
    if before_run:
        before_run(logs)
    run = subprocess.run(['/bin/bash', str(folder / 'print.sh')], capture_output=True, text=True, errors='replace',
                         timeout=120, env={**os.environ, 'QA_TRACE': str(trace), **(environment or {})})
    result['status'] = run.returncode
    result['output'] = run.stdout + run.stderr
    result['calls'] = calls(trace)
    return result


def text(data):
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        return None


failures = []


def expect(condition, message):
    if not condition:
        failures.append(message)


with tempfile.TemporaryDirectory(prefix='isix-print-job-files-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(program, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', str(work / 'main.swift'), '-o', str(work / 'generate')],
                           capture_output=True, text=True, timeout=600)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: the statements that compose a print job do not compile on their stand-in')
        raise SystemExit(1)
    generate = work / 'generate'
    recorders = {'dcmpsprt': RECORDER, 'HorosStoredPrint': RECORDER, 'dicom.dic': '# not read by the recording tools\n'}

    # ---- Configuration Information of the printer
    for index, (configuration, expected) in enumerate([('missing', None), ('null', None), ('empty', None), ('blank', None),
                                                       ('CS000', 'CS000'), ('LUT=m0.lut,2', 'LUT=m0.lut,2')]):
        done = job(generate, work / ('settings-%d' % index), ('resources', 'job', 'logs'), configuration, recorders)
        what = 'a printer whose Configuration Information is ' + (configuration if expected is None else '"%s"' % expected)
        if done['written'] or done.get('status'):
            failures.append('%s: the job was not written and run: %s' % (what, done.get('output', '')[-600:]))
            continue
        script = text(done['bytes']['print.sh']) or ''
        expect('(null)' not in script and '<null>' not in script,
               '%s: print.sh reads "(null)": %s' % (what, [line for line in script.splitlines() if 'null' in line]))
        expect([name for name, _ in done['calls']] == ['dcmpsprt', 'HorosStoredPrint'], '%s: ran %s' % (what, done['calls']))
        for name, given in done['calls']:
            expect(not any('(null)' in argument or '<null>' in argument for argument in given),
                   '%s: %s was given "(null)": %s' % (what, name, given))
            if name != 'dcmpsprt':
                continue
            asked = [given[i + 1] for i, argument in enumerate(given[:-1]) if argument == '--configinfo']
            expect(asked == ([] if expected is None else [expected]),
                   '%s: dcmpsprt was given --configinfo %s' % (what, asked))
            # The rest of the film box is as the printer's settings say.
            for option, value in (('--filmsize', '14INX17IN'), ('--magnification', 'BILINEAR'), ('--border', 'BLACK'),
                                  ('--empty-image', 'BLACK'), ('--printer', 'PRINTSCP')):
                expect(option in given and given[given.index(option) + 1] == value,
                       '%s: dcmpsprt was not given %s %s: %s' % (what, option, value, given))
            expect(given[-1].endswith('/image-01.dcm') and '--no-trim' in given and '--portrait' in given,
                   '%s: dcmpsprt was given %s' % (what, given))
    if not failures:
        print('PASS: a printer without Configuration Information (missing, null, empty or blank) asks for none, and no '
              'argument of the script reads "(null)"; a printer that has one passes it to dcmpsprt')

    # ---- The names of the folders
    before = len(failures)
    places = [
        ('an accented letter', ('Aplicación médica/Resources', 'trabajo é', 'Registros de impresión')),
        ('letters outside Windows-1250', ('Año ñandú 画像/Resources', '印刷 ジョブ ñ', 'журнал печати 로그')),
    ]
    for index, (kind, names) in enumerate(places):
        done = job(generate, work / ('names-%d' % index), names, 'missing', recorders)
        what = 'folders named with ' + kind
        if done['written']:
            failures.append('%s: the files of the job were not written: %s' % (what, done.get('output', '')[-600:]))
            continue
        for name, data in done['bytes'].items():
            expect(text(data) is not None, '%s: %s is not UTF-8' % (what, name))
        script, logger = text(done['bytes']['print.sh']) or '', text(done['bytes']['logger.cfg']) or ''
        expect(str(done['folder']) in script and str(done['resources']) in script and str(done['logs']) in script,
               '%s: print.sh does not name them as the file system does' % what)
        expect(str(done['logs']) + '/print.log' in logger, '%s: logger.cfg does not name the log as the file system does' % what)
        expect(done['status'] == 0 and 'IsiXPrintJob: step=send status=0' in done['output'],
               '%s: the script ended with status %s: %s' % (what, done['status'], done['output'][-600:]))
        expect([name for name, _ in done['calls']] == ['dcmpsprt', 'HorosStoredPrint'], '%s: ran %s' % (what, done['calls']))
        for name, given in done['calls']:
            for option in ('-c', '-lc'):
                path = given[given.index(option) + 1] if option in given else ''
                expect(os.path.isfile(path), '%s: %s was given %s "%s", which is no file' % (what, name, option, path))
            named = [argument for argument in given if argument.endswith('.dcm') or '/SP_' in argument]
            expect(named and all(os.path.isfile(path) for path in named), '%s: %s was given %s' % (what, name, named))
        log = done['logs'] / 'print.log'
        expect(log.is_file() and '[step=send status=0]' in log.read_text(encoding='utf-8', errors='replace'),
               '%s: the print log in the log folder does not have the end of the job' % what)
    if len(failures) == before:
        print('PASS: print.sh, print.cfg and logger.cfg are UTF-8, and a job whose application, folder and log are in '
              'folders named with accented and non-Latin letters runs to status 0 with every file it names found')

    # ---- A printer that lacks its address
    before = len(failures)
    for index, (settings, names_it) in enumerate([({'aeTitle': None}, 'AE Title'), ({'host': None}, 'address'), ({'port': None}, 'port'),
                                                  ({'host': ''}, 'address'), ({'host': '   '}, 'address'), ({'port': None, 'host': None}, 'address')]):
        done = job(generate, work / ('incomplete-%d' % index), ('resources', 'job', 'logs'), 'missing', recorders, settings=settings)
        what = 'a printer with ' + json.dumps(settings)
        expect(done['written'] == 4 and done['said'].startswith('refused: This printer has no %s.' % names_it),
               '%s: not refused with the name of what it lacks: exit %s, %s' % (what, done['written'], (done['said'] + done.get('output', ''))[-600:]))
        expect(sorted(path.name for path in done['folder'].iterdir()) == ['image-01.dcm'], '%s: files were written' % what)
    # A port kept as a number is a port, and a line break in a setting adds no setting.
    done = job(generate, work / 'settings-kinds', ('resources', 'job', 'logs'), 'missing', recorders,
               settings={'port': 10104, 'aeTitle': 'PRINT\nSupports12Bit = true\r\n QA'})
    if done['written'] or done.get('status'):
        failures.append('a numeric port and an AE title with line breaks: the job was not written and run: %s' % done.get('output', done['said'])[-600:])
    else:
        configuration = text(done['bytes']['print.cfg']) or ''
        expect('\nPort = 10104\n' in configuration, 'a numeric port is not in print.cfg: %s' % configuration)
        expect('\nAetitle = PRINT Supports12Bit = true   QA\n' in configuration
               and [line for line in configuration.splitlines() if line.startswith('Supports12Bit')] == ['Supports12Bit = false'],
               'a line break in the AE title added a setting to print.cfg: %s' % configuration)
    if len(failures) == before:
        print('PASS: a printer without AE title, address or port is refused with a sentence naming it and nothing is written; '
              'a numeric port is taken, and a line break in a setting adds none to print.cfg')

    # ---- What bash makes of the values and the paths
    before = len(failures)
    literal = ['a"b', 'x $(touch INJECTED) y', 'x `touch INJECTED` y', 'LUT=0\\1 $HOME ${PATH}', "it's 'quoted'", '; touch INJECTED #',
               '* ? [a-z] ~ & | < > ! \\', '-n $IFS"\'`']
    for index, value in enumerate(literal):
        done = job(generate, work / ('literal-%d' % index), ('resources', 'job', 'logs'), value, recorders)
        what = 'the Configuration Information ' + repr(value)
        if done['written'] or done.get('status'):
            failures.append('%s: the job was not written and run: %s' % (what, done.get('output', '')[-600:]))
            continue
        given = dict(done['calls']).get('dcmpsprt', [])
        asked = [given[i + 1] for i, argument in enumerate(given[:-1]) if argument == '--configinfo']
        expect(asked == [value], '%s reached dcmpsprt as %s' % (what, asked))
        expect([name for name, _ in done['calls']] == ['dcmpsprt', 'HorosStoredPrint'], '%s: ran %s' % (what, done['calls']))
        expect(not list((work / ('literal-%d' % index)).rglob('INJECTED')), '%s: a command in it was run' % what)
        expect('IsiXPrintJob: step=send status=0' in done['output'], '%s: the script said %s' % (what, done['output'][-300:]))
    places = ('App "quoted" $HOME `id`/Resources', "job $(touch INJECTED) it's; x", 'logs & "more" \\ $x')
    done = job(generate, work / 'literal-places', places, 'CS000', recorders)
    if done['written'] or done.get('status'):
        failures.append('folders named with quotes, dollars and backquotes: the job did not run: %s' % done.get('output', '')[-900:])
    else:
        expect([name for name, _ in done['calls']] == ['dcmpsprt', 'HorosStoredPrint'], 'such folders: ran %s' % done['calls'])
        for name, given in done['calls']:
            for option in ('-c', '-lc'):
                path = given[given.index(option) + 1] if option in given else ''
                expect(os.path.isfile(path), 'such folders: %s was given %s "%s", which is no file' % (name, option, path))
            named = [argument for argument in given if argument.endswith('.dcm') or '/SP_' in argument]
            expect(named and all(os.path.isfile(path) for path in named), 'such folders: %s was given %s' % (name, named))
        expect(not list((work / 'literal-places').rglob('INJECTED')), 'such folders: a command in a name was run')
        log = done['logs'] / 'print.log'
        expect(log.is_file() and 'Starting print job synthetic-QA' in log.read_text() and '[step=send status=0]' in log.read_text(),
               'such folders: the print log does not have the job')
    if len(failures) == before:
        print('PASS: quotes, dollar signs, backquotes, backslashes and the rest of what bash reads, in a Configuration '
              'Information or in the names of the folders, reach the tools as written, and no command in them is run')

    # ---- A print log that cannot be written
    before = len(failures)

    def lock(folder):
        folder.chmod(0o500)

    for index, (failing, expected, status) in enumerate([(None, 'IsiXPrintJob: step=send status=0', 0),
                                                         ('dcmpsprt', 'IsiXPrintJob: step=layout status=3', 3),
                                                         ('HorosStoredPrint', 'IsiXPrintJob: step=send status=3', 3)]):
        base = work / ('no-log-%d' % index)
        try:
            done = job(generate, base, ('resources', 'job', 'logs'), 'missing', recorders, before_run=lock,
                       environment={'QA_FAIL': failing} if failing else None)
        finally:
            (base / 'logs').chmod(0o700)
        what = 'a print log that cannot be written' + (', with %s failing' % failing if failing else '')
        expect(done['written'] == 0 and done.get('status') == status and expected in done.get('output', '').splitlines(),
               '%s: status %s, and the script said: %s' % (what, done.get('status'), done.get('output', '')[-600:]))
        expect(not (base / 'logs' / 'print.log').exists(), '%s: the log was written, so nothing was tried' % what)
    if len(failures) == before:
        print('PASS: with a print log that cannot be written the job still runs, and the script still says the step '
              'it ended at, when a tool fails too')

    # ---- For real, to the loopback print SCP
    if args.resources:
        before = len(failures)
        bundle = args.resources.resolve()
        real = {name: bundle / name for name in ('dcmpsprt', 'HorosStoredPrint', 'dicom.dic')}
        absent = [path for path in real.values() if not path.is_file()]
        if absent:
            print('skipped: not in --resources: ' + str(absent[0]))
            raise SystemExit(2)
        (work / 'image.py').write_text(IMAGE)

        def image(path):
            subprocess.run([str(args.scp_python), str(work / 'image.py'), str(path)], check=True, timeout=60)

        accented = ('Aplicación ñ 画像/Resources', 'trabajo é 印刷', 'Registros é ログ')
        shell = 'x"$(touch INJECTED)`touch INJECTED` \\ $HOME \'z'
        cases = [('missing', None, accented, None), ('CS000', 'CS000', accented, None),
                 # What bash reads, in the value and in the names; then a print log that cannot be written.
                 (shell, shell, ('App "quoted" $HOME `id`/Resources', "job $(touch INJECTED) it's; x", 'logs & "more" $x'), None),
                 ('missing', None, ('resources', 'job', 'logs'), lock)]
        for index, (configuration, expected, names, before_run) in enumerate(cases):
            base = work / ('printer-%d' % index)
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            received = base / 'received'
            received.mkdir(parents=True)
            scp = subprocess.Popen([str(args.scp_python), str(root / 'tools/validate-dicom-print-scp.py'), str(bundle),
                                    str(received), '--serve', '--port', str(port), '--columns', '1', '--rows', '1'],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                line = scp.stdout.readline()
                if 'listening' not in line:
                    scp.kill()
                    print('FAIL: the print SCP did not start: ' + line + scp.stdout.read()[-2000:])
                    raise SystemExit(1)
                done = job(generate, base, names, configuration, real, port=port, image=image, before_run=before_run)
            finally:
                if before_run:
                    (base / names[2]).chmod(0o700)
                scp.send_signal(signal.SIGINT)
                try:
                    scp.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    scp.kill()
            what = 'a printer whose Configuration Information is ' + (configuration if expected is None else '"%s"' % expected)
            if done['written'] or done.get('status'):
                failures.append('%s, for real: the job did not run to the end: %s' % (what, done.get('output', '')[-1500:]))
                continue
            capture = json.loads((received / 'received.json').read_text()) if (received / 'received.json').is_file() else {}
            films = capture.get('film_boxes', [])
            expect(len(films) == 1 and len(capture.get('images', [])) == 1 and capture.get('actions') == 1,
                   '%s, for real: the printer received %s' % (what, capture))
            if films:
                expect(films[0].get('ConfigurationInformation') == expected and films[0].get('FilmSizeID') == '14INX17IN',
                       '%s, for real: the film box the printer received is %s' % (what, films[0]))
            log = done['logs'] / 'print.log'
            if before_run:
                expect(not log.exists() and 'IsiXPrintJob: step=send status=0' in done['output'].splitlines(),
                       '%s, for real, with a print log that cannot be written: the script said %s' % (what, done['output'][-600:]))
            else:
                expect(log.is_file() and '[step=send status=0]' in log.read_text(encoding='utf-8', errors='replace'),
                       '%s, for real: the print log is not in its folder' % what)
            expect(not list(base.rglob('INJECTED')), '%s, for real: a command in a value or a name was run' % what)
            print('%s: the printer received the film box %s and %d image' % (what, films[0] if films else None,
                                                                             len(capture.get('images', []))))
        if len(failures) == before:
            print('PASS: the tools of the bundle, run from folders named with accented and non-Latin letters, or with what bash '
                  'reads, or with a print log that cannot be written, print to the loopback SCP; its film box has no '
                  'Configuration Information unless the printer has one, and then as it is written')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    raise SystemExit(1)
