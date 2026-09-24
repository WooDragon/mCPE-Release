#!/bin/sh
# Offline PhotoPrism image identity gate. This file is sourced by worker.sh after Docker is ready.

IMAGE_SPEC=/usr/share/photoprism/image-spec.sh
IMAGE_ARCHIVE=${PHOTOPRISM_IMAGE_ARCHIVE:-/usr/share/photoprism/image.tar.gz}
IMAGE_SIDECAR=${PHOTOPRISM_IMAGE_SIDECAR:-/usr/share/photoprism/image.tar.gz.sha256}

# shellcheck source=/dev/null
. "$IMAGE_SPEC" || return 1

# Print image ID and platform for a local Docker reference.
# Argument: image reference or image ID. Returns nonzero when Docker cannot inspect it.
image_identity() {
    docker_local image inspect --format '{{.Id}}|{{.Os}}|{{.Architecture}}' "$1" 2>/dev/null
}

# Classify one Docker reference against the shared immutable identity.
# Argument: image reference. Returns 0=valid, 1=absent, 2=present but wrong.
image_identity_status() {
    identity=$(image_identity "$1") || return 1
    [ "$identity" = "$PHOTOPRISM_IMAGE_ID|linux|arm64" ] && return 0
    return 2
}

# Verify the firmware archive sidecar without writing it to mutable overlay storage.
# Returns 0 only for its exact standard checksum line and matching compressed archive.
image_archive_valid() {
    [ -f "$IMAGE_ARCHIVE" ] && [ ! -L "$IMAGE_ARCHIVE" ] && [ -r "$IMAGE_ARCHIVE" ] || return 1
    [ -f "$IMAGE_SIDECAR" ] && [ ! -L "$IMAGE_SIDECAR" ] && [ -r "$IMAGE_SIDECAR" ] || return 1
    [ "$(wc -l < "$IMAGE_SIDECAR" 2>/dev/null)" -eq 1 ] || return 1
    grep -Eq '^[0-9a-f]{64}  image.tar.gz$' "$IMAGE_SIDECAR" || return 1
    archive_dir=$(dirname "$IMAGE_ARCHIVE")
    sidecar_name=$(basename "$IMAGE_SIDECAR")
    # Checksum work is bounded too: a corrupted compressed archive must not pin the lifecycle worker.
    # shellcheck disable=SC2016 # The bounded child expands its own positional directory and sidecar.
    run_bounded 180 sh -c 'cd "$1" && exec sha256sum -c "$2" >/dev/null 2>&1' sh "$archive_dir" "$sidecar_name"
}

# Require the still-open storage anchor immediately around a Docker write phase.
# Argument: phase name for the operator notice.
image_anchor_healthy() {
    target_anchor_healthy && return 0
    notice "PhotoPrism storage anchor changed ${1}; refusing image write"
    return 1
}

# Recover a valid untagged image by applying the local Compose reference and rechecking it.
# Returns 0=tagged/verified, 1=unsafe failure, 2=expected ID absent and archive fallback is allowed.
image_tag_expected() {
    image_identity_status "$PHOTOPRISM_IMAGE_ID"
    expected_status=$?
    [ "$expected_status" -eq 1 ] && return 2
    [ "$expected_status" -eq 0 ] || return 1
    image_anchor_healthy 'before image tag' || return 1
    docker_local image tag "$PHOTOPRISM_IMAGE_ID" "$PHOTOPRISM_IMAGE_LOCAL" || return 1
    image_anchor_healthy 'after image tag' || { image_identity_status "$PHOTOPRISM_IMAGE_LOCAL" >/dev/null; return 1; }
    image_identity_status "$PHOTOPRISM_IMAGE_LOCAL"
}

# Make the local Compose reference available from firmware only; network pulls are intentionally absent.
# Returns 0 when the image is already valid, tagged from a valid local ID, or loaded and re-inspected.
photoprism_image_ready() {
    image_identity_status "$PHOTOPRISM_IMAGE_LOCAL"
    local_status=$?
    [ "$local_status" -eq 0 ] && return 0
    if [ "$local_status" -eq 2 ]; then
        notice 'PhotoPrism local image tag has unexpected identity; refusing overwrite'
        return 1
    fi
    image_tag_expected
    tag_status=$?
    [ "$tag_status" -eq 0 ] && return 0
    [ "$tag_status" -eq 2 ] || return 1
    if ! image_archive_valid; then
        notice 'PhotoPrism firmware image archive or checksum unavailable/invalid; refusing pull'
        return 1
    fi
    image_anchor_healthy 'before firmware image load' || return 1
    # shellcheck disable=SC2016 # The bounded child expands its positional archive argument.
    run_bounded 1800 sh -c 'unset DOCKER_HOST DOCKER_CONTEXT; exec docker -H unix:///var/run/docker.sock load -i "$1"' sh "$IMAGE_ARCHIVE" || {
        notice 'PhotoPrism firmware image load failed or timed out; refusing pull'
        return 1
    }
    image_anchor_healthy 'after firmware image load' || { image_identity_status "$PHOTOPRISM_IMAGE_LOCAL" >/dev/null; return 1; }
    image_identity_status "$PHOTOPRISM_IMAGE_LOCAL" || {
        notice 'PhotoPrism loaded image identity rejected; refusing pull'
        return 1
    }
}
