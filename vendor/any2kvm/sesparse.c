/*-
 * Copyright (c) 2019  StorPool.
 * All rights reserved.
 */

/*
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

*/

/*
 * Modified by OpenNebula Systems, 2026.
 *
 * Changes:
 * - Added support for seSparse images with reserved1=0x200.
 *
 * Based on the patch proposed in:
 * https://github.com/storpool/any2kvm/pull/1
 */

/*
compile:

gcc -std=c99 -o sesparse sesparse.c
*/
#define _GNU_SOURCE 1
#define _BSD_SOURCE 1

#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

struct SeSparseHeader
{
	uint64_t magic;
	uint32_t versionUpper;
	uint32_t versionLower;
	uint64_t capacity;
	uint64_t grain_size;
	uint64_t grain_table_size;
	uint64_t flags;
	uint64_t reserved1;
	uint64_t reserved2;
	uint64_t reserved3;
	uint64_t reserved4;
	uint64_t volatile_header_offset;
	uint64_t volatile_header_size;
	uint64_t journal_header_offset;
	uint64_t journal_header_size;
	uint64_t journal_offset;
	uint64_t journal_size;
	uint64_t grain_dir_offset;
	uint64_t grain_dir_size;
	uint64_t grain_tables_offset;
	uint64_t grain_tables_size;
	uint64_t free_bitmap_offset;
	uint64_t free_bitmap_size;
	uint64_t backmap_offset;
	uint64_t backmap_size;
	uint64_t grains_offset;
	uint64_t grains_size;
	uint8_t pad[304];
} __attribute__((packed));

struct SESparseVolatileHeader
{
	uint64_t magic;
	uint64_t free_gt_number;
	uint64_t next_txn_seq_number;
	uint64_t replay_journal;
	uint8_t pad[480];
} __attribute__((packed));

char zeroes[512*8] __attribute__((aligned(4096)));

static int supported_reserved1(uint64_t reserved1)
{
      return reserved1 == 0 || reserved1 == 0x200;
}

int main(int argc, char *argv[])
{
	if( argc != 3 )
	{
		fprintf(stderr, "usage: %s /path/to/sesparse.vmdk /dev/storpool/targetVolume\n", argv[0]);
		exit(1);
	}
	
	const int fd = open(argv[1], O_RDONLY);
	if( fd == -1 )
	{
		perror("open");
		exit(1);
	}
	
	const int ofd = open(argv[2], O_RDWR | O_DIRECT);
	if( ofd == -1 )
	{
		perror("open");
		exit(1);
	}
	
	const size_t size = lseek(fd, 0, SEEK_END);
	const void *ptr = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
	
	const struct SeSparseHeader *hdr = ptr;
	if( hdr->magic != 0xcafebabe )
	{
		fprintf(stderr, "invalid magic\n");
		exit(1);
	}
	
	if( hdr->versionUpper != 1 || hdr->versionLower != 2 )
	{
		fprintf(stderr, "unsupported version %d.%d", hdr->versionUpper, hdr->versionLower);
		exit(1);
	}
	
	if( hdr->grain_size != 8 ||
		hdr->grain_table_size != 64 ||
		hdr->flags != 0 ||
		!supported_reserved1(hdr->reserved1) || hdr->reserved2 != 0 || hdr->reserved3 != 0 || hdr->reserved4 != 0 ||
		hdr->volatile_header_offset != 1 ||
		hdr->volatile_header_size != 1 ||
		hdr->journal_header_offset != 2 ||
		hdr->journal_header_size != 2 ||
		hdr->journal_offset != 2048 ||
		hdr->journal_size != 2048 ||
		hdr->grain_dir_offset != 4096 )
	{
		fprintf(stderr, "unsupported values in hdr: reserved1=0x%lx\n", hdr->reserved1);
		exit(1);
	}
	
	const struct SESparseVolatileHeader *vhdr = (ptr + 512);
	if( vhdr->magic != 0xcafecafe )
	{
		fprintf(stderr, "invalid volatile hdr magic\n");
		exit(1);
	}
	
	if( vhdr->replay_journal )
	{
		fprintf(stderr, "replay journal is not supported\n");
		exit(1);
	}
	
	const uint64_t *dir = ptr + hdr->grain_dir_offset * 512;
	printf("capacity %lu\n", hdr->capacity );
	
	const uint64_t dirEntVirtualSize = 8ull * 512 * 64 * 512 / 8;
	
	uint64_t lastAddr = 0;
	const unsigned iovecSize = 32;
	struct iovec iovec[iovecSize];
	unsigned iovecPtr = 0;
	
	for(unsigned i = 0; i < hdr->grain_dir_size * 512 / 8; i++ )
	{
		if( dir[i] )
		{
			printf("dir[%d] = %lx\n", i, dir[i]);
			const uint64_t *tbl = ptr + hdr->grain_tables_offset * 512 + (dir[i] & 0x00000000ffffffff) * (64 * 512);
			for(unsigned j = 0; j < 64 * 512 / 8; j++ )
			{
				if( tbl[j] )
				{
					
					// printf("  tbl[%d] = %lx\n", j, tbl[j]);
					const unsigned type = tbl[j] >> 60;
					if( type == 0 )
						continue;
					
					const uint64_t virtualOffset = i * (uint64_t)dirEntVirtualSize + j * 8 * 512lu;
					if( iovecPtr && (lastAddr != virtualOffset || iovecPtr == iovecSize) )
					{
						const ssize_t res = pwritev(ofd, iovec, iovecPtr, lastAddr - iovecPtr * 4096 );
						if( res != iovecPtr * 4096)
						{
							if( res < 0 )
								perror("pwrite");
							else
								abort();
							exit(1);
						}
						iovecPtr = 0;
					}
					lastAddr = virtualOffset + 4096;
					if( type == 1 || type == 2 )
					{
						// fprintf(stderr, "must write zeroes @%lu\n", virtualOffset);
						iovec[iovecPtr].iov_base = zeroes;
					}
					else if( type == 3 )
					{
						uint64_t offset = ((tbl[j] & 0x0fff000000000000) >> 48) | ((tbl[j] & 0xffffffffffff) << 12);
						const uint64_t fileOffset = hdr->grains_offset * 512ull + offset * 8 * 512;
						fprintf(stderr, "vo %lu file addr %lu\n", virtualOffset, fileOffset);
						iovec[iovecPtr].iov_base = (void*)ptr + fileOffset;
					}
					else
					{
						fprintf(stderr, "unknown grain type %x\n", type);
						exit(1);
					}
					
					iovec[iovecPtr].iov_len = 4096;
					iovecPtr++;
				}
			}
		}
	}
	
	if( iovecPtr )
	{
		const ssize_t res = pwritev(ofd, iovec, iovecPtr, lastAddr - iovecPtr * 4096 );
		if( res != iovecPtr * 4096)
		{
			if( res < 0 )
				perror("pwrite");
			else
				abort();
			exit(1);
		}
	}
}

