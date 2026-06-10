/*-
 * Copyright (c) 2020  StorPool.
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
compile:

gcc -std=c99 -o vmfssparse vmfssparse.c
*/

#define _GNU_SOURCE 1

#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#define COWDISK_MAX_PARENT_FILELEN 1024
#define COWDISK_MAX_NAME_LEN 60
#define COWDISK_MAX_DESC_LEN 512

#define GRAINS_PER_TABLE 4096
#define GRAIN_SIZE 512

struct COWDisk_Header
{
	uint32_t magicNumber;  // 0x44574f43
	uint32_t version;	// 1
	uint32_t flags;		// 3
	uint32_t numSectors;	// 0x0ca00000
	uint32_t grainSize;	// 1
	uint32_t gdOffset;	// 4
	uint32_t numGDEntries;	// 0xca00  (numSectors / 4k)
	uint32_t freeSector;
	union {
		struct {
			uint32_t cylinders;
			uint32_t heads;
			uint32_t sectors;
		} root;
		struct {
			char parentFileName[COWDISK_MAX_PARENT_FILELEN];
			uint32_t parentGeneration;
		} child;
	} u;
	uint32_t generation;
	char name[COWDISK_MAX_NAME_LEN];
	char description[COWDISK_MAX_DESC_LEN];
	uint32_t savedGeneration;
	char reserved[8];
	uint32_t uncleanShutdown;
	char padding[396];
} __attribute__((packed));


int main(int argc, char *argv[])
{
	if( argc != 3 )
	{
		fprintf(stderr, "usage: %s /path/to/sparse.vmdk /dev/storpool/targetVolume\n", argv[0]);
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

	const struct COWDisk_Header *hdr = ptr;
	if( hdr->magicNumber != 0x44574f43)
	{
		fprintf(stderr, "invalid magic\n");
		exit(1);
	}

	if( hdr->version != 1 )
	{
		fprintf(stderr, "unsupported version %d", hdr->version);
		exit(1);
	}


	if( hdr->flags != 3 )
	{
		fprintf(stderr, "unsupported values in hdr\n");
		exit(1);
	}

	if( hdr->grainSize != 1 )
	{
		fprintf(stderr, "unsupported grainSize %u\n", hdr->grainSize);
		exit(1);
	}


	const uint32_t *gDir = (void *) hdr + hdr->gdOffset * 512;
	printf("Number of tables: %u\n", hdr->numGDEntries);


	uint64_t lastAddr = 0;
	const unsigned iovecSize = 32 * 8;
	struct iovec iovec[iovecSize];
	unsigned iovecPtr = 0;

	for(unsigned i=0; i < hdr->numGDEntries; i++ )
	{
		uint32_t tblOffset = gDir[i];
		if (tblOffset)
		{
			uint32_t *tbl = (void *) hdr + tblOffset * 512;
			printf("Table[%4u] = %u\n", i, tblOffset);

			// apply_table(fd, ofd, tbl);
			for(unsigned j =0; j < GRAINS_PER_TABLE; j++)
			{
				const uint32_t grain = tbl[j];
				if (grain > 0)
				{
					const void *rdPtr = ptr + grain * 512ul;;
					const uint64_t wrOffset = (i * GRAINS_PER_TABLE + j) * 512ul;
					//printf("Grain[%4u] = %lu\n", j, grain * 512ul);


					if( iovecPtr && (lastAddr != wrOffset || iovecPtr == iovecSize) )
					{
						const ssize_t res = pwritev(ofd, iovec, iovecPtr, lastAddr - iovecPtr * 512 );
						if( res != iovecPtr * 512)
						{
							if( res < 0 )
								perror("pwrite");
							else
								abort();
							exit(1);
						}
						iovecPtr = 0;
					}
					iovec[iovecPtr].iov_base = (void *)rdPtr;
					iovec[iovecPtr].iov_len = 512;
					lastAddr = wrOffset + 512;
					iovecPtr++;

				}

			}

		}
	}

	if( iovecPtr )
	{
		const ssize_t res = pwritev(ofd, iovec, iovecPtr, lastAddr - iovecPtr * 512 );
		if( res != iovecPtr * 512)
		{
			if( res < 0 )
				perror("pwrite");
			else
				abort();
			exit(1);
		}
	}

	printf("Done.");
}

