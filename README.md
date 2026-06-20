# wharf

**Zero-touch Windows 11 ARM VMs on Apple silicon — the "dockur way", but native, and SSH/CI-ready.**

One command gives you an unattended Windows 11 ARM install that comes up with
**SSH ready to drive** — no clicking, no GUI, no manual setup:

```bash
wharf new win11        # downloads + installs Windows 11 ARM, returns when SSH is up
ssh Docker@127.0.0.1 -p 12222 -i ~/.wharf/ci_key 'hostname'
```

![wharf demo: one command to an SSH-ready Windows 11 ARM VM](docs/demo.gif)

<sub>(the ~12-minute unattended Windows install is fast-forwarded; `wharf ls` and the `ssh` into Windows are live)</sub>

It runs **QEMU directly on macOS with the HVF accelerator** (the same engine UTM
uses for Windows — single layer, hardware-accelerated), wrapped in dockur-style
automation: auto ISO download, virtio driver injection, unattended answer file,
and a viewer.

```
macOS (Apple silicon)
└─ HVF (Hypervisor.framework)        ← single layer, hardware accelerated
   └─ qemu-system-aarch64 -accel hvf
      └─ Windows 11 ARM  (+ OpenSSH, virtio drivers)
```

## Why this exists

Every "containers-for-VMs" tool on Apple silicon — **tart, lume, apple/container** —
is built on **Virtualization.framework**, which *structurally cannot host Windows*
(no vTPM, a fixed virtio device set Windows has no drivers for, generic-EFI boot
gaps). That's why [tart marks Windows ARM "not possible"](https://github.com/cirruslabs/tart/issues/1123)
and why UTM falls back to its QEMU backend for Windows.

And **dockur/windows** (QEMU-in-a-Docker-container) can't be accelerated on a Mac:
containers on macOS run inside a Linux VM, so QEMU there needs *nested*
virtualization — which either isn't exposed (Docker Desktop) or **hangs Windows
at boot** (verified on `apple/container`'s nested KVM: Linux boots fine, Windows
spins at 0 bytes written).

The unfilled niche is exactly this: **headless, scriptable, auto-installing
Windows 11 ARM on a Mac via QEMU+HVF — usable from CI.** That's `wharf`. UTM is the
GUI answer; wharf is the CLI/CI answer.

## Install

```bash
brew install fenio/tap/wharf
wharf doctor
```

That pulls `qemu` (the HVF-entitled build), `wimlib`, and `cdrtools`. Optional:
`brew install aria2` (faster ISO downloads) and `brew install swtpm` (only if you
set `USE_TPM=Y`).

From source instead: clone the repo and run `./wharf` directly (same deps).

Requirements: an **Apple silicon Mac**. `wharf doctor` verifies the toolchain and
the QEMU HVF entitlement; an SSH keypair (`~/.wharf/ci_key`) is generated
automatically on first use.

## Quickstart

```bash
# create + install a VM, zero-touch; returns once it's installed AND SSH-ready
wharf new win11
VERSION=11l RAM_SIZE=8G wharf new ltsc      # other editions / resources

wharf ls                      # list VMs: status, edition, VNC, RDP, disk
wharf endpoints win11         # show VNC / RDP / SSH for a VM
wharf run    win11            # boot an installed VM
wharf stop   win11            # graceful ACPI shutdown (falls back to kill)
wharf rm     win11            # stop + delete the VM
```

Each VM lives under `~/.wharf/<name>/` with auto-assigned, non-colliding ports
(all bound to `127.0.0.1`):

```
NAME    STATUS   EDITION          VNC               RDP               DISK
win11   running  Windows 11 Pro   127.0.0.1:5900    127.0.0.1:13389   16G
ltsc    stopped  Windows 11 LTSC  127.0.0.1:5901    127.0.0.1:13390   11G
```

Connect:
- **SSH** (the CI channel): `ssh Docker@127.0.0.1 -p <ssh> -i ~/.wharf/ci_key`
- **RDP** (full res/clipboard/audio): `127.0.0.1:<rdp>` (user `Docker` / pass `admin`)
- **Console (VNC):** `127.0.0.1:59NN` — use **`127.0.0.1`, never `localhost`**
  (localhost → IPv6 `::1`, where macOS Screen Sharing answers and demands your Mac
  password). Apple's Screen Sharing also refuses loopback; use **TigerVNC**
  (`brew install --cask tigervnc-viewer`).

## Headless / CI

wharf is built to be driven from scripts and pipelines:

```bash
WHARF_HEADLESS=1 wharf new ci-win11   # no auto-opened viewer
wharf wait      ci-win11              # block until the guest is SSH/CI-ready
wharf endpoints ci-win11 --json       # machine-readable ports + creds
wharf snapshot  ci-win11 golden       # save a golden disk image (APFS clone)
wharf reset     ci-win11 golden       # restore it between test runs
```

