# lib/display.sh — display + viewer.
#
# dockur ships a noVNC web viewer on :8006. We expose QEMU's VNC server and open
# a native VNC viewer. IMPORTANT macOS gotcha (learned the hard way): QEMU binds
# IPv4 127.0.0.1 only, but "localhost" resolves to IPv6 ::1 where macOS's own
# Screen Sharing answers and demands your Mac password. So ALWAYS use the numeric
# 127.0.0.1 — never "localhost". Apple's Screen Sharing app also refuses loopback
# ("can't control your own screen"); use TigerVNC or `open vnc://`.

VNC_HOST="127.0.0.1"
display_port() { echo $(( 5900 + VNC_DISPLAY )); }

display_opts() {
  # ramfb = simple framebuffer Windows can drive without extra drivers.
  DISPLAY_OPTS=( -device ramfb -vnc "${VNC_HOST}:${VNC_DISPLAY}" )
}

display_hint() {
  log "Console: VNC at ${VNC_HOST}:$(display_port)  (use 127.0.0.1, NOT localhost)"
  log "RDP after install: 127.0.0.1:${RDP_PORT}  (user: ${USERNAME} / pass: ${PASSWORD})"
}

display_open() {
  local p; p="$(display_port)"
  if [ -d "/Applications/TigerVNC.app" ]; then
    open -a TigerVNC --args "${VNC_HOST}:${p}" 2>/dev/null && return 0
  fi
  # Fall back to the URL handler (a non-Apple VNC client should grab it).
  open "vnc://${VNC_HOST}:${p}" 2>/dev/null \
    || warn "Open your VNC viewer manually and connect to ${VNC_HOST}:${p}"
}
