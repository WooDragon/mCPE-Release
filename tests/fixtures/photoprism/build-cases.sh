#!/usr/bin/env bash
# Shared outdoor post-feeds inputs; execute the delivered hook, never its copy.

PHOTOPRISM_DOCKERD_FIXTURE="$REPO_ROOT/tests/fixtures/photoprism/dockerd.init.upstream"
PHOTOPRISM_MT76_FIXTURE="$REPO_ROOT/tests/fixtures/mt7921-fail-stop/upstream/package/Makefile"
PHOTOPRISM_HOOK_EXIT=0

# All callers need both fixed upstream inputs before sourcing the outdoor hook.
prepare_photoprism_post_feeds_tree() {
  local tree=$1
  mkdir -p "$tree/package/kernel/mt76" "$tree/feeds/packages/utils/dockerd/files" || return 1
  cp "$PHOTOPRISM_MT76_FIXTURE" "$tree/package/kernel/mt76/Makefile" || return 1
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

# Preserve each real child stream and its exit, including expected failures.
run_photoprism_post_feeds() {
  local tree=$1
  if source_photoprism_post_feeds "$tree" > "$tree/hook.stdout" 2> "$tree/hook.stderr"; then
    PHOTOPRISM_HOOK_EXIT=0
  else
    PHOTOPRISM_HOOK_EXIT=$?
  fi
  printf 'HOOK_RESULT tree=%s exit=%s\n' "$tree" "$PHOTOPRISM_HOOK_EXIT"
  cat "$tree/hook.stdout"
  cat "$tree/hook.stderr" >&2
}

# Match the first error's owner/reason/target, not any nonzero child status.
photoprism_dockerd_failure_matches() {
  local tree=$1 site=$2 status=$3 description first_error init
  [ "$status" -eq 1 ] || return 1
  case "$site" in
    config-file) description='config-file' ;;
    default) description='default' ;;
    *) return 1 ;;
  esac
  IFS= read -r first_error < "$tree/hook.stderr" || return 1
  [[ "$first_error" == "ERROR [diy]: dockerd: guard $description command — sed 零匹配,"* ]] || return 1
  [[ "$first_error" == *' @ feeds/packages/utils/dockerd/files/dockerd.init' ]] || return 1
  grep -Fxq '==> [diy] mt76: install fixed recovery fail-stop prepare hook' "$tree/hook.stdout" || return 1
  init="$tree/feeds/packages/utils/dockerd/files/dockerd.init"
  [ -f "$init" ] || return 1
  if [ "$site" = default ]; then
    grep -Fxq '==> [diy] dockerd: guard config-file command' "$tree/hook.stdout" || return 1
    # shellcheck disable=SC2016 # The command contains literal upstream Make/UCI text.
    grep -Eq '^[[:space:]]*procd_set_param command /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --config-file="\$\{DOCKERD_CONF\}"$' "$init" || return 1
  fi
}

# The one-line negative input retains only the opposite real command site.
photoprism_remove_dockerd_site() {
  local tree=$1 site=$2 init
  init="$tree/feeds/packages/utils/dockerd/files/dockerd.init"
  case "$site" in
    config-file) printf '%s\n' 'procd_set_param command /usr/bin/dockerd' > "$init" ;;
    default) printf '%s\n' "procd_set_param command /usr/bin/dockerd --config-file=\"\${DOCKERD_CONF}\"" > "$init" ;;
    *) return 1 ;;
  esac
}

# Keep the original positive assertion, with complete setup and real output.
check_photoprism_post_feeds_positive() {
  local tree init
  tree=$(mktemp -d) || { bad 'post-feeds fixture allocation failed'; return; }
  if ! prepare_photoprism_post_feeds_tree "$tree"; then
    bad 'post-feeds positive fixture setup failed'
    rm -rf "$tree"
    return
  fi
  run_photoprism_post_feeds "$tree"
  init="$tree/feeds/packages/utils/dockerd/files/dockerd.init"
  # shellcheck disable=SC2016 # DOCKERD_CONF is literal text in the delivered file.
  if [ "$PHOTOPRISM_HOOK_EXIT" -eq 0 ] \
     && grep -Eq '^[[:space:]]*procd_set_param command /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --config-file="\$\{DOCKERD_CONF\}"$' "$init" \
     && grep -Eq '^[[:space:]]*procd_set_param command /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd$' "$init"; then
    ok 'post-feeds applies both dockerd guard patches to pinned upstream init'
  else
    bad 'post-feeds failed or did not apply both dockerd guard patches'
  fi
  rm -rf "$tree"
}

