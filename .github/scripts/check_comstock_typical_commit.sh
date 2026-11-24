#!/usr/bin/env bash
# Checks that `openstudio gem_list`, run through $OPENSTUDIO_EXE, loads comstock-typical from the
# commit pinned in resources/Gemfile ($COMSTOCK_TYPICAL_COMMIT). Matches build/build_apptainer_image.ps1.
set -euo pipefail

: "${OPENSTUDIO_EXE:?OPENSTUDIO_EXE must point to an OpenStudio wrapper}"
: "${COMSTOCK_TYPICAL_COMMIT:?COMSTOCK_TYPICAL_COMMIT must hold the expected commit}"

if ! output="$("$OPENSTUDIO_EXE" gem_list 2>&1)"; then
  echo "$output"
  echo "openstudio gem_list failed" >&2
  exit 1
fi

line="$(grep -E '^[[:space:]]*comstock-typical[[:space:]]' <<<"$output" | head -n 1 || true)"
if [[ -z "$line" ]]; then
  echo "$output"
  echo "comstock-typical is not in the gem list" >&2
  exit 1
fi
echo "$line"

found="$(grep -oE 'ComStock-Typical-[0-9a-fA-F]+' <<<"$line" | head -n 1 | sed 's/^ComStock-Typical-//' || true)"
if [[ -z "$found" ]]; then
  echo "Could not read the comstock-typical commit from the gem path" >&2
  exit 1
fi
if [[ "$found" != "$COMSTOCK_TYPICAL_COMMIT"* && "$COMSTOCK_TYPICAL_COMMIT" != "$found"* ]]; then
  echo "comstock-typical commit in the image is $found, expected $COMSTOCK_TYPICAL_COMMIT" >&2
  exit 1
fi
echo "comstock-typical commit $found matches resources/Gemfile"
