#!/bin/bash

# -------------------------------------------------------------------------- #
# Copyright 2002-2025, OpenNebula Project, OpenNebula Systems                #
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

ARGS=$*

usage() {
 echo
 echo "Usage: install.sh [-d ONE_LOCATION] [-h] [-l] [-m]"
 echo
 echo "-d: OpenNebula's CLI folder. Must be an absolute path."
 echo "-l: create only symlinks"
 echo "-m: generate and install man page for oneswap"
 echo "-h: prints this help"
}

PARAMETERS="hlmu:g:d:"

if [ $(getopt --version | tr -d " ") = "--" ]; then
    TEMP_OPT=`getopt $PARAMETERS "$@"`
else
    TEMP_OPT=`getopt -o $PARAMETERS -n 'install.sh' -- "$@"`
fi

if [ $? != 0 ] ; then
    usage
    exit 1
fi

eval set -- "$TEMP_OPT"

LINK="no"
MANPAGE="no"
SRC_DIR=$PWD

while true ; do
    case "$1" in
        -h) usage; exit 0;;
        -l) LINK='yes'; shift ;;
        -m) MANPAGE='yes'; shift ;;
        -d) ROOT="$2" ; shift 2 ;;
        --) shift ; break ;;
        *)  usage; exit 1 ;;
    esac
done

#-------------------------------------------------------------------------------
# Definition of locations
#-------------------------------------------------------------------------------
if [ -z "$ROOT" ] ; then
    LIB_LOCATION="/usr/lib/one"
    SHARE_LOCATION="/usr/share/one"
    BIN_LOCATION="/usr/bin"
    VAR_LOCATION="/var/lib/one"
    ETC_LOCATION="/etc/one"
    SCRIPTS_LOCATION="$LIB_LOCATION/oneswap/scripts"
else
    LIB_LOCATION="$ROOT/lib"
    SHARE_LOCATION="$ROOT/share"
    BIN_LOCATION="$ROOT/bin"
    VAR_LOCATION="$ROOT/var"
    ETC_LOCATION="$ROOT/etc/one"
    SCRIPTS_LOCATION="$LIB_LOCATION/oneswap/scripts"
fi

LIB_DIRS="$LIB_LOCATION/ruby/cli/one_helper"
MAN_LOCATION="/usr/share/man/man1"

MAKE_DIRS="$BIN_LOCATION $SHARE_LOCATION $LIB_LOCATION $ETC_LOCATION
           $VAR_LOCATION $LIB_DIRS $SCRIPTS_LOCATION"

#-------------------------------------------------------------------------------
# FILE DEFINITION, WHAT IS GOING TO BE INSTALLED AND WHERE
#-------------------------------------------------------------------------------
INSTALL_FILES=(
    BIN_FILES:$BIN_LOCATION
	ONE_CLI_LIB_FILES:$LIB_LOCATION/ruby/cli/one_helper
    CONF_FILES:$ETC_LOCATION
    SCRIPTS_FILES:$SCRIPTS_LOCATION
)


BIN_FILES="oneswap sesparse"
ONE_CLI_LIB_FILES="oneswap_helper.rb vsphere_client.rb esxi_client.rb esxi_vm.rb"
CONF_FILES="oneswap.yaml"
SCRIPTS_FILES="scripts/*"

#-----------------------------------------------------------------------------
# INSTALL.SH SCRIPT
#-----------------------------------------------------------------------------

# Build sesparse binary for delta transfer feature
git submodule init && gcc -w -std=c99 -o sesparse any2kvm/sesparse.c

if [ "$MANPAGE" = "yes" ]; then
    # base document
    echo "# oneswap(1) -- OpenNebula OneSwap Tool" > oneswap.1.ronn
    echo >> oneswap.1.ronn
    $BIN_LOCATION/oneswap --help >> oneswap.1.ronn

    # manual pages/html
    ronn --style toc --manual="oneswap(1) -- OpenNebula OneSwap Tool" oneswap.1.ronn
    gzip -c oneswap.1 > oneswap.1.gz

    cp oneswap.1.gz $MAN_LOCATION
    rm -f oneswap.1.ronn oneswap.1.gz

    exit 0
fi

for d in $MAKE_DIRS; do
	mkdir -p $DESTDIR$d
done

INSTALL_SET="${INSTALL_FILES[@]}"

do_file() {
	if [ "$LINK" = "yes" ]; then
		ln -s $SRC_DIR/$1 $DESTDIR$2
	else
		cp -RL $SRC_DIR/$1 $DESTDIR$2
	fi
}

for i in ${INSTALL_SET[@]}; do
    SRC=$`echo $i | cut -d: -f1`
    DST=`echo $i | cut -d: -f2`

    eval SRC_FILES=$SRC

    for f in $SRC_FILES; do
        do_file $f $DST
    done
done