# Setup failure is not the expected missing-site failure.
check_photoprism_post_feeds_missing_site() {
  local site=$1 tree
  tree=$(mktemp -d) || { bad "dockerd $site fixture allocation failed"; return; }
  if ! prepare_photoprism_post_feeds_tree "$tree" \
     || ! photoprism_remove_dockerd_site "$tree" "$site"; then
    bad "dockerd $site fixture setup failed"
    rm -rf "$tree"
    return
  fi
  run_photoprism_post_feeds "$tree"
  if photoprism_dockerd_failure_matches "$tree" "$site" "$PHOTOPRISM_HOOK_EXIT"; then
    ok "post-feeds fails at the actual missing dockerd $site sed_required site"
  else
    bad "post-feeds missing dockerd $site failed for the wrong reason or succeeded"
  fi
  rm -rf "$tree"
}

case_photoprism_post_feeds_patches() {
  scenario 'B04i — PhotoPrism post-feeds patches both pinned dockerd procd command sites'
  check_photoprism_post_feeds_positive
  check_photoprism_post_feeds_missing_site config-file
  check_photoprism_post_feeds_missing_site default
}

# Local-only prerequisite partitions reuse the same constructor as all callers.
case_photoprism_post_feeds_prerequisites() {
  scenario 'B04i inputs — complete fixed inputs and failed copy sources'
  local tree missing saved_recipe=$PHOTOPRISM_MT76_FIXTURE saved_dockerd=$PHOTOPRISM_DOCKERD_FIXTURE
  tree=$(mktemp -d) || { bad 'prerequisite fixture allocation failed'; return; }
  if prepare_photoprism_post_feeds_tree "$tree" \
     && cmp -s "$PHOTOPRISM_MT76_FIXTURE" "$tree/package/kernel/mt76/Makefile" \
     && cmp -s "$PHOTOPRISM_DOCKERD_FIXTURE" "$tree/feeds/packages/utils/dockerd/files/dockerd.init"; then
    ok 'shared constructor copies both complete fixed inputs'
  else
    bad 'shared constructor lacks a complete fixed input'
  fi
  rm -rf "$tree"
  for missing in mt76 dockerd; do
    tree=$(mktemp -d) || { bad "$missing fixture allocation failed"; continue; }
    case "$missing" in
      mt76) PHOTOPRISM_MT76_FIXTURE="$tree/absent-mt76" ;;
      dockerd) PHOTOPRISM_DOCKERD_FIXTURE="$tree/absent-dockerd" ;;
    esac
    if prepare_photoprism_post_feeds_tree "$tree"; then
      bad "shared constructor accepted missing $missing source"
    else
      ok "shared constructor rejects missing $missing source before hook execution"
    fi
    PHOTOPRISM_MT76_FIXTURE=$saved_recipe
    PHOTOPRISM_DOCKERD_FIXTURE=$saved_dockerd
    rm -rf "$tree"
  done
}

# Produce real errors, then require the classifier to reject the wrong owner.
case_photoprism_post_feeds_error_ownership() {
  scenario 'B04i errors — earlier mt76 and opposite dockerd errors are not accepted'
  local site other tree
  for site in missing-recipe config-file default; do
    tree=$(mktemp -d) || { bad "$site ownership fixture allocation failed"; continue; }
    if ! prepare_photoprism_post_feeds_tree "$tree"; then
      bad "$site ownership fixture setup failed"
      rm -rf "$tree"
      continue
    fi
    if [ "$site" = missing-recipe ]; then
      rm -f "$tree/package/kernel/mt76/Makefile"
    else
      photoprism_remove_dockerd_site "$tree" "$site" || { bad 'missing-site input failed'; rm -rf "$tree"; continue; }
    fi
    run_photoprism_post_feeds "$tree"
    if [ "$site" = missing-recipe ]; then
      if [ "$PHOTOPRISM_HOOK_EXIT" -eq 1 ] \
         && grep -q '^ERROR \[mt76\]: missing recipe:' "$tree/hook.stderr" \
         && ! photoprism_dockerd_failure_matches "$tree" config-file "$PHOTOPRISM_HOOK_EXIT" \
         && ! photoprism_dockerd_failure_matches "$tree" default "$PHOTOPRISM_HOOK_EXIT"; then
        ok 'actual earlier missing-recipe error is rejected by both dockerd oracles'
      else
        bad 'earlier missing-recipe error was accepted as a dockerd failure'
      fi
    else
      if [ "$site" = config-file ]; then other=default; else other=config-file; fi
      if photoprism_dockerd_failure_matches "$tree" "$site" "$PHOTOPRISM_HOOK_EXIT" \
         && ! photoprism_dockerd_failure_matches "$tree" "$other" "$PHOTOPRISM_HOOK_EXIT"; then
        ok "actual $site error matches only its own dockerd site"
      else
        bad "actual $site error was assigned to the wrong dockerd site"
      fi
    fi
    rm -rf "$tree"
  done
}

