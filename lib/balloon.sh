#!/usr/bin/env bash

[[ "${BASH_SOURCE[0]}" == "$0" ]] && { echo "This library must be sourced by pooly-server-guard.sh"; exit 1; }

balloon_defaults(){
  : "${POOLY_BALLOON_MONITOR_ENABLED:=0}"
  : "${POOLY_BALLOON_WARN_MIB:=1024}"
  : "${POOLY_BALLOON_HISTORY_MAX_LINES:=10000}"
  : "${POOLY_BALLOON_LOCK_WAIT_SECONDS:=2}"
  : "${POOLY_BALLOON_STATE_DIR:=${POOLY_STATE_DIR:-/etc/pooly/server-guard-state}/balloon}"
  : "${POOLY_BALLOON_VMSTAT_PATH:=/proc/vmstat}"
  : "${POOLY_BALLOON_MEMINFO_PATH:=/proc/meminfo}"
  : "${POOLY_BALLOON_PSI_PATH:=/proc/pressure/memory}"
  : "${POOLY_BALLOON_BOOT_ID_PATH:=/proc/sys/kernel/random/boot_id}"
  : "${POOLY_BALLOON_SYSFS_ROOT:=/sys}"
  : "${POOLY_BALLOON_ASSUME_SUPPORTED:=0}"
}

