#!/bin/bash
mkdir -p /output
cp "$(dirname "$0")/poc.bin" /output/poc.bin
cp "$(dirname "$0")/fix.patch" /output/fix.patch
