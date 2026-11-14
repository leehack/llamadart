#!/usr/bin/env python3
"""Check root-SDK formatting; Studio is checked with its own SDK in CI."""
from pathlib import Path
import subprocess

STUDIO_PACKAGES = frozenset(('llamadart_studio', 'llamadart_studio_core'))


def format_targets(root):
    targets = []
    for path in sorted(root.iterdir()):
        if path.name.startswith('.'):
            continue
        if path.name == 'packages' and path.is_dir():
            targets.extend(str(child.relative_to(root))
                           for child in sorted(path.iterdir())
                           if not child.name.startswith('.')
                           and child.name not in STUDIO_PACKAGES
                           and (child.is_dir() or child.suffix == '.dart'))
        elif path.is_dir() or path.suffix == '.dart':
            targets.append(str(path.relative_to(root)))
    return targets


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[2]
    raise SystemExit(subprocess.call(
        ['dart', 'format', '--output=none', '--set-exit-if-changed',
         *format_targets(root)], cwd=root))
