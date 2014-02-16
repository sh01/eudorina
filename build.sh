#!/bin/bash
CC=gdc

mkdir build build/include build/lib 2>/dev/null
rm build/include/* build/lib/* 2>/dev/null
pushd build

for bn in text logging io; do
	ofn=${bn}.o
	CMD0="$CC -o $ofn -c -fversion=Linux -fintfc -fintfc-dir=include/ -I../src/ ../src/${bn}.d"
	CMD1="ar rcs lib/${bn}.a $ofn"
	echo $CMD0; $CMD0
	echo $CMD1; $CMD1
	rm $ofn
done
popd
