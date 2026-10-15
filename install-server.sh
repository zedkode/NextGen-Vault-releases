#!/usr/bin/env bash
# NextVault Cloud server + website on a VPS, with HTTPS (Caddy, Let's Encrypt).
#
#   curl -fsSL https://raw.githubusercontent.com/zedkode/NextGen-Vault-releases/main/install-server.sh \
#     | sudo bash -s -- --domain vault.example.com --email you@example.com
#
# Options:
#   --domain NAME          public name pointing (DNS A/AAAA) at this server (required)
#   --email ADDRESS        contact for Let's Encrypt; also the only address allowed
#                          to create an account unless --registration says otherwise
#   --registration MODE    who may create accounts: closed | open | a list such as
#                          you@example.com,@family.example  (default: --email, else closed)
#   --with-admin           also publish the web Admin Console (/admin)
#   --auto-update          install a daily timer that applies new signed releases
#   --update               only update the server and website to the latest release
#
# For Debian 12+ / Ubuntu 22.04+ with systemd (dnf and pacman systems should
# work too). Everything downloaded is checked against the NextVault release key
# before it is installed. NEXTVAULT_RELEASE_DIR=/path installs a release that
# was already downloaded into that folder.
set -euo pipefail

RELEASES=zedkode/NextGen-Vault-releases
RELEASE_PUBLIC_KEY="RQ9/NRrFf5nSxCuLX+zOT/fuDe/9ig9T4Gs09lHWLGc="
PREFIX=/usr/local/bin
DATA=/var/lib/nextvault
WEB=/var/www/nextvault
CONF=/etc/nextvault
PORT=8787

DOMAIN="" EMAIL="" REGISTRATION="" WITH_ADMIN=0 AUTO_UPDATE=0 UPDATE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --registration) REGISTRATION=${2:-}; shift 2 ;;
    --with-admin) WITH_ADMIN=1; shift ;;
    --auto-update) AUTO_UPDATE=1; shift ;;
    --update) UPDATE_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ "$(uname -m)" == x86_64 ]] || die "only x86_64 servers are supported for now"
command -v systemctl >/dev/null || die "systemd is required"

install_packages() {
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl openssl ca-certificates >/dev/null
    if ! command -v caddy >/dev/null && ! apt-get install -y -qq caddy >/dev/null 2>&1; then
      say "Adding the official Caddy package repository"
      apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
      apt-get update -qq && apt-get install -y -qq caddy >/dev/null
    fi
  elif command -v dnf >/dev/null; then
    dnf install -y -q curl openssl caddy
  elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm --needed curl openssl caddy >/dev/null
  else
    die "unsupported distribution (needs apt, dnf or pacman)"
  fi
}

