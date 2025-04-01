#!/usr/bin/bash

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
 echo "Usage: install.sh [-d ONE_LOCATION] [-h] [-l]"
 echo
 echo "-d: OpenNebula's CLI folder. Must be an absolute path."
 echo "-l: create only symlinks"
 echo "-h: prints this help"
}

PARAMETERS="hlu:g:d:"

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
SRC_DIR=$PWD

while true ; do
    case "$1" in
        -h) usage; exit 0;;
        -l) LINK='yes'; shift ;;
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
else
    LIB_LOCATION="$ROOT/lib"
    SHARE_LOCATION="$ROOT/share"
    BIN_LOCATION="$ROOT/bin"
    VAR_LOCATION="$ROOT/var"
    ETC_LOCATION="$ROOT/etc/one"
fi

LIB_DIRS="$LIB_LOCATION/ruby/cli/one_helper"


MAKE_DIRS="$BIN_LOCATION $SHARE_LOCATION $LIB_LOCATION $ETC_LOCATION
           $VAR_LOCATION $LIB_DIRS"

#-------------------------------------------------------------------------------
# FILE DEFINITION, WHAT IS GOING TO BE INSTALLED AND WHERE
#-------------------------------------------------------------------------------
INSTALL_FILES=(
    BIN_FILES:$BIN_LOCATION
	ONE_CLI_LIB_FILES:$LIB_LOCATION/ruby/cli/one_helper
    CONF_FILES:$ETC_LOCATION
)


BIN_FILES="oneswap"
ONE_CLI_LIB_FILES="oneswap_helper.rb"
CONF_FILES="oneswap.yaml"

#-----------------------------------------------------------------------------
# INSTALL.SH SCRIPT
#-----------------------------------------------------------------------------

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
