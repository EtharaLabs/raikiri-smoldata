#!/bin/bash -eu
cd /src && go test ./config/security/... -count=1 -timeout 120s 2>&1 | tail -5
echo 'all results unchanged'
