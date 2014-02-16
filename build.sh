#!/bin/bash
CC=gdc

INC=include/eudorina/
LIB=lib/eudorina/

mkdir -p build/$INC build/$LIB build/bin 2>/dev/null
rm -rf build/$INC/* build/$LIB/* build/bin/* 2>/dev/null

pushd build
for bn in text logging io; do
	ofn=${bn}.o
	CMD0="$CC -o $ofn -c -fversion=Linux -Iinclude/ -fintfc -fintfc-dir=${INC} ../src/${bn}.d"
	CMD1="ar rcs ${LIB}/lib${bn}.a $ofn"
	echo $CMD0; $CMD0
	echo $CMD1; $CMD1
	rm $ofn
done

popd

for bn in test1; do
	CMD0="gdc -o build/bin/${bn} -Ibuild/include/ -Lbuild/lib/ -fversion=Linux src/test/${bn}.d  -llogging -lio -ltext"
	echo $CMD0; $CMD0
done
