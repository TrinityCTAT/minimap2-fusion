#!/bin/bash

set -ev

VERSION=`cat VERSION.txt`

docker push trinityctat/ctat_lr_fusion:${VERSION}
docker push trinityctat/ctat_lr_fusion:latest

