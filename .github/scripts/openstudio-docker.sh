#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must point to the checked-out repository}"

exec docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "${GITHUB_WORKSPACE}:${GITHUB_WORKSPACE}" \
  --workdir "$PWD" \
  comstock-ci \
  openstudio \
    --bundle /var/oscli/Gemfile \
    --bundle_path /var/oscli/gems \
    --bundle_without test \
    "$@"
