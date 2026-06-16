# lib/config.sh — defaults + config loading. Mirrors dockur's env-var UX so the
# tool "feels" the same: same VERSION codes, same RAM_SIZE/CPU_CORES/DISK_SIZE,
# same USERNAME/PASSWORD/LANGUAGE knobs.
#
# Precedence (low → high): defaults here  <  ./wharf.conf  <  environment vars.

# ---- supported Windows versions ---------------------------------------------
# Win11 ARM only. Win10 ARM is intentionally unsupported: it boots fine on Linux
# (dockur) but hangs in QEMU's aarch64 firmware ("Start boot option") under stock
# brew QEMU on Apple silicon — both HVF and TCG — while Win11 boots on the
# identical stack. Only UTM's patched QEMU gets its bootmgr running (and even then
# hits 0xc000000f). Use dockur on Linux if you need Win10 ARM. See win10 note in README.
# Case-functions (not associative arrays) so this runs on stock macOS bash 3.2.
wharf_versions_list() { echo "11 11l 11e"; }
wharf_version_label() {
  case "$1" in
    11)  echo "Windows 11 Pro" ;;
    11l) echo "Windows 11 LTSC" ;;
    11e) echo "Windows 11 Enterprise" ;;
    *)   echo "" ;;
  esac
}

# Exact WIM edition name for autounattend's /IMAGE/NAME (so Setup auto-picks the
# edition and skips the "Select Image" screen). Must match the name inside the
# ISO's install.wim/esd. LTSC ISOs use the IoT Enterprise LTSC edition.
wharf_image_name() {
  case "$1" in
    11)  echo "Windows 11 Pro" ;;
    11l) echo "Windows 11 IoT Enterprise LTSC" ;;
    11e) echo "Windows 11 Enterprise" ;;
    *)   echo "Windows 11 Pro" ;;
  esac
}

# ---- defaults (override via wharf.conf or env) -----------------------------
: "${VERSION:=11}"                 # which Windows (see WHARF_VERSIONS)
: "${RAM_SIZE:=4G}"                # guest RAM
: "${CPU_CORES:=4}"               # guest vCPUs
: "${DISK_SIZE:=64G}"             # growable disk size
# NOTE: USERNAME is also a macOS login env var (= $USER), which would clobber our
# default. If it's just the ambient host value, ignore it so the default applies.
# To set the Windows account name, use wharf.conf or an explicit USERNAME= override.
[ -n "${USERNAME:-}" ] && [ "${USERNAME}" = "${USER:-}" ] && unset USERNAME
: "${USERNAME:=Docker}"           # auto-created local account (dockur default)
: "${PASSWORD:=admin}"            # its password
: "${LANGUAGE:=English}"          # install language
: "${REGION:=}"                   # locale (defaults from LANGUAGE)
: "${KEYBOARD:=}"                 # keyboard layout

: "${NAME:=wharf}"               # VM / process name
: "${WHARF_VMS:=$HOME/.wharf}"   # registry root for named VMs (wharf new/ls/rm)
: "${STORAGE:=$WHARF_HOME/storage}"   # where ISO, disk, EFI vars live (default VM)
: "${RDP_PORT:=13389}"           # host port forwarded to guest RDP (3389)
: "${SSH_PORT:=12222}"           # host port forwarded to guest OpenSSH (22) — CI channel
: "${VNC_DISPLAY:=0}"            # VNC display number (port = 5900 + this)
: "${DISPLAY_DEVICE:=ramfb}"     # guest display: ramfb (default) or virtio-gpu-pci (2D accel/res)
: "${USE_TPM:=N}"                # add an emulated TPM 2.0 (needs swtpm)
: "${WHARF_SSH_KEY:=$HOME/.wharf/ci_key}"        # SSH keypair for the CI channel
: "${WHARF_SSH_PUBKEY:=${WHARF_SSH_KEY}.pub}"    # baked into the guest at install
: "${BOOT_ISO:=}"                # path to a pre-supplied Windows ARM ISO (BYO)
: "${VERIFY:=Y}"                 # verify downloaded ISO against known SHA-256
: "${VIRTIO_VERSION:=0.1.285}"   # qemus/virtiso-arm driver pack version

EDK2_CODE="${EDK2_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
EDK2_VARS_TMPL="${EDK2_VARS_TMPL:-/opt/homebrew/share/qemu/edk2-arm-vars.fd}"

# load user config file if present (can override STORAGE/NAME/etc.)
[ -f "$WHARF_HOME/wharf.conf" ] && source "$WHARF_HOME/wharf.conf"

# ---- derived paths (a function, so named-VM resolution can re-derive) --------
config_paths() {
  VARS="$STORAGE/efi-vars.fd"
  DISK="$STORAGE/data.img"
  ISO="$STORAGE/${NAME}.iso"                     # raw (downloaded) ISO
  ISO_PREPARED="$STORAGE/${NAME}.prepared.iso"   # after driver+XML injection
  PIDFILE="$STORAGE/qemu.pid"
  MONITOR="$STORAGE/qemu.monitor.sock"
  mkdir -p "$STORAGE"
}
config_paths

# ---- helpers ----------------------------------------------------------------
log()  { printf '\033[1;36m❯ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

config_summary() {
  local label; label="$(wharf_version_label "$VERSION")"
  [ -n "$label" ] || die "Unknown VERSION='$VERSION'. Supported: $(wharf_versions_list)"
  log "wharf: $label  |  ${CPU_CORES} vCPU / ${RAM_SIZE} RAM / ${DISK_SIZE} disk  |  storage: $STORAGE"
}
