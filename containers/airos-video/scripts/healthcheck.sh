#!/bin/sh
set -e

wget -qO /dev/null http://localhost:9997/v3/paths/list || exit 1
