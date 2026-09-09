#!/usr/bin/env python3
"""Install only a successfully built and signed XDR Brightness bundle."""
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'dist/XDR Brightness Boost.app'
DESTINATION = Path('/Applications/XDR Brightness Boost.app')
IDENTIFIER = 'local.elijah.XDRBrightness'


def signature(bundle):
    result = subprocess.run(['codesign', '-dvv', '-r-', str(bundle)],
                            check=True, capture_output=True, text=True)
    output = result.stdout + result.stderr
    requirement = re.search(r'^(?:# )?designated => (.+)$', output, re.MULTILINE)
    if requirement is None:
        raise RuntimeError('Cannot determine code identity; refusing installation')
    return 'Signature=adhoc' in output, requirement.group(1)


def verify_update_identity(source, destination=None):
    adhoc, _ = signature(source)
    if adhoc:
        raise RuntimeError('Refusing to install an ad-hoc build: rebuilding changes its macOS permission identity. Configure .local-signing-identity and rebuild.')
    if destination is not None and destination.exists():
        previous_adhoc, requirement = signature(destination)
        if previous_adhoc:
            print('Migrating from ad-hoc to certificate signing; macOS may require one final permission approval.')
        else:
            # Require the update to satisfy the installed app's identity, not
            # merely to possess an internally valid signature and bundle ID.
            subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(source)], check=True)


def metadata(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())


def digest(bundle):
    return {relative: hashlib.sha256((bundle / relative).read_bytes()).hexdigest()
            for relative in ['Contents/MacOS/XDRBrightness', 'Contents/MacOS/xdr-ddc', 'Contents/Helpers/XDRBrightnessController.app/Contents/MacOS/XDRBrightnessController']}


def verify(bundle):
    if metadata(bundle)['CFBundleIdentifier'] != IDENTIFIER:
        raise RuntimeError('Unexpected application identity')
    subprocess.run(['codesign', '--verify', '--strict', '--deep', str(bundle)], check=True)


def matching_app_running():
    return subprocess.run(['pgrep', '-f', r'^/Applications/XDR Brightness Boost\.app/Contents/MacOS/XDRBrightness($| )'], capture_output=True).returncode == 0


def main():
    verify(SOURCE)
    expected = digest(SOURCE)
    if DESTINATION.is_symlink():
        raise RuntimeError('Refusing to replace an application symlink')
    if DESTINATION.exists():
        if metadata(DESTINATION)['CFBundleIdentifier'] != IDENTIFIER:
            raise RuntimeError('Another app owns the destination')
    verify_update_identity(SOURCE, DESTINATION)
    staging = Path(tempfile.mkdtemp(prefix='.XDRBrightness-', dir='/Applications'))
    prepared = staging / DESTINATION.name
    backup = staging / 'previous.app'
    try:
        subprocess.run(['ditto', str(SOURCE), str(prepared)], check=True)
        verify(prepared)
        if digest(prepared) != expected:
            raise RuntimeError('Staged executable differs from build')
        if matching_app_running():
            subprocess.run(['osascript', '-e', f'tell application id "{IDENTIFIER}" to quit'], check=True, timeout=10)
            deadline = time.monotonic() + 8
            while matching_app_running() and time.monotonic() < deadline:
                time.sleep(0.2)
            if matching_app_running():
                raise RuntimeError('The installed app has not completed shutdown')
        if DESTINATION.exists():
            DESTINATION.rename(backup)
        try:
            prepared.rename(DESTINATION)
            verify(DESTINATION)
            if digest(DESTINATION) != expected:
                raise RuntimeError('Installed executable differs from build')
        except Exception:
            if backup.exists():
                if DESTINATION.exists():
                    shutil.rmtree(DESTINATION)
                backup.rename(DESTINATION)
            raise
        print(f'Installed: {DESTINATION}')
        print(f'Version: {metadata(DESTINATION)["CFBundleShortVersionString"]} ({metadata(DESTINATION)["CFBundleVersion"]})')
        for name, value in expected.items():
            print(f'SHA-256 {name}: {value}')
    finally:
        if backup.exists() and not DESTINATION.exists():
            backup.rename(DESTINATION)
        shutil.rmtree(staging)


if __name__ == '__main__':
    main()
