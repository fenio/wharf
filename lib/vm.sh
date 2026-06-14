# lib/vm.sh — named-VM registry. Each VM is a directory under $WHARF_VMS
# (~/.wharf/<name>/) holding its disk, ISOs, EFI vars, pidfile, plus a vm.conf
# recording its settings (VERSION, RAM, ports, account). This turns wharf from
# single-VM into a small fleet manager (wharf new/ls/rm + name args).

_in_list()        { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
_port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
vm_running()      { [ -f "$1/qemu.pid" ] && kill -0 "$(cat "$1/qemu.pid" 2>/dev/null)" 2>/dev/null; }

# point STORAGE/NAME at a named VM, load its saved settings, re-derive paths
vm_resolve() {
  local name="$1"
  [ -n "$name" ] || die "a VM name is required"
  STORAGE="$WHARF_VMS/$name"; NAME="$name"
  [ -d "$STORAGE" ] || die "no such VM: '$name'  (wharf ls to list, wharf new $name to create)"
  [ -f "$STORAGE/vm.conf" ] && source "$STORAGE/vm.conf"
  config_paths
}

# collect one field from every VM's vm.conf (for port-collision avoidance)
_vm_field_all() {
  local d v
  for d in "$WHARF_VMS"/*/vm.conf; do
    [ -f "$d" ] || continue
    v=$(grep -E "^$1=" "$d" 2>/dev/null | tail -1 | cut -d= -f2) || v=""
    if [ -n "$v" ]; then echo "$v"; fi
  done
}

# choose a free VNC display + RDP port (skip live ports and other VMs' reservations)
vm_alloc_ports() {
  local used_d used_p d p
  used_d="$(_vm_field_all VNC_DISPLAY | tr '\n' ' ')"
  used_p="$(_vm_field_all RDP_PORT | tr '\n' ' ')"
  d=0;     while _port_listening $((5900+d)) || _in_list "$d" "$used_d"; do d=$((d+1)); done; VNC_DISPLAY=$d
  p=13389; while _port_listening "$p"        || _in_list "$p" "$used_p"; do p=$((p+1)); done; RDP_PORT=$p
}

vm_save_conf() {
  cat > "$STORAGE/vm.conf" <<EOF
# wharf VM config (edit to taste; used by run/stop/status/view)
VERSION=$VERSION
RAM_SIZE=$RAM_SIZE
CPU_CORES=$CPU_CORES
DISK_SIZE=$DISK_SIZE
USERNAME=$USERNAME
PASSWORD=$PASSWORD
USE_TPM=$USE_TPM
VNC_DISPLAY=$VNC_DISPLAY
RDP_PORT=$RDP_PORT
EOF
}

_vm_field() { grep -E "^$2=" "$1/vm.conf" 2>/dev/null | tail -1 | cut -d= -f2; }

vm_ls() {
  mkdir -p "$WHARF_VMS"
  printf "%-16s %-9s %-24s %-18s %-18s %s\n" NAME STATUS EDITION VNC RDP DISK
  local d name status disk ver vd rp
  for d in "$WHARF_VMS"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    status=stopped
    if vm_running "${d%/}"; then status=running; fi
    disk=$(du -h "$d/data.img" 2>/dev/null | awk '{print $1}') || disk=""; [ -n "$disk" ] || disk="—"
    ver=$(_vm_field "${d%/}" VERSION) || ver=""; [ -n "$ver" ] || ver="?"
    vd=$(_vm_field "${d%/}" VNC_DISPLAY) || vd=0; case "$vd" in ''|*[!0-9]*) vd=0 ;; esac
    rp=$(_vm_field "${d%/}" RDP_PORT) || rp=""; [ -n "$rp" ] || rp="?"
    printf "%-16s %-9s %-24s %-18s %-18s %s\n" "$name" "$status" \
      "$(wharf_version_label "$ver")" "127.0.0.1:$((5900+vd))" "127.0.0.1:$rp" "$disk"
  done
}
