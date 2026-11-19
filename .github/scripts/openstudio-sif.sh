#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must point to the checked-out repository}"

exec docker run --rm --privileged \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume /etc/passwd:/etc/passwd:ro \
  --volume /etc/group:/etc/group:ro \
  --volume "${GITHUB_WORKSPACE}:${GITHUB_WORKSPACE}" \
  --workdir "$PWD" \
  apptainer-ci apptainer exec \
    --home /tmp \
    --bind "${GITHUB_WORKSPACE}:${GITHUB_WORKSPACE}" \
    "${GITHUB_WORKSPACE}/build/comstock-ci.sif" \
    openstudio \
      --bundle /var/oscli/Gemfile \
      --bundle_path /var/oscli/gems \
      --bundle_without test \
      "$@"
