#!/bin/bash
# Boots a throwaway FreeBSD VM (QEMU; amd64 or aarch64) from a cloud-init image, runs
# scripts/build-packages.sh inside it and copies ./out back.
# Meant for a Linux self-hosted runner; run from the repository root.
#
# Env:
#   FREEBSD_IMAGE   path to a FreeBSD *BASIC-CLOUDINIT* qcow2 image (never modified);
#                   default ~/FreeBSD-16.0-CURRENT-amd64-BASIC-CLOUDINIT-ufs.qcow2
#                   or ~/FreeBSD-16.0-CURRENT-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2
#   FBSD_ARCH       amd64 (default) or aarch64. A guest that differs from the host
#                   architecture runs under TCG emulation: very slow, needs a long timeout.
#   VM_CPUS, VM_MEM (MiB), VM_DISK  defaults: 4, 8192, 40G
#   PORTS_REF EXPECTED_CROWDSEC FBSD_RELEASE FBSD_ARCH   passed through to the build
set -euo pipefail

FBSD_ARCH=${FBSD_ARCH:-amd64}
HOST_ARCH=$(uname -m)
case "$FBSD_ARCH" in
  amd64)   DEFAULT_IMAGE=$HOME/FreeBSD-16.0-CURRENT-amd64-BASIC-CLOUDINIT-ufs.qcow2
           [ "$HOST_ARCH" = x86_64 ] && NATIVE=1 || NATIVE=0 ;;
  aarch64) DEFAULT_IMAGE=$HOME/FreeBSD-16.0-CURRENT-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2
           [ "$HOST_ARCH" = aarch64 ] && NATIVE=1 || NATIVE=0 ;;
  *) echo "unsupported FBSD_ARCH=$FBSD_ARCH (use amd64 or aarch64)" >&2; exit 1 ;;
esac
FREEBSD_IMAGE=${FREEBSD_IMAGE:-$DEFAULT_IMAGE}
[ -r "$FREEBSD_IMAGE" ] || { echo "cannot read $FREEBSD_IMAGE" >&2; exit 1; }
if [ "$NATIVE" = 1 ]; then
  [ -w /dev/kvm ] || { echo "/dev/kvm is not writable by $(id -un) (add the user to the kvm group)" >&2; exit 1; }
  BOOT_TRIES=180      # 15 minutes
else
  echo "guest $FBSD_ARCH on a $HOST_ARCH host: using slow TCG emulation" >&2
  BOOT_TRIES=720      # 60 minutes
fi

VM_CPUS=${VM_CPUS:-4}
VM_MEM=${VM_MEM:-8192}
VM_DISK=${VM_DISK:-40G}
REPO=$PWD
WORK=$(mktemp -d)
PIDFILE=$WORK/qemu.pid
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

cleanup() {
  if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
PUBKEY=$(cat "$WORK/key.pub")

# nuageinit (NoCloud): a shell-script user-data that lets root log in with our key
mkdir "$WORK/seed"
cat > "$WORK/seed/user-data" <<UD
#!/bin/sh
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo '$PUBKEY' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sed -i '' -e 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
service sshd reload || service sshd restart
UD
printf 'instance-id: build-%s\nlocal-hostname: builder\n' "$$" > "$WORK/seed/meta-data"
genisoimage -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock "$WORK/seed/user-data" "$WORK/seed/meta-data"

# copy-on-write overlay, so the base image stays pristine
qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$FREEBSD_IMAGE")" "$WORK/disk.qcow2" "$VM_DISK"

COMMON_ARGS=(
  -smp "$VM_CPUS" -m "$VM_MEM"
  -display none -serial "file:$WORK/console.log"
  -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2"
  -drive "file=$WORK/seed.iso,media=cdrom,readonly=on"
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=n0
  -daemonize -pidfile "$PIDFILE"
)
if [ "$FBSD_ARCH" = amd64 ]; then
  if [ "$NATIVE" = 1 ]; then ACCEL=(-machine accel=kvm -cpu host); else ACCEL=(-cpu max); fi
  qemu-system-x86_64 "${ACCEL[@]}" "${COMMON_ARGS[@]}"
else
  # aarch64 needs UEFI firmware (apt: qemu-efi-aarch64)
  FW=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
  [ -r "$FW" ] || { echo "missing $FW (apt install qemu-efi-aarch64 qemu-system-arm)" >&2; exit 1; }
  if [ "$NATIVE" = 1 ]; then ACCEL=(-machine virt,accel=kvm,gic-version=host -cpu host); else ACCEL=(-machine virt -cpu max); fi
  qemu-system-aarch64 "${ACCEL[@]}" -bios "$FW" "${COMMON_ARGS[@]}"
fi

SSH_OPTS=(-i "$WORK/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=30)
vm() { ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }

echo "waiting for the VM to accept ssh ($((BOOT_TRIES * 5 / 60)) minutes at most)..."
for _ in $(seq 1 "$BOOT_TRIES"); do
  vm true 2>/dev/null && break
  sleep 5
done
vm true || { echo "VM never became reachable; console log:" >&2; tail -n 60 "$WORK/console.log" >&2; exit 1; }
vm 'freebsd-version; uname -a'

# ship the repository, build, bring ./out back
tar -C "$REPO" --exclude=.git -cf - . | vm 'rm -rf /root/work && mkdir -p /root/work && tar -C /root/work -xf -'
vm "cd /root/work && env PORTS_REF='${PORTS_REF:-main}' EXPECTED_CROWDSEC='${EXPECTED_CROWDSEC:-}' \
  FBSD_RELEASE='${FBSD_RELEASE:?}' FBSD_ARCH='$FBSD_ARCH' sh scripts/build-packages.sh"
mkdir -p "$REPO/out"
vm 'tar -C /root/work/out -cf - .' | tar -C "$REPO/out" -xf -
ls -l "$REPO/out"
vm 'poweroff' || true
