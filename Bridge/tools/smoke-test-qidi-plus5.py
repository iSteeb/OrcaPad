#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
"""Validate profile indexes and slice four X-Plus 5 defaults with desktop Orca 2.4.2.

Usage: python3 Bridge/tools/smoke-test-qidi-plus5.py --slicer /path/to/OrcaSlicer
Uses a fresh temporary directory, including an isolated desktop data directory.
Flattens profile inheritance for CLI loading; the app uses PresetBundle instead.
This checks settings/G-code compatibility, not iOS UI or physical printing.
"""
import argparse, json, pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2] / 'Sources/OrcaPad/Resources/system'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--slicer', type=pathlib.Path, required=True)
args = parser.parse_args()
cli = str(args.slicer.resolve())
version = subprocess.run([cli, '--help'], capture_output=True, text=True, check=True)
if 'OrcaSlicer-2.4.2:' not in version.stdout + version.stderr:
    raise ValueError('Use OrcaSlicer 2.4.2 to match OrcaPad')
work = pathlib.Path(tempfile.mkdtemp(prefix='orcapad-plus5-'))
count = 0
for index in root.glob('*.json'):
    vendor = json.loads(index.read_text())
    for group in ['machine_model_list', 'machine_list', 'process_list', 'filament_list']:
        seen = set()
        for entry in vendor.get(group, []):
            path = root / index.stem / entry['sub_path']
            data = json.loads(path.read_text())
            if data['name'] != entry['name'] or entry['name'] in seen:
                raise ValueError(f'Duplicate or mismatched name: {path}')
            seen.add(entry['name'])
            count += 1
print(f'PASS: {count} indexed profiles exist with matching, unique names', flush=True)
profiles = {}
for vendor in ['Qidi', 'OrcaFilamentLibrary']:
    index = json.loads((root / (vendor + '.json')).read_text())
    for kind, group in [('machine', 'machine_list'), ('process', 'process_list'), ('filament', 'filament_list')]:
        for entry in index.get(group, []):
            d = json.loads((root / vendor / entry['sub_path']).read_text())
            profiles[vendor, kind, d['name']] = d

def resolve(vendor, kind, name, stack=()):
    key = (vendor, kind, name)
    if key not in profiles:
        key = ('OrcaFilamentLibrary', kind, name)
    if key in stack:
        raise ValueError(f'Inheritance cycle: {key}')
    d = profiles[key]
    parent = d.get('inherits', '')
    merged = resolve(key[0], kind, parent, stack + (key,)) if parent else {}
    return {**merged, **d}

def dump(d, path):
    d = {**d, 'inherits': ''}
    path.write_text(json.dumps(d, indent=2))
    return str(path)
verts = [(155, 155, 0), (165, 155, 0), (165, 165, 0), (155, 165, 0), (155, 155, 10), (165, 155, 10), (165, 165, 10), (155, 165, 10)]
faces = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
lines = ['solid cube']
for face in faces:
    lines += ['facet normal 0 0 0', 'outer loop'] + ['vertex %s %s %s' % verts[i] for i in face] + ['endloop', 'endfacet']
lines += ['endsolid cube']
(work / 'cube.stl').write_text('\n'.join(lines) + '\n')
for vendor, kind, name in profiles:
    if vendor == 'Qidi':
        resolve(vendor, kind, name)
print('PASS: all indexed QIDI inheritance chains resolve', flush=True)
results = []
for nozzle in ['0.2', '0.4', '0.6', '0.8']:
    out = work / ('nozzle-' + nozzle)
    out.mkdir(exist_ok=True)
    m = resolve('Qidi', 'machine', f'Qidi X-Plus 5 {nozzle} nozzle')
    proc = resolve('Qidi', 'process', m['default_print_profile'])
    fila = resolve('Qidi', 'filament', m['default_filament_profile'][0])
    machine = dump(m, out / 'machine.json')
    process = dump(proc, out / 'process.json')
    filament = dump(fila, out / 'filament.json')
    cmd = [cli, '--datadir', str(out / 'data'), '--debug', '2', '--load-settings', machine + ';' + process, '--load-filaments', filament, '--slice', '0', '--outputdir', str(out), str(work / 'cube.stl')]
    with (out / 'slice.log').open('w') as log:
        r = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    result = {'nozzle': nozzle, 'machine': m['name'], 'process': proc['name'], 'filament': fila['name'], 'exit_code': r.returncode, 'gcode_files': [p.name for p in out.glob('*.gcode')]}
    results.append(result)
    print(json.dumps(result), flush=True)
    if r.returncode:
        print((out / 'slice.log').read_text()[-3500:], flush=True)
    else:
        text = (out / 'plate_1.gcode').read_text()
        if 'Qidi X-Plus 5' not in text or 'MAIN_STATUS=printing' not in text or '!!!!' in text:
            raise ValueError(f'Incomplete G-code or placeholder error: {out}')
(work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(f'Logs, configs and G-code: {work}', flush=True)
raise SystemExit(any((r['exit_code'] for r in results)))
