#!/usr/bin/env python3
"""Create a source-only archive from explicit public paths; never invokes Git."""
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parent.parent
PATHS = ['README.md', 'CONTRIBUTING.md', '.gitignore', 'Docs', 'Resources',
         'Scripts', 'Sources', 'Tests', 'Tools', 'Vendor']


def main():
    destination = ROOT / 'dist/XDR-Brightness-Boost-source.tar.gz'
    destination.parent.mkdir(exist_ok=True)
    paths = PATHS + (['LICENSE'] if (ROOT / 'LICENSE').is_file() else [])
    with tarfile.open(destination, 'w:gz') as archive:
        for name in paths:
            path = ROOT / name
            files = [path] if path.is_file() else sorted(path.rglob('*'))
            for item in files:
                if item.is_symlink():
                    raise RuntimeError(f'Symlinks are not allowed in source packages: {item}')
                if not item.is_file() or '__pycache__' in item.parts or item.name == '.DS_Store' or item.suffix == '.pyc':
                    continue
                archive.add(item, arcname=str(Path('XDR-Brightness-Boost') / item.relative_to(ROOT)), recursive=False)
    print(destination)
    if not (ROOT / 'LICENSE').is_file():
        print('Project license is still undecided; resolve before an open-source release.')


if __name__ == '__main__':
    main()
