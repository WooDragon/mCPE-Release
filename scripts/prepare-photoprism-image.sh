#!/usr/bin/env bash
# Build the verified, offline PhotoPrism Docker archive for the firmware files tree.

set -euo pipefail

usage() {
  printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
  exit 2
}

# Print an actionable error and leave no completed-looking output behind.
# Arguments: error message.
fail() {
  printf 'prepare-photoprism-image: %s\n' "$1" >&2
  exit 1
}

# Require an executable needed to validate or package the archive.
# Arguments: command name.
require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command unavailable: $1"
}

# Accept only a portable, archive-relative path without traversal components.
# Arguments: candidate tar member path.
safe_member_path() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] || return 1
  [[ "/$1/" != *'/../'* ]]
}

[ "$#" -eq 1 ] || usage
output_dir=$1
[ -d "$output_dir" ] || fail "output directory does not exist: $output_dir"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=/dev/null
. "$repo_root/devices/r5s-outdoor/photoprism/files/usr/share/photoprism/image-spec.sh"

for required in skopeo jq tar gzip sha256sum mv mktemp; do
  require_command "$required"
done

stage=$(mktemp -d "$output_dir/.photoprism-image.XXXXXX")
archive="$stage/docker-archive.tar"
config_file="$stage/config.json"
compressed="$stage/image.tar.gz"
sidecar="$stage/image.tar.gz.sha256"
completed=0

# Staging makes an interrupted or failed invocation unambiguously unusable.
cleanup() {
  rm -rf "$stage"
  if [ "$completed" -ne 1 ]; then
    rm -f "$output_dir/image.tar.gz" "$output_dir/image.tar.gz.sha256"
  fi
}
trap cleanup EXIT

skopeo copy --override-os linux --override-arch arm64 \
  "docker://${PHOTOPRISM_IMAGE_SOURCE}" \
  "docker-archive:${archive}:${PHOTOPRISM_IMAGE_LOCAL}"

manifest=$(tar -xOf "$archive" manifest.json) || fail 'docker archive lacks manifest.json'
printf '%s' "$manifest" | jq -e --arg local_ref "$PHOTOPRISM_IMAGE_LOCAL" '
  type == "array" and length == 1 and
  (.[] | type == "object" and
    (.RepoTags | type == "array" and length == 1 and .[0] == $local_ref) and
    (.Config | type == "string" and length > 0))
' >/dev/null || fail 'docker archive manifest identity rejected'

config_member=$(printf '%s' "$manifest" | jq -er '.[0].Config') || fail 'docker archive config path rejected'
safe_member_path "$config_member" || fail 'docker archive config path is unsafe'
tar -xOf "$archive" -- "$config_member" > "$config_file" || fail 'docker archive config is unreadable'

actual_id="sha256:$(sha256sum "$config_file" | cut -d ' ' -f 1)"
[ "$actual_id" = "$PHOTOPRISM_IMAGE_ID" ] || fail 'docker archive config digest rejected'
jq -e '.os == "linux" and .architecture == "arm64"' "$config_file" >/dev/null || fail 'docker archive platform rejected'

gzip -n -c "$archive" > "$compressed"
size=$(wc -c < "$compressed")
[ "$size" -le $((1536 * 1024 * 1024)) ] || fail 'compressed docker archive exceeds 1536 MiB'
compressed_digest=$(sha256sum "$compressed" | cut -d ' ' -f 1) || fail 'compressed docker archive checksum failed'
printf '%s  image.tar.gz\n' "$compressed_digest" > "$sidecar"

mv -f "$compressed" "$output_dir/image.tar.gz"
mv -f "$sidecar" "$output_dir/image.tar.gz.sha256"
completed=1
