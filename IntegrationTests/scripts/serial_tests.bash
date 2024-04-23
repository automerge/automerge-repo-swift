#!/usr/bin/env bash

# bash "strict" mode
# https://gist.github.com/mohanpedala/1e2ff5661761d3abd0385e8223e16425
set -euxo pipefail

THIS_SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
cd ${THIS_SCRIPT_DIR}/..

TEST_LIST=$(swift test list)
for TESTNAME in ${TEST_LIST}
do
    swift test --filter ${TESTNAME}
    sleep 1
done
