#!/usr/bin/env bash
# PhotoPrism build-hook fixture. It executes the delivered post-feeds hook against
# the pinned upstream dockerd init; it never reimplements the hook's sed patches.

PHOTOPRISM_DOCKERD_FIXTURE="$REPO_ROOT/tests/fixtures/photoprism/dockerd.init.upstream"

prepare_photoprism_post_feeds_tree() {
  local tree=$1
  mkdir -p "$tree/feeds/packages/utils/dockerd/files" || return 1
  cp "$PHOTOPRISM_DOCKERD_FIXTURE" "$tree/feeds/packages/utils/dockerd/files/dockerd.init" || return 1
  # B04 sources the hook in this shell just as diy-part2 does.
  # shellcheck source=scripts/diy-lib.sh disable=SC1091
  . "$REPO_ROOT/scripts/diy-lib.sh"
}

# Use a separate -e shell: Bash suppresses errexit for commands evaluated by if.
source_photoprism_post_feeds() {
  local tree=$1
  bash -e -c '. "$1"; cd "$2"; . "$3"' _ \
    "$REPO_ROOT/scripts/diy-lib.sh" "$tree" "$REPO_ROOT/devices/r5s-outdoor/post-feeds.sh"
}

case_photoprism_post_feeds_patches() {
  scenario 'B04i — PhotoPrism post-feeds patches both pinned dockerd procd command sites'
  local fixture_tree patched_init missing_tree missing_init missing_site missing_failures
  fixture_tree=$(mktemp -d)
  if prepare_photoprism_post_feeds_tree "$fixture_tree" \
    && source_photoprism_post_feeds "$fixture_tree" >/dev/null 2>&1; then
    patched_init="$fixture_tree/feeds/packages/utils/dockerd/files/dockerd.init"
    if grep -Eq '^[[:space:]]*procd_set_param command /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --config-file="\$\{DOCKERD_CONF\}"$' "$patched_init" \
       && grep -Eq '^[[:space:]]*procd_set_param command /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd$' "$patched_init"; then
      ok 'post-feeds applies both dockerd guard patches to pinned upstream init'
    else
      bad 'post-feeds did not apply both dockerd guard patches'
    fi
  else
    bad 'post-feeds failed against pinned upstream dockerd fixture'
  fi
  rm -rf "$fixture_tree"

  missing_failures=0
  for missing_site in config-file default; do
    missing_tree=$(mktemp -d)
    prepare_photoprism_post_feeds_tree "$missing_tree"
    missing_init="$missing_tree/feeds/packages/utils/dockerd/files/dockerd.init"
    case "$missing_site" in
      config-file) printf '%s\n' 'procd_set_param command /usr/bin/dockerd' > "$missing_init" ;;
      default) printf '%s\n' "procd_set_param command /usr/bin/dockerd --config-file=\"\${DOCKERD_CONF}\"" > "$missing_init" ;;
    esac
    if source_photoprism_post_feeds "$missing_tree" >/dev/null 2>&1; then
      bad "post-feeds accepted missing dockerd $missing_site patch site"
      missing_failures=1
    else
      ok "post-feeds fails loudly when dockerd $missing_site patch site is absent"
    fi
    rm -rf "$missing_tree"
  done
  [ "$missing_failures" = 0 ] || true
}
