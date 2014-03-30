#!/bin/bash
CC=gdc

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
	CMD0="$CC -g -o $ofn -c -fversion=Linux -Iinclude/ -fintfc -fintfc-dir=${INC}/$DN ../src/${bn}.d"
	CMD1="ar rcs ${LIB}/${DN}/lib${FN}.a $ofn"
	echo $CMD0; $CMD0
	echo $CMD1; $CMD1
	rm $ofn
done

popd

for bn in test1; do
	CMD0="gdc -g -o build/bin/${bn} -Ibuild/include/ -Lbuild/lib/ -Lbuild/lib/eudorina -Lbuild/lib/eudorina/db -fversion=Linux src/test/${bn}.d -llogging -lservice_aggregation -lsignal -lio -ltext"
	echo $CMD0; $CMD0
done

for bn in test_sq0; do
	CMD0="gdc -g -o build/bin/${bn} -Ibuild/include/ -Lbuild/lib/ -Lbuild/lib/eudorina -Lbuild/lib/eudorina/db -fversion=Linux src/test/${bn}.d -lsqlit3 -lsqlite3 -llogging -lservice_aggregation -lsignal -lio -ltext"
	echo $CMD0; $CMD0
done
