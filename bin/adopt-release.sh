#!/usr/bin/env bash
#
# Adopt the assets of a published GitHub Release into this workspace.
#
#   bin/adopt-release.sh shellcell/snailmail v0.1.2
#   bin/adopt-release.sh --pin-downloads shellcell/ttysvg v0.1.2
#
# Every artifact is pinned to a SHA-256. Where the release publishes its own
# checksum file, that file is what this script trusts: if it is wrong, the wrong
# bytes are pinned. Sign it in the producing repository if that matters to you,
# and verify the signature here before adopting.
#
# Nothing is published. This only records desired state, which is then reviewed
# as a diff and applied by the publish workflow.
set -euo pipefail

checksumAsset=""
pinDownloads=0
positional=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --checksums)
            [ "$#" -ge 2 ] || { echo "$0: --checksums needs a value" >&2; exit 2; }
            checksumAsset=$2; shift 2 ;;
        # Producers differ in what they publish digests for. Some cover every
        # asset, some only the tarballs, some publish none at all. Adopting an
        # asset with no published digest means pinning the bytes this run
        # happens to download, which is a weaker claim — it attests to what was
        # fetched rather than to what the producer stood behind — so it is a
        # decision the operator makes explicitly rather than a default.
        --pin-downloads) pinDownloads=1; shift ;;
        --) shift; break ;;
        -*) echo "$0: unknown option '$1'" >&2; exit 2 ;;
        *) positional+=("$1"); shift ;;
    esac
done
positional+=("$@")

if [ "${#positional[@]}" -ne 2 ]; then
    echo "usage: $0 [--checksums NAME] [--pin-downloads] <owner/repo> <tag>" >&2
    exit 2
fi

repository=${positional[0]}
tag=${positional[1]}
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

tool=${repository#*/}
version=${tag#v}
download="https://github.com/${repository}/releases/download/${tag}"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# The release is listed rather than inferred from its checksum file. Reading
# only the checksum file makes every asset it omits invisible: a release whose
# digests cover its tarballs but not its packages would adopt cleanly and
# publish half of itself, which is the failure this listing exists to prevent.
echo "==> listing ${repository} ${tag}"
api="https://api.github.com/repos/${repository}/releases/tags/${tag}"
# A token raises the anonymous API rate limit and reaches private releases; it
# is optional because the common case is a public release and requiring one
# would make this unusable by hand.
auth=()
if [ -n "${GH_TOKEN:-}" ]; then
    auth=(--header "Authorization: Bearer ${GH_TOKEN}")
fi
if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --max-time 120 ${auth[@]+"${auth[@]}"} \
        --output "$scratch/release.json" "$api"; then
    {
        echo "$0: cannot read the release ${repository} ${tag}."
        echo "Check the tag exists and is published, and set GH_TOKEN if it is private"
        echo "or if the anonymous API rate limit has been reached."
    } >&2
    exit 1
fi
jq -r '.assets[].name' < "$scratch/release.json" > "$scratch/assets"
if [ ! -s "$scratch/assets" ]; then
    echo "$0: ${repository} ${tag} publishes no assets" >&2
    exit 1
fi

# checksumFileFor finds the asset carrying digests. Producers name it several
# ways and none of them is wrong, so the common ones are recognised rather than
# demanded; --checksums overrides when a release uses something else.
checksumFileFor() {
    local candidate
    for candidate in SHA256SUMS SHA256SUMS.txt sha256sums.txt checksums.txt \
                     checksums_sha256.txt sha256sum.txt SHASUMS256.txt; do
        if grep -qx -- "$candidate" "$scratch/assets"; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

if [ -z "$checksumAsset" ]; then
    checksumAsset=$(checksumFileFor)
fi
# Digests are kept in a normalized file rather than an associative array:
# macOS ships bash 3.2, which has none, and a script that only ran in CI would
# be one an operator could not reproduce by hand.
: > "$scratch/digests"
if [ -n "$checksumAsset" ]; then
    if ! grep -qx -- "$checksumAsset" "$scratch/assets"; then
        echo "$0: ${repository} ${tag} has no asset named '${checksumAsset}'" >&2
        exit 1
    fi
    echo "==> reading ${download}/${checksumAsset}"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --max-time 120 --output "$scratch/checksums" "${download}/${checksumAsset}"
    while read -r digest name; do
        name=${name#\*}
        name=${name#./}
        [ -n "$name" ] || continue
        case "$digest" in
            [0-9a-f]*) ;;
            *) echo "$0: unusable digest for '$name'" >&2; exit 1 ;;
        esac
        if [ "${#digest}" -ne 64 ]; then
            echo "$0: digest for '$name' is not 64 hex characters" >&2
            exit 1
        fi
        printf '%s %s\n' "$digest" "$name" >> "$scratch/digests"
    done < "$scratch/checksums"
else
    echo "    this release publishes no checksum file"
fi

# repositoryFor decides where an artifact belongs, or reports that it is not a
# package at all.
#
# A release carries more than packages — checksums, signatures, SBOMs,
# provenance, notes — and those are not failures, they are simply not ours. An
# artifact this workspace could serve but has nowhere to put is a different
# thing: that is a repository someone meant to configure and did not.
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

# rawIdentityFor supplies the identity a raw artifact cannot carry.
#
# Raw reads <name>_<version>_<os>_<arch>.<ext> out of the filename, and a
# producer using another shape has to be told what it published. Where the
# filename is the same information in a different punctuation — and the name and
# version in it agree with the release being adopted — it is rewritten to the
# convention, so the architecture is recorded and the published layout matches
# every other tool. Anything else falls back to naming the tool and version
# only, which is always true and merely less specific.
rawIdentityFor() {
    local name=$1
    local stem extension os arch rest
    case "$name" in
        *.tar.gz)  stem=${name%.tar.gz};  extension=tar.gz ;;
        *.tar.xz)  stem=${name%.tar.xz};  extension=tar.xz ;;
        *.tar.zst) stem=${name%.tar.zst}; extension=tar.zst ;;
        *.tar.bz2) stem=${name%.tar.bz2}; extension=tar.bz2 ;;
        *.zip)     stem=${name%.zip};     extension=zip ;;
        *) echo "--name $tool --version $version"; return ;;
    esac
    # <tool><sep><optional v><version><sep><os><sep><arch>
    rest=${stem#"$tool"}
    rest=${rest#[-_.]}
    rest=${rest#v}
    case "$rest" in
        "$version"[-_.]*) rest=${rest#"$version"}; rest=${rest#[-_.]} ;;
        *) echo "--name $tool --version $version"; return ;;
    esac
    os=${rest%%[-_.]*}
    arch=${rest#"$os"}
    arch=${arch#[-_.]}
    case "$os" in
        linux|darwin|windows|freebsd|openbsd|netbsd) ;;
        *) echo "--name $tool --version $version"; return ;;
    esac
    case "$arch" in
        amd64|arm64|386|i386|arm|armv6|armv7|riscv64|ppc64le|s390x|x86_64|aarch64) ;;
        *) echo "--name $tool --version $version"; return ;;
    esac
    echo "--filename ${tool}_${version}_${os}_${arch}.${extension}"
}

