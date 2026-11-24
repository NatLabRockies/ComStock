#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must point to the checked-out repository}"

# --network none: run OpenStudio offline to prove simulations make no network calls at run time.
# The CI image may be built without the NREL root certificates (see ci_dockerfile.py); if runs
# never use the network, the SIF behaves the same on Kestrel as one built on the NREL network.
# A connection error here means something does reach out, and the image should get the certificates
# (the NREL_ROOT_CERT and NREL_XCA1_CERT secrets in container-build.yml).
exec docker run --rm --privileged \
  --network none \
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
