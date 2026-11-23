#!/usr/bin/env bash
# Creates the labels of a labels file, and updates the colour and description of those that exist.
# It never deletes one.
#
#   GH_TOKEN=... GH_REPO=owner/repo tool/ci/sync_labels.sh .github/labels.yml
#
# Needs gh and yq (mikefarah's), which the GitHub-hosted runners have. A label's name, colour (six hex
# digits, no #) and description are read with yq.
set -euo pipefail

file="${1:?usage: $0 <labels.yml>}"
: "${GH_REPO:?set GH_REPO to owner/repo}"

count="$(yq 'length' "$file")"
echo "Syncing $count label(s) from $file to $GH_REPO"

for i in $(seq 0 $((count - 1))); do
  name="$(yq ".[$i].name" "$file")"
  color="$(yq ".[$i].color" "$file")"
  description="$(yq ".[$i].description // \"\"" "$file")"
  gh label create "$name" --color "$color" --description "$description" --force
done

existing="$(gh label list --limit 500 --json name --jq '.[].name' | sort)"
wanted="$(yq '.[].name' "$file" | sort)"
extra="$(comm -23 <(printf '%s\n' "$existing") <(printf '%s\n' "$wanted"))"
if [ -n "$extra" ]; then
  echo "Labels not in $file (left as they are):"
  sed 's/^/  /' <<<"$extra"
fi
