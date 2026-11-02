#!/bin/sh
# Writes GitHub release notes to stdout.
# Usage: release-notes.sh <tag> <versions.txt> <artifacts-dir>
# versions.txt: pfsense_pkg=, crowdsec=, bouncer= (written by build-packages.sh)
set -eu
tag=$1
versions=$2
artifacts=$3
repo=${GITHUB_REPOSITORY:-JohnFawkes/pfSense-pkg-crowdsec}
descr=$(dirname "$0")/../security/pfSense-pkg-crowdsec/pkg-descr

# shellcheck disable=SC1090
. "$versions"
pkgver=${pfsense_pkg%%_*}

echo "## pfSense-pkg-crowdsec $pkgver"
echo
echo "| Component | Version |"
echo "|---|---|"
echo "| pfSense-pkg-crowdsec | $pfsense_pkg |"
echo "| crowdsec | $crowdsec |"
echo "| crowdsec-firewall-bouncer | $bouncer |"
echo
echo "### Changes"
echo
# the section of pkg-descr between "<version>" and the next version heading
awk -v v="$pkgver" '
  $0 == v { on = 1; next }
  on && /^[0-9]+\.[0-9]+\.[0-9]+$/ { exit }
  on { print }
' "$descr" | awk 'NF { started = 1 } started { line[++n] = $0 } END { while (n > 0 && line[n] == "") n--; for (i = 1; i <= n; i++) print line[i] }'
echo
echo "### Install"
echo
echo "On the pfSense console or over SSH, as root:"
echo
echo '```sh'
echo "fetch https://raw.githubusercontent.com/$repo/refs/heads/main/install-crowdsec.sh"
echo "sh install-crowdsec.sh --release $tag"
echo '```'
echo
echo "The script picks the archive that matches your FreeBSD version and architecture."
echo
echo "### Archives"
echo
echo "| Archive | FreeBSD | Architecture |"
echo "|---|---|---|"
for f in $(ls "$artifacts"/*/freebsd-*.tar 2>/dev/null | xargs -n1 basename | sort -t- -k2,2n -k3); do
  rest=${f#freebsd-}; rest=${rest%.tar}
  echo "| \`$f\` | ${rest%%-*} | ${rest#*-} |"
done
