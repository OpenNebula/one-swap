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
compile:

gcc -std=c99 -D _BSD_SOURCE -D _XOPEN_SOURCE=500 -o vhd vhd.c
*/

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <inttypes.h>
#include <endian.h>
#include <assert.h>
#include <string.h>

struct VhdHeader
{
	uint64_t	cookie;
	uint32_t	features;
	uint32_t	version;
	uint64_t	dataOffset;
	uint32_t	timestamp;
	uint32_t	creatorApp;
	uint32_t	creatorVer;
	uint32_t	creatorHostOs;
	uint64_t	origSize;
	uint64_t	currentSize;
	uint32_t	geom;
	uint32_t	type;
	uint32_t	chsum;
	uint8_t		uuid[16];
	uint8_t		savedState;
} __attribute__((packed));

struct VhdDyn
{
	uint64_t	cookie;
	uint64_t	dataOffset;
	uint64_t	tableOffset;
	uint32_t	headerVersion;
	uint32_t	maxTableEntries;
	uint32_t	blockSize;
	uint32_t	checksum;
	uint8_t		parentUuid[16];
	uint32_t	parentTimestamp;
	uint32_t	reserved;
	uint16_t	parentUnicodeName[256];
	
	struct ParentLocator
	{
		uint32_t	platformCode;
		uint32_t	dataSpace;
		uint32_t	dataLength;
		uint32_t	reserved;
		uint64_t	dataOffset;
	}		parentLocators[8];
	
} __attribute__((packed));

void printUUid(uint8_t *uuid)
{
	for(unsigned i = 0; i < 16; i++, uuid++)
	{
		printf("%X%X", uuid[0] >> 4, uuid[0] & 0xf);
		if( i % 4 == 0 )
			printf("-");
	}
}

void printUnicode(uint16_t *n)
{
	for(;; n++)
	{
		if( n[0] == 0 )
			break;
		printf("%c", be16toh(n[0]));
	}
}

