all: sesparse

sesparse:
	gcc -w -std=c99 -o sesparse any2kvm/sesparse.c
