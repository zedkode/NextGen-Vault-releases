#!/usr/bin/env bash
# Install or update NextVault for the current user on Linux x86_64 (no root).
#
#   curl -fsSL https://raw.githubusercontent.com/zedkode/NextGen-Vault-releases/main/install.sh | bash
#
# Installs nextvault, nextvault-desktop, nextvault-native-host and
# nextvault-cloud into ~/.local/bin, adds NextVault to the application menu and
# registers the Brave/Chromium extension's native host. Everything downloaded
# is checked against the NextVault release key before it is installed
# (NEXTVAULT_RELEASE_DIR=/path installs a release already downloaded there).
#
# Options:
#   --prefix DIR     install the programs into DIR instead of ~/.local/bin
#   --no-browser     skip the browser extension setup
set -euo pipefail

RELEASES=zedkode/NextGen-Vault-releases
RELEASE_PUBLIC_KEY="RQ9/NRrFf5nSxCuLX+zOT/fuDe/9ig9T4Gs09lHWLGc="
EXTENSION_ID=bjgankijkmkepahceappdojedpegojmb
PREFIX="$HOME/.local/bin"
BROWSER=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --no-browser) BROWSER=0; shift ;;
    -h|--help) sed -n '2,14p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mnote:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "NextVault releases are built for Linux x86_64"
[[ $EUID -ne 0 ]] || die "run this as your normal user, not root"
for tool in curl openssl sha256sum base64; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

