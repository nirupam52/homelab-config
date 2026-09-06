#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
if ! python3 -B -c '
import sys
if sys.version_info < (3, 8):
    print(
        "hardening: Python 3.8 or newer is required "
        "(found {})".format(sys.version.split()[0]),
        file=sys.stderr,
    )
    raise SystemExit(1)
'; then
    exit 1
fi
exec python3 -B -m hardening.apply "$@"
