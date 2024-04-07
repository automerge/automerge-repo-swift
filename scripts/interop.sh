#!/usr/bin/env bash
set -eou pipefail

# see https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
THIS_SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
REPO_DIR=$THIS_SCRIPT_DIR/../

docker run -d --name syncserver -p 3030:3030 ghcr.io/heckj/automerge-repo-sync-server:main
