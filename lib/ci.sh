# lib/ci.sh — headless / CI helpers: endpoints, wait-for-ready, snapshot/reset.
# These make a wharf VM usable from an automated pipeline (see examples/ci).

SSH_KEY_DEFAULT="${WHARF_SSH_KEY:-$HOME/.wharf/ci_key}"

# Ensure the wharf CI SSH keypair exists (auto-generated on first use), so a plain
# `wharf new <name>` bakes a key and SSH/CI works with no extra setup.
ensure_ssh_key() {
  local key="${WHARF_SSH_KEY:-$HOME/.wharf/ci_key}"
  if [ ! -f "$key" ]; then
    mkdir -p "$(dirname "$key")"
    ssh-keygen -t ed25519 -N "" -f "$key" -C "wharf-ci" >/dev/null 2>&1 \
      && log "Generated wharf CI SSH key: $key" || warn "Could not generate SSH key at $key"
  fi
  WHARF_SSH_PUBKEY="${WHARF_SSH_PUBKEY:-${key}.pub}"
}

# ssh into the VM with sane non-interactive defaults (key if present, else password
# must be supplied by the caller's environment/agent). Honors $SSH_PORT/$USERNAME.
_ci_ssh() {
  local opts=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
             -o ConnectTimeout=5 -o LogLevel=ERROR)
  [ -f "$SSH_KEY_DEFAULT" ] && opts+=(-i "$SSH_KEY_DEFAULT")
  ssh "${opts[@]}" "${USERNAME}@127.0.0.1" "$@"
}

_port_open() { # host port -> 0 if accepting connections
  nc -z -G 2 127.0.0.1 "$1" >/dev/null 2>&1
}

# Babysit an unattended install until the guest is SSH-ready, auto-recovering from
# the intermittent edk2 "Start boot option" firmware hang (CPU pegged + disk frozen),
# which a full QEMU process restart clears. Called by cmd_install so `wharf new`
# returns only when the VM is actually usable. Set WHARF_NO_SUPERVISE=1 to skip.
vm_supervise_install() {
  [ "${WHARF_NO_SUPERVISE:-}" = "1" ] && return 0
  local timeout="${WHARF_INSTALL_TIMEOUT:-3600}" t=0 prev=0 frozen=0 cur cpu pid
  log "Supervising install until SSH-ready on :$SSH_PORT (auto-recovers firmware hangs; ~20-40 min)..."
  while [ "$t" -lt "$timeout" ]; do
    sleep 30; t=$((t+30))
    # ready? SSH port answers AND a command succeeds
    if _port_open "$SSH_PORT" && _ci_ssh 'exit 0' >/dev/null 2>&1; then
      log "VM '$NAME' is SSH-ready after ~${t}s."; return 0
    fi
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "QEMU exited during install — restarting."; firmware_setup; qemu_boot install; prev=0; frozen=0; continue
    fi
    cur="$(du -k "$DISK" 2>/dev/null | awk '{print $1}')"; cur="${cur:-0}"
    cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"; cpu="${cpu%%.*}"; cpu="${cpu:-0}"
    if [ "$cur" -le "$prev" ]; then frozen=$((frozen+1)); else frozen=0; fi
    prev="$cur"
    # disk frozen ~3 min AND CPU pegged => firmware hang (Setup tolerates the reboot)
    if [ "$frozen" -ge 6 ] && [ "$cpu" -ge 85 ]; then
      warn "Firmware hang suspected (disk frozen, CPU ${cpu}%) — power-cycling QEMU."
      kill "$pid" 2>/dev/null; sleep 3; qemu_boot install; prev=0; frozen=0
    fi
  done
  die "VM '$NAME' did not become SSH-ready within ${timeout}s (see $STORAGE/qemu.log)."
}

