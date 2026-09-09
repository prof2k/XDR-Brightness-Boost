#!/usr/bin/env python3
"""Opt-in panel test: live readback and requested XDR target stay independent."""
import json
from pathlib import Path
import queue
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / 'dist/XDR Brightness Boost.app/Contents/Helpers/XDRBrightnessController.app/Contents/MacOS/XDRBrightnessController'


def main():
    for name in ['XDRBrightness', 'XDRBrightnessController']:
        assert subprocess.run(['pgrep', '-x', name], capture_output=True).returncode != 0, f'Quit {name} before testing'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-module-cache-path', ROOT / '.build/module-cache',
                    '-import-objc-header', ROOT / 'Sources/NativePanel.h', ROOT / 'Tools/SetNativeBrightness.swift',
                    ROOT / '.build/NativePanel.o', '-framework', 'AppKit', '-framework', 'CoreGraphics',
                    '-framework', 'IOKit', '-o', ROOT / '.build/set-native-brightness'], check=True)

    def snapshot():
        return json.loads(subprocess.check_output([ROOT / '.build/display-probe', '--native']))['displays'][0]

    def native(value):
        subprocess.run([ROOT / '.build/set-native-brightness', str(value)], check=True, timeout=5)

    before = snapshot()
    original = before['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']
    assert all(abs(v - 1) < 0.003 for v in before['gammaReadback']['lastRGB']), 'Test requires a neutral starting white level'
    process = subprocess.Popen([EXE, '--worker'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    events = queue.Queue()
    transcript = []
    request = 0

    def read():
        for line in process.stdout:
            event = json.loads(line)
            transcript.append(event)
            events.put(event)

    threading.Thread(target=read, daemon=True).start()

    def send(command, **values):
        nonlocal request
        if command != 'heartbeat':
            request += 1
        process.stdin.write(json.dumps({'command': command, 'requestID': request, **values}) + '\n')
        process.stdin.flush()

    def wait(state, percentage=None):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            send('heartbeat')
            try:
                event = events.get(timeout=0.1)
            except queue.Empty:
                continue
            assert event['state'] != 'error', event
            if event['requestID'] == request and event['state'] == state and not event.get('ramping', False):
                if percentage is None or abs(event['percentage'] - percentage) < 0.05:
                    return event
        raise AssertionError(f'Missing {state}/{percentage}: {transcript[-4:]}')

    try:
        initial = wait('off')
        native(0.625)
        assert wait('off', 62.5)['requestedPercentage'] == initial['requestedPercentage']
        send('enable', percentage=120)
        assert wait('active', 120)['requestedPercentage'] == 120
        native(0.5)
        assert wait('active', 60)['requestedPercentage'] == 120
        send('disable')
        wait('off', 60)
        send('enable', percentage=120)
        assert wait('active', 120)['requestedPercentage'] == 120
        send('disable')
        assert not wait('off', 100)['boostEnabled']
        send('adjust', direction=1, fine=False)
        assert not wait('off', 100)['boostEnabled']
        send('disable')
        wait('off', 100)
        send('set', percentage=70, activate=False)
        wait('off', 70)
        send('set', percentage=120, activate=True)
        wait('active', 120)
        send('set', percentage=100, activate=False)
        wait('off', 100)
        send('set', percentage=95, activate=False)
        assert wait('off', 95)['boostEnabled']
        send('adjust', direction=1, fine=False)
        assert wait('active', 101.25)['boostEnabled']
        send('set', percentage=120, activate=True)
        wait('active', 120)
        send('set', percentage=65, activate=False)
        assert wait('off', 65)['boostEnabled']
        send('disable')
        assert not wait('off', 65)['boostEnabled']
        send('set', percentage=150, activate=True)
        wait('active', 150)
        hold_until = time.monotonic() + 6
        while time.monotonic() < hold_until:
            send('heartbeat')
            time.sleep(0.1)
        send('heartbeat')
        current = snapshot()
        actual = current['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness'] * max(current['gammaReadback']['lastRGB']) * 100
        assert abs(actual - 150) < 0.1, actual
        # Rapid pointer-like retargets across the boost boundary settle at
        # the final intent, without stale ramps restoring earlier targets.
        for target in [80, 110, 125, 105, 95, 85, 115, 130, 90]:
            send('set', percentage=target, activate=target > 100)
            time.sleep(0.025)
        wait('off', 90)
        send('set', percentage=20, activate=False)
        wait('off', 20)
        send('quit')
        process.wait(timeout=10)
        assert snapshot()['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness'] >= 0.349
    finally:
        if process.poll() is None:
            send('quit')
            process.wait(timeout=10)
        subprocess.run([EXE, '--recover'], check=True, timeout=10)
        native(original)
        output = ROOT / 'local-results/live-readback'
        output.mkdir(parents=True, exist_ok=True)
        (output / 'events.json').write_text(json.dumps(transcript, indent=2))

    after = snapshot()
    assert before['gammaReadback'] == after['gammaReadback'], 'Color curve did not restore'
    assert abs(after['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness'] - original) < 0.005
    for key in ['modePixelSize', 'modeLogicalSize']:
        assert before[key] == after[key]
    print('PASS: live off-state readback, external native change under XDR, independent 120% target, reactivation, brightness/gamma/mode restoration')


if __name__ == '__main__':
    main()
