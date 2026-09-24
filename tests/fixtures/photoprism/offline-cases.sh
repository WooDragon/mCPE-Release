#!/usr/bin/env bash
# Offline image delivery BDD. The delivery helpers, rather than copied logic, execute in every case.
# shellcheck disable=SC2016 # Quoted child shells deliberately expand their own positional arguments.

IMAGE_SOURCE='docker.io/photoprism/photoprism@sha256:8aba1c708c423b1493e4835f61b3b410898b7accbfd040416e2f1665b2bef8c5'
IMAGE_ID='sha256:2b4df7fce4093791db60ade433e267968f67358dabd5b2172a32eb3c79c49706'
IMAGE_LOCAL='docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc'

image_fixture_new() {
  fixture_new
  export OFFLINE_ARCHIVE="$FIXTURE_ROOT/image.tar"
  export OFFLINE_MODE=first-load
  export OFFLINE_DOCKER_LOG="$FIXTURE_ROOT/offline-docker.log"
  : > "$OFFLINE_DOCKER_LOG"
  printf '%s\n' "$OFFLINE_MODE" > "$FIXTURE_ROOT/offline-state"
  printf '%s\n' healthy > "$FIXTURE_ROOT/anchor-state"
  cat > "$FIXTURE_ROOT/image-runtime.sh" <<'SHIM'
target_anchor_healthy() { [ "$(cat /fixture/anchor-state)" = healthy ]; }
SHIM
  cat > "$FIXTURE_BIN/docker" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$OFFLINE_DOCKER_LOG"
for argument in "$@"; do reference=$argument; done
mode=$(cat /fixture/offline-state)
case "$*" in
  *'image inspect'*)
    case "$reference:$mode" in
      'docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc:cached'|\
      'docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc:loaded-first-load'|\
      'docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc:loaded-load-anchor-lost'|\
      'docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc:expected-only-tagged')
        printf 'sha256:2b4df7fce4093791db60ade433e267968f67358dabd5b2172a32eb3c79c49706|linux|arm64\n'; exit 0 ;;
      'docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc:bad-local'|\
      'docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc:loaded-load-wrong-id')
        printf 'sha256:wrong|linux|arm64\n'; exit 0 ;;
      'docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc:loaded-load-wrong-arch')
        printf 'sha256:2b4df7fce4093791db60ade433e267968f67358dabd5b2172a32eb3c79c49706|linux|amd64\n'; exit 0 ;;
      'sha256:2b4df7fce4093791db60ade433e267968f67358dabd5b2172a32eb3c79c49706:expected-only')
        printf 'sha256:2b4df7fce4093791db60ade433e267968f67358dabd5b2172a32eb3c79c49706|linux|arm64\n'; exit 0 ;;
    esac
    exit 1 ;;
  *'image tag'*)
    [ "$mode" = expected-only ] || exit 1
    printf '%s\n' expected-only-tagged > /fixture/offline-state
    printf tagged > /fixture/offline-tagged
    exit 0 ;;
  *' load -i '*)
    case "$mode" in first-load|load-wrong-id|load-wrong-arch|load-anchor-lost) :;; *) exit 1;; esac
    [ "$mode" = load-anchor-lost ] && printf '%s\n' changed > /fixture/anchor-state
    printf 'loaded-%s\n' "$mode" > /fixture/offline-state
    printf loaded > /fixture/offline-loaded
    exit 0 ;;
  *' pull '*)
    printf pulled > /fixture/offline-pulled
    exit 99 ;;
esac
exit 2
SHIM
  chmod +x "$FIXTURE_BIN/docker"
}

write_archive_sidecar() {
  local payload=${1:-fixture-image}
  printf '%s' "$payload" | gzip -n > "$FIXTURE_ROOT/image.tar.gz"
  sha256sum "$FIXTURE_ROOT/image.tar.gz" | {
    read -r digest _
    printf '%s  image.tar.gz\n' "$digest" > "$FIXTURE_ROOT/image.tar.gz.sha256"
  }
}

