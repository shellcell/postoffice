#!/usr/bin/env bash
#
# Adopt the assets of a published GitHub Release into this workspace.
#
#   bin/adopt-release.sh shellcell/snailmail v0.1.2
#
# Every artifact is pinned to the digest listed in the release's own SHA256SUMS.
# That file is the one thing this script trusts: if it is wrong, the wrong bytes
# are pinned. Sign it in the producing repository if that matters to you, and
# verify the signature here before adopting.
#
# Nothing is published. This only records desired state, which is then reviewed
# as a diff and applied by the publish workflow.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <owner/repo> <tag>" >&2
    exit 2
fi

repository=$1
tag=$2
snailmail=${SNAILMAIL:-snailmail}
workspace=$(cd "$(dirname "$0")/.." && pwd)
cd "$workspace"

case "$repository" in
    */*) ;;
    *) echo "$0: repository must be owner/name, got '$repository'" >&2; exit 2 ;;
esac
case "$tag" in
    v[0-9]*) ;;
    *) echo "$0: tag must look like v1.2.3, got '$tag'" >&2; exit 2 ;;
esac

download="https://github.com/${repository}/releases/download/${tag}"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

echo "==> reading ${download}/SHA256SUMS"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --max-time 120 --output "$scratch/SHA256SUMS" "${download}/SHA256SUMS"

adopted=0
while read -r digest name; do
    # sha256sum writes "<digest>  ./<name>"; drop the leading marker.
    name=${name#\*}
    name=${name#./}
    case "$name" in
        ''|SHA256SUMS) continue ;;
    esac
    case "$digest" in
        [0-9a-f]*) ;;
        *) echo "$0: unusable digest for '$name'" >&2; exit 1 ;;
    esac
    if [ "${#digest}" -ne 64 ]; then
        echo "$0: digest for '$name' is not 64 hex characters" >&2
        exit 1
    fi

    # Which repository serves an artifact is decided by what it is, so a new
    # asset type fails here rather than landing somewhere arbitrary.
    case "$name" in
        *.deb) target=apt ;;
        *.tgz) target=charts ;;
        *.tar.gz|*.tar.xz|*.tar.zst|*.tar.bz2|*.zip) target=releases ;;
        *)
            echo "$0: no repository serves '$name'; add a rule to $0" >&2
            exit 1 ;;
    esac

    echo "==> adopt ${target}: ${name}"
    "$snailmail" adopt --sha256 "$digest" --public-origin "$target" "${download}/${name}"
    adopted=$((adopted + 1))
done < "$scratch/SHA256SUMS"

if [ "$adopted" -eq 0 ]; then
    echo "$0: SHA256SUMS listed no adoptable assets" >&2
    exit 1
fi
echo "==> adopted ${adopted} artifacts from ${repository} ${tag}"
