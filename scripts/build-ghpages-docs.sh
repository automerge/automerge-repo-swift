#!/usr/bin/env bash
set -eou pipefail

# see https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
THIS_SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
PACKAGE_PATH=$THIS_SCRIPT_DIR/../
BUILD_DIR=$PACKAGE_PATH/.build

#echo "THIS_SCRIPT_DIR= ${THIS_SCRIPT_DIR}"
#echo "PACKAGE_PATH = ${PACKAGE_PATH}"
#echo "BUILD_DIR = ${BUILD_DIR}"
pushd ${PACKAGE_PATH}

# Enables deterministic output
# - useful when you're committing the results to host on github pages
export DOCC_JSON_PRETTYPRINT=YES

# LEGACY WAY OF DOING THIS
# mkdir -p "${BUILD_DIR}/symbol-graphs"

# $(xcrun --find swift) build --target AutomergeRepo \
#    -Xswiftc -emit-symbol-graph \
#    -Xswiftc -emit-symbol-graph-dir -Xswiftc "${BUILD_DIR}/symbol-graphs"

# $(xcrun --find docc) convert Sources/AutomergeRepo/Documentation.docc \
#     --output-path ./docs \
#     --fallback-display-name AutomergeRepo \
#     --fallback-bundle-identifier com.github.automerge.automerge-repo-swift \
#     --fallback-bundle-version 0.0.1 \
#     --additional-symbol-graph-dir "${BUILD_DIR}/symbol-graphs" \
#     --emit-digest \
#     --transform-for-static-hosting \
#     --hosting-base-path 'automerge-repo-swift'

$(xcrun --find swift) package \
    --allow-writing-to-directory ./docs \
    generate-documentation \
    --fallback-bundle-identifier com.github.automerge.automerge-repo-swift \
    --target AutomergeRepo \
    --output-path ${PACKAGE_PATH}/docs \
    --emit-digest \
    --hosting-base-path 'automerge-repo-swift'
#    --disable-indexing \

# The following options are Swift 5.8  *only* and add github reference
# links to the hosted documentation.
#    --source-service github \
#    --source-service-base-url https://github.com/automerge/automerge-repo-swift/blob/main \
#    --checkout-path ${PACKAGE_PATH}

