# wharf — summary (2026-06-16)

## Headline: `./wharf new <name>` reliably installs Win11 ARM with working SSH

One command, fully unattended, returns only when SSH is ready. **Zero manual steps. Survives reboot.** Validated on a clean `./wharf new windows11`:
- "VM 'windows11' is SSH-ready after ~600s" → `ssh Docker@127.0.0.1 -p 12222 -i ~/.wharf/ci_key` → Windows 11 Pro, ARM64.
- Rebooted → SSH auto-came-up on first probe.

## What it took (all root-caused + fixed in source)

1. **`$OEM$` must live under `\sources\$OEM$`** (not ISO root) or Windows Setup ignores it → no `C:\OEM`/`C:\Drivers`, first-logon script never staged. (`lib/prepare.sh`)
2. **Launch guest-setup via `RunOnce`** (specialize pass), not FirstLogonCommands — those are suppressed by `SkipMachineOOBE`. (`assets/autounattend.xml.tmpl`)
3. **guest-setup.ps1 must be ASCII** — an em-dash made Win PowerShell (ANSI, BOM-less) throw a parse error and abort the whole script. *This was why it silently never ran.*
4. **OpenSSH-on-ARM64 hardening** (`assets/guest-setup.ps1`): network wait, `ssh-keygen -A`, ownership/ACL fixes on host keys + `administrators_authorized_keys`, and the listener:
   - SCM `sshd` service crashes (error 1067); plain `sshd.exe` daemon exits 1; SYSTEM task gives no banner.
   - **Only `sshd.exe -D` in the autologon user's elevated *interactive* session works** → run it via an **AtLogOn scheduled task, LogonType=Interactive, RunLevel=Highest** (needs `EnableLUA=false`, which the answer file sets).
5. **Install supervisor** (`vm_supervise_install` in `lib/ci.sh`, called by `cmd_install`): blocks until SSH-ready and **auto-power-cycles the QEMU process** through the intermittent edk2 "Start boot option" firmware hang (hits Win11 too; a process restart clears it).
6. **`ensure_ssh_key`** auto-generates+bakes `~/.wharf/ci_key` so SSH works with no setup.

## CI commands (also added)
`wharf endpoints <name> [--json]`, `wharf wait <name>`, `wharf snapshot/reset <name> [tag]`; envs `WHARF_HEADLESS=1`, `WHARF_SSH_PUBKEY`, `WHARF_NO_SUPERVISE=1`, `DISPLAY_DEVICE=virtio-gpu-pci`. Example CI in `examples/ci/`.

## Graphics (for the 2D/SDL game question)
Measured via dxdiag: no hardware 3D for a Windows guest (WARP software only), BUT D3D **Feature Level 12_1** is available via WARP + native ARM64 CPU → a **2D/SDL game will run and be playable**. Not viable: GPU perf/FPS/benchmark testing.

## Test the game
`scp -P 12222 -i ~/.wharf/ci_key game/ Docker@127.0.0.1:C:/game/` then ssh and run it; watch via VNC 127.0.0.1:5900. Send me the game and I'll run it + capture frames.
