# wharf

**Run Windows 11 / 10 ARM on Apple silicon — the "dockur way", but native.**

`wharf` gives you dockur's ergonomics (pick a `VERSION`, set RAM/CPU/disk, get an
auto-installing Windows with a viewer) while running **QEMU directly on macOS with
the HVF accelerator** — the same engine UTM uses for Windows, single-layer and fast.

```
macOS (Apple silicon)
└─ HVF (Hypervisor.framework)        ← single layer, hardware accelerated
   └─ qemu-system-aarch64 -accel hvf
      └─ Windows 11 / 10 ARM
```

## Why this exists

Every "containers-for-VMs" tool on Apple silicon — **tart, lume, apple/container** —
is built on **Virtualization.framework**, which *structurally cannot host Windows*
(no vTPM, a fixed virtio device set Windows has no drivers for, generic-EFI boot
gaps). That's why [tart marks Windows ARM "not possible"](https://github.com/openai/tart/issues/1123)
and why UTM falls back to its QEMU backend for Windows.

And **dockur** (QEMU-in-a-Docker-container) can't be accelerated on a Mac: containers
on macOS run inside a Linux VM, so QEMU there needs *nested* virtualization — which
either isn't exposed (Docker Desktop) or **hangs Windows at boot** (we verified this
on `apple/container`'s nested KVM: Linux boots fine, Windows spins at 0 bytes written).

So the unfilled niche is exactly this: **headless/scriptable, auto-installing
Windows-ARM on Mac via QEMU+HVF.** That's `wharf`.

## Requirements

- Apple silicon Mac.
- `brew install qemu` (signed with the HVF entitlement — required).
- `brew install wimlib cdrtools aria2` (driver injection + UDF ISO build + fast download).
- For TPM: `brew install swtpm` (and set `USE_TPM=Y`).

Run `./wharf doctor` to check everything.

## Usage

```bash
cp wharf.conf.example wharf.conf      # optional: edit VERSION, RAM, etc.

# install (auto-downloads, prepares, boots, installs — zero-touch to desktop)
VERSION=11 ./wharf install
# or bring your own ISO:  BOOT_ISO=/path/to/Win11_arm64.iso ./wharf install

# day-to-day
./wharf run         # boot the installed VM from its disk
./wharf status      # is it running + how to view
./wharf view        # open a VNC viewer
./wharf stop        # graceful ACPI shutdown (falls back to kill)
```

Then:
- **Console:** VNC at `127.0.0.1:5900` — use **`127.0.0.1`, never `localhost`**
  (localhost → IPv6 `::1`, where macOS's own Screen Sharing answers and demands
  your Mac password). Apple's Screen Sharing app also refuses loopback; use
  **TigerVNC** (`brew install --cask tigervnc-viewer`).
- **RDP:** `127.0.0.1:13389` once installed (user `Docker` / pass `admin`).

## Supported versions (same codes as dockur/windows-arm)

| `VERSION` | Edition |
|---|---|
| `11`  | Windows 11 Pro |
| `11l` | Windows 11 LTSC |
| `11e` | Windows 11 Enterprise |
| `10`  | Windows 10 Pro |
| `10l` | Windows 10 LTSC |
| `10e` | Windows 10 Enterprise |

## Status

**Win11 ARM: validated zero-touch end-to-end — `VERSION=11 ./wharf install` reaches the desktop with no interaction.**

| Area | State |
|---|---|
| QEMU+HVF launch (install/run/stop/status/view) | ✅ proven |
| Config / version model (dockur-compatible) | ✅ |
| UEFI firmware + disk + user-mode net + VNC | ✅ |
| Unattended install — auto edition + OOBE-skip (BypassNRO) | ✅ proven zero-touch to desktop (Win11) |
| Use an already-prepared ISO (e.g. dockur's) | ✅ |
| **Auto ISO download** (mirror map + SHA-256, aria2/curl) | ✅ proven (Win11) |
| **UDF ISO rebuild** (hdiutil extract + wimlib inject + mkisofs -udf) | ✅ proven (Win11) |
| Emulated TPM 2.0 (`USE_TPM=Y`) | ✅ wired (needs swtpm) |
| virtio-gpu display + drivers (nicer than ramfb) | 🔭 future |
| tart-style OCI image distribution | 🔭 future |

## Layout

```
wharf            CLI dispatcher (install/run/stop/status/view/doctor)
lib/config.sh     defaults + wharf.conf/env loading + version map
lib/deps.sh       dependency checks (doctor)
lib/iso.sh        acquire ISO (mirror map + SHA-256, aria2/curl)
lib/prepare.sh    hdiutil extract + wimlib driver inject + mkisofs -udf
lib/firmware.sh   edk2 code + writable vars
lib/disk.sh       qemu-img growable disk
lib/network.sh    user-mode net + RDP host-forward
lib/display.sh    VNC + viewer launch
lib/qemu.sh       assemble & run qemu-system-aarch64 -accel hvf
assets/autounattend.xml.tmpl   OOBE-skip answer file (dockur-ported)
```
