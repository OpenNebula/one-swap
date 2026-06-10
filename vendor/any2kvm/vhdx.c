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

gcc -std=c99 -Wall -Werror -o vhdx vhdx.c
*/
/*
#define _GNU_SOURCE 1
#define _BSD_SOURCE 1
*/
#define _DEFAULT_SOURCE 1

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdbool.h>
#include <assert.h>

uint32_t		crc32Table[256];

// reverse of CRC32C_POLYNOMIAL		0x1edc6f41UL, used for table init
#define			CRC32C_POLYNOMIAL_REV	0x82f63b78

void initCrc32(void)
{
	for(unsigned i = 0; i < 256; i++)
	{
		unsigned v = i;
		for(unsigned j = 0; j < 8; j++)
		{
			bool xor = (v & 1);
			v >>= 1;
			if( xor )
				v ^= CRC32C_POLYNOMIAL_REV;
		}
		
		crc32Table[i] = v;
	}
}

uint32_t crc32c(void *vdata, unsigned size, unsigned skip)
{
	uint8_t *data = vdata;
	uint32_t crc = -1u;
	
	for(unsigned i = 0; i < size; i++)
	{
		uint8_t val = data[i];
		if( i / 4 == skip / 4 )
			val = 0;
		crc = ( crc >> 8 ) ^ crc32Table[(uint8_t)crc ^ val];
	}
	
	return crc ^ -1u;
}

struct VhdxTypeIdentifier
{
	char			signature[8];
	char			creator[512];
};

const char guid0[16];

struct VhdxHeader
{
	uint32_t		signature;
	uint32_t		crc32c;
	uint64_t		seqNum;
	uint8_t			fileWriteGuid[16];
	uint8_t			dataWriteGuid[16];
	uint8_t			logGuid[16];
	uint16_t		logVersion;
	uint16_t		version;
	uint32_t		logLength;
	uint32_t		logOffset;
	
};


struct VhdxRegionEntry
{
	uint8_t			guid[16];
	uint64_t		fileOffset;
	uint32_t		length;
	uint32_t		required;
};


struct VhdxRegionTable
{
	uint32_t					signature;
	uint32_t					crc32c;
	uint32_t					entriesCount;
	
	struct VhdxRegionEntry		entries[];
};

struct VhdxMetadataEntry
{
	uint8_t			itemId[16];
	uint32_t		offset;
	uint32_t		length;
	uint32_t		isUser:1,
					isVirtualDisk:1,
					isRequired:1,
					zeroes1:29;
	uint32_t		zeroes2;
};

struct VhdxMetadataHeader
{
	uint8_t						signature[8];
	uint16_t					reserved;
	uint16_t					entriesCount;
	uint8_t						reserved2[20];
	
	struct VhdxMetadataEntry	entries[];
} __attribute__((packed));

struct VhdxBatEntry
{
	uint64_t			state:3,
						zeroes:17,
						offsetMB:44;
};

struct VhdxParentLocatorEntry
{
	uint32_t		keyOffset;
	uint32_t		valOffset;
	uint16_t		keyLength;
	uint16_t		valLength;
};

struct VhdxParentLocator
{
	uint8_t			locatorType[16];
	uint16_t		reserved;
	uint16_t		entriesCount;
	
	struct VhdxParentLocatorEntry entries[];
};

struct VhdxFileParameters
{
	uint32_t		blockSize;
	uint32_t		leaveBlockAllocated:1,
					hasParent:1,
					reserverd:30;
};

void printUUid(const uint8_t *uuid)
{
	printf("%08x-%04hx-%04hx-%02hhx%02hhx-%02hhx%02hhx%02hhx%02hhx%02hhx%02hhx",
		*(uint32_t*)&uuid[0],
		*(uint16_t*)&uuid[4],
		*(uint16_t*)&uuid[6],
		uuid[8], uuid[9],
		uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]);
}

void printUnicodeSize(uint16_t *n, unsigned size)
{
	for(unsigned i = 0; i < size/2; i++)
	{
		printf("%c", n[i]);
	}
}

