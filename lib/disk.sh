# lib/disk.sh — the Windows system disk. Raw + sparse (grows on demand), so a
# 64G disk costs only what Windows actually writes. macOS APFS is sparse-friendly.

disk_create() {
  if [ -f "$DISK" ]; then
    log "Reusing existing disk: $DISK"
    return 0
  fi
  qemu-img create -f raw "$DISK" "$DISK_SIZE" >/dev/null
  log "Created ${DISK_SIZE} growable disk: $DISK"
}
