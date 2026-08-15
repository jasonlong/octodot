#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <tag>" >&2
  exit 1
fi

tag="$1"

if ! printf '%s\n' "$tag" | grep -Eq '^v(0|[1-9][0-9]{0,17})\.(0|[1-9][0-9]{0,17})\.(0|[1-9][0-9]{0,17})$'; then
  echo "Release tag must use canonical stable vMAJOR.MINOR.PATCH format: $tag" >&2
  exit 1
fi