# The registration set drives expected counts; each case must execute three assertions.
run_photoprism_post_feeds_local() {
  local cases=(case_photoprism_post_feeds_patches case_photoprism_post_feeds_prerequisites case_photoprism_post_feeds_error_ownership)
  local entry start=$((PASS+FAIL)) scenario_count_before=$SCENARIOS expected=0
  for entry in "${cases[@]}"; do
    "$entry"
    expected=$((expected+3))
  done
  printf 'post_feeds_local scenarios=%s ran=%s passed=%s failed=%s expected=%s\n' \
    "$((SCENARIOS-scenario_count_before))" "$((PASS+FAIL-start))" "$PASS" "$FAIL" "$expected"
  [ "$((SCENARIOS-scenario_count_before))" -eq "${#cases[@]}" ] \
    && [ "$((PASS+FAIL-start))" -eq "$expected" ] && [ "$FAIL" -eq 0 ]
}

# Mutate only a disposable copy of this test file, never a production source.
write_photoprism_fixture_mutant() {
  python3 -B - "$1" "$2" "$3" <<'PY'
import sys
from pathlib import Path
source, destination, mutation = map(str, sys.argv[1:])
text = Path(source).read_text()
name = 'prepare_photoprism_post_feeds_tree' if mutation == 'drop-recipe' else 'photoprism_dockerd_failure_matches'
begin = text.index(name + '() {')
end = text.index('\n}\n', begin) + 3
body = text[begin:end]
if mutation == 'drop-recipe':
    old = '  cp "$PHOTOPRISM_MT76_FIXTURE" "$tree/package/kernel/mt76/Makefile" || return 1'
    assert body.count(old) == 1
    body = body.replace(old, '  : # removed prerequisite copy')
elif mutation == 'any-nonzero':
    body = name + '() {\n  [ "$3" -ne 0 ]\n}'
elif mutation == 'swap-sites':
    old = "config-file) description='config-file' ;;\n    default) description='default' ;;"
    assert body.count(old) == 1
    body = body.replace(old, "config-file) description='default' ;;\n    default) description='config-file' ;;")
else:
    raise ValueError(mutation)
Path(destination).write_text(text[:begin] + body + text[end:])
PY
}

# Every mutant must pass syntax and execute the same full local registration set.
run_photoprism_post_feeds_mutants() {
  local mutation tree status ran=0 rejected=0
  for mutation in drop-recipe any-nonzero swap-sites; do
    tree=$(mktemp -d) || return 1
    if ! write_photoprism_fixture_mutant "${BASH_SOURCE[0]}" "$tree/build-cases.sh" "$mutation" \
       || ! bash -n "$tree/build-cases.sh"; then
      printf 'MUTANT_UNDECIDABLE %s syntax/source failure\n' "$mutation" >&2
      rm -rf "$tree"
      return 1
    fi
    printf 'MUTANT_SYNTAX_OK %s\n' "$mutation"
    if bash -u -c '
      REPO_ROOT=$1
      . "$2"
      PASS=0; FAIL=0; SCENARIOS=0
      ok() { PASS=$((PASS+1)); printf "PASS %s\n" "$1"; }
      bad() { FAIL=$((FAIL+1)); printf "FAIL %s\n" "$1"; }
      scenario() { SCENARIOS=$((SCENARIOS+1)); printf "SCENARIO %s\n" "$1"; }
      run_photoprism_post_feeds_local
    ' _ "$REPO_ROOT" "$tree/build-cases.sh" > "$tree/mutant.stdout" 2> "$tree/mutant.stderr"; then
      status=0
    else
      status=$?
    fi
    printf 'MUTANT_BEGIN %s\n' "$mutation"
    cat "$tree/mutant.stdout"
    cat "$tree/mutant.stderr" >&2
    ran=$((ran+1))
    if [ "$status" -eq 1 ] \
       && grep -Eq '^post_feeds_local scenarios=3 ran=9 passed=[0-9]+ failed=[1-9][0-9]* expected=9$' "$tree/mutant.stdout"; then
      rejected=$((rejected+1))
      printf 'MUTANT_REJECTED %s actual_exit=%s\n' "$mutation" "$status"
    else
      printf 'MUTANT_UNDECIDABLE_OR_ESCAPED %s actual_exit=%s\n' "$mutation" "$status" >&2
      rm -rf "$tree"
      return 1
    fi
    rm -rf "$tree"
  done
  printf 'post_feeds_mutations ran=%s rejected=%s escaped=%s expected=3\n' "$ran" "$rejected" "$((ran-rejected))"
  [ "$ran" -eq 3 ] && [ "$rejected" -eq 3 ]
}
