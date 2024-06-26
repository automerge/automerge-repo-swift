#!/usr/bin/env bash
set -eou pipefail

# see https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
THIS_SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
PACKAGE_PATH=$THIS_SCRIPT_DIR/../
# BUILD_DIR=$PACKAGE_PATH/.build

#echo "THIS_SCRIPT_DIR= ${THIS_SCRIPT_DIR}"
#echo "PACKAGE_PATH = ${PACKAGE_PATH}"
#echo "BUILD_DIR = ${BUILD_DIR}"
pushd ${PACKAGE_PATH}

$(xcrun --find swift) package --disable-sandbox plugin preview-documentation 