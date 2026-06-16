# lib/network.sh — networking.
#
# dockur builds a Linux bridge/tap inside its container. We don't need any of
# that: QEMU's built-in user-mode (slirp) networking gives the guest outbound
# internet with zero host config, and host-forwards a port to the guest's RDP
# (3389) so you can connect with Microsoft Remote Desktop. This is the macOS
# equivalent of dockur's USER_PORTS path — which is exactly the mode we had to
# force when running under apple/container, now the natural default.
#
# Emits the QEMU -netdev/-device pair into the NET_OPTS array.

network_opts() {
  # Forward host ports to the guest. Bound to 127.0.0.1 (not all interfaces) so a
  # VM isn't unintentionally exposed on the LAN; a same-host CI runner reaches it
  # on loopback. SSH (22) is the headless/CI control channel (see guest-setup.ps1).
  local fwd="hostfwd=tcp:127.0.0.1:${RDP_PORT}-:3389,hostfwd=udp:127.0.0.1:${RDP_PORT}-:3389"
  fwd="${fwd},hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
  NET_OPTS=(
    -netdev "user,id=net0,${fwd}"
    -device "virtio-net-pci,netdev=net0"
  )
}
