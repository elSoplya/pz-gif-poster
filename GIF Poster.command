#!/usr/bin/env bash
# Double-click launcher for gifposter.py's interactive mode. Keep it next to gifposter.py.
exec python3 "$(cd "$(dirname "$0")" && pwd)/gifposter.py"
