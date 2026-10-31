#!/usr/bin/env python3
"""Fail closed unless the authenticated registry confirms this new tag is absent."""
import subprocess
import sys

EXPECTED = 'repo.cylo.net/gogs:0.14.2-1'
# gogs:0.14.2, the image behind the current default catalogue version.
CURRENT = 'repo.cylo.net/gogs@sha256:b066557beeedba9901606663a0a890095ffb83612a7bb4632d4f995e615f22e8'
# gogs:latest (Gogs 0.13.2), the image behind the older 0.13.2 catalogue version.
LEGACY = 'repo.cylo.net/gogs@sha256:5c6db62be51088621efdb2731a5d7c23cd7c01b48ef490cf673b72ab14c5fc43'


def require_absent(image):
    if image != EXPECTED:
        raise RuntimeError('Unexpected image reference')
    for baseline in (CURRENT, LEGACY):
        known = subprocess.run(['docker', 'manifest', 'inspect', baseline], capture_output=True, text=True, timeout=90)
        if known.returncode:
            raise RuntimeError('Authenticated registry baseline read failed; state is indeterminate')
    result = subprocess.run(['docker', 'manifest', 'inspect', image], capture_output=True, text=True, timeout=90)
    if result.returncode == 0:
        raise RuntimeError('Release tag exists; refusing replacement')
    if result.stderr.strip() != 'no such manifest: ' + image:
        raise RuntimeError('Registry response is indeterminate; refusing publication')
    print('PASS registry: baselines readable and exact release tag definitively absent', flush=True)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: registry-check.py IMAGE')
    require_absent(sys.argv[1])
