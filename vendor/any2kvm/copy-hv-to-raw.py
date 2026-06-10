#!/usr/bin/env python
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
import md5
import os
import socket
import subprocess


def exec_ssh(host, cmd):
    output = subprocess.check_output([
        'ssh', host,
        cmd
        ])
    return output

def unix2windows(path):
    if '\\' in path:
        raise ValueError("Path contains '\\' [{}]".format(path))
    return path.replace('/', '\\')

def windows2unix(path):
    if '/' in path:
        raise ValueError("Path contains '/' [{}]".format(path))
    return path.replace('\\', '/')

def hash_filename(path):
    return md5.new(path.upper()).hexdigest()

def copy_file_from_hv(args, transfer_dir, path):
    # path is in windows format

    img_name = hash_filename(path)
    dst = os.path.join(args.dir, img_name)

    print "Downloading {} ({})".format(img_name, path)

    if os.path.isfile(dst):
        print "File {} already exists. Skipping.".format(img_name)
        return dst

    upath = windows2unix(path)
    cmd = [
            'scp', '-C',
            "{u}@{h}:/'{p}'".format(u=args.user, h=args.host, p=upath),
            os.path.join(transfer_dir, img_name),
            ]

    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError as e:
        print e.output
        raise

    os.rename(os.path.join(transfer_dir, img_name), dst)
    return dst


def get_info(path):

    try:
        output = subprocess.check_output([ './vhdx', path ])
    except subprocess.CalledProcessError as e:
        print e.output
        raise

    info = {}
    for l in output.splitlines():
        a,v = l.split('=', 2)
        info[a] = v
    return info

def get_parent(args, path):

    host = "@".join((args.user, args.host))
    cmd="Get-VHD '{}' | select -exp ParentPath".format(path)
    #print "SSH {} [{}]".format(host, cmd)

    try:
        output = exec_ssh(host, cmd)
    except subprocess.CalledProcessError as e:
        print e.output
        raise
    #print "[{}]".format(output)
    return output.strip()


def convert_image(src, dst):

    info = get_info(src)
    if not os.path.exists(dst):
        # Create sparse file
        size = int(info.get('virtualSize'))  # in bytes
        size_mb = (size - 1) // 1024 // 1024 + 1
        print "Creating sparce raw output image " + dst
        try:
            subprocess.check_call([ 'dd', 'if=/dev/zero', 'of='+dst,
                'bs=1', 'count=0', 'seek={}M'.format(size_mb)
                ])
        except subprocess.CalledProcessError as e:
            print e.output
            raise

    print "Converting {}".format(src)
    try:
        output = subprocess.check_output([ './vhdx', src, dst ])
    except subprocess.CalledProcessError as e:
        print e.output
        raise
    print output
    print "Conversion Done!"


def main():

    parser = argparse.ArgumentParser(description='Convert Hyper-V images to OpenNebula')
    parser.add_argument('host', help='Hyper-V hostname. Must support ssh as Administrator')
    parser.add_argument('path', help='Image file path at the Windows host. '
            'Shall be .vhdx or .avhdx file. '
            "Example: 'C:\\dir\\file.vhdx'")
    parser.add_argument('out', help='Output raw image. Filename or block device')
    parser.add_argument('-u', '--user', default='Administrator',
            help='Username in the Hyper-V. Default is Administrator.')
    parser.add_argument('-d', '--download-dir', default='/var/tmp/hv-convert',
            dest='dir',
            help='Temporary directory where Hyper-V images will be downloaded'
                ' before being stored in StorPool. Default is /var/tmp/hv_convert.')
    parser.add_argument('-s', '--start-at',
            help='Skip converting images from root to this one, inclusive. '
            'Use this option when previous snapshots were already converted.')
    parser.add_argument('-f', '--finish', action='store_true',
            help='Apply the top image. Without this option the top file will '
            'be skipped. Use this option at the last invocation of the command, '
            'when the source VM is stopped.')

    args = parser.parse_args()

    transfer_dir = os.path.join(args.dir, 'transfer')

    if not os.path.isdir(transfer_dir):
        os.makedirs(transfer_dir)

    # Get snapshot chain
    chain = [] # root at the beginning
    path = args.path
    dst = args.out
    while path :
        chain.insert(0, path)
        parent = get_parent(args, path)
        print "Parent = ", parent
        path = parent
        if args.start_at == parent:
            print("Reached the image {}, Skiping all the rest."
                    .format(args.start_at))
            break

    if not args.finish:  # skip top image
        print('Skipping the top image {}.'.format(chain[-1]))
        chain = chain[:-1]

    print "Chain to convert, starting from root:"
    print "\n".join(chain)

    parent = None
    for path in chain:
        image = copy_file_from_hv(args, transfer_dir, path)
        convert_image(image, dst)

    if not args.finish and path is not None:
        _, image = os.path.split(path)
        print('To continue with the conversion from the current state, '
                'next time run this tool with `--start-at {}`'
                .format(image))

if __name__ == '__main__':
    main()
