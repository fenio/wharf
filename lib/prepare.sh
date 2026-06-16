# lib/prepare.sh — turn a plain Windows ARM ISO into auto-installing media:
#   (a) inject virtio drivers so Setup (boot.wim) can see the virtio-scsi disk,
#       and the installed OS (install.wim) keeps them,
#   (b) drop autounattend.xml at the ISO root (silent install + TPM/secure-boot
#       bypass + local account),
#   (c) rebuild a UEFI-bootable ISO.
#
# macOS port of dockur's install.sh:addDrivers + buildImage. Tools: bsdtar (ships
# with macOS) for extract, wimlib-imagex for WIM editing, xorriso for the rebuild
# (the macOS stand-in for genisoimage). ARM Windows ISOs are EFI-only, so the
# rebuild uses a single EFI El Torito entry (efisys), no BIOS boot.
#
# Sets: $ISO_PREPARED (path to the prepared ISO that lib/qemu.sh boots)

# virtio drivers to inject (same set dockur uses), storage/net ones are critical
WHARF_DRIVERS="qxl viofs sriov smbus qxldod viorng viostor viomem NetKVM Balloon vioscsi pvpanic vioinput viogpudo vioserial qemupciserial"

prepare_media() {
  if _iso_has_autounattend "$ISO"; then
    log "ISO already contains autounattend.xml — using it directly."
    ISO_PREPARED="$ISO"; return 0
  fi
  if [ -f "$ISO_PREPARED" ]; then log "Reusing prepared media: $ISO_PREPARED"; return 0; fi

  deps_require wimlib-imagex mkisofs

  local work="$STORAGE/prep" root="$STORAGE/prep/iso" drv="$STORAGE/prep/drivers"
  _rmrf "$work"; mkdir -p "$root" "$drv"

  log "Extracting ISO (this takes a minute)..."
  _iso_extract "$ISO" "$root"
  chmod -R u+w "$root"

  _fetch_virtio "$drv"

  local id; id="$(wharf_version_id "$VERSION")"; [ -n "$id" ] || id="win11arm64"
  local boot="$root/sources/boot.wim"
  local inst="$root/sources/install.wim"; [ -f "$inst" ] || inst="$root/sources/install.esd"
  [ -f "$boot" ] || die "sources/boot.wim not found in ISO."

  log "Injecting virtio drivers into boot.wim (so Setup sees the disk)..."
  _inject_drivers "$boot" "$id" "$drv"

  if [ "${inst##*.}" = "wim" ]; then
    log "Injecting virtio drivers into install.wim..."
    _inject_drivers "$inst" "$id" "$drv"
  else
    warn "install.esd is solid-compressed — skipping its driver inject; relying on boot.wim + \$OEM\$."
  fi

  log "Staging drivers for the installed OS (\$OEM\$\\\$1\\Drivers)..."
  _stage_oem_drivers "$root" "$id" "$drv"

  log "Staging guest setup (driver install + OpenSSH) to C:\\OEM..."
  _stage_oem_setup "$root"

  log "Writing autounattend.xml ($USERNAME / $LANGUAGE)..."
  _render_autounattend > "$root/autounattend.xml"

  log "Rebuilding UEFI-bootable ISO..."
  _build_iso "$root" "$ISO_PREPARED"
  _rmrf "$work"
  log "Prepared media: $ISO_PREPARED"
}

# --- helpers -----------------------------------------------------------------

# rm -rf that survives read-only files (virtio pack / ISO copies extract ro)
_rmrf() {
  [ -e "$1" ] || return 0
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1"
}

_fetch_virtio() {
  local dest="$1"
  local url="https://github.com/qemus/virtiso-arm/releases/download/v${VIRTIO_VERSION}-1/virtio-win-${VIRTIO_VERSION}.tar.xz"
  log "Fetching virtio ARM drivers v${VIRTIO_VERSION}..."
  curl -fL --retry 3 -o "$STORAGE/prep/virtio.tar.xz" "$url" || die "Failed to download virtio pack: $url"
  bsdtar -C "$dest" -xf "$STORAGE/prep/virtio.tar.xz" || die "Failed to extract virtio pack."
}

# folder inside the virtio pack for this Windows id (e.g. w11/ARM64)
_virtio_folder() {
  case "$1" in
    win11arm64*) echo "w11/ARM64" ;;
    win10arm64*) echo "w10/ARM64" ;;
    *)           echo "w11/ARM64" ;;
  esac
}

# collect this arch's drivers into a single staging tree -> echoes its path
_collect_drivers() {
  local id="$1" drv="$2" folder stage="$STORAGE/prep/_stage" d
  folder="$(_virtio_folder "$id")"
  rm -rf "$stage"; mkdir -p "$stage"
  for d in $WHARF_DRIVERS; do
    if [ -d "$drv/$d/$folder" ]; then
      mkdir -p "$stage/$d"
      cp -RL "$drv/$d/$folder/." "$stage/$d/" 2>/dev/null || true
    fi
  done
  echo "$stage"
}

# inject the staged drivers into every image index of a .wim, under \$WinPEDriver\$
_inject_drivers() {
  local wim="$1" id="$2" drv="$3" stage i n
  stage="$(_collect_drivers "$id" "$drv")"
  [ -n "$(ls -A "$stage" 2>/dev/null)" ] || { warn "No drivers found for $id — skipping inject."; return 0; }
  n="$(wimlib-imagex info "$wim" 2>/dev/null | awk -F: '/Image Count/{gsub(/ /,"",$2);print $2}')"
  [ -n "$n" ] || n=1
  for i in $(seq 1 "$n"); do
    wimlib-imagex update "$wim" "$i" --command 'delete --force --recursive /$WinPEDriver$' >/dev/null 2>&1 || true
    wimlib-imagex update "$wim" "$i" --command "add $stage /\$WinPEDriver\$" >/dev/null \
      || warn "driver inject into image $i failed"
  done
}

