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

Installed apps update themselves from here and install an update only when its signature verifies against the key built into them.

**Install (per user):** copy the programs to `~/.local/bin` without the `-linux-x86_64` suffix and make them executable. Requires `webkit2gtk-4.1`, `gtk3` and GStreamer (`gst-plugins-good`).

Experimental software, not independently audited.