# Everything is classified before anything is adopted, so a missing repository
# or an undigested asset stops the run while the workspace is still untouched
# rather than half way through it.
plan="$scratch/plan"
: > "$plan"
missing=""
undigested=""
skipped=0
while read -r name; do
    [ -n "$name" ] || continue
    if [ "$name" = "$checksumAsset" ]; then
        continue
    fi
    case "$name" in
        *.sig|*.asc|*.pem|*.sbom.json|*.spdx.json|*.cdx.json|*.intoto.jsonl)
            echo "    not a package, leaving alone: $name"
            skipped=$((skipped + 1))
            continue ;;
    esac

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
    digest=$(awk -v want="$name" '$2 == want { print $1; exit }' "$scratch/digests")
    if [ -z "$digest" ]; then
        if [ "$pinDownloads" -eq 0 ]; then
            undigested="${undigested}  ${name}"$'\n'
            continue
        fi
        digest=$(curl --fail --silent --show-error --location --proto '=https' \
            --tlsv1.2 --max-time 600 "${download}/${name}" | shasum -a 256 | cut -d' ' -f1)
        if [ "${#digest}" -ne 64 ]; then
            echo "$0: could not compute a digest for '$name'" >&2
            exit 1
        fi
    fi
    printf '%s %s %s\n' "$digest" "$target" "$name" >> "$plan"
done < "$scratch/assets"

if [ -n "$missing" ]; then
    {
        echo "$0: this release carries packages with nowhere to go:"
        printf '%s' "$missing"
        echo "configure them with 'snailmail setup', or nothing will publish them."
    } >&2
    exit 1
fi

if [ -n "$undigested" ]; then
    {
        echo "$0: this release publishes no digest for packages this workspace serves:"
        printf '%s' "$undigested"
        if [ -n "$checksumAsset" ]; then
            echo "'${checksumAsset}' does not cover them."
        fi
        echo "Adopting them anyway pins the bytes this run downloads rather than a"
        echo "digest the producer published, which is a weaker claim about what was"
        echo "released. Pass --pin-downloads to accept that, or publish digests for"
        echo "them in ${repository}."
    } >&2
    exit 1
fi

adopted=0
while read -r digest target name; do
    echo "==> adopt ${target}: ${name}"
    identity=()
    if [ "$target" = releases ]; then
        read -r -a identity <<< "$(rawIdentityFor "$name")"
    fi
    # ${x[@]+"${x[@]}"} rather than "${x[@]}": under set -u, bash 3.2 treats an
    # empty array as unbound, and the identity flags are empty for every format
    # that reads its own identity out of the bytes.
    "$snailmail" adopt --sha256 "$digest" ${identity[@]+"${identity[@]}"} \
        --public-origin "$target" "${download}/${name}"
    adopted=$((adopted + 1))
done < "$plan"

if [ "$adopted" -eq 0 ]; then
    echo "$0: ${repository} ${tag} carries no adoptable packages" >&2
    exit 1
fi
echo "==> adopted ${adopted} artifacts from ${repository} ${tag} (${skipped} left alone)"