latest_version() {
  local url
  if [[ -n "${NEXTVAULT_RELEASE_DIR:-}" ]]; then
    # A release already downloaded (or built) into a local folder.
    [[ "$(head -1 "$NEXTVAULT_RELEASE_DIR/SHA256SUMS")" =~ ^#\ nextvault\ ([0-9.]+)\  ]] || die "no SHA256SUMS in $NEXTVAULT_RELEASE_DIR"
    echo "${BASH_REMATCH[1]}"; return
  fi
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$RELEASES/releases/latest") || die "cannot reach GitHub"
  [[ "$url" =~ /tag/v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "no published release found"
  echo "${BASH_REMATCH[1]}"
}

# Download the release files we need into $1 and verify the signed checksums.
fetch_verified() {
  local dir=$1 version=$2; shift 2
  local base="https://github.com/$RELEASES/releases/download/v$version"
  if [[ -n "${NEXTVAULT_RELEASE_DIR:-}" ]]; then base="file://$NEXTVAULT_RELEASE_DIR"; fi
  for file in SHA256SUMS SHA256SUMS.sig "$@"; do
    curl -fsSL -o "$dir/$file" "$base/$file" || die "could not download $file"
  done
  { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf %s "$RELEASE_PUBLIC_KEY" | base64 -d; } > "$dir/key.der"
  openssl pkey -pubin -inform DER -in "$dir/key.der" -out "$dir/key.pem" 2>/dev/null
  base64 -d < "$dir/SHA256SUMS.sig" > "$dir/sig.bin"
  openssl pkeyutl -verify -pubin -inkey "$dir/key.pem" -rawin -in "$dir/SHA256SUMS" -sigfile "$dir/sig.bin" >/dev/null 2>&1 \
    || die "release signature does not match the NextVault release key — nothing installed"
  [[ "$(head -1 "$dir/SHA256SUMS")" == "# nextvault $version linux-x86_64" ]] || die "signed checksums are for another release"
  for file in "$@"; do
    grep -qE "^[0-9a-f]{64}  $file\$" "$dir/SHA256SUMS" || die "$file is not in the signed checksums"
    (cd "$dir" && grep -E "  $file\$" SHA256SUMS | sha256sum -c --quiet -) || die "$file does not match its signed checksum"
  done
}

install_release() {
  local version work
  version=$(latest_version)
  work=$(mktemp -d); trap 'rm -rf "$work"' RETURN
  say "Downloading NextVault $version (signature-checked)"
  fetch_verified "$work" "$version" nextvault-cloud-linux-x86_64 "nextvault-website-$version.tar.gz" install-server.sh
  # This installer, from the same signed release, for later updates.
  install -m 755 "$work/install-server.sh" /usr/local/sbin/nextvault-server-install
  install -m 755 "$work/nextvault-cloud-linux-x86_64" "$PREFIX/nextvault-cloud.new"
  mv -f "$PREFIX/nextvault-cloud.new" "$PREFIX/nextvault-cloud"
  rm -rf "$WEB.new" && mkdir -p "$WEB.new"
  tar -xzf "$work/nextvault-website-$version.tar.gz" -C "$WEB.new" --no-same-owner
  rm -rf "$WEB.old"; [[ -d "$WEB" ]] && mv "$WEB" "$WEB.old"; mv "$WEB.new" "$WEB"; rm -rf "$WEB.old"
  chmod -R a+rX "$WEB"
  echo "$version" > "$CONF/version"
}

if [[ $UPDATE_ONLY == 1 ]]; then
  [[ -f "$CONF/cloud.env" ]] || die "NextVault is not installed here yet"
  current=$(cat "$CONF/version" 2>/dev/null || echo none)
  latest=$(latest_version)
  if [[ "$current" == "$latest" ]]; then say "Already at $latest"; exit 0; fi
  install_release
  systemctl restart nextvault-cloud
  say "Updated $current -> $latest"
  exit 0
fi

[[ -n "$DOMAIN" ]] || die "--domain is required (e.g. --domain vault.example.com)"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain"
if [[ -z "$REGISTRATION" ]]; then REGISTRATION=${EMAIL:-closed}; fi

say "Installing packages"
install_packages
mkdir -p "$CONF" "$DATA" "$WEB"
id nextvault >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin nextvault
chown nextvault:nextvault "$DATA"; chmod 700 "$DATA"
install_release

cat > "$CONF/cloud.env" <<ENV
# NextVault Cloud settings (see https://github.com/$RELEASES)
NEXTVAULT_CLOUD_DB=$DATA/cloud.sqlite
NEXTVAULT_CLOUD_PORT=$PORT
NEXTVAULT_PUBLIC_HOSTS=$DOMAIN
# closed | open | you@example.com,@family.example
NEXTVAULT_REGISTRATION=$REGISTRATION
ENV
chmod 640 "$CONF/cloud.env"; chgrp nextvault "$CONF/cloud.env"

cat > /etc/systemd/system/nextvault-cloud.service <<UNIT
[Unit]
Description=NextVault Cloud (end-to-end encrypted vault sync)
After=network-online.target
Wants=network-online.target

[Service]
User=nextvault
Group=nextvault
EnvironmentFile=$CONF/cloud.env
ExecStart=$PREFIX/nextvault-cloud serve
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ReadWritePaths=$DATA
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
CapabilityBoundingSet=
AmbientCapabilities=
PrivateUsers=yes
ProtectHostname=yes
ProtectClock=yes
ProtectKernelLogs=yes
ProtectProc=invisible
ProcSubset=pid
RestrictRealtime=yes
RestrictSUIDSGID=yes
RemoveIPC=yes
DevicePolicy=closed
# It only listens on 127.0.0.1 behind Caddy and never connects out.
IPAddressAllow=localhost
IPAddressDeny=any
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

API_PATHS="/v1/* /healthz"
[[ $WITH_ADMIN == 1 ]] && API_PATHS="$API_PATHS /admin /admin.js /admin.css"
CADDYFILE=/etc/caddy/Caddyfile
if [[ -f "$CADDYFILE" ]] && ! grep -q "NextVault" "$CADDYFILE"; then
  cp "$CADDYFILE" "$CADDYFILE.before-nextvault"
  say "Kept the previous Caddyfile as $CADDYFILE.before-nextvault"
fi
mkdir -p /etc/caddy
{
  echo "# NextVault — written by install-server.sh"
  if [[ -n "$EMAIL" ]]; then printf '{\n\temail %s\n}\n\n' "$EMAIL"; fi
  cat <<CADDY
$DOMAIN {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		X-Frame-Options "DENY"
		Content-Security-Policy "default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
		-Server
	}
	@api path $API_PATHS
	handle @api {
		reverse_proxy 127.0.0.1:$PORT
	}
	handle {
		root * $WEB
		file_server
	}
}
CADDY
} > "$CADDYFILE"
caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || die "Caddy rejected the generated configuration"

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  say "Opened ports 80 and 443 in ufw"
fi

if [[ $AUTO_UPDATE == 1 ]]; then
  cat > /etc/systemd/system/nextvault-update.service <<UNIT
[Unit]
Description=Apply the latest signed NextVault release
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextvault-server-install --update
UNIT
  cat > /etc/systemd/system/nextvault-update.timer <<UNIT
[Unit]
Description=Daily NextVault update check
[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
fi

systemctl daemon-reload
systemctl enable --now nextvault-cloud >/dev/null
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
[[ $AUTO_UPDATE == 1 ]] && systemctl enable --now nextvault-update.timer >/dev/null

for _ in $(seq 30); do curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 || die "the NextVault service did not start: journalctl -u nextvault-cloud"

cat <<DONE

NextVault $(cat "$CONF/version") is running.

  Website           https://$DOMAIN
  Server address    https://$DOMAIN   (NextVault → Settings → NextVault account)
  New accounts      $REGISTRATION   (change NEXTVAULT_REGISTRATION in $CONF/cloud.env,
                                     then: systemctl restart nextvault-cloud)
  Logs              journalctl -u nextvault-cloud -u caddy
  Update            sudo nextvault-server-install --update$( [[ $AUTO_UPDATE == 1 ]] && echo "   (daily timer is on)")

HTTPS certificates are requested from Let's Encrypt on the first visit; the DNS
record for $DOMAIN must point at this server and ports 80/443 must be reachable.
Back up $DATA (database and audit key): it holds encrypted vaults and account data.
DONE
if [[ $WITH_ADMIN == 1 ]]; then
  echo "Admin Console: https://$DOMAIN/admin  (one-time setup code: journalctl -u nextvault-cloud | grep -i 'setup code')"
fi
