#!/usr/bin/env python3
"""The smart album's modality matrix of the PACS On-Demand pane offers each modality once.

The matrix (OSIPACSOnDemand.xib, matrix 616) is bound to the album's list of
modalities by the cells' titles, so a cell per modality is what the user ticks
and what an album saved with that modality shows ticked again. Its twenty cells
once held VL twice. The matrix must offer the nineteen modalities of the Query
window's matrix, each once, and fill its last cell with an empty one that is
neither drawn nor clickable, in the Base nib and in every localized copy, which
keep one structure.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PANE = ROOT / 'Preference Panes' / 'OSIPACSOnDemandPreferencePane'
COPIES = [PANE / 'Base.lproj' / 'OSIPACSOnDemand.xib', PANE / 'ja-JP.lproj' / 'OSIPACSOnDemand.xib',
          *sorted((ROOT / 'Horos' / 'Resources').glob('*.lproj/OSIPACSOnDemand.xib'))]
QUERY = ROOT / 'Horos' / 'Resources' / 'en.lproj' / 'Query.xib'


def matrix_cells(path, matrix_id):
    matrix = next((m for m in ET.parse(path).iter('matrix') if m.get('id') == matrix_id), None)
    if matrix is None:
        raise SystemExit(f'FAIL {path.relative_to(ROOT)}: no matrix {matrix_id}')
    return [cell for column in matrix.iter('column') for cell in column.findall('buttonCell')]


def query_modalities():
    for matrix in ET.parse(QUERY).iter('matrix'):
        titles = [c.get('title') for col in matrix.iter('column') for c in col.findall('buttonCell')]
        if 'XC' in titles and 'VL' in titles:
            return sorted(t for t in titles if t)
    raise SystemExit('FAIL Query.xib: no modality matrix')


def main():
    expected = query_modalities()
    failures, structures = [], {}
    for path in COPIES:
        name = str(path.relative_to(ROOT))
        cells = matrix_cells(path, '616')
        titles = [c.get('title') for c in cells]
        modalities = [t for t in titles if t]
        duplicates = sorted({t for t in modalities if modalities.count(t) > 1})
        if duplicates:
            failures.append(f'{name}: {", ".join(duplicates)} more than once')
        if sorted(set(modalities)) != expected:
            failures.append(f'{name}: modalities {sorted(set(modalities))} differ from the Query window {expected}')
        if len(cells) != 20:
            failures.append(f'{name}: {len(cells)} cells, expected 20')
        else:
            last = cells[-1]
            if last.get('title') or last.get('transparent') != 'YES' or last.get('enabled') != 'NO':
                failures.append(f'{name}: the last cell is not empty, transparent and disabled')
        structures[name] = [(c.get('id'), c.get('title') or '') for c in cells]
    base = structures[str(COPIES[0].relative_to(ROOT))]
    for name, structure in structures.items():
        if structure != base:
            failures.append(f'{name}: matrix cells differ from the Base nib')
    for failure in failures:
        print('FAIL', failure)
    if failures:
        return 1
    print(f'ok: {len(COPIES)} copies, {len(expected)} modalities once each, last cell empty and disabled')
    return 0


if __name__ == '__main__':
    sys.exit(main())
