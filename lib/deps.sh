# lib/deps.sh — host dependency checks. Everything is plain macOS + Homebrew.

deps_require() {
  local missing=()
  for bin in "$@"; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
  if (( ${#missing[@]} )); then
    warn "Missing: ${missing[*]}"
    die "Install with: brew install qemu wimlib aria2  (and 'brew install swtpm' if USE_TPM=Y)"
  fi
  [ -f "$EDK2_CODE" ] || die "UEFI firmware not found at $EDK2_CODE (reinstall qemu, or set EDK2_CODE)."
}

deps_check_all() {
  log "wharf doctor"
  local ok=1
  _chk() { if command -v "$1" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1  ($2)"; ok=0; fi; }
  _chk qemu-system-aarch64 "brew install qemu"
  _chk qemu-img            "brew install qemu"
  _chk wimlib-imagex       "brew install wimlib   (driver/XML injection)"
  _chk aria2c              "brew install aria2     (faster ISO download; optional)"
  _chk swtpm               "brew install swtpm     (only if USE_TPM=Y)"
  [ -f "$EDK2_CODE" ] && echo "  ✓ edk2 firmware ($EDK2_CODE)" || { echo "  ✗ edk2 firmware"; ok=0; }
  # HVF entitlement sanity
  if codesign -d --entitlements - "$(command -v qemu-system-aarch64)" 2>/dev/null | grep -q hypervisor; then
    echo "  ✓ qemu has the HVF (hypervisor) entitlement"
  else
    echo "  ✗ qemu missing hypervisor entitlement — HVF will fail (reinstall via brew)"; ok=0
  fi
  # Apple silicon check
  [ "$(uname -m)" = "arm64" ] && echo "  ✓ Apple silicon (arm64)" || { echo "  ✗ not arm64"; ok=0; }
  (( ok )) && log "All good." || die "Some dependencies are missing (see above)."
}