# stage the first-logon setup script (+ optional SSH pubkey) into C:\OEM.
# IMPORTANT: $OEM$ folders are only copied to %SystemDrive% by Windows Setup when
# they live under \sources\$OEM$ on the media — NOT at the ISO root. (Staging at the
# root silently no-ops: C:\OEM / C:\Drivers never appear and first-logon scripts
# never run.) So everything goes under sources/$OEM$/$1/.
_stage_oem_setup() {
  local root="$1" dst="$root/sources/\$OEM\$/\$1/OEM"
  mkdir -p "$dst"
  cp "$WHARF_HOME/assets/guest-setup.ps1" "$dst/wharf-setup.ps1"
  if [ -n "${WHARF_SSH_PUBKEY:-}" ] && [ -f "${WHARF_SSH_PUBKEY}" ]; then
    cp "${WHARF_SSH_PUBKEY}" "$dst/authorized_keys"
    log "  bundled SSH public key from $WHARF_SSH_PUBKEY"
  fi
}

# put drivers on the ISO so the installed OS picks them up ($OEM$ -> C:\Drivers,
# installed by guest-setup.ps1 via pnputil). Must be under \sources\$OEM$ (see above).
_stage_oem_drivers() {
  local root="$1" id="$2" drv="$3" stage dst
  stage="$(_collect_drivers "$id" "$drv")"
  dst="$root/sources/\$OEM\$/\$1/Drivers"
  mkdir -p "$dst"
  cp -RL "$stage/." "$dst/" 2>/dev/null || true
}

# rebuild a UEFI-bootable Windows ARM ISO from the extracted tree.
# Mirrors what dockur does with genisoimage, using Schily mkisofs (cdrtools):
# UDF filesystem (preserves the exact case/layout Windows' EFI boot chain needs,
# and handles >4 GB install.wim) + an EFI El Torito entry pointing at the
# *no-prompt* boot image (efisys_noprompt) so it auto-boots headless. The El
# Torito boot-load-size must cover the whole efisys image or edk2 loads a
# truncated FAT and hangs at "Start boot option".
_build_iso() {
  local dir="$1" out="$2" efisys label sz lsz
  efisys="efi/microsoft/boot/efisys_noprompt.bin"
  [ -f "$dir/$efisys" ] || efisys="efi/microsoft/boot/efisys.bin"
  [ -f "$dir/$efisys" ] || die "No EFI boot image (efisys) in ISO — cannot make it bootable."
  sz=$(stat -f%z "$dir/$efisys"); lsz=$(( (sz + 511) / 512 ))
  label="WHARF_$(echo "$VERSION" | tr '[:lower:]' '[:upper:]')"
  rm -f "$out"
  if command -v mkisofs >/dev/null 2>&1; then
    mkisofs -iso-level 4 -J -joliet-long -l -udf -V "${label:0:30}" \
      -eltorito-platform efi -eltorito-boot "$efisys" -no-emul-boot -boot-load-size "$lsz" \
      -eltorito-catalog boot.catalog \
      -o "$out" "$dir" || die "mkisofs failed to build $out"
  else
    warn "Schily mkisofs not found (brew install cdrtools) — falling back to xorriso (no UDF; may not boot)."
    xorriso -as mkisofs -iso-level 3 -J -joliet-long -l -R -V "${label:0:30}" \
      -no-emul-boot -e "$efisys" -o "$out" "$dir" || die "xorriso failed to build $out"
  fi
}

# Extract an ISO to a directory. Windows ARM ISOs are UDF-primary (the ISO9660
# layer is just a "use a UDF reader" README), which bsdtar/libarchive can't read.
# macOS's hdiutil mounts UDF natively, so we mount read-only and copy the tree.
_iso_extract() {
  local iso="$1" dest="$2" mnt="$STORAGE/prep/mnt"
  mkdir -p "$mnt"
  hdiutil detach "$mnt" >/dev/null 2>&1 || true
  hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mnt" "$iso" >/dev/null \
    || die "Failed to mount $iso"
  # copy the ISO's contents into dest (ditto is macOS-native, preserves all names)
  ditto "$mnt" "$dest" || { hdiutil detach "$mnt" >/dev/null 2>&1; die "Failed to copy ISO contents"; }
  hdiutil detach "$mnt" >/dev/null 2>&1 || true
}

# Is this ISO already auto-install media? Check via hdiutil (UDF-aware).
_iso_has_autounattend() {
  local iso="$1" mnt="$STORAGE/prep/_chk" found=1
  mkdir -p "$mnt"; hdiutil detach "$mnt" >/dev/null 2>&1 || true
  if hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mnt" "$iso" >/dev/null 2>&1; then
    [ -f "$mnt/autounattend.xml" ] || [ -f "$mnt/Autounattend.xml" ] || [ -f "$mnt/AUTOUNATTEND.XML" ]
    found=$?
    hdiutil detach "$mnt" >/dev/null 2>&1 || true
  fi
  rmdir "$mnt" 2>/dev/null || true
  return $found
}

_render_autounattend() {
  local region="${REGION:-en-US}" kbd="${KEYBOARD:-0409:00000409}" image
  image="$(wharf_image_name "$VERSION")"
  sed -e "s|@USERNAME@|$USERNAME|g" \
      -e "s|@PASSWORD@|$PASSWORD|g" \
      -e "s|@REGION@|$region|g" \
      -e "s|@KEYBOARD@|$kbd|g" \
      -e "s|@IMAGE@|$image|g" \
      "$WHARF_HOME/assets/autounattend.xml.tmpl"
}
