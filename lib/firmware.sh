# lib/firmware.sh — UEFI (edk2) setup. Code blob is read-only; vars must be a
# private writable copy per VM (stores boot entries / EFI NVRAM).

firmware_setup() {
  if [ ! -f "$VARS" ]; then
    [ -f "$EDK2_VARS_TMPL" ] || die "edk2 vars template not found at $EDK2_VARS_TMPL"
    cp "$EDK2_VARS_TMPL" "$VARS"
    log "Initialized EFI vars: $VARS"
  fi
}
