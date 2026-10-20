#!/usr/bin/env bash
# After browser shows the verification code at sdk.cloud.google.com/authcode.html:
#   ./infrastructure/gcp/finish_auth.sh PASTE_CODE_HERE
set -euo pipefail
CODE="${1:?usage: finish_auth.sh <verification-code>}"
echo "$CODE" > /tmp/gcloud_auth_code.txt
echo "Code submitted to waiting gcloud auth process."
echo "Also run: gcloud auth application-default login"
