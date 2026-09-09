#!/usr/bin/env python3
"""Bounded native-control experiment; independent process restores after a crash."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
EXE = str(ROOT / '.build/native-control-experiment')
BD = '/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay'
DIRECTORY = ROOT / 'local-results/native-experiment-isolated'
SNAPSHOT = DIRECTORY / 'recovery.json'
LEASE = DIRECTORY / 'lease.json'


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=8)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name}: {result.stderr.strip()} {result.stdout.strip()}')
    return result.stdout.strip()


def bd(action, feature):
    return run([BD, action, '-displayID=1', '-' + feature])


def capture(name):
    run([sys.executable, str(ROOT / 'Scripts/capture-state.py'), str(DIRECTORY / f'{name}.json')])


def restore():
    state = json.loads(LEASE.read_text())
    failures = []
    if SNAPSHOT.exists():
        try:
            print(run([EXE, 'restore', str(SNAPSHOT)]), flush=True)
        except Exception as error:
            failures.append(str(error))
    try:
        run(['/usr/bin/open', '-a', '/Applications/BetterDisplay.app'])
        time.sleep(1)
    except Exception as error:
        failures.append(str(error))
    for feature in [f'brightnessUpscaling={state["upscaling"]}', f'brightness={state["brightness"]}']:
        try:
            bd('set', feature)
        except Exception as error:
            failures.append(str(error))
    if failures:
        raise RuntimeError('; '.join(failures))
    LEASE.unlink()
    print('Original settings restored.', flush=True)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--guard':
        parent = int(sys.argv[2])
        deadline = time.monotonic() + 45
        while LEASE.exists() and time.monotonic() < deadline:
            try:
                os.kill(parent, 0)
            except ProcessLookupError:
                break
            time.sleep(0.5)
        if LEASE.exists():
            restore()
        return
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    if LEASE.exists():
        raise RuntimeError('A prior recovery lease exists; resolve it before another test')
    SNAPSHOT.unlink(missing_ok=True)
    state = {'brightness': bd('get', 'brightness'), 'upscaling': bd('get', 'brightnessUpscaling')}
    if state['upscaling'] not in ('on', 'off', 'true', 'false'):
        raise RuntimeError(f'Unrecognized BetterDisplay mode: {state["upscaling"]}')
    capture('before')
    LEASE.write_text(json.dumps(state))
    os.chmod(LEASE, 0o600)
    with (DIRECTORY / 'guard.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, __file__, '--guard', str(os.getpid())], stdout=log, stderr=log, start_new_session=True)
    try:
        bd('set', 'brightnessUpscaling=off')
        run(['/usr/bin/osascript', '-e', 'tell application id "pro.betterdisplay.BetterDisplay" to quit'])
        time.sleep(1)
        capture('without-betterdisplay')
        print(run([EXE, 'prepare', str(SNAPSHOT)]), flush=True)
        time.sleep(1)
        for target in [200, 650]:
            print(f'Target {target}: {run([EXE, "set", str(target)])}', flush=True)
            time.sleep(2)
            capture(f'target-{target}')
    finally:
        restore()
        guard.wait(timeout=3)
        time.sleep(1)
        capture('restored')


if __name__ == '__main__':
    main()
