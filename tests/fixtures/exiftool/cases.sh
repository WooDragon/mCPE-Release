#!/usr/bin/env bash
# Source from bdd-matrix-build.sh; --exiftool-only runs these scenarios alone.
# Each check loads the delivered config, guard, orchestration or package recipe.
exiftool_cases() {
  local tmp recipe dev mode config line rc
  tmp=$(mktemp -d) || return 1
  recipe="$REPO_ROOT/package/exiftool/Makefile"
  scenario "B49 — ExifTool is built in only for r5s-outdoor"
  for dev in $ALL_DEVICES; do
    if [ "$dev" = r5s-outdoor ]; then
      if assemble "$dev" | grep -qxF 'CONFIG_PACKAGE_exiftool=y'; then ok "$dev ExifTool=y"; else bad "$dev missing ExifTool=y"; fi
    elif assemble "$dev" | grep -q 'CONFIG_PACKAGE_exiftool'; then bad "$dev ExifTool leaked"; else ok "$dev no ExifTool selection"; fi
  done
  scenario "B50 — Real guard rejects non-built-in ExifTool without rewriting config"
  for mode in y missing not-set module prefix suffix value-suffix; do
    config="$tmp/$mode.config"
    assemble r5s-outdoor | grep -v 'CONFIG_PACKAGE_exiftool' > "$config"
    case "$mode" in
      y) line='CONFIG_PACKAGE_exiftool=y' ;;
      missing) line='' ;;
      not-set) line='# CONFIG_PACKAGE_exiftool is not set' ;;
      module) line='CONFIG_PACKAGE_exiftool=m' ;;
      prefix) line='XCONFIG_PACKAGE_exiftool=y' ;;
      suffix) line='CONFIG_PACKAGE_exiftool-extra=y' ;;
      value-suffix) line='CONFIG_PACKAGE_exiftool=y-extra' ;;
    esac
    printf '%s\n' "$line" >> "$config"
    cp "$config" "$config.before"
    if verify_device_packages r5s-outdoor "$config" 2>"$config.err"; then rc=0; else rc=$?; fi
    if ! cmp -s "$config" "$config.before"; then bad "$mode guard rewrote config"
    elif [ "$mode" = y ] && [ "$rc" -eq 0 ]; then ok "exact =y accepted, config unchanged"
    elif [ "$mode" != y ] && [ "$rc" -ne 0 ] && grep -Fq 'CONFIG_PACKAGE_exiftool=y' "$config.err"; then ok "$mode rejected, config unchanged"
    else bad "$mode unexpected guard rc=$rc"; fi
  done
  if verify_device_packages r5s-outdoor "$tmp/nonexistent" 2>"$tmp/missing.err"; then
    bad "missing config accepted"
  elif grep -Fq 'CONFIG_PACKAGE_exiftool=y' "$tmp/missing.err" && [ ! -e "$tmp/nonexistent" ]; then
    ok "missing config rejected with ExifTool diagnostic, no config created"
  else
    bad "missing config diagnostic or absence incorrect"
  fi
  for dev in r2s r3s r5s r68s x86; do
    if verify_device_packages "$dev" "$tmp/nonexistent"; then ok "$dev exempt even without config"; else bad "$dev not exempt"; fi
  done
  scenario "B51 — Versioned source, hash, license and runtime installation are pinned"
  if [ -f "$recipe" ] && python3 "$REPO_ROOT/tests/fixtures/exiftool/recipe-check.py" "$recipe"; then ok "recipe source/dependency contract"; else bad "recipe source/dependency contract"; fi
  if [ -f "$recipe" ] && python3 "$REPO_ROOT/tests/fixtures/exiftool/recipe-check.py" "$recipe" --install; then ok "actual recipe installs executable and complete runtime tree only"; else bad "actual recipe install layout"; fi
  scenario "B52 — Package overlay precedes feeds update/install; config follows install"
  if python3 "$REPO_ROOT/tests/fixtures/exiftool/recipe-check.py" "$REPO_ROOT/scripts/build-firmware.sh" --overlay; then ok "overlay timing and hidden/nested files"; else bad "overlay timing or copying"; fi
  rm -rf "$tmp"
}
exiftool_cases
