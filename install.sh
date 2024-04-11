#!/bin/bash

# -------------------------------------------------------------------------- #
# Copyright 2002-2024, OpenNebula Project, OpenNebula Systems                #
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

function usage {
    echo "Use either -l for linked install or -c for copy install."
    echo "This should be run from the same directory as the script."
    exit
}

function link_install {
    echo "Creating symbolic links."
    ln -s `pwd`/oneswap /usr/bin/oneswap
    ln -s `pwd`/oneswap_helper.rb /usr/lib/one/ruby/cli/one_helper/oneswap_helper.rb
    chmod +x `pwd`/oneswap
    ls -lh /usr/bin/oneswap
    ls -lh /usr/lib/one/ruby/cli/one_helper/oneswap_helper.rb
}

function copy_install {
    echo "Copying files for install."
    cp -f `pwd`/oneswap /usr/bin/oneswap
    cp -f `pwd`/oneswap_helper.rb /usr/lib/one/ruby/cli/one_helper/oneswap_helper.rb
    chmod +x `pwd`/oneswap
    ls -lh /usr/bin/oneswap
    ls -lh /usr/lib/one/ruby/cli/one_helper/oneswap_helper.rb
}

while getopts "lc" option; do
    case $option in
        l)
            link_install
            exit;;
        c)
            copy_install
            exit;;
        *)
            usage
            exit;;
    esac
done

usage