run_image_helper() {
  local body=$1
  docker run --rm --user 0:0 \
    -e 'PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    -e OFFLINE_MODE -e OFFLINE_DOCKER_LOG=/fixture/offline-docker.log \
    -e PHOTOPRISM_IMAGE_ARCHIVE=/fixture/image.tar.gz \
    -e PHOTOPRISM_IMAGE_SIDECAR=/fixture/image.tar.gz.sha256 \
    -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    -v "$RUNTIME_DIR/usr/share/photoprism:/usr/share/photoprism:ro" \
    alpine:3.20 /bin/sh -c "$body"
}

case_offline_static_contracts() {
  scenario 'offline image delivery has one shared identity and never gates generation on stat'
  local spec="$RUNTIME_DIR/usr/share/photoprism/image-spec.sh" helper="$REPO_ROOT/scripts/prepare-photoprism-image.sh"
  local runtime="$RUNTIME_DIR/usr/libexec/photoprism/image-helper.sh" compose="$RUNTIME_DIR/usr/share/photoprism/compose.yaml"
  assert_true 'image spec contains exactly the three producer-consumer variables' \
    bash -c 'source "$1" && [ "$(wc -l < "$1")" -eq 3 ] && [ "$(grep -Ec "^PHOTOPRISM_IMAGE_(SOURCE|ID|LOCAL)=" "$1")" -eq 3 ] && [ "$PHOTOPRISM_IMAGE_SOURCE" = "$2" ] && [ "$PHOTOPRISM_IMAGE_ID" = "$3" ] && [ "$PHOTOPRISM_IMAGE_LOCAL" = "$4" ]' _ "$spec" "$IMAGE_SOURCE" "$IMAGE_ID" "$IMAGE_LOCAL"
  assert_true 'build helper has the strict one-output-dir CLI and no stat generation gate' \
    bash -c 'grep -Fq "usage:" "$1" && ! grep -Eq "(^|[^[:alnum:]_])stat([^[:alnum:]_]|$)" "$1"' _ "$helper"
  assert_true 'runtime helper sources the shared image spec instead of duplicating identity' \
    bash -c 'grep -Fq "/usr/share/photoprism/image-spec.sh" "$1" && ! grep -Fq "8aba1c708c423" "$1" && ! grep -Fq "2b4df7fce409" "$1"' _ "$runtime"
  assert_true 'compose requires the worker-exported local image and forbids pulls' \
    bash -c 'grep -Fq "image: \${PHOTOPRISM_IMAGE:?" "$1" && grep -Fq "pull_policy: never" "$1"' _ "$compose"
}

case_image_helper_runtime_paths() {
  scenario 'runtime image helper fails closed offline and uses cached or loaded Docker identity only'
  if ! docker_ready; then skip 'Docker daemon unavailable; runtime image helper integration not run'; return; fi

  image_fixture_new
  assert_true 'missing firmware archive rejects without any Docker pull' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ :; }
    ! photoprism_image_ready
  '
  assert_true 'missing archive does not pull' test ! -e "$FIXTURE_ROOT/offline-pulled"
  fixture_cleanup

  image_fixture_new
  write_archive_sidecar
  printf '%s  image.tar.gz\n' '0000000000000000000000000000000000000000000000000000000000000000' > "$FIXTURE_ROOT/image.tar.gz.sha256"
  assert_true 'bad sidecar rejects before Docker load' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ :; }
    ! photoprism_image_ready
  '
  assert_true 'bad hash never loads or pulls' bash -c 'test ! -e "$1/offline-loaded" && test ! -e "$1/offline-pulled"' _ "$FIXTURE_ROOT"
  fixture_cleanup

  image_fixture_new
  write_archive_sidecar
  assert_true 'first boot validates sidecar and bounded-loads the firmware image' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ :; }
    photoprism_image_ready
  '
  assert_true 'first boot performs exactly the local Docker load' test -e "$FIXTURE_ROOT/offline-loaded"
  assert_true 'first boot never pulls' test ! -e "$FIXTURE_ROOT/offline-pulled"
  fixture_cleanup

  image_fixture_new
  export OFFLINE_MODE=cached
  printf '%s\n' "$OFFLINE_MODE" > "$FIXTURE_ROOT/offline-state"
  assert_true 'valid local tag is idempotent and skips archive load' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ :; }
    photoprism_image_ready
  '
  assert_true 'cached image does not load or pull' bash -c 'test ! -e "$1/offline-loaded" && test ! -e "$1/offline-pulled"' _ "$FIXTURE_ROOT"
  fixture_cleanup

  image_fixture_new
  export OFFLINE_MODE=expected-only
  printf '%s\n' "$OFFLINE_MODE" > "$FIXTURE_ROOT/offline-state"
  assert_true 'correct untagged expected ID is tagged without requiring archive' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ :; }
    photoprism_image_ready
  '
  assert_true 'expected-ID recovery tags and does not pull' bash -c 'test -e "$1/offline-tagged" && test ! -e "$1/offline-pulled"' _ "$FIXTURE_ROOT"
  fixture_cleanup

  image_fixture_new
  export OFFLINE_MODE=bad-local
  printf '%s\n' "$OFFLINE_MODE" > "$FIXTURE_ROOT/offline-state"
  assert_true 'wrong existing local tag fails closed without overwrite' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ :; }
    ! photoprism_image_ready
  '
  assert_true 'wrong existing tag is never replaced, loaded, or pulled' bash -c 'test ! -e "$1/offline-tagged" && test ! -e "$1/offline-loaded" && test ! -e "$1/offline-pulled"' _ "$FIXTURE_ROOT"
  fixture_cleanup
}