unsigned decodeUnicodeHex(uint16_t *p)
{
	unsigned val = 0;
	for(unsigned i = 0; i < 2; i++)
	{
		val <<= 4;
		switch(p[i])
		{
			case '0'...'9':
				val += p[i] - '0';
				break;
			case 'a'...'f':
				val += p[i] - 'a' + 10;
				break;
			default:
				fprintf(stderr, "invalid hex\n");
				exit(1);
		}
	}
	return val;
}

void utf16_to_8(const uint16_t *val, unsigned valBytesLen, char *out, unsigned outLen)
{
	if( outLen < 4 )
	{
tooSmall:
		fprintf(stderr, "can't convert to utf8. Output buf too small");
		exit(1);
	}
	
	unsigned l = 0;
	for(unsigned pos = 0; pos < valBytesLen / 2; pos++)
	{
		if( l >= outLen - 4 )
			goto tooSmall;
		
		if( val[pos] <= 0x7f )
		{
			out[l++] = val[pos];
		}
		else if( val[pos] <= 0x7ff )
		{
			out[l++] = 0xc0 + ( val[pos] >> 6 );
			out[l++] = 0x80 + ( val[pos] & 0x3f );
		}
		else
		{
			out[l++] = 0xe0 + ( val[pos] >> 12 );
			out[l++] = 0x80 + ( ( val[pos] >> 6 ) & 0x3f );
			out[l++] = 0x80 + ( val[pos] & 0x3f );
		}
	}
	out[l] = 0;
}

