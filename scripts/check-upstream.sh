#!/bin/bash
# Compares the versions of crowdsec and crowdsec-firewall-bouncer in the FreeBSD
# ports tree (what the release archives are built from) with the minimums this
# repo requires, and optionally bumps the package.
#
#   check-upstream.sh            print key=value lines (for $GITHUB_OUTPUT)
#   check-upstream.sh --apply    also bump PORTVERSION, RUN_DEPENDS and the
#                                changelog in the working tree
#
# Env: GH_TOKEN (optional) lets `gh` read upstream release notes without hitting
#      the anonymous rate limit.
set -euo pipefail

cd "$(dirname "$0")/.."
ports_raw=${PORTS_RAW_URL:-https://cgit.freebsd.org/ports/plain/security}
mk=security/pfSense-pkg-crowdsec/Makefile
descr=security/pfSense-pkg-crowdsec/pkg-descr
apply=0
[ "${1:-}" = "--apply" ] && apply=1

# DISTVERSION (or PORTVERSION) plus _PORTREVISION, e.g. 1.8.2 or 0.0.38_2
port_version() {
  local m v r
  m=$(curl -fsS --retry 3 "$ports_raw/$1/Makefile")
  v=$(printf '%s\n' "$m" | sed -n 's/^\(DISTVERSION\|PORTVERSION\)=[[:space:]]*//p' | head -n1)
  r=$(printf '%s\n' "$m" | sed -n 's/^PORTREVISION=[[:space:]]*//p' | head -n1)
  [ -n "$v" ] || { echo "cannot read the version of $1 from the ports tree" >&2; exit 1; }
  echo "$v${r:+_$r}"
}

# true when $1 is a strictly newer version than $2
newer() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

cs_ports=$(port_version crowdsec)
bn_ports=$(port_version crowdsec-firewall-bouncer)
cs_min=$(sed -n 's/.*[[:space:]=]crowdsec>=\([^:]*\):.*/\1/p' "$mk" | head -n1)
bn_min=$(sed -n 's/.*crowdsec-firewall-bouncer>=\([^:]*\):.*/\1/p' "$mk" | head -n1)
pkg_cur=$(sed -n 's/^PORTVERSION=[[:space:]]*//p' "$mk")
[ -n "$cs_min" ] && [ -n "$bn_min" ] && [ -n "$pkg_cur" ] || { echo "cannot parse $mk" >&2; exit 1; }

needs_bump=false
if newer "$cs_ports" "$cs_min" || newer "$bn_ports" "$bn_min"; then needs_bump=true; fi

# New package version: a new crowdsec major/minor (1.8 -> 1.9) bumps the package
# minor, anything else the package patch level.
IFS=. read -r p_maj p_min p_pat <<< "$pkg_cur"
if [ "${cs_ports%.*}" != "${cs_min%.*}" ]; then
  pkg_new="$p_maj.$((p_min + 1)).0"
else
  pkg_new="$p_maj.$p_min.$((p_pat + 1))"
fi

# security fixes announced in the upstream release notes of the new crowdsec version
security_ids=""
if [ "$needs_bump" = true ] && newer "$cs_ports" "$cs_min"; then
  notes=""
  if command -v gh > /dev/null; then
    notes=$(gh api "repos/crowdsecurity/crowdsec/releases/tags/v${cs_ports%%_*}" --jq .body 2> /dev/null || true)
  fi
  security_ids=$(printf '%s\n' "$notes" | grep -oE 'GHSA(-[a-z0-9]{4}){3}|CVE-[0-9]{4}-[0-9]+' | sort -u | paste -sd, - || true)
fi

echo "cs_ports=$cs_ports"
echo "bn_ports=$bn_ports"
echo "cs_min=$cs_min"
echo "bn_min=$bn_min"
echo "pkg_cur=$pkg_cur"
echo "pkg_new=$pkg_new"
echo "needs_bump=$needs_bump"
echo "security_ids=$security_ids"

[ "$apply" = 1 ] || exit 0
[ "$needs_bump" = true ] || { echo "nothing to bump" >&2; exit 0; }

sed -i.bak \
  -e "s/^PORTVERSION=.*/PORTVERSION=\t$pkg_new/" \
  -e "s/crowdsec>=$cs_min:/crowdsec>=$cs_ports:/" \
  -e "s/crowdsec-firewall-bouncer>=$bn_min:/crowdsec-firewall-bouncer>=$bn_ports:/" \
  "$mk"
rm -f "$mk.bak"

entry=$(mktemp)
{
  echo "$pkg_new"
  echo
  echo " * ship with crowdsec ${cs_ports%%_*} and crowdsec-firewall-bouncer ${bn_ports%%_*}"
  echo " * require crowdsec $cs_ports and crowdsec-firewall-bouncer $bn_ports"
  [ -z "$security_ids" ] || echo " * includes upstream security fixes ($security_ids)"
  echo
} > "$entry"
awk -v entry="$entry" '
  { print }
  /^=+$/ && !done { getline; print; while ((getline line < entry) > 0) print line; done = 1 }
' "$descr" > "$descr.new"
mv "$descr.new" "$descr"
rm -f "$entry"