if [[ -n "${NEXTVAULT_RELEASE_DIR:-}" ]]; then
  # A release already downloaded (or built) into a local folder.
  [[ "$(head -1 "$NEXTVAULT_RELEASE_DIR/SHA256SUMS")" =~ ^#\ nextvault\ ([0-9.]+)\  ]] || die "no SHA256SUMS in $NEXTVAULT_RELEASE_DIR"
  VERSION=${BASH_REMATCH[1]}
  BASE="file://$NEXTVAULT_RELEASE_DIR"
else
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$RELEASES/releases/latest") || die "cannot reach GitHub"
  [[ "$url" =~ /tag/v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "no published release found"
  VERSION=${BASH_REMATCH[1]}
  BASE="https://github.com/$RELEASES/releases/download/v$VERSION"
fi

PROGRAMS=(nextvault nextvault-desktop nextvault-native-host nextvault-cloud)
FILES=(nextvault.desktop nextvault.svg "nextvault-browser-$VERSION.zip")
for program in "${PROGRAMS[@]}"; do FILES+=("$program-linux-x86_64"); done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
say "Downloading NextVault $VERSION"
for file in SHA256SUMS SHA256SUMS.sig "${FILES[@]}"; do
  curl -fsSL -o "$WORK/$file" "$BASE/$file" || die "could not download $file"
done

# The signature covers SHA256SUMS; SHA256SUMS covers every file.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf %s "$RELEASE_PUBLIC_KEY" | base64 -d; } > "$WORK/key.der"
openssl pkey -pubin -inform DER -in "$WORK/key.der" -out "$WORK/key.pem" 2>/dev/null || die "openssl cannot read Ed25519 keys (needs OpenSSL 1.1.1+)"
base64 -d < "$WORK/SHA256SUMS.sig" > "$WORK/sig.bin"
openssl pkeyutl -verify -pubin -inkey "$WORK/key.pem" -rawin -in "$WORK/SHA256SUMS" -sigfile "$WORK/sig.bin" >/dev/null 2>&1 \
  || die "release signature does not match the NextVault release key — nothing installed"
[[ "$(head -1 "$WORK/SHA256SUMS")" == "# nextvault $VERSION linux-x86_64" ]] || die "signed checksums are for another release"
for file in "${FILES[@]}"; do
  grep -qE "^[0-9a-f]{64}  $file\$" "$WORK/SHA256SUMS" || die "$file is not in the signed checksums"
  (cd "$WORK" && grep -E "  $file\$" SHA256SUMS | sha256sum -c --quiet -) || die "$file does not match its signed checksum"
done
say "Signature and checksums verified"

mkdir -p "$PREFIX"
for program in "${PROGRAMS[@]}"; do
  install -m 755 "$WORK/$program-linux-x86_64" "$PREFIX/.$program.new"
  mv -f "$PREFIX/.$program.new" "$PREFIX/$program"
done

DATA=${XDG_DATA_HOME:-$HOME/.local/share}
install -Dm644 "$WORK/nextvault.svg" "$DATA/icons/hicolor/scalable/apps/nextvault.svg"
sed "s|^Exec=nextvault-desktop|Exec=$PREFIX/nextvault-desktop|" "$WORK/nextvault.desktop" > "$WORK/desktop"
install -Dm644 "$WORK/desktop" "$DATA/applications/nextvault.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$DATA/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true

if [[ $BROWSER == 1 ]]; then
  EXT="$DATA/nextvault/browser-extension"
  rm -rf "$EXT" && mkdir -p "$EXT"
  if command -v python3 >/dev/null; then
    python3 -I -m zipfile -e "$WORK/nextvault-browser-$VERSION.zip" "$EXT"
  elif command -v unzip >/dev/null; then
    unzip -q "$WORK/nextvault-browser-$VERSION.zip" -d "$EXT"
  fi
  registered=""
  for pair in brave:BraveSoftware/Brave-Browser chromium:chromium chrome:google-chrome; do
    browser=${pair%%:*}
    [[ -d "$HOME/.config/${pair#*:}" ]] || command -v "$browser" >/dev/null || continue
    # Replace an earlier NextVault registration (it may point at an old path).
    rm -f "$HOME/.config/${pair#*:}/NativeMessagingHosts/com.dohotstudio.nextvault.json"
    if "$PREFIX/nextvault-native-host" install "$EXTENSION_ID" "$browser" >/dev/null 2>&1; then
      registered+=" $browser"
    fi
  done
  [[ -n "$registered" ]] && say "Browser connection registered for:$registered"
fi

missing=()
libraries=$( (ldconfig -p || /sbin/ldconfig -p) 2>/dev/null || true)
for library in libwebkit2gtk-4.1.so.0 libgstreamer-1.0.so.0 libgstapp-1.0.so.0 libzbar.so.0; do
  [[ "$libraries" == *"$library "* ]] || missing+=("$library")
done

cat <<DONE

NextVault $VERSION is installed in $PREFIX.
  Start it from the application menu, or run: nextvault-desktop
  Updates: the app checks for signed updates itself (Settings → Updates),
           or run this installer again.
DONE
case ":$PATH:" in *":$PREFIX:"*) ;; *) warn "$PREFIX is not on your PATH; add it to use the nextvault command." ;; esac
if [[ ${#missing[@]} -gt 0 ]]; then
  warn "missing system libraries: ${missing[*]}"
  echo "  Arch:          sudo pacman -S webkit2gtk-4.1 gst-plugins-base gst-plugins-good zbar"
  echo "  Debian/Ubuntu: sudo apt install libwebkit2gtk-4.1-0 gstreamer1.0-plugins-good libzbar0"
  echo "  Fedora:        sudo dnf install webkit2gtk4.1 gstreamer1-plugins-good zbar"
fi
if [[ $BROWSER == 1 ]]; then
  cat <<DONE

Browser extension (Brave): install it once, with automatic updates, by running
  echo '{"ExtensionInstallForcelist":["$EXTENSION_ID;https://github.com/$RELEASES/releases/latest/download/update.xml"]}' \\
    | sudo tee /etc/brave/policies/managed/nextvault.json
then restart Brave (sudo mkdir -p /etc/brave/policies/managed first if needed).
Without root: brave://extensions → Developer mode → Load unpacked → $EXT
DONE
fi
