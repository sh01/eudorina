#!/bin/bash

# gdc values
CC=gdc
INT="-fintfc -fintfc-dir"
OUT="-o"
VER="-fversion"
L=""

# ldc2 values
#CC=ldc2
#INT="-Hd"
#OUT="-of"
#VER="-d-version"
#L="-L"


INC=include/eudorina/
LIB=lib/eudorina/

rm -rf build/$INC/* build/$LIB/* build/bin/* 2>/dev/null

mkdir -p build/$INC build/$LIB build/bin 2>/dev/null
for sdir in db; do
	mkdir build/$INC/${sdir}/
	mkdir build/$LIB/${sdir}/
done

pushd build
for bn in text logging io signal service_aggregation db/sqlit3; do
	DN=$(dirname $bn)
	FN=$(basename $bn)
	ofn=${FN}.o
	CMD0="$CC -g $OUT $ofn -c ${VER}=Linux -Iinclude/ ${INT}=${INC}/$DN ../src/${bn}.d"
	CMD1="ar rcs ${LIB}/${DN}/lib${FN}.a $ofn"
	echo $CMD0; $CMD0
	echo $CMD1; $CMD1
	rm $ofn
done

popd

for bn in test1; do
	CMD0="$CC -g $OUT build/bin/${bn} -Ibuild/include/ $L-Lbuild/lib/ $L-Lbuild/lib/eudorina $L-Lbuild/lib/eudorina/db ${VER}=Linux src/test/${bn}.d $L-llogging $L-lservice_aggregation $L-lsignal $L-lio $L-ltext"
	echo $CMD0; $CMD0
done

for bn in test_sq0; do
	CMD0="$CC -g $OUT build/bin/${bn} -Ibuild/include/ $L-Lbuild/lib/ $L-Lbuild/lib/eudorina $L-Lbuild/lib/eudorina/db ${VER}=Linux src/test/${bn}.d $L-lsqlit3 $L-lsqlite3 $L-llogging $L-lservice_aggregation $L-lsignal $L-lio $L-ltext"
	echo $CMD0; $CMD0
done