case_image_helper_write_anchor() {
  scenario 'new Docker writes recheck the live storage anchor and reject post-load identity mismatches'
  if ! docker_ready; then skip 'Docker daemon unavailable; image write-anchor integration not run'; return; fi

  image_fixture_new
  export OFFLINE_MODE=expected-only
  printf '%s\n' "$OFFLINE_MODE" > "$FIXTURE_ROOT/offline-state"
  printf '%s\n' changed > "$FIXTURE_ROOT/anchor-state"
  assert_true 'lost anchor before tag rejects the untagged expected image' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ printf "%s\\n" "$*" > /fixture/notice; }
    ! photoprism_image_ready
  '
  assert_true 'lost anchor before tag performs no Docker write and emits a phase notice' \
    bash -c 'test ! -e "$1/offline-tagged" && test ! -e "$1/offline-loaded" && grep -Fq "storage anchor changed" "$1/notice"' _ "$FIXTURE_ROOT"
  fixture_cleanup

  image_fixture_new
  write_archive_sidecar
  assert_true 'anchor loss after bounded checksum rejects before Docker load' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ limit=$1; shift; "$@"; result=$?; [ "$limit" -eq 180 ] && { printf checked > /fixture/checksummed; printf changed > /fixture/anchor-state; }; return "$result"; }
    notice(){ printf "%s\\n" "$*" > /fixture/notice; }
    ! photoprism_image_ready
  '
  assert_true 'completed checksum followed by anchor loss starts no image load and emits notice' \
    bash -c 'test -e "$1/checksummed" && test ! -e "$1/offline-loaded" && grep -Fq "before firmware image load" "$1/notice"' _ "$FIXTURE_ROOT"
  fixture_cleanup

  image_fixture_new
  write_archive_sidecar
  export OFFLINE_MODE=load-anchor-lost
  printf '%s\n' "$OFFLINE_MODE" > "$FIXTURE_ROOT/offline-state"
  assert_true 'anchor loss immediately after Docker load rejects instead of accepting the new image' run_image_helper '
    . /usr/libexec/photoprism/image-helper.sh
    . /fixture/image-runtime.sh
    docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
    run_bounded(){ shift; "$@"; }
    notice(){ printf "%s\\n" "$*" > /fixture/notice; }
    ! photoprism_image_ready
  '
  assert_true 'post-load anchor loss is noticed and cannot reach a caller Compose action' \
    bash -c 'test -e "$1/offline-loaded" && grep -Fq "after firmware image load" "$1/notice" && test ! -e "$1/offline-compose"' _ "$FIXTURE_ROOT"
  fixture_cleanup

  local image_mode
  for image_mode in load-wrong-id load-wrong-arch; do
    image_fixture_new
    write_archive_sidecar
    OFFLINE_MODE=$image_mode
    export OFFLINE_MODE
    printf '%s\n' "$OFFLINE_MODE" > "$FIXTURE_ROOT/offline-state"
    assert_true "$OFFLINE_MODE post-load identity rejects before Compose" run_image_helper '
      . /usr/libexec/photoprism/image-helper.sh
      . /fixture/image-runtime.sh
      docker_local(){ unset DOCKER_HOST DOCKER_CONTEXT; docker -H unix:///var/run/docker.sock "$@"; }
      run_bounded(){ shift; "$@"; }
      notice(){ printf "%s\\n" "$*" > /fixture/notice; }
      ! photoprism_image_ready
    '
    assert_true "$OFFLINE_MODE performs load plus a second inspect, then returns failure without Compose" \
      bash -c 'test -e "$1/offline-loaded" && [ "$(grep -Fc "image inspect" "$1/offline-docker.log")" -ge 2 ] && grep -Fq "loaded image identity rejected" "$1/notice" && test ! -e "$1/offline-compose"' _ "$FIXTURE_ROOT"
    fixture_cleanup
  done
}

