#!/usr/bin/env bash

validate_repo_release(){
  local failed=0 f required=(pooly-server-guard.sh lib/core.sh lib/health.sh lib/drift.sh lib/discord.sh lib/update.sh lib/systemd.sh lib/main.sh VERSION)
  for f in "${required[@]}"; do
    if [[ ! -s "$POOLY_REPO_DIR/$f" ]]; then echo "FAIL: missing release file: $f"; failed=1; fi
  done
  if [[ $failed -ne 0 ]]; then return 1; fi
  for f in "$POOLY_REPO_DIR/pooly-server-guard.sh" "$POOLY_REPO_DIR"/lib/*.sh; do
    bash -n "$f" || failed=1
  done
  return "$failed"
}

self_update(){
  section "POOLY SERVER GUARD UPDATE CHECK"
  load_env; health_defaults
  echo "Running version: $VERSION"; echo "Auto update: ${POOLY_GUARD_AUTO_UPDATE:-1}"; echo "Repo dir: $POOLY_REPO_DIR"; echo "Install path: $POOLY_INSTALL_PATH"; echo "Git user: ${REPORT_OWNER:-$(id -un)}"
  if [[ "${POOLY_GUARD_AUTO_UPDATE:-1}" != "1" ]]; then echo "SKIP: auto update disabled"; echo "UPDATE RESULT: PASS"; return 0; fi
  if ! command -v git >/dev/null 2>&1; then echo "FAIL: git is not installed"; echo "UPDATE RESULT: FAIL"; return 1; fi
  if [[ ! -d "$POOLY_REPO_DIR/.git" ]]; then echo "FAIL: repo missing at $POOLY_REPO_DIR"; echo "UPDATE RESULT: FAIL"; return 1; fi
  local branch remote_ref before after repo_version installed_changed=0 tmp_install
  branch="${POOLY_GUARD_AUTO_UPDATE_BRANCH:-main}"; remote_ref="origin/$branch"
  before="$(run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"; echo "Local repo before: $before"
  if ! run_as_report_owner git -C "$POOLY_REPO_DIR" fetch --quiet --all --prune; then echo "FAIL: git fetch failed"; echo "UPDATE RESULT: FAIL"; return 1; fi
  if ! run_as_report_owner git -C "$POOLY_REPO_DIR" reset --hard "$remote_ref" >/dev/null; then echo "FAIL: git reset to $remote_ref failed"; echo "UPDATE RESULT: FAIL"; return 1; fi
  after="$(run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"; repo_version="$(cat "$POOLY_REPO_DIR/VERSION" 2>/dev/null || echo unknown)"
  echo "Local repo after:  $after"; echo "Latest repo version: $repo_version"
  if ! validate_repo_release; then echo "FAIL: repo release validation failed; install skipped"; echo "UPDATE RESULT: FAIL"; return 1; fi
  if [[ ! -x "$POOLY_INSTALL_PATH" ]] || ! cmp -s "$POOLY_REPO_DIR/pooly-server-guard.sh" "$POOLY_INSTALL_PATH"; then
    need_sudo; tmp_install="$(mktemp)"; install -m 755 "$POOLY_REPO_DIR/pooly-server-guard.sh" "$tmp_install"; $SUDO install -m 755 "$tmp_install" "$POOLY_INSTALL_PATH"; rm -f "$tmp_install"
    [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$POOLY_INSTALL_PATH" 2>/dev/null || true
    installed_changed=1; echo "UPDATED: installed script refreshed from validated repo"
  else echo "PASS: installed script already matches repo"; fi
  if [[ "$repo_version" != "$VERSION" ]]; then echo "INFO: this running process is v$VERSION; installed script is now repo v$repo_version"; echo "INFO: the next timer/manual run will execute the updated script."; fi
  [[ "$installed_changed" == "1" ]] && echo "UPDATE ACTION: INSTALLED" || echo "UPDATE ACTION: NONE"; echo "UPDATE RESULT: PASS"
}
