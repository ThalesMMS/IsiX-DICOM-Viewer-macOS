#!/usr/bin/env python3
"""No catalog value is half English.

Some Spanish entries had been made by replacing words one at a time: "The remote
database index está empty.", "Sin se puede decompress images in a distant database."
The sentence stayed half English, and sometimes said the opposite of the original.
Others had every word replaced and kept the English order and capitals: "clave
Imágenes" for "Key Images", "Añadir Actual WL/WW" for "Add Current WL/WW". The menus,
the labels of toolbar items and the tooltips showed them.

`tools/inventory-mixed-translations.py` reports a value that carries an English word
its language does not have, a word of its own English original, a first word in lower
case under an English capital and, in Spanish, the capitals and the order of an
English title. It runs here over the Spanish and the Italian catalogs. Against the
Spanish catalog before the first translation pass it reported 436 of 2787 entries;
before the second, with the rules of order and capitals, 310 of 4812, and 100 of the
4783 Italian ones.

The rules themselves are then checked on phrases the catalogs held, each of which must
be reported, and on right translations that look like them, which must not.
"""
import importlib.util
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
tool = root / 'tools/inventory-mixed-translations.py'
run = subprocess.run([sys.executable, str(tool), '--check'], capture_output=True, text=True)
if run.returncode != 0:
    print((run.stdout + run.stderr).strip()[-3000:])
    raise SystemExit(1)
counts = [line for line in run.stdout.strip().splitlines() if ' mixed of ' in line]
if len(counts) != 2:
    raise SystemExit(f'the inventory did not read the Spanish and the Italian catalogs: {counts}')

spec = importlib.util.spec_from_file_location('inventory', tool)
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)
residual = inventory.residual_module()
products = sorted(residual.PRODUCT, key=len, reverse=True)
spanish = inventory.vocabulary(inventory.catalog('es'))


def reasons(language, original, value):
    return inventory.reasons(language, original, value, spanish if language == 'es' else {}, products, residual.FORMAT)


# What the catalogs held, by the rule that reports it.
REPORTED = [
    ('es', 'Mouse button function', 'ratón button function', 'words of the English original'),
    ('es', 'Set WL/WW manually', 'Definir WL/WW manually', 'words of the English original'),
    ('es', 'Show orientation cube', 'Mostrar orientation cube', 'words of the English original'),
    ('es', 'Level of Detail', 'nivel de Detail', 'starts in lower case'),
    ('es', 'Key Images', 'clave Imágenes', 'starts in lower case'),
    ('es', 'Add Current WL/WW', 'Añadir Actual WL/WW', 'a capital inside'),
    ('es', 'Study Date', 'Estudio Fecha', 'a capital inside'),
    ('es', 'Study Date:', 'Estudio Fecha:', 'a capital inside'),
    ('es', 'Background Color', 'Fondo Color', 'the English order'),
    ('es', 'Series Selection', 'Serie selección', 'the English order'),
    ('es', 'DICOM File', 'DICOM Archivo', 'the English order'),
    ('es', 'Propagate settings (WL/WW, zoom, ...)', 'Propagar settings ( WL/WW , zoom ,... )', 'a space around punctuation'),
    ('es', 'Set the three views to the same height', 'Definir el three views a el mismo height', 'an article that does not contract'),
    ('es', 'The remote database index is empty.', 'The remote database index está empty.', 'english words left'),
    ('it-IT', 'Add Current WL/WW', 'Aggiungi actual WL/WW', 'english words left'),
    ('it-IT', 'DICOM Network Error', 'Errore DICOM Network', 'words of the English original'),
    ('it-IT', 'Merge Series', 'Serie Merge', 'words of the English original'),
]
# Right translations: a verb or an adjective first, a participle last, a name, a word both languages have,
# the labels of a readout of several fields.
ACCEPTED = [
    ('es', 'Add Current WL/WW', 'Añadir WL/WW actual'),
    ('es', 'Open Image', 'Abrir imagen'),
    ('es', 'New group', 'Nuevo grupo'),
    ('es', 'Plugin Installed', 'Plugin instalado'),
    ('es', 'Background Color', 'Color de fondo'),
    ('es', 'Export to Photos', 'Exportar a Fotos'),
    ('es', 'Arrow Tool', 'Herramienta Flecha'),
    ('es', 'Explicit Little Endian', 'Little Endian explícito'),
    ('es', 'Details are in print.log in %@.', 'Los detalles están en print.log, en %@.'),
    ('es', 'Thickness: %1$.2f mm Location: %2$.2f mm', 'Grosor: %1$.2f mm Posición: %2$.2f mm'),
    ('es', 'X: %1$d px Y: %2$d px Value: %3$.2f %4$@', 'X: %1$d px Y: %2$d px Valor: %3$.2f %4$@'),
    ('it-IT', 'Add Current WL/WW', 'Aggiungi WL/WW attuale'),
    ('it-IT', 'Background Operations', 'Operazioni in background'),
    ('it-IT', 'Variable flip angle', 'Angolo di flip variabile'),
]
failures = []
for language, original, value, rule in REPORTED:
    found = reasons(language, original, value)
    if not any(reason.startswith(rule) for reason in found):
        failures.append(f'{language}: {value!r} for {original!r} is not reported for {rule!r}: {found}')
for language, original, value in ACCEPTED:
    found = reasons(language, original, value)
    if found:
        failures.append(f'{language}: {value!r} for {original!r} is reported: {found}')
if failures:
    print('\n'.join(failures))
    raise SystemExit(1)
print('; '.join(counts) + f'; {len(REPORTED)} half-translated phrases reported and {len(ACCEPTED)} translations accepted')
