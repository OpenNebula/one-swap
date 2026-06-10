all: sesparse

sesparse:
	gcc -w -std=c99 -o sesparse vendor/any2kvm/sesparse.c
