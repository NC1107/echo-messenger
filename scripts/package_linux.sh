#!/usr/bin/env bash
# Build .deb and .rpm packages for the Echo Messenger Linux desktop client from
# an already-built Flutter Linux release bundle, using fpm.
#
# Usage:  scripts/package_linux.sh <version> [out_dir]
#   <version>  package version, e.g. 0.0.500 (no leading "v")
#   [out_dir]  output directory for the packages (default: ./dist)
#
# Prerequisites (already true on the CI runner — see
# .github/workflows/linux-packages.yml):
#   * a completed `flutter build linux --release`
#   * `fpm` on PATH (gem install fpm)
#
# Why packages instead of just the AppImage: distro packages put the app in the
# user's package manager (dnf/apt) so it installs, updates, and uninstalls like
# any other app, and the runtime libs (GTK, mpv, gstreamer, …) are pulled in as
# dependencies rather than bundled.
set -euo pipefail

VERSION="${1:?usage: package_linux.sh <version> [out_dir]}"
OUT_DIR="${2:-dist}"

APP=echo-messenger          # package name + /usr/bin launcher wrapper
EXE=echo_app                # the Flutter binary inside the bundle
DISPLAY_NAME="Echo Messenger"
APPID=com.echo.echo_app

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/apps/client/build/linux/x64/release/bundle"
ICON_SRC="$ROOT/apps/client/web/icons/Icon-512.png"

[ -d "$BUNDLE" ] || {
  echo "::error::Flutter bundle not found at $BUNDLE — run 'flutter build linux --release' first"
  exit 1
}
[ -x "$BUNDLE/$EXE" ] || {
  echo "::error::expected binary '$EXE' not found (or not executable) in the bundle"
  exit 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Install layout: the app under /opt, a launcher wrapper on PATH, a desktop
# entry, and an icon. Flutter locates its bundled `data/` relative to the
# executable, so keeping the whole bundle together under /opt is required.
install -d "$STAGE/opt/$APP" "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/512x512/apps"
cp -r "$BUNDLE/." "$STAGE/opt/$APP/"

cat >"$STAGE/usr/bin/$APP" <<EOF
#!/bin/sh
exec /opt/$APP/$EXE "\$@"
EOF
chmod 0755 "$STAGE/usr/bin/$APP"

cp "$ICON_SRC" "$STAGE/usr/share/icons/hicolor/512x512/apps/$APP.png"

cat >"$STAGE/usr/share/applications/$APP.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$DISPLAY_NAME
GenericName=Encrypted Messenger
Comment=Decentralized encrypted messenger (Signal Protocol E2E)
Exec=$APP %U
Icon=$APP
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=$APPID
EOF

mkdir -p "$OUT_DIR"

# Shared fpm arguments. Source = the staged directory tree above.
common=(
  --input-type dir
  --chdir "$STAGE"
  --name "$APP"
  --version "$VERSION"
  --architecture native
  --maintainer "Echo Messenger <noreply@echo-messenger.us>"
  --vendor "Echo Messenger"
  --url "https://echo-messenger.us"
  --description "Decentralized encrypted messenger (Signal Protocol E2E). Desktop client."
  --license "see bundled LICENSE"
)

# --- .deb (Debian / Ubuntu) ---------------------------------------------------
# Runtime libraries the Flutter bundle dynamically links against. `libmpv2 |
# libmpv1` is a Debian alternative dependency (libmpv2 on 24.04+, libmpv1 on
# 22.04) so the package installs across releases.
fpm "${common[@]}" --output-type deb \
  --package "$OUT_DIR/${APP}_${VERSION}_amd64.deb" \
  --depends 'libgtk-3-0' \
  --depends 'libsecret-1-0' \
  --depends 'libayatana-appindicator3-1' \
  --depends 'libmpv2 | libmpv1' \
  --depends 'libgstreamer1.0-0' \
  --depends 'gstreamer1.0-plugins-base' \
  .

# --- .rpm (Fedora / RHEL / openSUSE) -----------------------------------------
# Equivalent runtime package names on the RPM side.
fpm "${common[@]}" --output-type rpm \
  --package "$OUT_DIR/${APP}-${VERSION}-1.x86_64.rpm" \
  --depends 'gtk3' \
  --depends 'libsecret' \
  --depends 'libayatana-appindicator-gtk3' \
  --depends 'mpv-libs' \
  --depends 'gstreamer1' \
  --depends 'gstreamer1-plugins-base' \
  .

echo "Built Linux packages in $OUT_DIR:"
ls -la "$OUT_DIR"
