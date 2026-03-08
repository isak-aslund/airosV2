#!/bin/sh
set -e

# Check that mavlink-routerd is running
pgrep -x mavlink-routerd > /dev/null || exit 1

# Check that the ACC main process is running
pgrep -f acc_main.py > /dev/null || exit 1
