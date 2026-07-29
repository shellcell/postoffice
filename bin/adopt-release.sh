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

# repositoryFor decides where an artifact belongs, or reports that it is not a
# package at all.
#
# A release carries more than packages — checksums, signatures, SBOMs,
# provenance — and those are not failures, they are simply not ours. An artifact
# this workspace could serve but has nowhere to put is a different thing: that
# is a repository someone meant to configure and did not.
repositoryFor() {
    case "$1" in
        *.deb) echo apt ;;
        *.rpm) echo yum ;;
        *.apk) echo alpine ;;
        *.tgz) echo charts ;;
        *.tar.gz|*.tar.xz|*.tar.zst|*.tar.bz2|*.zip) echo releases ;;
        *) echo "" ;;
    esac
}

configured() {
    grep -q "^\[repo\.$1\]" snailmail.toml
}

# Everything is classified before anything is adopted, so a missing repository
# stops the run while the workspace is still untouched rather than half way
# through it.
plan="$scratch/plan"
: > "$plan"
missing=""
skipped=0
while read -r digest name; do
    name=${name#\*}
    name=${name#./}
    case "$name" in
        ''|SHA256SUMS|*.sig|*.asc|*.pem|*.sbom.json|*.spdx.json|*.cdx.json|*.intoto.jsonl)
            [ -n "$name" ] && [ "$name" != SHA256SUMS ] && {
                echo "    not a package, leaving alone: $name"
                skipped=$((skipped + 1))
            }
            continue ;;
    esac
    case "$digest" in
        [0-9a-f]*) ;;
        *) echo "$0: unusable digest for '$name'" >&2; exit 1 ;;
    esac
    if [ "${#digest}" -ne 64 ]; then
        echo "$0: digest for '$name' is not 64 hex characters" >&2
        exit 1
    fi

    target=$(repositoryFor "$name")
    if [ -z "$target" ]; then
        echo "    unrecognised, leaving alone: $name"
        skipped=$((skipped + 1))
        continue
    fi
    if ! configured "$target"; then
        missing="${missing}  ${name} needs a '${target}' repository"$'\n'
        continue
    fi
    printf '%s %s %s\n' "$digest" "$target" "$name" >> "$plan"
done < "$scratch/SHA256SUMS"

if [ -n "$missing" ]; then
    {
        echo "$0: this release carries packages with nowhere to go:"
        printf '%s' "$missing"
        echo "configure them with 'snailmail setup', or nothing will publish them."
    } >&2
    exit 1
fi

adopted=0
while read -r digest target name; do
    echo "==> adopt ${target}: ${name}"
    "$snailmail" adopt --sha256 "$digest" --public-origin "$target" "${download}/${name}"
    adopted=$((adopted + 1))
done < "$plan"

if [ "$adopted" -eq 0 ]; then
    echo "$0: SHA256SUMS listed no adoptable packages" >&2
    exit 1
fi
echo "==> adopted ${adopted} artifacts from ${repository} ${tag} (${skipped} left alone)"
