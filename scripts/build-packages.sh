#!/bin/sh
# Builds crowdsec, crowdsec-firewall-bouncer and pfSense-pkg-crowdsec on FreeBSD
# and writes freebsd-<major>-<arch>.tar + versions.txt to ./out.
# Run from the repository root, as root, on FreeBSD.
# Env: PORTS_REF EXPECTED_CROWDSEC FBSD_RELEASE FBSD_ARCH [USE_RE2=yes]
set -eux
pkg install -y git gmake
WS="$PWD"
export PACKAGES=/tmp/packages
# pfSense bases lag behind FreeBSD's support window, so the ports
# tree's "unsupported release" check must not block the build
export ALLOW_UNSUPPORTED_SYSTEM=yes
mkdir -p "$PACKAGES/All" "$WS/out"

# Ports tree
# /usr/ports can be a mount point in the VM image: empty it, don't remove it
mkdir -p /usr/ports
find /usr/ports -mindepth 1 -delete
git clone --depth 1 --branch "$PORTS_REF" https://git.freebsd.org/ports.git /usr/ports \
  || { find /usr/ports -mindepth 1 -delete; git clone https://git.freebsd.org/ports.git /usr/ports && git -C /usr/ports checkout "$PORTS_REF"; }

# pfSense does not necessarily provide re2 (the port links libre2/abseil
# dynamically through the re2_cgo build tag), so by default build crowdsec
# with Go's own regexp engine and no re2/abseil dependency. USE_RE2=yes keeps
# the port as is.
if [ "${USE_RE2:-no}" != yes ]; then
  mk=/usr/ports/security/crowdsec/Makefile
  sed -i.orig \
    -e '/^LIB_DEPENDS=[[:space:]]*libabsl_base\.so/,/libre2\.so:devel\/re2/d' \
    -e 's/,re2_cgo//' \
    -e 's|cwversion\.Libre2=C++|cwversion.Libre2=Go|' \
    "$mk"
  if grep -Eq 're2_cgo|libre2\.so|devel/(re2|abseil)' "$mk"; then
    echo "failed to strip re2 from $mk:" >&2
    diff "$mk.orig" "$mk" >&2 || true
    exit 1
  fi
  diff "$mk.orig" "$mk" || true
fi

# Our package goes into the tree like any other port
cp -R "$WS/security/pfSense-pkg-crowdsec" /usr/ports/security/

CS_VER=$(make -C /usr/ports/security/crowdsec -V PKGVERSION)
BN_VER=$(make -C /usr/ports/security/crowdsec-firewall-bouncer -V PKGVERSION)
PF_VER=$(make -C /usr/ports/security/pfSense-pkg-crowdsec -V PKGVERSION)
echo "crowdsec=$CS_VER bouncer=$BN_VER pfSense-pkg=$PF_VER"

if [ -n "$EXPECTED_CROWDSEC" ] && [ "${CS_VER%%_*}" != "$EXPECTED_CROWDSEC" ]; then
  echo "ports tree provides crowdsec $CS_VER, expected $EXPECTED_CROWDSEC" >&2
  exit 1
fi

# Build in dependency order; install each so the next can depend on it
for port in crowdsec crowdsec-firewall-bouncer pfSense-pkg-crowdsec; do
  cd "/usr/ports/security/$port"
  make BATCH=yes install-missing-packages
  make BATCH=yes package
  pkg add -f "$(find "/usr/ports/security/$port" "$PACKAGES" -name "$port-[0-9]*.pkg" | head -n 1)"
done

# The result must not need re2/abseil on pfSense
if [ "${USE_RE2:-no}" != yes ]; then
  crowdsec_pkg=$(find /usr/ports/security/crowdsec "$PACKAGES" -name 'crowdsec-[0-9]*.pkg' | head -n 1)
  if pkg info -d -F "$crowdsec_pkg" | grep -Eqi 're2|abseil'; then
    echo "crowdsec still depends on re2/abseil:" >&2
    pkg info -d -F "$crowdsec_pkg" >&2
    exit 1
  fi
fi

# Collect the three packages (never abseil/re2: pfSense manages those)
for port in crowdsec crowdsec-firewall-bouncer pfSense-pkg-crowdsec; do
  f=$(find "/usr/ports/security/$port" "$PACKAGES" -name "$port-[0-9]*.pkg" | head -n 1)
  test -n "$f"
  cp "$f" "$WS/out/"
done
cd "$WS/out"
MAJOR=${FBSD_RELEASE%%.*}
tar -czf "freebsd-$MAJOR-$FBSD_ARCH.tar" ./*.pkg
rm -f ./*.pkg
printf 'pfsense_pkg=%s\ncrowdsec=%s\nbouncer=%s\n' "$PF_VER" "$CS_VER" "$BN_VER" > versions.txt
ls -l