# wharf endpoints <name> [--json]
ci_endpoints() {
  local json="" name=""
  for a in "$@"; do case "$a" in --json) json=1 ;; -*) ;; *) name="$a" ;; esac; done
  [ -n "$name" ] && vm_resolve "$name"
  local vnc=$((5900+VNC_DISPLAY)) running=false key=""
  vm_running "$STORAGE" && running=true
  [ -f "$SSH_KEY_DEFAULT" ] && key="$SSH_KEY_DEFAULT"
  if [ -n "$json" ]; then
    printf '{"name":"%s","running":%s,"host":"127.0.0.1","vnc":%d,"rdp":%d,"ssh":%d,"username":"%s","password":"%s","ssh_key":"%s"}\n' \
      "$NAME" "$running" "$vnc" "$RDP_PORT" "$SSH_PORT" "$USERNAME" "$PASSWORD" "$key"
  else
    log "Endpoints for VM '${NAME}' (running=$running):"
    printf '  VNC : 127.0.0.1:%d\n' "$vnc"
    printf '  RDP : 127.0.0.1:%d   (user %s / pass %s)\n' "$RDP_PORT" "$USERNAME" "$PASSWORD"
    printf '  SSH : ssh %s@127.0.0.1 -p %d%s\n' "$USERNAME" "$SSH_PORT" \
      "$([ -n "$key" ] && echo " -i $key")"
  fi
}

# wharf wait <name> [timeout_seconds]  — block until the guest is ready for CI.
# Ready = OpenSSH answering AND the guest-setup marker (C:\OEM\wharf-ready) exists.
ci_wait() {
  local name="" timeout=2400
  for a in "$@"; do case "$a" in [0-9]*) timeout="$a" ;; *) name="$a" ;; esac; done
  [ -n "$name" ] && vm_resolve "$name"
  vm_running "$STORAGE" || die "VM '$NAME' is not running."
  log "Waiting up to ${timeout}s for '$NAME' to become CI-ready (SSH :$SSH_PORT)..."
  local t=0 step=10
  # phase 1: SSH port accepts connections
  while ! _port_open "$SSH_PORT"; do
    sleep "$step"; t=$((t+step))
    [ "$t" -ge "$timeout" ] && die "Timed out waiting for SSH on :$SSH_PORT (install may still be running)."
  done
  log "SSH port open after ${t}s; checking setup marker..."
  # phase 2: guest-setup finished (marker file present)
  while ! _ci_ssh 'if (Test-Path C:\OEM\wharf-ready) { exit 0 } else { exit 1 }' >/dev/null 2>&1; do
    sleep "$step"; t=$((t+step))
    [ "$t" -ge "$timeout" ] && die "SSH up but guest-setup marker not found within ${timeout}s."
  done
  log "VM '$NAME' is CI-ready (${t}s)."
}

# wharf snapshot <name> [tag]  — copy the disk to a golden image (APFS clone if possible)
ci_snapshot() {
  local name="${1:-}" tag="${2:-golden}"
  [ -n "$name" ] || die "usage: wharf snapshot <name> [tag]"
  vm_resolve "$name"
  vm_running "$STORAGE" && warn "VM is running — snapshot may be crash-consistent only. Stop it for a clean image."
  [ -f "$DISK" ] || die "No disk at $DISK"
  local snap="$STORAGE/data.${tag}.img"
  log "Snapshotting $DISK -> $snap ..."
  cp -c "$DISK" "$snap" 2>/dev/null || cp "$DISK" "$snap" || die "snapshot copy failed"
  log "Snapshot '$tag' saved ($(du -h "$snap" | awk '{print $1}'))."
}

# wharf reset <name> [tag]  — restore the disk from a golden image
ci_reset() {
  local name="${1:-}" tag="${2:-golden}"
  [ -n "$name" ] || die "usage: wharf reset <name> [tag]"
  vm_resolve "$name"
  vm_running "$STORAGE" && die "Stop the VM first (wharf stop $name) before reset."
  local snap="$STORAGE/data.${tag}.img"
  [ -f "$snap" ] || die "No snapshot '$tag' at $snap (create one with: wharf snapshot $name $tag)."
  log "Restoring $DISK from $snap ..."
  rm -f "$DISK"
  cp -c "$snap" "$DISK" 2>/dev/null || cp "$snap" "$DISK" || die "reset copy failed"
  log "VM '$name' reset to snapshot '$tag'."
}
