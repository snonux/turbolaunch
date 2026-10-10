#!/usr/bin/env bash
# Starts a throwaway single-node Garage S3 server in Docker for the sync tests,
# with the bucket turbolaunch-test and a fresh random key that may use it, and
# prints the test variables as KEY=value lines (the format of $GITHUB_ENV):
#
#   tool/garage_test.sh >>"$GITHUB_ENV"                  # in CI
#   eval "$(tool/garage_test.sh | sed 's/^/export /')"   # in a shell
#
# The S3 API listens on port 3900 of the host; an emulator reaches it at
# 10.0.2.2 (S3_TEST_PHONE_ENDPOINT). Data lives in the container only;
# `docker rm -f turbolaunch-garage` throws it away.
set -euo pipefail
image=${GARAGE_IMAGE:-dxflrs/garage:v2.1.0}
name=turbolaunch-garage
bucket=turbolaunch-test
dir=$(mktemp -d)

cat >"$dir/garage.toml" <<EOF
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "0.0.0.0:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$(openssl rand -hex 32)"

[s3_api]
s3_region = "garage"
api_bind_addr = "0.0.0.0:3900"
EOF

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p 3900:3900 -v "$dir/garage.toml:/etc/garage.toml:ro" "$image" >/dev/null
garage() { docker exec -e RUST_LOG=warn "$name" /garage "$@"; }

for _ in $(seq 30); do
  garage status >/dev/null 2>&1 && break
  sleep 1
done
node=$(garage node id -q 2>/dev/null | cut -d@ -f1)
garage layout assign -z dc1 -c 1G "$node" >/dev/null
garage layout apply --version 1 >/dev/null
garage bucket create "$bucket" >/dev/null
key_id="GK$(openssl rand -hex 12)"
secret=$(openssl rand -hex 32)
garage key import --yes -n turbolaunch-test-app "$key_id" "$secret" >/dev/null
garage bucket allow --read --write --owner "$bucket" --key "$key_id" >/dev/null

# The S3 API answers a signed list once the layout is live.
for _ in $(seq 30); do
  curl -sS --fail -o /dev/null --aws-sigv4 "aws:amz:garage:s3" --user "$key_id:$secret" \
    "http://localhost:3900/$bucket?list-type=2" 2>/dev/null && break
  sleep 1
done
curl -sS --fail -o /dev/null --aws-sigv4 "aws:amz:garage:s3" --user "$key_id:$secret" \
  "http://localhost:3900/$bucket?list-type=2"
echo "Garage $image is up on port 3900 with bucket $bucket" >&2

echo "S3_TEST_ENDPOINT=http://localhost:3900"
echo "S3_TEST_PHONE_ENDPOINT=http://10.0.2.2:3900"
echo "S3_TEST_BUCKET=$bucket"
echo "S3_TEST_ACCESS_KEY_ID=$key_id"
echo "S3_TEST_SECRET_KEY=$secret"
