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

release_engineering_commits=()
onboarding_commits=()
settings_commits=()
remaining_subjects=()

for subject in "${commit_subjects[@]}"; do
  if [[ "$subject" == "Bump version to "* || "$subject" == "Bump to "* ]]; then
    continue
  elif [[ "$subject" == *signing* || "$subject" == *notariz* || "$subject" == *stapler* || "$subject" == *"archive export"* || "$subject" == *entitlements* || "$subject" == *"notarized releases"* || "$subject" == *"for CI"* ]]; then
    release_engineering_commits+=("$subject")
  elif [[ "$subject" == *"first run"* || "$subject" == *first-run* || "$subject" == *"panel automatically"* || "$subject" == *"QA mode"* ]]; then
    onboarding_commits+=("$subject")
  elif [[ "$subject" == *settings* || "$subject" == *"window behavior"* ]]; then
    settings_commits+=("$subject")
  else
    remaining_subjects+=("$subject")
  fi
done

highlights=()

if [[ ${#release_engineering_commits[@]} -gt 0 ]]; then
  highlights+=("Developer ID signing, notarization, and stapled GitHub release builds now run automatically in CI")
fi

if [[ ${#onboarding_commits[@]} -gt 0 ]]; then
  highlights+=("First-run onboarding is smoother, including automatic panel opening and a clean first-run QA mode")
fi

if [[ ${#settings_commits[@]} -gt 0 ]]; then
  highlights+=("Settings window behavior and presentation were tightened up")
fi

for subject in "${remaining_subjects[@]}"; do
  highlights+=("$subject")
done

if [[ ${#highlights[@]} -eq 0 ]]; then
  highlights=("Maintenance release")
fi

notes=""
notes+=$'## Highlights\n'
for subject in "${highlights[@]}"; do
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
