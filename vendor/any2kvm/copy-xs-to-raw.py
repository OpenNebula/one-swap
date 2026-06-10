#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Copyright (c) 2019  StorPool.
All rights reserved.



  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
  SUCH DAMAGE.
"""


import argparse
import os
import socket
import subprocess


def exec_ssh(host, cmd):
    output = subprocess.check_output([
        'ssh', host,
        cmd
        ])
    return output


def copy_file_from_hv(args, path):
    # path is in windows format

    src_dir, img_name = os.path.split(path)
    dst = os.path.join(args.dir, img_name)

    print("Downloading {} ({})".format(img_name, path))

    cmd = [
            'rsync', '-u', '--progress',
            '{u}@{h}:/{p}'.format(u=args.user, h=args.host, p=path),
            dst,
            ]

    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError as e:
        print(e.output)
        raise

    return dst


def get_info(path):

    try:
        output = subprocess.check_output([ './vhd', path ])
    except subprocess.CalledProcessError as e:
        print(e.output)
        raise

    info = {}
    for l in output.decode('utf-8').splitlines():
        a,v = l.split('=', 2)
        info[a] = v
    return info

def get_parent(image):
    info = get_info(image)
    return info['parentPath']

def convert_image(src, dst):

    info = get_info(src)
    if not os.path.exists(dst):
        # Create sparse file
        size = int(info.get('size'))  # in bytes
        size_mb = (size - 1) // 1024 // 1024 + 1
        print("Creating sparce raw output image " + dst)
        try:
            subprocess.check_call([ 'dd', 'if=/dev/zero', 'of='+dst,
                'bs=1', 'count=0', 'seek={}M'.format(size_mb)
                ])
        except subprocess.CalledProcessError as e:
            print(e.output)
            raise

    print("Converting {}".format(src))
    try:
        subprocess.check_call([ './vhd', src, dst ])
    except subprocess.CalledProcessError as e:
        print(e.output)
        raise
    print("Conversion Done!")


def main():

    parser = argparse.ArgumentParser(description='Convert XenServer images to Raw')
    parser.add_argument('host',
            help='XenServer or NFS server hostname. Must support ssh')
    parser.add_argument('path',
            help='Image file path at the host. Shall be a .vhd file. '
            "Example: '/run/sr-mount/93a3cf4c-0061-0dc9-2a70-dc1a42b2b1a1/"
            "1c005a0e-46f9-450b-98b7-c7b582dbacec.vhd'")
    parser.add_argument('out', help='Output raw image. Filename or block device')
    parser.add_argument('-u', '--user', default='root',
            help='Username in the XenServer hypervisor. Default is root.')
    parser.add_argument('-d', '--download-dir', default='/var/tmp/xen_convert',
            dest='dir',
            help='Temporary directory where images will be downloaded and '
            'stored, before being applied to the output image. Default is '
            '/var/tmp/xen_convert.')
    parser.add_argument('-s', '--stop-at',
            help='Stop converting when this file is reached. This file will '
            'not be copied nor applied to the output image. Use this option '
            'when previous snapshots were already converted.')
    parser.add_argument('-f', '--finish', action='store_true',
            help='Apply the top image. Without this option the top file will '
            'be skipped. Use this option at the last invocation of the command, '
            'when the source VM is stopped.')


    args = parser.parse_args()

    # Get snapshot chain
    chain = [] # root at the beginning
    path = args.path
    dst = args.out
    src_dir, _ = os.path.split(path)
    while path :
        image = copy_file_from_hv(args, path)
        chain.insert(0, image)
        parent = get_parent(image)
        print("Parent = " + parent)
        if parent:
            path = os.path.join(src_dir, parent)
        else:
            path = None
        if args.stop_at == parent:
            print("Reached the image {}, Skiping all the rest."
                    .format(args.stop_at))
            break

    if not args.finish:  # skip top image
        print('Skipping the top image {}.'.format(chain[-1]))
        chain = chain[:-1]

    print("Chain to convert, starting from root:")
    print("\n".join(chain))

    for path in chain:
        convert_image(path, dst)

    if not args.finish and path is not None:
        _, image = os.path.split(path)
        print('To continue with the conversion from the current state, '
                'next time run this tool with `--stop-at {}`'
                .format(image))

if __name__ == '__main__':
    main()
