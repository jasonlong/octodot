#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <tag> [output-path]" >&2
  exit 1
fi

tag="$1"
output_path="${2:-}"

repo_slug="${GITHUB_REPOSITORY:-jasonlong/octodot}"
compare_base=""

previous_tag="$(git describe --tags --abbrev=0 "${tag}^" 2>/dev/null || true)"

if [[ -n "$previous_tag" ]]; then
  compare_base="${previous_tag}...${tag}"
  commit_range="${previous_tag}..${tag}"
else
  compare_base="${tag}"
  commit_range="${tag}"
fi

commit_subjects=("${(@f)$(git log --format=%s --no-merges "$commit_range")}")

if [[ ${#commit_subjects[@]} -eq 0 ]]; then
  commit_subjects=("Maintenance release")
fi

notes=""
notes+=$'## Highlights\n'
for subject in "${commit_subjects[@]}"; do
  notes+="- ${subject}"$'\n'
done

notes+=$'\n'
notes+=$'## Download\n'
notes+="- Download \`Octodot-${tag}-macos.zip\` from the assets below."$'\n'
notes+=$'\n'
notes+=$'## Full Changelog\n'
if [[ -n "$previous_tag" ]]; then
  notes+="https://github.com/${repo_slug}/compare/${compare_base}"$'\n'
else
  notes+="https://github.com/${repo_slug}/releases/tag/${tag}"$'\n'
fi

if [[ -n "$output_path" ]]; then
  printf '%s\n' "$notes" > "$output_path"
else
  printf '%s\n' "$notes"
fi
