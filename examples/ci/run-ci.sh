#!/usr/bin/env bash
# Example: drive a wharf Windows 11 VM from CI on a self-hosted macOS runner.
#
# Flow:  (provision once OR reset from golden) -> wait-ready -> run tests over SSH
#        -> collect artifacts -> stop. Idempotent enough to run per-pipeline.
#
# Prereqs: wharf on PATH (or adjust WHARF), an SSH key baked in at install time
#          (WHARF_SSH_PUBKEY=~/.wharf/ci_key.pub wharf new ...), brew qemu etc.
set -Eeuo pipefail

WHARF="${WHARF:-$HOME/wharf/wharf}"
VM="${VM:-ci-win11}"
SSH_KEY="${SSH_KEY:-$HOME/.wharf/ci_key}"
ART_DIR="${ART_DIR:-./artifacts}"
TEST_CMD_LOCAL="${1:-}"   # optional: a local .ps1/.bat to copy in and run

# --- helper: read endpoints as shell vars (uses the --json output) -----------
eval "$(
  "$WHARF" endpoints "$VM" --json 2>/dev/null | python3 - <<'PY'
import sys, json
d = json.load(sys.stdin)
print(f'SSH_PORT={d["ssh"]}')
print(f'USER_NAME={d["username"]}')
print(f'HOST={d["host"]}')
PY
)"

ssh_vm() { ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
              "${USER_NAME}@${HOST}" "$@"; }
scp_to() { scp -P "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }

echo "==> Provision / reset VM '$VM'"
if "$WHARF" status "$VM" >/dev/null 2>&1 || [ -d "$HOME/.wharf/$VM" ]; then
  # already installed: restore a clean golden snapshot for a deterministic run
  "$WHARF" stop "$VM" 2>/dev/null || true
  "$WHARF" reset "$VM" golden 2>/dev/null || echo "   (no golden snapshot yet; using current disk)"
  WHARF_HEADLESS=1 "$WHARF" run "$VM"
else
  # first time: install Windows (zero-touch) with the CI SSH key baked in
  WHARF_HEADLESS=1 WHARF_SSH_PUBKEY="${SSH_KEY}.pub" VERSION=11 "$WHARF" new "$VM"
fi

echo "==> Wait for guest to be CI-ready"
"$WHARF" wait "$VM" 2400

echo "==> Run tests inside Windows"
mkdir -p "$ART_DIR"
if [ -n "$TEST_CMD_LOCAL" ]; then
  scp_to "$TEST_CMD_LOCAL" "${USER_NAME}@${HOST}:C:/Windows/Temp/test_payload"
  ssh_vm 'powershell -ExecutionPolicy Bypass -File C:\Windows\Temp\test_payload' | tee "$ART_DIR/test-output.txt"
else
  # default smoke test: prove we can run commands + report the GPU/render path
  ssh_vm 'powershell -Command "Get-ComputerInfo | Select-Object OsName,OsArchitecture,CsProcessors | Format-List; Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion | Format-List"' \
    | tee "$ART_DIR/smoke.txt"
fi

echo "==> Collect artifacts"
scp_to "${USER_NAME}@${HOST}:C:/OEM/wharf-setup.log" "$ART_DIR/" 2>/dev/null || true

echo "==> Tear down"
"$WHARF" stop "$VM"
echo "Done. Artifacts in $ART_DIR/"
