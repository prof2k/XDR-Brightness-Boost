#!/usr/bin/env python3
"""Opt-in live validation of the preset-preserving packaged helper."""
import json
from pathlib import Path
import queue
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / 'dist/XDR Brightness Boost.app/Contents/Helpers/XDRBrightnessController.app/Contents/MacOS/XDRBrightnessController'


def main():
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-module-cache-path', ROOT / '.build/module-cache',
                    '-import-objc-header', ROOT / 'Sources/NativePanel.h', ROOT / 'Tools/SetNativeBrightness.swift',
                    ROOT / '.build/NativePanel.o', '-framework', 'AppKit', '-framework', 'CoreGraphics',
                    '-framework', 'IOKit', '-o', ROOT / '.build/set-native-brightness'], check=True)
    output = ROOT / 'local-results/color-controller'
    output.mkdir(parents=True, exist_ok=True)
    for name in ['BetterDisplay', 'XDRBrightness', 'XDRBrightnessController']:
        assert subprocess.run(['pgrep', '-x', name], capture_output=True).returncode != 0, f'Quit {name} before testing'

    def snapshot(name):
        path = output / f'{name}.json'
        subprocess.run(['python3', ROOT / 'Scripts/capture-state.py', path], check=True, timeout=10)
        return json.loads(path.read_text())

    before = snapshot('before')
    original_native = before['displayProbe']['displays'][0]['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']
    assert before['activePresets'][0]['activePreset']['index'] == 0
    process = subprocess.Popen([EXE, '--worker'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    events = queue.Queue()
    transcript = []
    request = 0

    def reader():
        for line in process.stdout:
            event = json.loads(line)
            transcript.append(event)
            events.put(event)

    threading.Thread(target=reader, daemon=True).start()

    def send(command, **values):
        nonlocal request
        if command != 'heartbeat': request += 1
        process.stdin.write(json.dumps({'command': command, 'requestID': request, **values}) + '\n')
        process.stdin.flush()

    def wait(state, percentage=None):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            send('heartbeat')
            try: event = events.get(timeout=.2)
            except queue.Empty: continue
            assert event['state'] != 'error', event
            if event['requestID'] == request and event['state'] == state and (percentage is None or abs(event['percentage'] - percentage) < .05): return event
        raise AssertionError(f'Missing {state}/{percentage}: {transcript[-4:]}')

    external_change_pending = False
    try:
        wait('off')
        # A drag while off activates at the chosen level, without first
        # publishing the default expanded/max target.
        send('set', percentage=50, activate=True); wait('active', 50)
        assert all(event['percentage'] == 50 for event in transcript if event['state'] == 'active')
        time.sleep(.7)
        for value in [50, 100, 110, 160, 100]:
            send('set', percentage=value); wait('active', value)
            time.sleep(.25)
            state = snapshot(f'level-{value}')
            assert state['activePresets'][0]['activePreset']['index'] == 0
            endpoint = state['displayProbe']['displays'][0]['gammaReadback']['lastRGB'][0]
            expected = 1 + max(0, value - 100) / 100
            assert abs(endpoint - expected) < .005, (value, endpoint, expected)
        send('adjust', direction=1); wait('active', 106.25)
        send('disable'); wait('off')
        # The menu's saved intent wins over a later native brightness change.
        external_change_pending = True
        subprocess.run([ROOT / '.build/set-native-brightness', '0.625'], check=True, timeout=5)
        time.sleep(.25)
        send('enable', percentage=106.25); wait('active', 106.25)
        time.sleep(.4)
        send('disable'); wait('off')
        subprocess.run([ROOT / '.build/set-native-brightness', str(original_native)], check=True, timeout=5)
        time.sleep(.25)
        external_change_pending = False
        send('set', percentage=115, activate=True); wait('active', 115)
        # A killed worker must leave a recoverable record.
        process.kill(); process.wait(timeout=5)
        subprocess.run([EXE, '--recover'], check=True, timeout=10)
    finally:
        if process.poll() is None:
            send('quit'); process.wait(timeout=10)
        subprocess.run([EXE, '--recover'], check=True, timeout=10)
        if external_change_pending:
            subprocess.run([ROOT / '.build/set-native-brightness', str(original_native)], check=True, timeout=5)
        (output / 'events.json').write_text(json.dumps(transcript, indent=2))
    time.sleep(.5)
    after = snapshot('after')
    assert before['activePresets'] == after['activePresets']
    a, b = [s['displayProbe']['displays'][0] for s in [before, after]]
    for key in ['gammaReadback', 'modePixelSize', 'modeLogicalSize']:
        assert a[key] == b[key], key
    key = 'DisplayServicesGetBrightness'
    assert abs(a['unsupportedReadOnlyAPI'][key] - b['unsupportedReadOnlyAPI'][key]) < .005
    print('PASS: drag activation, saved target after external brightness change, 50–160% range, key-adjust protocol, crash recovery, preset/gamma/native restoration')


if __name__ == '__main__':
    main()
