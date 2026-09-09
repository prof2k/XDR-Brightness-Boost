#!/usr/bin/env python3
"""Read display state into a local diagnostic file. Does not alter the display."""
import json
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
output = pathlib.Path(sys.argv[1])
probe = json.loads(subprocess.check_output([root / '.build/display-probe', '--native']))
presets = json.loads(subprocess.check_output([root / '.build/display-preset-probe']))
registry = plistlib.loads(subprocess.check_output(['ioreg', '-a', '-r', '-c', 'AppleCLCD2']))
terms = ('brightness', 'luminance', 'nits', 'backlight', 'gamma', 'edr', 'hdr', 'contrast', 'colorremap')
panels = []
for entry in registry:
    properties = {key: value for key, value in entry.items()
                  if isinstance(value, (bool, int, float))
                  or (any(term in key.lower() for term in terms) and isinstance(value, str))}
    panels.append({'registryEntryID': entry.get('IORegistryEntryID'), 'properties': properties})
result = {'displayProbe': probe, 'activePresets': [
    {'sessionDisplayID': d['sessionDisplayID'], 'activePreset': d['activePreset']}
    for d in presets], 'panels': panels}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print(output)