int main(int argc, char *argv[])
{
	if( argc != 2 && argc != 3 )
	{
		fprintf(stderr, "usage: %s: file.vhd [output.raw]\n", argv[0]);
		exit(1);
	}
	
	int fd = open(argv[1], O_RDONLY);
	if( fd == -1 )
	{
		perror("open");
		exit(1);
	}
	
	uint64_t size = lseek(fd, 0, SEEK_END);
	
	void *base = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
	if( base == MAP_FAILED )
	{
		perror("mmap");
		exit(1);
	}
	
	struct VhdHeader *vhd = base;
//	printf("cookie %lx, features %x, version %x, dataOffset %lx, origSize %ld, currentSize %ld, type %d, uuid ",
//		vhd->cookie, be32toh(vhd->features), be32toh(vhd->version), be64toh(vhd->dataOffset), be64toh(vhd->origSize), be64toh(vhd->currentSize), be32toh(vhd->type));
//	printUUid(vhd->uuid);
//	printf(" savedState %d\n", vhd->savedState);
	const unsigned type = be32toh(vhd->type);
	const uint64_t dataOffset = be64toh(vhd->dataOffset);
	if( vhd->cookie != 0x78697463656e6f63 ||
		be32toh(vhd->features) != 2 ||
		(type != 3 && type !=4 ) ||
		dataOffset > size - sizeof(struct VhdDyn) )
	{
		fprintf(stderr, "unsupported'n");
		exit(1);
	}
	
	uint64_t diskSize = be64toh(vhd->currentSize);
	
	struct VhdDyn *dyn = base + be64toh(vhd->dataOffset);
//	printf("cookie %lx, dataOffset %ld, tableOffset %ld, hederVersion %lx, maxTableEntries %d, blockSize %d, parentName ",
//		dyn->cookie, be64toh(dyn->dataOffset), be64toh(dyn->tableOffset), be32toh(dyn->headerVersion), be32toh(dyn->maxTableEntries), be32toh(dyn->blockSize) );
//	printUnicode(dyn->parentUnicodeName);
//	printf(" patrentUuid ");
//	printUUid(dyn->parentUuid);
//	printf("\n");
	
	if( dyn->cookie != 0x6573726170737863 ||
		be64toh(dyn->dataOffset) != -1ul ||
		be32toh(dyn->headerVersion) != 0x10000 )
	{
		fprintf(stderr, "unsupported\n");
		exit(1);
	}
	
	if( type == 4 && 0 )
	{
		for(unsigned i = 0; i < 8; i++)
		{
			if( dyn->parentLocators[i].platformCode != 0 )
			{
				struct ParentLocator *pl = &dyn->parentLocators[i];
				printf("%d: %x %x %x %x\n", i, be32toh(pl->platformCode), be32toh(pl->dataSpace), be32toh(pl->dataLength), be64toh(pl->dataOffset));
				if( be32toh(pl->platformCode) != 0x4D616358)
				{
					fprintf(stderr, "unsupported\n");
					exit(1);
				}
				printf("%d = %s\n", i, base + be64toh(pl->dataOffset));
			}
		}
	}
	
	printf("size=%ld\n", diskSize);
	printf("parentPath=");
	printUnicode(dyn->parentUnicodeName);
	printf("\n");
	
	uint32_t maxTableEntries = be32toh(dyn->maxTableEntries);
	uint32_t blockSize = be32toh(dyn->blockSize);
	uint32_t *bat = base + be64toh(dyn->tableOffset);
	
	if( argc == 3 )
	{
		int out = open(argv[2], O_WRONLY);
		
		const unsigned bitmapSize = (blockSize / 512 / 8 + 511) / 512 * 512;
		const unsigned blockFullSize = bitmapSize + blockSize;
		
		for(unsigned i = 0; i < maxTableEntries; i++)
		{
			if( bat[i] == -1 )
				continue;
			
			const uint64_t blockOffset = be32toh(bat[i]) * 512ul;
			if( blockOffset + bitmapSize > size )
			{
				fprintf(stderr, "invalid table %d, %lu %lu %lu\n", i, blockOffset, blockFullSize, size);
				exit(1);
			}
			printf("%d: %lu\r", i, blockOffset);
			
			uint8_t *bitmap = base + blockOffset;
			void *data = bitmap + bitmapSize;
			unsigned startSec = -1;
			unsigned contSize = 0;
			static char zeroes[512];
			for(unsigned sec = 0; sec < blockSize / 512; sec++)
			{
				const unsigned byteOffset = sec / 8;
				const unsigned bitOffset = sec % 8;
				
				if( bitmap[byteOffset] & ( 1 << (7 - bitOffset)) )
				{
hasData:
					if( startSec != -1 )
					{
						if( startSec + contSize == sec )
							contSize++;
						else
						{
							if( (uintptr_t)data - (uintptr_t)base + startSec * 512  + contSize * 512> size )
							{
								fprintf(stderr, "invalid table %d, %lu %lu %lu\n", i, blockOffset, blockFullSize, size);
								exit(1);
							}
//							printf("startSec %d contSize %d\n", startSec, contSize);
							const unsigned res = pwrite(out, data + startSec * 512, contSize * 512, (uint64_t)i * blockSize + startSec * 512);
							assert( res == contSize * 512 );
							
							startSec = sec;
							contSize = 1;
						}
					}
					else
					{
						startSec = sec;
						contSize = 1;
					}
				}
			}
			
			if( contSize )
			{
				if( (uintptr_t)data - (uintptr_t)base + startSec * 512 + contSize * 512 > size )
				{
					fprintf(stderr, "invalid table %d, %lu %lu %lu\n", i, blockOffset, blockFullSize, size);
					exit(1);
				}
//				printf("startSec %d contSize %d\n", startSec, contSize);
				const unsigned res = pwrite(out, data + startSec * 512, contSize * 512, (uint64_t)i * blockSize + startSec * 512);
				assert( res == contSize * 512 );
			}
		}
		printf("\nsyncing\n");
		fdatasync(out);
	}
	
}
