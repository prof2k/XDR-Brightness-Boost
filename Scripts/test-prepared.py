#!/usr/bin/env python3
"""Opt-in panel tests for prepared toggles and recovery while boost is off."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('controller', ROOT / 'Scripts/test-controller.py')
test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(test)
RESULTS = ROOT / 'local-results/prepared-toggles'


def standby(client, seconds=0.8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        client.send('heartbeat')
        time.sleep(0.1)


def off(client):
    client.send('disable')
    event = client.wait(lambda value: value['state'] == 'off')
    assert event['prepared'], event
    return event


def main():
    RESULTS.mkdir(parents=True, exist_ok=True)
    assert not test.JOURNAL.exists(), 'Resolve existing recovery before testing'
    before = test.capture('before-prepared-suite')
    original_native = before['displayProbe']['displays'][0]['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']
    client = None
    trace = None
    events = []
    try:
        client = test.Client()
        client.send('enable', nits=650)
        client.target(650)
        off(client)
        standby(client)
        test.restored(before, test.capture('prepared-first-off'), prepared=True)
        # Trace only the already-prepared period. Any preset 0 sample would
        # expose a regression that restores/reselects it during a toggle.
        with (RESULTS / 'repeated-toggle-trace.jsonl').open('w') as stream:
            trace = subprocess.Popen([str(ROOT / '.build/watch-panel'), '5'], stdout=stream)
            for _ in range(3):
                client.send('enable', nits=650)
                event = client.target(650)
                timing = event['activationMilliseconds']
                assert timing['initialLevelApplied'] < 120, timing
                print('Prepared first write:', round(timing['initialLevelApplied'], 2), 'ms', flush=True)
                off(client)
                standby(client, 0.35)
            # New input and disable must cancel a pending native handoff;
            # an old completion must never brighten an off/prepared display.
            client.send('enable', nits=1000)
            client.wait(lambda value: value['state'] == 'active')
            client.send('set', percentage=80)
            client.send('set', percentage=70)
            client.target(350)
            off(client)
            standby(client)
            test.restored(before, test.capture('off-cancels-native-handoff'), prepared=True)
            print('PASS: disable cancels a pending handoff without replaying the old target', flush=True)
            # Redundant off is idempotent and retains the recovery information.
            off(client)
            while trace.poll() is None:
                standby(client, 0.2)
            assert trace.returncode == 0
        samples = [json.loads(line) for line in (RESULTS / 'repeated-toggle-trace.jsonl').read_text().splitlines()]
        assert samples and all(value['preset'] == 1 and value['awake'] for value in samples)
        assert len({value['mode'] for value in samples}) == 1
        print('PASS: repeated toggles retain the preset and display mode', flush=True)

        test.run([ROOT / '.build/set-native-brightness', '0.625'])
        standby(client)
        manual = test.capture('manual-brightness-while-prepared')
        scalar = manual['displayProbe']['displays'][0]['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']
        assert abs(scalar - 0.625) < 0.005
        client.send('enable')
        assert abs(client.target(500)['percentage'] - 100) < 0.1
        off(client)
        standby(client)
        expected = copy.deepcopy(before)
        expected['displayProbe']['displays'][0]['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness'] = scalar
        events.extend(client.transcript)
        client.send('quit')
        client.wait(lambda value: value['state'] == 'off' and not value['prepared'])
        assert client.process.wait(timeout=8) == 0
        client = None
        test.restored(expected, test.capture('quit-after-manual-prepared-brightness'))
        print('PASS: reactivation adopts off-state brightness; quit preserves it and restores the original preset', flush=True)

        test.run([ROOT / '.build/set-native-brightness', str(original_native)])
        client = test.Client()
        client.send('enable', nits=650)
        client.target(650)
        off(client)
        client.process.kill()
        client.process.wait(timeout=5)
        events.extend(client.transcript)
        client = None
        assert test.JOURNAL.exists()
        test.run([test.EXE, '--recover'])
        test.restored(before, test.capture('crash-while-prepared'))
        print('PASS: crash recovery while boost is off restores the original preset', flush=True)
    finally:
        if client is not None and client.process.poll() is None:
            client.close()
        if test.JOURNAL.exists():
            print(test.run([test.EXE, '--recover']), flush=True)
        test.run([ROOT / '.build/set-native-brightness', str(original_native)])
        if trace is not None and trace.poll() is None:
            trace.wait(timeout=7)
        (RESULTS / 'controller-events.json').write_text(json.dumps(events, indent=2) + '\n')
    test.restored(before, test.capture('after-prepared-suite'))


if __name__ == '__main__':
    main()
