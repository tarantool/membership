#!/bin/bash

TAG=$(git describe --exact-match HEAD 2>/dev/null)
if [ -z "$TAG" ]
then
	echo "Skipping release: no git tag found."
	exit 0
fi

echo TAG = \"$TAG\"
mkdir -p release
sed -e "s/branch = '.\+'/tag = '$TAG'/g" \
    -e "s/version = '.\+'/version = '$TAG-1'/g" \
    -e "s/BUILD_DOC = '.\+'/BUILD_DOC = 'YES'/g" \
    membership-scm-1.rockspec > release/membership-$TAG-1.rockspec

tarantoolctl rocks make release/membership-$TAG-1.rockspec
tarantoolctl rocks pack membership $TAG && mv membership-$TAG-1.all.rock release/

mkdir -p release-doc
cp -RT doc/ release-doc/membership-$TAG-1
