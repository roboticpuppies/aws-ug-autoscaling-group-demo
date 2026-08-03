#!/usr/bin/env bash
#
# Runs as root inside the Packer build instance. Everything installed here is
# something the demo would otherwise have to install at boot, on stage.
set -euo pipefail

log() {
  echo "[provision] $*"
}

log "updating base packages"
dnf -y update

log "installing docker and stress-ng"
dnf -y install docker stress-ng

# AL2023 already ships AWS CLI v2. Install explicitly anyway so the AMI's
# contents are not left to base-image drift, but tolerate the package being
# absent or already satisfied -- the assertion below is what actually matters.
log "ensuring AWS CLI v2 is present"
dnf -y install awscli-2 || log "awscli-2 not installed via dnf; relying on the preinstalled CLI"

log "enabling docker"
systemctl enable --now docker

# Pre-pull the web server image so user-data's docker pull is a cache hit and
# scale-out is fast in front of an audience.
log "pre-pulling nginx:alpine"
docker pull nginx:alpine

log "asserting the AMI contains what the demo needs"
docker --version
stress-ng --version
aws --version

# Hard-fail the build if the CLI is not v2. v1 has different command output and
# would break the lifecycle-hook calls in user-data.
if ! aws --version 2>&1 | grep -q 'aws-cli/2'; then
  log "ERROR: AWS CLI v2 is required but not present"
  exit 1
fi

log "verifying nginx:alpine is in the local image cache"
docker image inspect nginx:alpine >/dev/null

log "done"
