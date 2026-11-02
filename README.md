# pfSense-pkg-crowdsec

This package integrates CrowdSec in pfSense.

It is not installed from the official repositories, at least not yet, but you are free to test from the Releases page.

Please refer to the [detailed documentation](https://docs.crowdsec.net/docs/getting_started/install_crowdsec_pfsense/) to install or update it from a release archive.

It provides a basic UI with settings to configure the Security Engine and the Firewall Remediation Component (bouncer).

Three types of configuration are supported:

- Small: remediation only. Use this to protect a set of existing servers already running CrowdSec. The remediation component
  feeds the Packet Filter with the blocklists received by the main CrowdSec instance (*).

- Medium: like Small but can also detect attacks by parsing logs in the pfSense machine. Attack data is sent to the CrowdSec
  instance for analysis and possibly sharing.

- Large: deploy a fully autonomous CrowdSec Security Engine on the pfSense machine and allow other servers to connect to it.
  Requires a persistent /var directory (no RAM disk) and a slightly larger pfSense machine, depending on the amount of data
  to be processed.

(*) If you are already using a Blocklist Mirror, this replaces it while being faster and not requiring pfBlockerNG.

## How releases are made

Releases are built by GitHub Actions from the FreeBSD ports tree (`security/crowdsec`, `security/crowdsec-firewall-bouncer`) plus this repository's `pfSense-pkg-crowdsec`.

1. **`watch-upstream.yml`** runs daily at midnight EST (05:00 UTC). When the ports tree has a newer CrowdSec or firewall bouncer than the minimums in `security/pfSense-pkg-crowdsec/Makefile`, it opens a pull request that bumps `PORTVERSION`, the minimum versions and the changelog (and labels it `security` if the upstream release notes mention GHSA/CVE ids). It opens an issue if the check itself keeps failing or a bump pull request is left open for a week.
2. Merging that pull request starts **`build-release.yml`**: FreeBSD 14, 15 and 16 on amd64, published as a pre-release `v<package>-<crowdsec>-<bouncer build>` with generated release notes.
3. When the release exists, it starts **`build-release-aarch64.yml`** (emulated, several hours), which attaches the aarch64 archives to the same release.
4. Promote the pre-release to a normal release when you have tested it.

Both build workflows can also be run by hand from the Actions tab. The repository setting *Actions → General → Allow GitHub Actions to create and approve pull requests* must be on for step 1.