int main(int argc, char *argv[])
{
	initCrc32();
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
	
	struct VhdxTypeIdentifier *typeIdent = base;
	if( memcmp(typeIdent->signature, "vhdxfile", 8 ) != 0 )
	{
		fprintf(stderr, "not a vhdx file\n");
		exit(1);
	}
	
	struct VhdxHeader *hdr;
	{
		struct VhdxHeader *hdrs[2];
		hdrs[0] = base + 64*1024;
		hdrs[1] = base + 128*1024;
		
		for(unsigned i = 0; i < 2; i++)
		{
			if( hdrs[i]->signature != 0x64616568 )
			{
				printf("hdr %d inalid signature. skipping\n", i);
				hdrs[i] = NULL;
				continue;
			}
			
			if( hdrs[i]->crc32c != crc32c(hdrs[i], 4096, 4) )
			{
				printf("hdr %d invalid checksum. skipping\n", i);
				hdrs[i] = NULL;
				continue;
			}
		}
		
		if( !hdrs[0] && !hdrs[1] )
		{
			fprintf(stderr, "no valid header found\n");
			exit(1);
		}
		else if( !hdrs[0] )
			hdr = hdrs[1];
		else if( !hdrs[1] )
			hdr = hdrs[0];
		else if( hdrs[0]->seqNum > hdrs[1]->seqNum )
			hdr = hdrs[0];
		else
			hdr = hdrs[1];
	}
	
	if( memcmp(hdr->logGuid, guid0, 16) != 0 )
	{
		fprintf(stderr, "log replay not supported yet\n");
		exit(1);
	}
	
	struct VhdxRegionTable *reg = base + 192 * 1024;
	if( reg->signature != 0x69676572 )
	{
		fprintf(stderr, "region table has invalid signatur\n");
		exit(1);
	}
	
	if( reg->crc32c != crc32c(reg, 64*1024, 4) )
	{
		fprintf(stderr, "region table checksum mismatch\n");
		exit(1);
	}
	
	struct VhdxRegionEntry *batReg = NULL;
	struct VhdxRegionEntry *metadataReg = NULL;
	for(unsigned i = 0; i < reg->entriesCount; i++)
	{
		static const char batGuid[16] = { 0x66, 0x77, 0xc2, 0x2d, 0x23, 0xf6, 0x00, 0x42, 0x9d, 0x64, 0x11, 0x5e, 0x9b, 0xfd, 0x4a, 0x08 };
		static const char metaGuid[16] = { 0x06, 0xa2, 0x7c, 0x8b, 0x90, 0x47, 0x9a, 0x4b, 0xb8, 0xfe, 0x57, 0x5f, 0x05, 0x0f, 0x88, 0x6e };
		
		if( memcmp(reg->entries[i].guid, batGuid, 16) == 0 )
			batReg = &reg->entries[i];
		else if( memcmp(reg->entries[i].guid, metaGuid, 16) == 0 )
			metadataReg = &reg->entries[i];
		else if (reg->entries[i].required )
		{
			fprintf(stderr, "unknown required region\n");
			exit(1);
		}
	}
	
	if( !batReg || !metadataReg )
	{
		fprintf(stderr, "bat or metadata region missing\n");
		exit(1);
	}
	
	struct VhdxMetadataHeader *metadata = base + metadataReg->fileOffset;
	
	if( memcmp(metadata->signature, "metadata", 8) != 0 )
	{
		fprintf(stderr, "metadata invalid signatiure\n");
		exit(1);
	}
	
	uint32_t		blockSize = -1;
	uint64_t		virtualDiskSize = -1ul;
	bool			hasParent;
	
	char parentPathForScp[1024] = {};
	char parentVolumePath[2048] = {};
	uint8_t			parentGuid[16];
	
	bool gotParentPath = false;
	bool gotParentGuid = false;
	bool gotParentVolumePath = false;
	
	for(unsigned i = 0; i < metadata->entriesCount; i++)
	{
		static const char fileParamsGuid[16] = { 0x37, 0x67, 0xa1, 0xca, 0x36, 0xfa, 0x43, 0x4d, 0xb3, 0xb6, 0x33, 0xf0, 0xaa, 0x44, 0xe7, 0x6b};
		static const char virtualDiskSizeGuid[16] = { 0x24, 0x42, 0xa5, 0x2f, 0x1b, 0xcd, 0x76, 0x48, 0xb2, 0x11, 0x5d, 0xbe, 0xd8, 0x3b, 0xf4, 0xb8 };
		static const char virtualDiskIdGuid[16] = { 0xab, 0x12, 0xca, 0xbe, 0xe6, 0xb2, 0x23, 0x45, 0x93, 0xef, 0xc3, 0x9, 0xe0, 0x0, 0xc7, 0x46 };
		static const char logicalSectorSizeGuid[16] = { 0x1d, 0xbf, 0x41, 0x81, 0x6f, 0xa9, 0x9, 0x47, 0xba, 0x47, 0xf2, 0x33, 0xa8, 0xfa, 0xab, 0x5f };
		static const char physicalSectorSizeGuid[16] = { 0xc7, 0x48, 0xa3, 0xcd, 0x5d, 0x44, 0x71, 0x44, 0x9c, 0xc9, 0xe9, 0x88, 0x52, 0x51, 0xc5, 0x56};
		static const char parentLocator[16] = { 0x2d, 0x5f, 0xd3, 0xa8, 0xb, 0xb3, 0x4d, 0x45, 0xab, 0xf7, 0xd3, 0xd8, 0x48, 0x34, 0xab, 0xc};
		
		const void *metaBase = (void*)metadata;
		if( memcmp(metadata->entries[i].itemId, fileParamsGuid, 16) == 0 )
		{
			assert( metadata->entries[i].length == 8 );
			const struct VhdxFileParameters *fparams = (metaBase + metadata->entries[i].offset);
			blockSize = fparams->blockSize;
			hasParent = fparams->hasParent;
		}
		else if( memcmp(metadata->entries[i].itemId, virtualDiskSizeGuid, 16) == 0 )
		{
			assert( metadata->entries[i].length == 8 );
			virtualDiskSize = *(uint64_t*)(metaBase + metadata->entries[i].offset);
		}
		else if( memcmp(metadata->entries[i].itemId, virtualDiskIdGuid, 16) == 0 )
		{
			assert( metadata->entries[i].length == 16 );
			continue;
		}
		else if( memcmp(metadata->entries[i].itemId, logicalSectorSizeGuid, 16) == 0 )
		{
			assert( metadata->entries[i].length == 4 );
			const uint32_t ss = *(uint32_t*)(metaBase + metadata->entries[i].offset);
			if( ss != 512 )
			{
				fprintf(stderr, "unsupported virtual sector size %d\n", ss);
				exit(1);
			}
		}
		else if( memcmp(metadata->entries[i].itemId, physicalSectorSizeGuid, 16) == 0 )
		{
			assert( metadata->entries[i].length == 4 );
			const uint32_t ss = *(uint32_t*)(metaBase + metadata->entries[i].offset);
			if( ss != 512 && ss != 4096 )
			{
				fprintf(stderr, "unsupported physical sector size %d\n", ss);
				exit(1);
			}
		}
		else if( memcmp(metadata->entries[i].itemId, parentLocator, 16) == 0 )
		{
			static const char parentLocatorVhdx[16] = { 0xb7, 0xef, 0x4a, 0xb0, 0x9e, 0xd1, 0x81, 0x4a, 0xb7,  0x89, 0x25, 0xb8, 0xe9, 0x44, 0x59, 0x13 };
			const struct VhdxParentLocator *loc = (metaBase + metadata->entries[i].offset);
			
			if( memcmp(loc->locatorType, parentLocatorVhdx, 16) != 0 )
			{
				fprintf(stderr, "unknown parent locator type\n");
				exit(1);
			}
			
			const uint16_t parentLinkage[] = { 'p', 'a', 'r', 'e', 'n', 't', '_', 'l', 'i', 'n', 'k', 'a', 'g', 'e' };
			const uint16_t absoluteWin32Path[] = { 'a', 'b', 's', 'o', 'l', 'u', 't', 'e', '_', 'w', 'i', 'n', '3', '2', '_', 'p', 'a', 't', 'h' };
			const uint16_t volumePath[] = { 'v', 'o', 'l', 'u', 'm', 'e', '_', 'p', 'a', 't', 'h' };
			
			for( unsigned i = 0; i < loc->entriesCount; i++)
			{
				void *key = (void*)loc + loc->entries[i].keyOffset;
				uint16_t *val = (void*)loc + loc->entries[i].valOffset;
				if( loc->entries[i].keyLength == sizeof(parentLinkage) && memcmp(key, parentLinkage, sizeof(parentLinkage)) == 0 )
				{
					gotParentGuid = true;
					if( val[0] != '{' )
					{
invalidLinkage:
						printf("invalid parent linkage: ");
						printUnicodeSize(val, loc->entries[i].valLength);
						printf("\n");
						exit(1);
					}
					
					uint16_t *ptr = val + 1;
					for(unsigned i = 0; i < 4; i++ )
					{
						parentGuid[3 - i] = decodeUnicodeHex(ptr);
						ptr += 2;
					}
					if( ptr[0] != '-' )
						goto invalidLinkage;
					ptr++;
					for(unsigned i = 0; i < 2; i++)
					{
						parentGuid[4 + 1 - i] = decodeUnicodeHex(ptr);
						ptr += 2;
					}
					if( ptr[0] != '-' )
						goto invalidLinkage;
					ptr++;
					for(unsigned i = 0; i < 2; i++)
					{
						parentGuid[6 + 1 - i] = decodeUnicodeHex(ptr);
						ptr += 2;
					}
					if( ptr[0] != '-' )
						goto invalidLinkage;
					ptr++;
					for(unsigned i = 0; i < 2; i++)
					{
						parentGuid[8 + i] = decodeUnicodeHex(ptr);
						ptr += 2;
					}
					if( ptr[0] != '-' )
						goto invalidLinkage;
					ptr++;
					for(unsigned i = 0; i < 6; i++)
					{
						parentGuid[10 + i] = decodeUnicodeHex(ptr);
						ptr += 2;
					}
					
					if( ptr[0] != '}' )
						goto invalidLinkage;
				}
				else if( loc->entries[i].keyLength == sizeof(absoluteWin32Path) && memcmp(key, absoluteWin32Path, sizeof(absoluteWin32Path)) == 0 )
				{
					gotParentPath = true;
					utf16_to_8(val, loc->entries[i].valLength, parentPathForScp, sizeof(parentPathForScp));
					for(unsigned pos = 0; parentPathForScp[pos]; pos++)
					{
						if( parentPathForScp[pos] == '\\' )
							parentPathForScp[pos] = '/';
					}
				}
				else if( loc->entries[i].keyLength == sizeof(volumePath) && memcmp(key, volumePath, sizeof(volumePath)) == 0 )
				{
					gotParentVolumePath = true;
					utf16_to_8(val, loc->entries[i].valLength, parentVolumePath, sizeof(parentVolumePath));
				}
				else if(0)
				{
					printUnicodeSize(key, loc->entries[i].keyLength);
					printf("=");
					printUnicodeSize(val, loc->entries[i].valLength);
					printf("\n");
				}
			}
			
		}
		else
			abort();
	}
	
	
	
	if( blockSize == -1 || virtualDiskSize == -1 )
	{
		fprintf(stderr, "fileParams or virtualDiskSize missing\n");
		exit(1);
	}
	
	if( hasParent )
	{
		if( !gotParentPath || !gotParentGuid || !gotParentVolumePath )
		{
			fprintf(stderr, "hasParent but no parentPath or no parentGuid or no parentVolumePath\n");
			exit(1);
		}
	}
	
	if( argc == 2 )
	{
		printf("virtualSize=%ld\n", virtualDiskSize);
		printf("dataGuid=");
		printUUid(hdr->dataWriteGuid);
		printf("\n");
		if( hasParent )
		{
			printf("parentDataGuid=");
			printUUid(parentGuid);
			printf("\n");
			printf("parentPath=%s\n", parentPathForScp);
			printf("parentVolumePath=%s\n", parentVolumePath);
		}
		exit(0);
	}
	
	{
		int out = open(argv[2], O_WRONLY);
		if( out == -1 )
		{
			perror("open");
			exit(1);
		}
		
		const unsigned chunkRatio = (1ull << 23) * 512 / blockSize;
		
		struct VhdxBatEntry *bat = base + batReg->fileOffset;
		
		unsigned batId = 0;
		unsigned nextBmapId = chunkRatio;
		unsigned entriesFromLastBmap = 0;
		uint64_t virtualOffset = 0;
		
		while(virtualOffset < virtualDiskSize)
		{
			if( entriesFromLastBmap == chunkRatio )
			{
				batId++;
				entriesFromLastBmap = 0;
				nextBmapId += chunkRatio + 1;
				continue;
			}
			
			switch( bat[batId].state )
			{
				case 0:
				case 1:
				case 2:
				case 3:
					break;
				
				case 6:
					{
						const unsigned res = pwrite(out, base + bat[batId].offsetMB * 1024ull*1024, blockSize, virtualOffset);
						assert( res == blockSize );
					}
					break;
				
				case 7:
					{
						assert( bat[nextBmapId].state == 6 );
						uint8_t *bitmap = base + bat[nextBmapId].offsetMB * 1024ull*1024 + entriesFromLastBmap * blockSize / 512 / 8;
						
						void *data = base + bat[batId].offsetMB * 1024ull*1024;
						unsigned startSec = -1;
						unsigned contSize = 0;
						
						for(unsigned sec = 0; sec < blockSize / 512; sec++)
						{
							const unsigned byteOffset = sec / 8;
							const unsigned bitOffset = sec % 8;
							
							if( bitmap[byteOffset] & ( 1 << bitOffset ) )
							{
								if( startSec != -1 )
								{
									if( startSec + contSize == sec )
										contSize++;
									else
									{
										if( (uintptr_t)data - (uintptr_t)base + startSec * 512  + contSize * 512 > size )
										{
											fprintf(stderr, "invalid table\n");
											exit(1);
										}
										const unsigned res = pwrite(out, data + startSec * 512, contSize * 512, virtualOffset + startSec * 512);
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
								fprintf(stderr, "invalid table\n");
								exit(1);
							}
							const unsigned res = pwrite(out, data + startSec * 512, contSize * 512, virtualOffset + startSec * 512);
							assert( res == contSize * 512 );
						}
					}
					break;
			}
			
			entriesFromLastBmap++;
			batId++;
			virtualOffset += blockSize;
		}
		
		printf("\nsyncing\n");
		fdatasync(out);
	}
}

