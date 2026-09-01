#!/usr/bin/env bash
# shellcheck shell=bash

set -eo pipefail

if [[ "${HOST_OS^^}" == "DARWIN" ]]; then
    # Sync container back to repository
    echo "Syncing container back to repository"
    rsync -hrPti --update --fsync --exclude buildroot --exclude .git --exclude dist --exclude .patch-work --exclude tmp --exclude dev-docs /work/ /mnt | tee -a /tmp/sync.log
    echo "Syncing repository to container"
    rsync -hrPti --delete --update --fsync --exclude buildroot --exclude .git --exclude dist --exclude .patch-work --exclude tmp --exclude dev-docs /mnt/ /work | tee -a /tmp/sync.log
else
    echo "sync.sh is only used on macOS"
    exit 1
fi
