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

# setup_nbdkit_vddk.sh
#
# One-time, idempotent setup that gives nbdkit the VDDK plugin required by
# virt-v2v's '-it vddk' mode (oneswap --vddk). Debian/Ubuntu do not package
# the plugin, so it is built from the nbdkit sources matching the installed
# distro package, and only the plugin .so is copied into nbdkit's plugindir
# (no 'make install', which would install a parallel nbdkit in /usr/local).

set -euo pipefail

REPO_URL="${NBDKIT_REPO_URL:-https://gitlab.com/nbdkit/nbdkit.git}"
PLUGIN_NAME="nbdkit-vddk-plugin.so"
FORCE="no"
VERIFY="yes"

usage() {
    cat <<'EOF'
Usage: setup_nbdkit_vddk.sh [--force] [--no-verify] [-h|--help]

Builds and installs the nbdkit VDDK plugin required for oneswap --vddk
transfers. Run once, as root, on the migration host.

Options:
  --force      redo the setup even if the plugin is already installed
  --no-verify  skip the 'nbdkit vddk --dump-plugin' verification step
  -h, --help   show this help

Environment overrides:
  NBDKIT_REPO_URL   git URL of the nbdkit source (default: upstream GitLab)
  NBDKIT_GIT_REF    git tag/branch to build (default: v<installed version>)
  NBDKIT_BUILD_DIR  build directory (default: mktemp -d, removed on exit)
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
    die "apt-get not found: only Debian/Ubuntu migration hosts are supported (on RHEL install the nbdkit-vddk-plugin package instead)"

# Make sure nbdkit itself is installed, then locate its plugindir
if ! command -v nbdkit >/dev/null 2>&1; then
    echo "Installing nbdkit..."
    apt-get update || \
        echo "WARNING: apt-get update failed, continuing with cached package lists"
    DEBIAN_FRONTEND=noninteractive apt-get install -y nbdkit \
        || die "failed to install nbdkit"
fi

plugindir=$(nbdkit --dump-config 2>/dev/null | sed -n 's/^plugindir=//p') \
    || die "nbdkit --dump-config failed (nbdkit installed but non-functional?)"
[ -n "$plugindir" ] || die "could not determine nbdkit's plugindir"
mkdir -p "$plugindir"

echo "nbdkit plugindir: $plugindir"

if [ "$FORCE" = "no" ] && [ -f "$plugindir/$PLUGIN_NAME" ]; then
    echo "Already configured. Use --force to redo the setup."
    exit 0
fi

# Build dependencies
echo "Installing build dependencies..."
# non-fatal on purpose: cached package lists are usually good enough
apt-get update || \
    echo "WARNING: apt-get update failed, continuing with cached package lists"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential git autoconf automake libtool pkg-config \
    || die "failed to install build dependencies"

# Build nbdkit from the sources matching the installed distro package
installed_version=$(dpkg-query -W -f='${source:Upstream-Version}' nbdkit 2>/dev/null || true)
git_ref="${NBDKIT_GIT_REF:-v$installed_version}"
[ "$git_ref" != "v" ] || \
    die "could not detect the installed nbdkit version; set NBDKIT_GIT_REF"

if [ -n "${NBDKIT_BUILD_DIR:-}" ]; then
    build_dir="$NBDKIT_BUILD_DIR"
    mkdir -p "$build_dir"
else
    build_dir=$(mktemp -d)
    trap 'rm -rf "$build_dir"' EXIT
fi

echo "Building nbdkit $git_ref in $build_dir..."
src_dir="$build_dir/nbdkit"
rm -rf "$src_dir"
git clone --depth 1 --branch "$git_ref" "$REPO_URL" "$src_dir" || \
    die "git clone of ref $git_ref failed; set NBDKIT_GIT_REF to a valid nbdkit tag/branch"
cd "$src_dir"
autoreconf -fi
./configure --disable-dependency-tracking
make -j"$(nproc)"
built_plugin="$src_dir/plugins/vddk/.libs/$PLUGIN_NAME"
[ -f "$built_plugin" ] || die "build finished but $built_plugin is missing"

# Install only the plugin into the distro plugindir (no 'make install')
echo "Installing $PLUGIN_NAME into $plugindir..."
# stage next to the destination so the final rename is atomic (same filesystem)
install -m 0644 "$built_plugin" "$plugindir/.$PLUGIN_NAME.tmp"
mv "$plugindir/.$PLUGIN_NAME.tmp" "$plugindir/$PLUGIN_NAME"

# Verification
if [ "$VERIFY" = "yes" ]; then
    nbdkit vddk --dump-plugin >/dev/null \
        || die "verification failed: 'nbdkit vddk --dump-plugin' returned an error"
    echo "OK: the VDDK plugin is installed and loadable by nbdkit."
fi

echo
echo "Done. VDDK-based transfers (--vddk) can now be used on this host."
