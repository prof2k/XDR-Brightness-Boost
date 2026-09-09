#!/usr/bin/env python3
"""Opt-in, bounded color-table experiment. Requires the existing XDR preset.

This is a diagnostic, not a production brightness engine. The parent process
restores the saved table if the probe crashes or exceeds its time limit.
"""
import datetime
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / '.build/preset-preserving-probe'


def main():
    for name in ['XDRBrightness', 'XDRBrightnessController', 'BetterDisplay', 'BrightIntosh']:
        assert subprocess.run(['pgrep', '-x', name], capture_output=True).returncode != 0, f'Quit {name} before testing'
    directory = ROOT / 'local-results/preset-preserving' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    directory.mkdir(parents=True)
    snapshot = directory / 'gamma-recovery.json'

    def capture(name):
        path = directory / f'{name}.json'
        subprocess.run(['python3', ROOT / 'Scripts/capture-state.py', path], check=True, timeout=10)
        return json.loads(path.read_text())

    before = capture('before')
    assert before['activePresets'][0]['activePreset']['index'] == 0, 'Select Apple XDR Display before testing'
    try:
        with (directory / 'trace.jsonl').open('w') as output:
            subprocess.run([PROBE, 'run', snapshot], stdout=output, check=True, timeout=15)
    finally:
        if snapshot.exists():
            subprocess.run([PROBE, 'restore', snapshot], check=True, timeout=10)
        time.sleep(0.5)
        after = capture('after')

    assert before['activePresets'] == after['activePresets'], 'Preset restoration failed'
    a, b = [value['displayProbe']['displays'][0] for value in [before, after]]
    for field in ['gammaReadback', 'modeLogicalSize', 'modePixelSize']:
        assert a[field] == b[field], f'{field} changed'
    scalar = 'DisplayServicesGetBrightness'
    assert abs(a['unsupportedReadOnlyAPI'][scalar] - b['unsupportedReadOnlyAPI'][scalar]) < 0.005
    rows = [json.loads(line) for line in (directory / 'trace.jsonl').read_text().splitlines()]
    assert len(rows) == 315 and all(row['preset'] == 0 and row['awake'] for row in rows)
    print('PASS: 315 samples retained XDR preset and awake state; gamma, mode and brightness restored')
    clipped = any(row['factor'] > 1 and row['gammaThreeQuarter'] >= row['gammaEndpoint'] for row in rows)
    print('REJECT candidate: gamma highlight entries collapse' if clipped else 'Further visual validation required')
    print(directory)


if __name__ == '__main__':
    main()
