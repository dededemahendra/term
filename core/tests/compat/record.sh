#!/bin/sh
# Records a real program into a fixture at 80x24, the size the runner uses.
# Usage: record.sh NAME COMMAND [ARGS...]
# Example: record.sh vim-quit vim -u NONE -c ':q'
# Only deterministic programs make stable fixtures. Review the resulting
# .snap by eye before committing; the recording includes echoed input.
set -eu
cd "$(dirname "$0")"
name=$1
shift
stty cols 80 rows 24
script -q "$name.in" "$@"
