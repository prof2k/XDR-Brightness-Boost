"""Exercise installer identity checks with real disposable signed bundles."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('installer', ROOT / 'Scripts/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def main():
    config = ROOT / '.local-signing-identity'
    if not config.exists():
        print('SKIP: no local signing identity configured')
        return
    identity = config.read_text().strip()
    with tempfile.TemporaryDirectory(prefix='xdr-signing-tests-') as directory:
        def fixture(name, version, signer, identifier=installer.IDENTIFIER):
            app = Path(directory) / (name + '.app')
            executable = app / 'Contents/MacOS/Fixture'
            executable.parent.mkdir(parents=True)
            shutil.copyfile('/usr/bin/true', executable)
            executable.chmod(0o755)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Fixture',
                'CFBundleVersion': version, 'CFBundlePackageType': 'APPL',
            }))
            subprocess.run(['codesign', '--force', '--sign', signer, str(app)], check=True, capture_output=True)
            return app

        old = fixture('old', '1', identity)
        new = fixture('new', '2', identity)
        adhoc = fixture('adhoc', '3', '-')
        different = fixture('different', '4', identity, 'local.test.DifferentApp')
        assert installer.signature(old)[1] == installer.signature(new)[1]
        installer.verify_update_identity(new, old)
        installer.verify_update_identity(new, adhoc)
        try:
            installer.verify_update_identity(adhoc, old)
        except RuntimeError:
            pass
        else:
            raise AssertionError('Ad-hoc replacement was accepted')
        try:
            installer.verify_update_identity(different, old)
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError('A different application identity was accepted')
        print('PASS: stable certificate updates, ad-hoc migration, ad-hoc rejection, identity-change rejection')


if __name__ == '__main__':
    main()