balloon_uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }
balloon_decimal(){ [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

balloon_state_dir_safe(){
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 1
  case "$dir" in /|/etc|/home|/root) return 1 ;; esac
  [[ "$dir" != *$'\n'* && "$dir" != *$'\r'* ]]
}

balloon_pages_to_mib(){
  local pages="${1:-0}" page_size="${2:-4096}"
  awk -v p="$pages" -v s="$page_size" 'BEGIN{printf "%.2f", (p*s)/1048576}'
}

balloon_kib_to_mib(){
  local kib="${1:-0}"
  awk -v k="$kib" 'BEGIN{printf "%.2f", k/1024}'
}

balloon_pages_to_gib(){
  local pages="${1:-0}" page_size="${2:-4096}"
  awk -v p="$pages" -v s="$page_size" 'BEGIN{printf "%.2f", (p*s)/1073741824}'
}

balloon_bound_device_present(){
  local driver_dir="${POOLY_BALLOON_SYSFS_ROOT%/}/bus/virtio/drivers/virtio_balloon"
  [[ -d "$driver_dir" ]] || return 1
  find "$driver_dir" -maxdepth 1 -type l -name 'virtio*' -print -quit 2>/dev/null | grep -q .
}

balloon_collect_sample(){
  local vmstat="$POOLY_BALLOON_VMSTAT_PATH" meminfo="$POOLY_BALLOON_MEMINFO_PATH"
  local psi_path="$POOLY_BALLOON_PSI_PATH" boot_path="$POOLY_BALLOON_BOOT_ID_PATH"
  local inflate=0 deflate=0 migrate=0 pswpin=0 pswpout=0 pgmajfault=0 oom_kill=0
  local mem_total_kib=0 mem_available_kib=0 swap_total_kib=0 swap_free_kib=0
  local psi_some="0" psi_full="0" boot_id epoch utc page_size

  [[ -r "$vmstat" ]] || return 1
  [[ -r "$meminfo" ]] || return 1
  [[ -r "$boot_path" ]] || return 1

  local have_inflate=0 have_deflate=0
  read -r inflate deflate migrate pswpin pswpout pgmajfault oom_kill have_inflate have_deflate < <(
    awk '
      BEGIN{i=d=m=swapin=swapout=major=oomc=0; have_i=have_d=0}
      $1=="balloon_inflate"{i=$2; have_i=1}
      $1=="balloon_deflate"{d=$2; have_d=1}
      $1=="balloon_migrate"{m=$2}
      $1=="pswpin"{swapin=$2}
      $1=="pswpout"{swapout=$2}
      $1=="pgmajfault"{major=$2}
      $1=="oom_kill"{oomc=$2}
      END{print i,d,m,swapin,swapout,major,oomc,have_i,have_d}
    ' "$vmstat"
  )

  [[ "$have_inflate" == "1" && "$have_deflate" == "1" ]] || return 3
  for value in "$inflate" "$deflate" "$migrate" "$pswpin" "$pswpout" "$pgmajfault" "$oom_kill"; do
    balloon_uint "$value" || return 1
  done

  if [[ "$POOLY_BALLOON_ASSUME_SUPPORTED" != "1" ]] && ! balloon_bound_device_present; then
    if (( inflate == 0 && deflate == 0 && migrate == 0 )); then
      return 3
    fi
  fi

  read -r mem_total_kib mem_available_kib swap_total_kib swap_free_kib < <(
    awk '
      BEGIN{mt=ma=st=sf=0}
      $1=="MemTotal:"{mt=$2}
      $1=="MemAvailable:"{ma=$2}
      $1=="SwapTotal:"{st=$2}
      $1=="SwapFree:"{sf=$2}
      END{print mt,ma,st,sf}
    ' "$meminfo"
  )
  for value in "$mem_total_kib" "$mem_available_kib" "$swap_total_kib" "$swap_free_kib"; do
    balloon_uint "$value" || return 1
  done
  (( mem_total_kib > 0 )) || return 1
  (( mem_available_kib <= mem_total_kib )) || return 1
  (( swap_free_kib <= swap_total_kib )) || return 1

  if [[ -r "$psi_path" ]]; then
    read -r psi_some psi_full < <(
      awk '
        /^some /{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){split($i,a,"="); some=a[2]}}
        /^full /{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){split($i,a,"="); full=a[2]}}
        END{print some+0,full+0}
      ' "$psi_path"
    )
  fi
  balloon_decimal "$psi_some" || psi_some="0"
  balloon_decimal "$psi_full" || psi_full="0"

  boot_id="$(tr -d '[:space:]' < "$boot_path" 2>/dev/null || true)"
  [[ "$boot_id" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  epoch="$(date +%s)"
  utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  page_size="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
  balloon_uint "$page_size" || page_size=4096
  (( page_size > 0 )) || page_size=4096

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$boot_id" "$epoch" "$utc" "$inflate" "$deflate" "$migrate" "$pswpin" "$pswpout" \
    "$pgmajfault" "$oom_kill" "$mem_total_kib" "$mem_available_kib" "$swap_total_kib" \
    "$swap_free_kib" "$psi_some" "$psi_full" "$page_size"
}

balloon_read_state(){
  local state_file="$1"
  local version boot_id epoch inflate deflate migrate pswpin pswpout pgmajfault oom_kill outstanding state extra
  [[ -r "$state_file" ]] || return 1
  IFS=$'\t' read -r version boot_id epoch inflate deflate migrate pswpin pswpout pgmajfault oom_kill outstanding state extra < "$state_file" || return 2
  [[ "$version" == "v1" && -z "${extra:-}" ]] || return 2
  [[ "$boot_id" =~ ^[A-Za-z0-9-]+$ ]] || return 2
  for value in "$epoch" "$inflate" "$deflate" "$migrate" "$pswpin" "$pswpout" "$pgmajfault" "$oom_kill" "$outstanding"; do
    balloon_uint "$value" || return 2
  done
  [[ "$state" =~ ^[A-Z_]+$ ]] || return 2
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$boot_id" "$epoch" "$inflate" "$deflate" "$migrate" "$pswpin" "$pswpout" "$pgmajfault" "$oom_kill" "$outstanding" "$state"
}

balloon_write_state(){
  local state_file="$1" boot_id="$2" epoch="$3" inflate="$4" deflate="$5" migrate="$6"
  local pswpin="$7" pswpout="$8" pgmajfault="$9" oom_kill="${10}" outstanding="${11}" state="${12}"
  local tmp
  tmp="$(mktemp "${state_file}.tmp.XXXXXX")" || return 1
  if ! printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$boot_id" "$epoch" "$inflate" "$deflate" "$migrate" "$pswpin" "$pswpout" \
    "$pgmajfault" "$oom_kill" "$outstanding" "$state" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$state_file"
}

balloon_append_history(){
  local history_file="$1" max_lines="$2" line="$3"
  local tmp trimmed
  tmp="$(mktemp "${history_file}.tmp.XXXXXX")" || return 1
  trimmed="$(mktemp "${history_file}.trim.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if [[ -r "$history_file" ]]; then
    cat "$history_file" > "$tmp" || { rm -f "$tmp" "$trimmed"; return 1; }
  fi
  printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp" "$trimmed"; return 1; }
  tail -n "$max_lines" "$tmp" > "$trimmed" || { rm -f "$tmp" "$trimmed"; return 1; }
  chmod 600 "$trimmed" || { rm -f "$tmp" "$trimmed"; return 1; }
  mv -f "$trimmed" "$history_file" || { rm -f "$tmp" "$trimmed"; return 1; }
  rm -f "$tmp"
}

balloon_release_lock(){
  local fd="${1:-}"
  [[ -n "$fd" ]] || return 0
  balloon_uint "$fd" || return 0
  flock -u "$fd" 2>/dev/null || true
  eval "exec ${fd}>&-"
}

balloon_status(){
  load_env || { section "POOLY MEMORY BALLOON"; echo "WARN: unable to load safe Server Guard environment"; echo "BALLOON STATE: ERROR"; echo "BALLOON RESULT: WARN"; return 2; }
  balloon_defaults
  section "POOLY MEMORY BALLOON"

  if [[ "$POOLY_BALLOON_MONITOR_ENABLED" != "1" ]]; then
    echo "BALLOON SUPPORTED: not checked"
    echo "BALLOON STATE: DISABLED"
    echo "BALLOON RESULT: PASS"
    return 0
  fi

  if ! balloon_uint "$POOLY_BALLOON_WARN_MIB" || (( POOLY_BALLOON_WARN_MIB < 1 || POOLY_BALLOON_WARN_MIB > 1048576 )); then
    echo "WARN: invalid POOLY_BALLOON_WARN_MIB=$POOLY_BALLOON_WARN_MIB"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi
  if ! balloon_uint "$POOLY_BALLOON_HISTORY_MAX_LINES" || (( POOLY_BALLOON_HISTORY_MAX_LINES < 1 || POOLY_BALLOON_HISTORY_MAX_LINES > 100000 )); then
    echo "WARN: invalid POOLY_BALLOON_HISTORY_MAX_LINES=$POOLY_BALLOON_HISTORY_MAX_LINES"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi
  if ! balloon_uint "$POOLY_BALLOON_LOCK_WAIT_SECONDS" || (( POOLY_BALLOON_LOCK_WAIT_SECONDS > 60 )); then
    echo "WARN: invalid POOLY_BALLOON_LOCK_WAIT_SECONDS=$POOLY_BALLOON_LOCK_WAIT_SECONDS"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi

  local sample rc
  if sample="$(balloon_collect_sample)"; then rc=0; else rc=$?; fi
  if (( rc == 3 )); then
    echo "BALLOON SUPPORTED: no"
    echo "BALLOON STATE: UNSUPPORTED"
    echo "BALLOON RESULT: PASS"
    return 0
  elif (( rc != 0 )); then
    echo "BALLOON SUPPORTED: unknown"
    echo "WARN: unable to read balloon metrics safely"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi

  local boot_id="" epoch=0 utc="" inflate=0 deflate=0 migrate=0 pswpin=0 pswpout=0 pgmajfault=0 oom_kill=0
  local mem_total_kib=0 mem_available_kib=0 swap_total_kib=0 swap_free_kib=0 psi_some=0 psi_full=0 page_size=4096
  IFS=$'\t' read -r boot_id epoch utc inflate deflate migrate pswpin pswpout pgmajfault oom_kill \
    mem_total_kib mem_available_kib swap_total_kib swap_free_kib psi_some psi_full page_size <<< "$sample"

  local state_dir="$POOLY_BALLOON_STATE_DIR" state_file history_file lock_file lock_fd
  state_file="$state_dir/state.tsv"
  history_file="$state_dir/history.tsv"
  lock_file="$state_dir/state.lock"

  if ! balloon_state_dir_safe "$state_dir"; then
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: refusing unsafe balloon state directory: $state_dir"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi
  if [[ -L "$state_dir" || -L "$state_file" || -L "$history_file" || -L "$lock_file" ]]; then
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: refusing symlinked balloon state path"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    install -d -o root -g root -m 700 "$state_dir" 2>/dev/null || {
      echo "BALLOON SUPPORTED: yes"
      echo "WARN: unable to create protected balloon state directory: $state_dir"
      echo "BALLOON STATE: ERROR"
      echo "BALLOON RESULT: WARN"
      return 2
    }
  elif ! install -d -m 700 "$state_dir" 2>/dev/null; then
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: unable to create protected balloon state directory: $state_dir"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi
  if [[ ! -d "$state_dir" || -L "$state_dir" ]]; then
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: balloon state path is not a safe directory: $state_dir"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi
  if [[ ${EUID:-$(id -u)} -eq 0 && "$(stat -c '%u' "$state_dir" 2>/dev/null || echo -1)" != "0" ]]; then
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: balloon state directory is not root-owned: $state_dir"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi
  chmod 700 "$state_dir" 2>/dev/null || true
  touch "$lock_file" 2>/dev/null || {
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: unable to open balloon state lock: $lock_file"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  }
  chmod 600 "$lock_file" 2>/dev/null || true
  [[ ${EUID:-$(id -u)} -eq 0 ]] && chown root:root "$lock_file" 2>/dev/null || true
  exec {lock_fd}>"$lock_file" || {
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: unable to acquire balloon state lock descriptor"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  }
  if ! flock -w "$POOLY_BALLOON_LOCK_WAIT_SECONDS" "$lock_fd"; then
    balloon_release_lock "$lock_fd"
    echo "BALLOON SUPPORTED: yes"
    echo "WARN: balloon state is busy; sample not persisted"
    echo "BALLOON STATE: ERROR"
    echo "BALLOON RESULT: WARN"
    return 2
  fi

  local outstanding_pages=$((inflate-deflate))
  (( outstanding_pages < 0 )) && outstanding_pages=0
  local threshold_pages=$((POOLY_BALLOON_WARN_MIB*1024*1024/page_size))
  (( threshold_pages < 1 )) && threshold_pages=1

  local prev_boot="" prev_epoch=0 prev_inflate=0 prev_deflate=0 prev_migrate=0
  local prev_pswpin=0 prev_pswpout=0 prev_pgmajfault=0 prev_oom=0 prev_outstanding=0 prev_state=""
  local previous_status="missing" state_line state_rc
  if state_line="$(balloon_read_state "$state_file" 2>/dev/null)"; then state_rc=0; else state_rc=$?; fi
  if (( state_rc == 0 )); then
    previous_status="valid"
    IFS=$'\t' read -r prev_boot prev_epoch prev_inflate prev_deflate prev_migrate prev_pswpin prev_pswpout \
      prev_pgmajfault prev_oom prev_outstanding prev_state <<< "$state_line"
  elif (( state_rc == 2 )); then
    previous_status="corrupt"
  fi

  local delta_inflate=0 delta_deflate=0 delta_migrate=0 delta_pswpin=0 delta_pswpout=0
  local delta_pgmajfault=0 delta_oom=0 state="BASELINE" result="PASS" note=""
  local reset=0

  if [[ "$previous_status" == "corrupt" ]]; then
    state="STATE_RESET"
    result="WARN"
    note="previous balloon state was invalid and has been replaced"
  elif [[ "$previous_status" == "missing" ]]; then
    if (( outstanding_pages >= threshold_pages )); then
      state="ACTIVE"
      result="WARN"
      note="significant host ballooning was already active at first observation"
    else
      state="BASELINE"
    fi
  elif [[ "$prev_boot" != "$boot_id" ]] || (( inflate < prev_inflate || deflate < prev_deflate || migrate < prev_migrate || pswpin < prev_pswpin || pswpout < prev_pswpout || pgmajfault < prev_pgmajfault || oom_kill < prev_oom )); then
    state="COUNTER_RESET"
    reset=1
    note="boot identity or one or more cumulative counters changed"
  else
    delta_inflate=$((inflate-prev_inflate))
    delta_deflate=$((deflate-prev_deflate))
    delta_migrate=$((migrate-prev_migrate))
    delta_pswpin=$((pswpin-prev_pswpin))
    delta_pswpout=$((pswpout-prev_pswpout))
    delta_pgmajfault=$((pgmajfault-prev_pgmajfault))
    delta_oom=$((oom_kill-prev_oom))

    local prev_active=0
    case "$prev_state" in ACTIVE|ACTIVE_CONTINUING|DEFLATING) prev_active=1 ;; esac

    if (( outstanding_pages >= threshold_pages )); then
      if (( delta_deflate > delta_inflate && delta_deflate > 0 )); then
        state="DEFLATING"
      elif (( prev_active == 1 || prev_outstanding >= threshold_pages )); then
        state="ACTIVE_CONTINUING"
      else
        state="ACTIVE"
        result="WARN"
        note="new significant host balloon inflation detected"
      fi
    else
      if (( delta_inflate >= threshold_pages && delta_deflate >= threshold_pages )); then
        state="CYCLE_COMPLETED"
        result="WARN"
        note="one or more complete balloon cycles occurred between checks"
      elif (( prev_active == 1 || prev_outstanding >= threshold_pages )); then
        state="RECOVERED"
      elif (( delta_deflate > 0 )); then
        state="RECOVERED"
      else
        state="IDLE"
      fi
    fi

    if (( delta_oom > 0 )); then
      result="WARN"
      if [[ -n "$note" ]]; then note="$note; OOM kill counter increased"; else note="OOM kill counter increased"; fi
    fi
  fi

  local ram_pressure_pct swap_used_kib swap_pct=0
  ram_pressure_pct=$(( (mem_total_kib-mem_available_kib)*100/mem_total_kib ))
  swap_used_kib=$((swap_total_kib-swap_free_kib))
  if (( swap_total_kib > 0 )); then swap_pct=$((swap_used_kib*100/swap_total_kib)); fi

  local state_write_ok=1 history_write_ok=1
  if ! balloon_write_state "$state_file" "$boot_id" "$epoch" "$inflate" "$deflate" "$migrate" \
    "$pswpin" "$pswpout" "$pgmajfault" "$oom_kill" "$outstanding_pages" "$state"; then
    state_write_ok=0
    state="ERROR"
    result="WARN"
    note="unable to persist balloon state atomically"
  fi

  local history_line
  printf -v history_line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$epoch" "$utc" "$boot_id" "$state" "$result" "$inflate" "$deflate" "$outstanding_pages" \
    "$delta_inflate" "$delta_deflate" "$mem_available_kib" "$ram_pressure_pct" "$swap_used_kib" \
    "$swap_pct" "$delta_pswpin" "$delta_pswpout" "$delta_pgmajfault" "$delta_oom" "$psi_some" "$psi_full" "$page_size"
  if ! balloon_append_history "$history_file" "$POOLY_BALLOON_HISTORY_MAX_LINES" "$history_line"; then
    history_write_ok=0
    state="ERROR"
    result="WARN"
    note="unable to persist bounded balloon history"
  fi
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    chown root:root "$state_file" "$history_file" 2>/dev/null || { state="ERROR"; result="WARN"; note="unable to enforce root ownership on balloon state"; }
  fi
  balloon_release_lock "$lock_fd"

  echo "BALLOON SUPPORTED: yes"
  echo "BALLOON STATE: $state"
  echo "BALLOON OUTSTANDING: $(balloon_pages_to_gib "$outstanding_pages" "$page_size") GiB"
  echo "BALLOON INFLATE SINCE LAST CHECK: $(balloon_pages_to_gib "$delta_inflate" "$page_size") GiB"
  echo "BALLOON DEFLATE SINCE LAST CHECK: $(balloon_pages_to_gib "$delta_deflate" "$page_size") GiB"
  echo "BALLOON MIGRATE SINCE LAST CHECK: $delta_migrate page(s)"
  echo "MEM AVAILABLE: $(balloon_kib_to_mib "$mem_available_kib") MiB"
  echo "RAM PRESSURE: ${ram_pressure_pct}%"
  echo "SWAP USED: $(balloon_kib_to_mib "$swap_used_kib") MiB / ${swap_pct}%"
  echo "SWAP-IN DELTA: $(balloon_pages_to_mib "$delta_pswpin" "$page_size") MiB"
  echo "SWAP-OUT DELTA: $(balloon_pages_to_mib "$delta_pswpout" "$page_size") MiB"
  echo "MAJOR PAGE FAULT DELTA: $delta_pgmajfault"
  echo "OOM KILL DELTA: $delta_oom"
  echo "MEMORY PSI SOME/FULL: $psi_some / $psi_full"
  [[ "$reset" == "1" ]] && echo "INFO: balloon counters were re-baselined after reset"
  [[ -n "$note" ]] && echo "WARN: $note"
  [[ "$state_write_ok" == "1" && "$history_write_ok" == "1" ]] || echo "WARN: balloon state persistence is degraded"
  echo "BALLOON RESULT: $result"
  status_return "$result"
}

balloon_history(){
  load_env || { section "POOLY MEMORY BALLOON HISTORY"; echo "WARN: unable to load safe Server Guard environment"; return 2; }
  balloon_defaults
  section "POOLY MEMORY BALLOON HISTORY"
  local history_file="$POOLY_BALLOON_STATE_DIR/history.tsv" lines="${1:-50}"
  if ! balloon_uint "$lines" || (( lines < 1 || lines > 10000 )); then
    echo "Usage: pooly-server-guard.sh balloon-history [1-10000]"
    return 1
  fi
  echo -e 'UTC\tSTATE\tRESULT\tOUTSTANDING_MIB\tINFLATE_DELTA_MIB\tDEFLATE_DELTA_MIB\tMEM_AVAILABLE_MIB\tRAM_PCT\tSWAP_USED_MIB\tSWAP_PCT\tOOM_DELTA\tPSI_SOME\tPSI_FULL'
  if [[ ! -r "$history_file" ]]; then
    echo "No balloon history has been recorded."
    return 0
  fi
  tail -n "$lines" "$history_file" | awk -F'\t' '
    NF>=21 {
      printf "%s\t%s\t%s\t%.2f\t%.2f\t%.2f\t%.2f\t%s\t%.2f\t%s\t%s\t%s\t%s\n",
        $2,$4,$5,($8*$21)/1048576,($9*$21)/1048576,($10*$21)/1048576,$11/1024,$12,$13/1024,$14,$18,$19,$20
    }
  '
}
