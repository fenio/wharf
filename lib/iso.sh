# lib/iso.sh — acquire the Windows ARM installation ISO for $VERSION.
#
# Port of the mirror/version logic from dockur/windows-arm's define.sh: each
# VERSION maps to one or more mirror URLs (Microsoft static CDN first, then
# community mirrors) with a known SHA-256. We download (resumable), verify, and
# fall through to the next mirror on failure.
#
# Sets: $ISO (path to the acquired raw ISO)

# VERSION code -> driver/edition id (used by lib/prepare.sh for the driver folder)
wharf_version_id() {
  case "$1" in
    11|11e|11l) echo "win11arm64" ;;
    *)          echo "" ;;
  esac
}

# Emits mirror lines "<sha256> <url>", best/primary first. (sums from dockur.)
_iso_sources() {
  case "$1" in
    11)
      echo "638aa2c88e94385b00f4f178d071e3df0b7d9e335577a83bd533b7f2eb65adf0 https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_a64fre_en-us.iso"
      echo "1e480d324ef02d340008b49433cd2d8d4ccac3476edb7a9a900c22ea5eceae42 https://dl.bobpony.com/windows/11/en-us_windows_11_25h2_arm64.iso"
      echo "57d1dfb2c6690a99fe99226540333c6c97d3fd2b557a50dfe3d68c3f675ef2b0 https://archive.org/download/Windows11_24H2_Arm64_ISO/Win11_24H2_English_Arm64.iso"
      ;;
    11e)
      echo "dad633276073f14f3e0373ef7e787569e216d54942ce522b39451c8f2d38ad43 https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1.240331-1435.ge_release_CLIENTENTERPRISEEVAL_OEMRET_A64FRE_en-us.iso"
      echo "2bf0fd1d5abd267cd0ae8066fea200b3538e60c3e572428c0ec86d4716b61cb7 https://archive.org/download/win11-23h2-en-fr/ARM64/SW_DVD9_Win_Pro_11_23H2_Arm64_English_Pro_Ent_EDU_N_MLF_X23-59519.ISO"
      ;;
    11l)
      echo "3dcdba9c9c0aa0430d4332b60c9afcb3cd613d648a49cbba2d4ef7b5978f32e8 https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_IOT_LTSC_EVAL_A64FRE_en-us.iso"
      echo "f8f068cdc90c894a55d8c8530db7c193234ba57bb11d33b71383839ac41246b4 https://dl.bobpony.com/windows/11/X23-81950_26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_ENTERPRISES_OEM_A64FRE_en-us.iso"
      ;;
  esac
}

iso_acquire() {
  if [ -n "${BOOT_ISO:-}" ]; then
    [ -f "$BOOT_ISO" ] || die "BOOT_ISO set but not found: $BOOT_ISO"
    ISO="$BOOT_ISO"; log "Using provided ISO: $ISO"; return 0
  fi
  if [ -f "$ISO" ]; then log "Reusing ISO: $ISO"; return 0; fi
  _iso_download "$VERSION"
}

_iso_download() {
  local version="$1" sha url ok="" label srcs
  label="$(wharf_version_label "$version")"; [ -n "$label" ] || label="$version"
  srcs="$(_iso_sources "$version")"
  [ -n "$srcs" ] || die "No download source defined for VERSION=$version."

  while read -r sha url; do
    [ -z "$url" ] && continue
    log "Downloading $label from $(printf '%s' "$url" | sed -E 's#https?://([^/]+).*#\1#')..."
    if _fetch "$url" "$ISO"; then
      if [ "${VERIFY}" != "N" ] && [ "${VERIFY}" != "n" ] && [ -n "$sha" ]; then
        log "Verifying SHA-256..."
        local got; got="$(shasum -a 256 "$ISO" | awk '{print $1}')"
        if [ "$got" != "$sha" ]; then
          warn "Checksum mismatch (got ${got:0:12}…, want ${sha:0:12}…) — discarding."
          rm -f "$ISO"; continue
        fi
        log "Checksum OK."
      fi
      ok=1; break
    fi
    warn "Mirror failed — trying next."
  done <<EOF
$srcs
EOF
  [ -n "$ok" ] || die "All mirrors failed for VERSION=$version. Provide BOOT_ISO=/path/to.iso instead."
  log "ISO ready: $ISO"
}

_fetch() {
  local url="$1" out="$2"
  if command -v aria2c >/dev/null 2>&1; then
    # quiet, single updating progress line: no periodic summary blocks, no result
    # table, errors-only log (transient mirror 5xx are retried automatically).
    aria2c -x4 -s4 -k1M --continue=true --auto-file-renaming=false --allow-overwrite=true \
           --summary-interval=0 --download-result=hide --console-log-level=error \
           --max-tries=10 --retry-wait=3 \
           -d "$(dirname "$out")" -o "$(basename "$out")" "$url"
  else
    curl -fL --retry 5 --retry-delay 3 -C - -o "$out" "$url"
  fi
}
