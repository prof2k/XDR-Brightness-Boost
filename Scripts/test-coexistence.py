#!/usr/bin/env python3
"""Opt-in coexistence checks; expects BetterDisplay initially closed and restores panel state."""
import json
from pathlib import Path
import subprocess
import sys
import time
import os
os.chdir(Path(__file__).resolve().parent.parent)
import importlib.util
spec=importlib.util.spec_from_file_location('controller_test',Path.cwd()/'Scripts/test-controller.py')
test=importlib.util.module_from_spec(spec);spec.loader.exec_module(test)
Client,capture,restored,run,EXE,JOURNAL = test.Client,test.capture,test.restored,test.run,test.EXE,test.JOURNAL

assert subprocess.run(['pgrep','-x','BetterDisplay'],capture_output=True).returncode != 0, 'This scenario expects BetterDisplay initially closed'
before=capture('before-coexistence')
client=None
started_bd=False
try:
    client=Client();client.send('enable',nits=650);client.target(650)
    run([Path.cwd()/'.build/set-native-brightness','0.8'])
    client.hold(.8)
    external=capture('external-native-adjustment')
    scalar=external['displayProbe']['displays'][0]['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']
    assert abs(scalar-.8)<.005, 'Controller fought the external native adjustment'
    print('PASS: native brightness adjustment leaves control on and is not overwritten',flush=True)
    client.send('adjust',direction=1,fine=False);client.target(431)
    print('PASS: next owned key command resumes full-range control',flush=True)
    run(['/usr/bin/open','/Applications/BetterDisplay.app']);started_bd=True
    client.hold(2)
    print('PASS: launching BetterDisplay leaves the switch on',flush=True)
    client.send('disable');client.wait(lambda e:e['state']=='off')
    client.send('enable',nits=650);client.target(650)
    print('PASS: enabling while BetterDisplay is running is allowed',flush=True)
    run(['/usr/bin/osascript','-e','tell application id "pro.betterdisplay.BetterDisplay" to quit']);started_bd=False
    client.hold(.5)
    client.send('set',percentage=160);client.target(1600)
    time.sleep(.2)
    client.send('set',percentage=90);client.target(450)
    print('PASS: 160% reaches 1600 native readback and returns below 100%',flush=True)
    client.close();client=None
finally:
    if started_bd:
        run(['/usr/bin/osascript','-e','tell application id "pro.betterdisplay.BetterDisplay" to quit'])
    if client is not None and client.process.poll() is None:
        client.close()
    if JOURNAL.exists():
        print(run([EXE,'--recover']))
    scalar=before['displayProbe']['displays'][0]['unsupportedReadOnlyAPI']['DisplayServicesGetBrightness']
    run([Path.cwd()/'.build/set-native-brightness',scalar])
    restored(before,capture('after-coexistence'))
print('Coexistence checks complete; BetterDisplay returned to its initially closed state.',flush=True)
