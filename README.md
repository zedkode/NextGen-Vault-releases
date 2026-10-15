# NextVault releases

Compiled releases of **NextVault** — a local-first encrypted password, 2FA and developer-secrets manager (desktop app, CLI, Brave/Chromium extension, self-hostable sync server). The source code is kept in a private repository; this repository only publishes builds.

**Download:** see [Releases](../../releases). Each release contains:

| File | What |
|---|---|
| `nextvault-desktop-linux-x86_64` | desktop app (Linux, x86_64) |
| `nextvault-linux-x86_64` | command-line tool |
| `nextvault-native-host-linux-x86_64` | bridge between the browser extension and the app |
| `nextvault-cloud-linux-x86_64` | self-hosted sync server |
| `nextvault-browser-X.Y.Z.crx` / `.zip` | browser extension (ID `bjgankijkmkepahceappdojedpegojmb`) |
| `SHA256SUMS`, `SHA256SUMS.sig` | checksums signed with the NextVault release key (Ed25519) |
| `update.xml` | update manifest for the browser extension |
| `install.sh`, `install-server.sh` | the installers below |
| `nextvault-website-X.Y.Z.tar.gz` | the website the server installer publishes |
| `nextvault.desktop`, `nextvault.svg` | application menu entry and icon |

Installed apps update themselves from here and install an update only when its signature verifies against the key built into them.

## Install the app (Linux x86_64, no root)

```sh
curl -fsSL https://raw.githubusercontent.com/zedkode/NextGen-Vault-releases/main/install.sh | bash
```

Downloads the latest release, verifies the signature and every checksum, installs the programs into `~/.local/bin`, the menu entry and the browser connection, and prints the one `sudo` command that makes Brave install the extension with automatic updates. The desktop app needs `webkit2gtk-4.1`, GStreamer (`gst-plugins-good`) and `zbar` (camera QR scanning). [Read the script](install.sh).

## Run your own sync server + website on a VPS

```sh
curl -fsSL https://raw.githubusercontent.com/zedkode/NextGen-Vault-releases/main/install-server.sh \
  | sudo bash -s -- --domain vault.example.com --email you@example.com
```

For Debian 12+ / Ubuntu 22.04+. Point the domain's DNS at the server first and keep ports 80 and 443 open. It installs the signature-checked server as a sandboxed systemd service, Caddy with automatic HTTPS (Let's Encrypt) and the NextVault website on `https://vault.example.com`. Only `--email` may create an account unless you pass `--registration open` (or a list such as `you@example.com,@family.example`). Other options: `--auto-update` (daily signed updates), `--with-admin` (web Admin Console). Update by hand with `sudo nextvault-server-install --update`. [Read the script](install-server.sh).

Then in the app: Settings → NextVault account → server `https://vault.example.com` → Create account; on other computers: Sign in to my account.

Experimental software, not independently audited.