- `wharf new` runs an **install supervisor** that blocks until SSH is reachable and
  auto-recovers from the intermittent edk2 firmware hang on mid-install reboots
  (a full QEMU process restart clears it).
- The guest gets **OpenSSH Server** + virtio drivers installed automatically at
  first boot, and `~/.wharf/ci_key` is baked in — so SSH works with no manual step,
  and survives reboots.
- See [`examples/ci/`](examples/ci/) for a runnable script + a GitHub Actions
  workflow for a self-hosted macOS runner.

Set `WHARF_SSH_PUBKEY=/path/key.pub` before `new` to bake in your own key.

## Supported versions (Windows 11 ARM only)

| `VERSION` | Edition |
|---|---|
| `11`  | Windows 11 Pro |
| `11l` | Windows 11 LTSC (IoT Enterprise) |
| `11e` | Windows 11 Enterprise |

> **No Windows 10?** Win10 ARM boots fine on Linux (dockur) but **hangs in QEMU's
> aarch64 firmware on Apple silicon** under stock brew QEMU (HVF *and* TCG) — while
> Win11 boots on the identical stack. (Root-caused to the Win10 bootloader vs the
> `virt` EDK2 build — `ConvertPages: failed to find range` — reproducible even under
> TCG; see [QEMU #2893](https://gitlab.com/qemu-project/qemu/-/issues/2893).) If you
> need Win10 ARM, run dockur on Linux and RDP in. wharf is Win11-only by design.

## Scope & limitations

- **Apple silicon + macOS + Windows 11 ARM only.** Not x86, not Intel Macs.
- **No hardware 3D.** There's no GPU passthrough for a Windows guest under QEMU on
  Apple silicon, and the only Windows-ARM virtio GPU driver is display-only.
  Direct3D falls back to **WARP (software)** — fine for desktop apps, 2D/SDL games,
  build/test/CLI work; not for GPU benchmarks or demanding 3D.
- **Bring your own Windows license.** wharf downloads official Microsoft ARM ISOs
  (same mirror logic as dockur/windows-arm) for convenience; activating and
  licensing Windows is your responsibility.
- Young and tuned against current Homebrew QEMU on recent macOS — other QEMU/macOS
  combinations may surface new edges. `wharf doctor` helps diagnose.

## Status

**Win11 ARM: validated zero-touch end-to-end** — `wharf new <name>` installs and
returns SSH-ready with no interaction, and SSH survives reboots. Verified by
building three VMs back-to-back and by building + running a native ARM64 SDL3 game
inside one over SSH.

| Area | State |
|---|---|
| QEMU+HVF launch, multi-VM (new/ls/rm/run/stop/status) | ✅ |
| Unattended install → desktop (auto edition + OOBE-skip) | ✅ |
| Auto ISO download (mirror map + SHA-256) + UDF rebuild + driver inject | ✅ |
| OpenSSH out of the box + install supervisor (firmware-hang auto-recovery) | ✅ |
| CI helpers: endpoints/--json, wait, snapshot, reset; headless | ✅ |
| Emulated TPM 2.0 (`USE_TPM=Y`) | ✅ |
| virtio-gpu display (`DISPLAY_DEVICE=virtio-gpu-pci`, 2D/res; no 3D) | ✅ |
| OCI-style image distribution | 🔭 future |

## Layout

```
wharf             CLI dispatcher
lib/config.sh      defaults + wharf.conf/env + version map
lib/vm.sh          named-VM registry (new/ls/rm, port allocation)
lib/ci.sh          endpoints / wait / snapshot / reset + install supervisor
lib/deps.sh        dependency checks (doctor)
lib/iso.sh         acquire ISO (mirror map + SHA-256, aria2/curl)
lib/prepare.sh     hdiutil extract + wimlib driver inject + mkisofs -udf + $OEM$ staging
lib/firmware.sh    edk2 code + writable vars
lib/disk.sh        qemu-img growable disk
lib/network.sh     user-mode net + RDP/SSH host-forwards (127.0.0.1)
lib/display.sh     VNC + viewer launch (ramfb / virtio-gpu-pci)
lib/qemu.sh        assemble & run qemu-system-aarch64 -accel hvf
assets/autounattend.xml.tmpl   OOBE-skip answer file (RunOnce -> guest-setup)
assets/guest-setup.ps1         first-boot: install drivers + enable OpenSSH
examples/ci/                   CI script + GitHub Actions example
```

## License

MIT — see [LICENSE](LICENSE).

> Not affiliated with Microsoft. "Windows" is a trademark of Microsoft Corporation.
> wharf orchestrates QEMU and Microsoft's own ISOs; it ships no Microsoft software.
