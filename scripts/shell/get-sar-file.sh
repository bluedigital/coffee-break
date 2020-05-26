#!/bin/bash

set -e

# Script to get sar output using ssh and scp
# Usage: get-sar-file.sh [sar_file_name] [key_files_local_path]
# Usage example: get-sar-file.sh sa04 ~/.ssh
# -------------------------------
# Environment variables:
#   - INSTANCES: array with connection specifications.
#
# Environment variables example:
# export INSTANCES=(
#   "i-00000000000000000" "key_name.pem" "root@x.x.x.x" "/var/log/sa/"
#   "i-00000000000000001" "other_key_name.pem" "root@y.y.y.y" "/var/log/sa/"
# )

FILE_NAME=$1
KEY_PATH=$2

COUNT=${#INSTANCES[@]}

for ((i=0; i<COUNT; i+=4)); do

  INSTANCE_ID=${INSTANCES[i]}
  INSTANCE_KEY="$KEY_PATH/${INSTANCES[i+1]}"
  INSTANCE_CONN="${INSTANCES[i+2]}"
  REMOTE_FILE="${INSTANCES[i+3]}$FILE_NAME"

  OUTPUT_PATH="sar-output/$INSTANCE_ID"

  echo "Getting file from $INSTANCE_ID ($INSTANCE_CONN) using key $INSTANCE_KEY: $OUTPUT_PATH"

  mkdir -p "$OUTPUT_PATH"

  ssh -i "$INSTANCE_KEY" "$INSTANCE_CONN" "LC_TIME='POSIX' sar -A -t -f $REMOTE_FILE > /tmp/$FILE_NAME.txt"
  scp -i "$INSTANCE_KEY" "$INSTANCE_CONN:/tmp/$FILE_NAME.txt" "$OUTPUT_PATH/$FILE_NAME.txt"
done

echo "Done."