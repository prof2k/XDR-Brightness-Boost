#!/usr/bin/env python3
"""Opt-in live controller checks. Restores the original panel; no UI permissions needed."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / 'dist/XDR Brightness Boost.app/Contents/Helpers/XDRBrightnessController.app/Contents/MacOS/XDRBrightnessController'
JOURNAL = Path.home() / 'Library/Application Support/XDRBrightness/recovery.json'
RESULTS = ROOT / 'local-results/controller-update'


def run(args):
    return subprocess.check_output([str(arg) for arg in args], text=True, stderr=subprocess.STDOUT, timeout=12).strip()


def capture(name):
    path = RESULTS / (name + '.json')
    run([sys.executable, ROOT / 'Scripts/capture-state.py', path])
    return json.loads(path.read_text())


def restored(before, after, prepared=False):
    a, b = (snapshot['displayProbe']['displays'][0] for snapshot in [before, after])
    for key in ['sessionDisplayID', 'modeLogicalSize', 'modePixelSize', 'gammaReadback']:
        assert a[key] == b[key], key
    if prepared:
        assert after['activePresets'][0]['activePreset']['index'] == 1, 'Prepared preset lost'
    else:
        assert before['activePresets'] == after['activePresets'], 'Preset restoration'
    assert abs(a['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness'] - b['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']) < .005
    for key in ['limit_max_physical_brightness', 'IOMFBIndicatorNitsCap']:
        assert before['panels'][0]['properties'][key] == after['panels'][0]['properties'][key], key
    if prepared:
        record = json.loads(JOURNAL.read_text())
        assert record['sessionPreset'] == before['activePresets'][0]['activePreset']['index']
        assert record['controlsNativeBrightness'] is False
        assert not record['expected'] and not record['previous']
    else:
        assert not JOURNAL.exists()


class Client:
    def __init__(self):
        self.process = subprocess.Popen([str(EXE), '--worker'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.messages = queue.Queue()
        self.request = 0
        self.transcript = []
        threading.Thread(target=self.reader, daemon=True).start()
        self.wait(lambda event: event['state'] == 'off')

    def reader(self):
        for line in self.process.stdout:
            try:
                event = json.loads(line)
                self.transcript.append(event)
                self.messages.put(event)
            except ValueError:
                pass

    def send(self, command, **values):
        if command != 'heartbeat':
            self.request += 1
        self.process.stdin.write(json.dumps({'command': command, 'requestID': self.request, **values}) + '\n')
        self.process.stdin.flush()

    def wait(self, predicate, timeout=6, heartbeat=True):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            if heartbeat and self.process.poll() is None:
                self.send('heartbeat')
            try:
                last = self.messages.get(timeout=.2)
                if last['requestID'] == self.request and predicate(last):
                    return last
                if last['state'] == 'error':
                    raise AssertionError(last)
            except queue.Empty:
                if self.process.poll() is not None:
                    break
        raise AssertionError(f'Expected response absent: {last}; exit={self.process.poll()}')

    def target(self, nits):
        return self.wait(lambda event: event['state'] == 'active' and abs(event.get('reported', -10000) - nits) < 1)

    def hold(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.send('heartbeat')
            time.sleep(.1)
        # Ignore observations queued before the hold elapsed. Require a fresh
        # status so a transient earlier sample is not mistaken for steady state.
        while not self.messages.empty():
            self.messages.get_nowait()
        return self.wait(lambda event: event['state'] == 'active')

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=8) == 0, self.process.stderr.read()


def main():
    RESULTS.mkdir(parents=True, exist_ok=True)
    assert not JOURNAL.exists(), 'Resolve the pending recovery record first'
    before = capture('baseline-0.3')
    native = before['displayProbe']['displays'][0]['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']
    client = None
    trace = None
    all_events = []
    try:
        with (RESULTS / 'ramp-trace.jsonl').open('w') as stream:
            trace = subprocess.Popen([str(ROOT / '.build/watch-panel'), '15'], stdout=stream)
        client = Client()
        start = time.monotonic()
        client.send('enable')
        on = client.wait(lambda event: event['state'] == 'active')
        assert abs(on['percentage'] - min(160, native * 160)) < .1, on
        target = on['requested']
        settled = client.target(target)
        print('PASS: expanded native position and smooth activation', round((time.monotonic() - start) * 1000), 'ms', settled, flush=True)
        # Slider/key input is immediate, and brightness keys span the SDR boundary.
        client.send('set', percentage=100)
        client.target(500)
        start = time.monotonic()
        client.send('adjust', direction=1, fine=False)
        client.target(615)
        print('PASS: brightness up crosses 100%; command latency', round((time.monotonic() - start) * 1000), 'ms', flush=True)
        client.send('adjust', direction=-1, fine=False)
        client.target(500)
        client.send('set', percentage=50)
        client.target(250)
        client.hold(.6)
        client.send('set', percentage=0)
        client.target(0)
        time.sleep(.15)
        client.send('adjust', direction=1, fine=False)
        client.target(31)
        client.send('set', percentage=0)
        client.target(0)
        run([ROOT / '.build/set-native-brightness', '1'])
        client.target(31)
        print('PASS: native up releases the owned zero cap without Accessibility', flush=True)
        client.send('set', percentage=110)
        client.target(683)
        print('PASS: 0%, dimming, and keys recover from black without switching off', flush=True)
        client.send('set', percentage=130)
        client.send('set', percentage=80)
        client.target(400)
        assert abs(client.hold(.6)['reported'] - 400) < 1
        print('PASS: latest slider input wins without debounce', flush=True)
        client.send('disable')
        client.wait(lambda event: event['state'] == 'off')
        restored(before, capture('after-disable-prepared'), prepared=True)
        print('PASS: disable restores brightness and retains the prepared preset', flush=True)
        client.send('enable', nits=1000)
        client.wait(lambda event: event['state'] == 'active')
        client.send('set', percentage=70)
        client.target(350)
        assert abs(client.hold(.6)['reported'] - 350) < 1
        print('PASS: slider interrupts activation ramp with no stale endpoint', flush=True)
        all_events.extend(client.transcript)
        client.close(); client = None
        restored(before, capture('after-eof-0.3'))
        print('PASS: EOF restoration', flush=True)
        client = Client(); client.send('enable', nits=650); client.target(650)
        client.wait(lambda event: event['state'] == 'off', timeout=8, heartbeat=False)
        all_events.extend(client.transcript)
        client.close(); client = None
        restored(before, capture('after-timeout-0.3'))
        print('PASS: heartbeat timeout restoration', flush=True)
        client = Client(); client.send('enable', nits=650); client.target(650)
        client.process.kill(); client.process.wait(timeout=5)
        all_events.extend(client.transcript)
        client = None
        assert JOURNAL.exists()
        print(run([EXE, '--recover']), flush=True)
        restored(before, capture('after-crash-0.3'))
        print('PASS: crash recovery', flush=True)
    finally:
        if client is not None and client.process.poll() is None:
            all_events.extend(client.transcript)
            client.close()
        if JOURNAL.exists():
            print(run([EXE, '--recover']), flush=True)
        if trace is not None:
            trace.wait(timeout=18)
        (RESULTS / 'controller-events.json').write_text(json.dumps(all_events, indent=2) + '\n')


if __name__ == '__main__':
    main()
