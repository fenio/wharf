# lib/qemu.sh — assemble and run qemu-system-aarch64 with the HVF accelerator.
# This is the exact configuration we proved boots & installs Windows 11 ARM
# (data.img 0→8.6G in 100s), generalized into install/run modes.

_qemu_base_args() {
  network_opts
  display_opts
  QEMU_ARGS=(
    -name "${NAME}"
    -accel hvf
    -cpu host
    -M virt,highmem=on
    -m "$RAM_SIZE"
    -smp "$CPU_CORES"
    # UEFI: read-only code + private writable vars
    -drive "if=pflash,format=raw,readonly=on,file=${EDK2_CODE}"
    -drive "if=pflash,format=raw,file=${VARS}"
    # input
    -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet
    # system disk on virtio-scsi (drivers injected into the install media)
    -device virtio-scsi-pci,id=scsi0,iothread=io0
    -object iothread,id=io0
    -drive "file=${DISK},format=raw,if=none,id=hd,cache=writeback,discard=on,detect-zeroes=on"
    -device "scsi-hd,drive=hd,bus=scsi0.0,bootindex=1"
    -rtc base=localtime
    -device virtio-rng-pci
    # control + lifecycle
    -monitor "unix:${MONITOR},server,nowait"
    -pidfile "$PIDFILE"
    "${NET_OPTS[@]}"
    "${DISPLAY_OPTS[@]}"
  )

  if [ "${USE_TPM}" = "Y" ]; then
    command -v swtpm >/dev/null || die "USE_TPM=Y but swtpm not installed (brew install swtpm)"
    mkdir -p "$STORAGE/tpm"
    swtpm socket --tpm2 --tpmstate "dir=$STORAGE/tpm" \
      --ctrl "type=unixio,path=$STORAGE/tpm/swtpm.sock" --daemon
    QEMU_ARGS+=( -chardev "socket,id=chrtpm,path=$STORAGE/tpm/swtpm.sock"
                 -tpmdev "emulator,id=tpm0,chardev=chrtpm"
                 -device "tpm-tis-device,tpmdev=tpm0" )
  fi
}

# qemu_boot install|run
qemu_boot() {
  local mode="$1"
  _qemu_base_args
  if [ "$mode" = "install" ]; then
    local media="${ISO_PREPARED:-$ISO}"
    [ -f "$media" ] || die "Install media not found: $media"
    QEMU_ARGS+=(
      -drive "file=${media},format=raw,if=none,id=cd,media=cdrom,readonly=on"
      # CD gets LOWER priority than the disk (disk is bootindex=1). An empty disk
      # has no EFI boot entry, so firmware falls through to the CD on the first
      # boot; once Setup writes the bootloader to disk, every later reboot boots
      # the disk — so Setup's mid-install reboots CONTINUE instead of restarting
      # the installer. (CD-first would loop forever in Setup.)
      -device "usb-storage,drive=cd,bootindex=2"
    )
  fi
  display_hint
  log "Launching QEMU (HVF). Logs: $STORAGE/qemu.log"
  # detach so the shell returns; the VM keeps running
  nohup qemu-system-aarch64 "${QEMU_ARGS[@]}" >"$STORAGE/qemu.log" 2>&1 &
  sleep 2
  if qemu_status >/dev/null 2>&1; then
    log "Started (pid $(cat "$PIDFILE" 2>/dev/null))."
    display_open || true
  else
    die "QEMU failed to start — see $STORAGE/qemu.log"
  fi
}

qemu_status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "VM '${NAME}' running (pid $(cat "$PIDFILE"))."
    display_hint
    return 0
  fi
  warn "VM '${NAME}' is not running."
  return 1
}

qemu_stop() {
  [ -f "$PIDFILE" ] || { warn "No pidfile; nothing to stop."; return 0; }
  local pid; pid="$(cat "$PIDFILE")"
  # try ACPI graceful shutdown via the monitor first
  if [ -S "$MONITOR" ]; then
    echo "system_powerdown" | nc -U "$MONITOR" >/dev/null 2>&1 || true
    log "Sent ACPI shutdown; waiting up to 60s..."
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || { log "Stopped."; return 0; }; sleep 1; done
  fi
  warn "Forcing kill of pid $pid"; kill "$pid" 2>/dev/null || true
}