build_fixture_new() {
  fixture_new
  export BUILD_INPUT="$FIXTURE_ROOT/build-input.tar"
  export BUILD_MODE=valid
  export BUILD_OUTPUT="$FIXTURE_ROOT/output"
  export BUILD_TREE="$FIXTURE_ROOT/build-tree"
  export BUILD_SKOPEO_CALL="$FIXTURE_ROOT/skopeo-call"
  REAL_SHA256SUM=$(command -v sha256sum)
  export REAL_SHA256SUM IMAGE_LOCAL
  mkdir -p "$BUILD_OUTPUT" "$FIXTURE_ROOT/build-tree"
  printf '{"os":"linux","architecture":"arm64"}' > "$FIXTURE_ROOT/build-tree/config.json"
  cat > "$FIXTURE_ROOT/build-tree/manifest.json" <<EOF
[{"Config":"config.json","RepoTags":["$IMAGE_LOCAL"],"Layers":[]}]
EOF
  tar -C "$FIXTURE_ROOT/build-tree" -cf "$BUILD_INPUT" config.json manifest.json
  cat > "$FIXTURE_BIN/skopeo" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" > "$BUILD_SKOPEO_CALL"
for argument in "$@"; do destination=$argument; done
case "$BUILD_MODE" in
  bad-manifest) printf '{}' > "$BUILD_TREE/manifest.json"; tar -C "$BUILD_TREE" -cf "$BUILD_INPUT" config.json manifest.json ;;
  path-traversal) printf '[{"Config":"../config.json","RepoTags":["docker.io/library/mcpe-photoprism:260728-arm64-2b4df7fc"],"Layers":[]}]' > "$BUILD_TREE/manifest.json"; tar -C "$BUILD_TREE" -cf "$BUILD_INPUT" config.json manifest.json ;;
  bad-tag) printf '[{"Config":"config.json","RepoTags":["wrong:tag"],"Layers":[]}]' > "$BUILD_TREE/manifest.json"; tar -C "$BUILD_TREE" -cf "$BUILD_INPUT" config.json manifest.json ;;
  bad-arch) printf '{"os":"linux","architecture":"amd64"}' > "$BUILD_TREE/config.json"; tar -C "$BUILD_TREE" -cf "$BUILD_INPUT" config.json manifest.json ;;
  wrong-config) printf '{"os":"linux","architecture":"arm64","tampered":true}' > "$BUILD_TREE/config.json"; tar -C "$BUILD_TREE" -cf "$BUILD_INPUT" config.json manifest.json ;;
