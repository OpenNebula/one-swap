#!/bin/bash

# -------------------------------------------------------------------------- #
# Copyright 2002-2026, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

# setup_ntfs_wof.sh
#
# One-time, idempotent setup that lets virt-v2v (and therefore OneSwap) read
# CompactOS / WOF-compressed NTFS partitions during Windows VM conversions.
#
# It builds the ntfs-3g-system-compression plugin, installs it for the
# host's ntfs-3g, and packs it as a supermin.d overlay so every libguestfs
# appliance rebuild automatically includes it. No fixed appliance and no
# LIBGUESTFS_PATH are needed; the setup survives /var/tmp/.guestfs-* wipes.

set -euo pipefail

REPO_URL="${NTFS_WOF_REPO_URL:-https://github.com/ebiggers/ntfs-3g-system-compression.git}"
PLUGIN_NAME="ntfs-plugin-80000017.so"
OVERLAY_NAME="zz-ntfs-wof.tar.gz"
FORCE="no"
VERIFY="yes"

usage() {
    cat <<'EOF'
Usage: setup_ntfs_wof.sh [--force] [--no-verify] [-h|--help]

Enables CompactOS (WOF-compressed NTFS) support for Windows VM conversions.
Run once, as root, on the migration host.

Options:
  --force      redo the setup even if it looks already configured
  --no-verify  skip the appliance rebuild + verification step
  -h, --help   show this help

Environment overrides:
  NTFS_WOF_REPO_URL   git URL of the plugin source (default: upstream GitHub)
  NTFS_WOF_BUILD_DIR  build directory (default: mktemp -d, removed on exit)
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE="yes"; shift ;;
        --no-verify) VERIFY="no"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "this script must be run as root"
command -v apt-get >/dev/null 2>&1 || \
    die "apt-get not found: only Debian/Ubuntu migration hosts are supported"

# Locate the supermin input dir and derive the ntfs-3g plugin dir from it
supermin_dir=$(ls -d /usr/lib/*/guestfs/supermin.d 2>/dev/null | head -n 1 || true)
[ -n "$supermin_dir" ] || \
    die "supermin.d not found: install virt-v2v / libguestfs-tools first"

libdir=${supermin_dir%/guestfs/supermin.d}
plugin_dir="$libdir/ntfs-3g"

echo "ntfs-3g plugin dir: $plugin_dir"
echo "supermin input dir: $supermin_dir"

if [ "$FORCE" = "no" ] && [ -f "$plugin_dir/$PLUGIN_NAME" ] \
       && [ -f "$supermin_dir/$OVERLAY_NAME" ]; then
    echo "Already configured. Use --force to redo the setup."
    exit 0
fi

# Build dependencies
echo "Installing build dependencies..."
# non-fatal on purpose: cached package lists are usually good enough
apt-get update || \
    echo "WARNING: apt-get update failed, continuing with cached package lists"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential git pkg-config autoconf automake libtool \
    ntfs-3g-dev ntfs-3g libguestfs-tools \
    || die "failed to install build dependencies"

# Build the plugin from source
if [ -n "${NTFS_WOF_BUILD_DIR:-}" ]; then
    build_dir="$NTFS_WOF_BUILD_DIR"
    mkdir -p "$build_dir"
else
    build_dir=$(mktemp -d)
    trap 'rm -rf "$build_dir"' EXIT
fi

echo "Building ntfs-3g-system-compression in $build_dir..."
src_dir="$build_dir/ntfs-3g-system-compression"
rm -rf "$src_dir"
git clone "$REPO_URL" "$src_dir" || die "git clone failed: $REPO_URL"
cd "$src_dir"
autoreconf -i
./configure --libdir="$libdir"
make
make install
[ -f "$plugin_dir/$PLUGIN_NAME" ] || \
    die "build finished but $plugin_dir/$PLUGIN_NAME is missing"
echo "Plugin installed: $plugin_dir/$PLUGIN_NAME"

# supermin.d overlay so every appliance rebuild includes the plugin
echo "Creating supermin overlay $supermin_dir/$OVERLAY_NAME..."
overlay_root="$build_dir/overlay"
mkdir -p "$overlay_root$plugin_dir"
install -m 0644 "$plugin_dir/$PLUGIN_NAME" "$overlay_root$plugin_dir/$PLUGIN_NAME"
tar -C "$overlay_root" --owner=0 --group=0 -czf "$build_dir/$OVERLAY_NAME" \
    "${plugin_dir#/}"
# stage next to the destination so the final rename is atomic (same filesystem)
cp "$build_dir/$OVERLAY_NAME" "$supermin_dir/.$OVERLAY_NAME.tmp"
mv "$supermin_dir/.$OVERLAY_NAME.tmp" "$supermin_dir/$OVERLAY_NAME"
echo "Overlay installed; the cached appliance rebuilds automatically on next use."

# Verification
if [ "$VERIFY" = "yes" ]; then
    command -v guestfish >/dev/null 2>&1 || \
        die "guestfish not found, cannot verify (rerun with --no-verify to skip)"
    echo "Rebuilding the libguestfs appliance (this can take a minute)..."
    # -a /dev/null is a placeholder disk: launching any guestfs handle forces
    # supermin to rebuild the cached appliance with the new overlay included
    guestfish -a /dev/null run || die "appliance rebuild failed"

    # libguestfs caches the appliance under LIBGUESTFS_CACHEDIR (default /var/tmp)
    appliance_root=""
    for cache_dir in "${LIBGUESTFS_CACHEDIR:-}" "${TMPDIR:-}" /var/tmp; do
        [ -n "$cache_dir" ] || continue
        if [ -f "$cache_dir/.guestfs-0/appliance.d/root" ]; then
            appliance_root="$cache_dir/.guestfs-0/appliance.d/root"
            break
        fi
    done
    [ -n "$appliance_root" ] || \
        die "could not locate the rebuilt appliance root image (.guestfs-0/appliance.d/root)"

    plugin_listing=$(guestfish --ro -a "$appliance_root" -m /dev/sda ls "$plugin_dir" 2>&1) \
        || die "guestfish failed to inspect the appliance image: $plugin_listing"
    echo "$plugin_listing" | grep -q "$PLUGIN_NAME" \
        || die "verification failed: $PLUGIN_NAME not found inside the appliance"
    echo "OK: $PLUGIN_NAME is present inside the libguestfs appliance."
fi

echo
echo "Done. Windows guests using CompactOS can now be converted on this host."