esac
path=${destination#docker-archive:}
path=${path%:$IMAGE_LOCAL}
cp "$BUILD_INPUT" "$path"
SHIM
  cat > "$FIXTURE_BIN/sha256sum" <<'SHIM'
#!/bin/sh
for argument in "$@"; do last=$argument; done
case "$BUILD_MODE:$last" in
  wrong-config:*/config.json) exec "$REAL_SHA256SUM" "$@" ;;
  *:/config.json|*:*/config.json) printf '%s  %s\n' '2b4df7fce4093791db60ade433e267968f67358dabd5b2172a32eb3c79c49706' "$last" ;;
  *) exec "$REAL_SHA256SUM" "$@" ;;
esac
SHIM
  chmod +x "$FIXTURE_BIN/skopeo" "$FIXTURE_BIN/sha256sum"
}

run_build_helper() {
  PATH="$FIXTURE_BIN:$PATH" BUILD_INPUT="$BUILD_INPUT" BUILD_MODE="$BUILD_MODE" BUILD_TREE="$BUILD_TREE" \
    BUILD_SKOPEO_CALL="$BUILD_SKOPEO_CALL" REAL_SHA256SUM="$REAL_SHA256SUM" IMAGE_LOCAL="$IMAGE_LOCAL" \
    "$REPO_ROOT/scripts/prepare-photoprism-image.sh" "$BUILD_OUTPUT"
}

no_build_output() { test ! -e "$BUILD_OUTPUT/image.tar.gz" && test ! -e "$BUILD_OUTPUT/image.tar.gz.sha256"; }
build_helper_rejects() { ! run_build_helper && no_build_output; }

case_image_build_helper_validation() {
  scenario 'build helper normalizes a small archive and rejects malformed manifest identity safely'
  build_fixture_new
  assert_true 'valid small docker archive is copied from pinned arm64 source into normalized compressed output' run_build_helper
  assert_true 'skopeo receives exact source, linux/arm64 overrides, and local archive reference' \
    bash -c 'grep -Fq -- "copy --override-os linux --override-arch arm64 docker://$1 docker-archive:" "$2" && grep -Fq -- ":$3" "$2"' _ "$IMAGE_SOURCE" "$FIXTURE_ROOT/skopeo-call" "$IMAGE_LOCAL"
  assert_true 'successful output has sidecar naming and checksum accepted by standard sha256sum' \
    bash -c 'test -f "$1/image.tar.gz" && (cd "$1" && sha256sum -c image.tar.gz.sha256)' _ "$BUILD_OUTPUT"
  fixture_cleanup

  local rejection_mode
  for rejection_mode in bad-manifest path-traversal bad-tag bad-arch wrong-config; do
    build_fixture_new
    BUILD_MODE=$rejection_mode
    export BUILD_MODE
    assert_true "$BUILD_MODE archive fails before publishing an output" build_helper_rejects
    fixture_cleanup
  done
}

case_offline_compose_config() {
  scenario 'actual Compose file resolves only a supplied local image and preserves never-pull policy'
  local compose_copy env_file rendered
  fixture_new
  compose_copy="$FIXTURE_ROOT/compose.yaml"
  env_file="$FIXTURE_ROOT/photoprism.env"
  rendered="$FIXTURE_ROOT/compose.rendered.yaml"
  printf 'PHOTOPRISM_ADMIN_PASSWORD=0123456789abcdef0123456789abcdef\n' > "$env_file"
  sed "s|/mnt/ssd/PhotoPrism/secrets/photoprism.env|$env_file|" "$RUNTIME_DIR/usr/share/photoprism/compose.yaml" > "$compose_copy"
  assert_true 'Compose parses its real configuration with the worker-provided local image' \
    env PHOTOPRISM_IMAGE="$IMAGE_LOCAL" PHOTOPRISM_HTTP_HOST=192.168.233.1 docker compose -f "$compose_copy" config --no-interpolate
  env PHOTOPRISM_IMAGE="$IMAGE_LOCAL" PHOTOPRISM_HTTP_HOST=192.168.233.1 docker compose -f "$compose_copy" config > "$rendered"
  assert_true 'rendered Compose image is the local reference and its policy remains never' \
    bash -c 'grep -Fq "image: $1" "$2" && grep -Fq "pull_policy: never" "$2"' _ "$IMAGE_LOCAL" "$rendered"
  fixture_cleanup
}
