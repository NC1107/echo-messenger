#!/usr/bin/env bash
# Build apps/client/build/linux/x64/release/bundle into Echo-x86_64.AppImage
# (created in the current directory). Bundles libmpv + GTK runtime deps so
# the AppImage runs on hosts without them.
#
# Single source of truth shared by release.yml (stable) and dev-build.yml
# (rolling dev channel) — keep this in sync, don't fork it. Run from the
# repo root AFTER `flutter build linux --release`.
set -euo pipefail

wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x appimagetool
mkdir -p Echo.AppDir/usr/bin Echo.AppDir/usr/share/applications Echo.AppDir/usr/share/icons/hicolor/256x256/apps
cp -r apps/client/build/linux/x64/release/bundle/* Echo.AppDir/usr/bin/
# Bundle libmpv.so.2 (and runtime deps) inside the AppImage so it
# actually runs on hosts that don't ship libmpv globally.
# `media_kit_libs_video` declares a runtime dependency on libmpv
# via the dynamic linker but does NOT copy the .so into the
# bundle, which left users hitting "libmpv.so.2: cannot open
# shared object file" at launch (reported 2026-05-08).  AppRun
# already prepends usr/bin/lib to LD_LIBRARY_PATH so the loader
# finds these copies.
mkdir -p Echo.AppDir/usr/bin/lib
LIBMPV_PATH=$(ldconfig -p | awk '/libmpv\.so\.2 / {print $4; exit}')
if [ -z "$LIBMPV_PATH" ] || [ ! -e "$LIBMPV_PATH" ]; then
  echo "::error::libmpv.so.2 not resolvable on the build host; install libmpv2 or libmpv-dev before this step."
  exit 1
fi
cp -L "$LIBMPV_PATH" Echo.AppDir/usr/bin/lib/
# Deny-list approach (replaces the per-lib allowlist after we
# hit libjpeg / libsixel / libjxl / etc. one-by-one across
# v0.0.296..v0.0.301).  Bundle EVERY transitive dep of libmpv
# + echo_app that isn't in the deny list, then validate with
# `ldd` that no soname is unresolved against the bundle path.
#
# The deny list covers libs that vary across distros and must
# come from the user's host — bundling them shadows the host
# version and breaks symbol lookups (e.g. v0.0.296's broken
# bundle of libglib-2.0 on Fedora 43 caused
# "undefined symbol: g_variant_builder_*" at startup).
# Keep this list tight and additive; everything else gets
# bundled.
# Layered deny list: keep libs that must come from the user's
# host so they can talk to the host's display server, audio
# daemon, dbus, etc.  Bundling these would shadow the host's
# service-talking versions and break routing.  Everything not
# matched here gets bundled.
DENY_GROUPS=(
  # Core C runtime + ELF loader.
  'ld-linux|libc\.so|libm\.so|libpthread\.so|librt\.so|libdl\.so'
  'libgcc_s\.so|libstdc\+\+\.so|libgomp\.so|libnsl\.|libresolv\.'
  'libutil\.|libanl\.|libcrypt\.|libcap\.'

  # GLib / GObject / GIO — system glue, must match host.
  'libglib-|libgio-|libgobject-|libgthread-|libgmodule-'

  # GTK / Pango / Cairo / Harfbuzz / Fonts — display chain.
  'libgtk-|libgdk-|libgdk_pixbuf-|libpango-|libpangocairo-|libpangoft'
  'libcairo-|libcairo\.|libharfbuzz|libatk-|libatk\.'
  'libfontconfig|libfreetype|libdatrie|libthai|libgraphite2|libfribidi'

  # X / Wayland / GL — windowing + GPU.
  'libxkbcommon|libwayland|libxcb|libX11|libXext|libXi|libXrender'
  'libXrandr|libXcomposite|libXdamage|libXfixes|libXcursor|libXau'
  'libXdmcp|libXinerama|libXxf86vm|libdrm|libgbm|libEGL|libGLESv2'
  'libGL\.|libGLX|libGLdispatch|libxshmfence'

  # Audio daemons that users have (ALSA / PulseAudio / PipeWire)
  # MUST come from the host so they reach the running daemon.
  # libsndio + libjack intentionally NOT here — they're rare
  # (OpenBSD / pro-audio) and most Linux desktops don't ship
  # them, so we bundle them.  libmpv hard-links them.
  'libasound|libpulse|libpipewire|libapulse'

  # GStreamer + GNOME / KDE shell integrations — pulled in by
  # GTK image loaders, file pickers, tray indicators, etc.
  # Bundling these breaks if the host's gst-plugins / GIO
  # modules don't match the bundled lib version.
  'libgstreamer|libgst[a-z]+-|libgstapp|libgstbase|libgstvideo|libgstaudio'
  'libcloudproviders|libayatana|libappindicator|libtinysparql|libjson-glib'
  'libglycin|libdconf|libgsettings'

  # System services / IPC.
  'libdbus|libsystemd|libudev|libelogind|libavahi'

  # util-linux suite — libmount + libblkid are tightly coupled
  # to the host's libgio version via MOUNT_2.* symbol versions.
  # Bundling an Ubuntu-built libmount shadows the host's and
  # breaks libgio symbol lookups on Fedora 44+ (#v0.0.303
  # incident).
  'libmount|libblkid|libsmartcols|libuuid|libfdisk'

  # ICU (text + Unicode) — Ubuntu and Fedora ship different
  # major versions (74 vs 76+); symbol mismatches surface as
  # silent crashes in GTK/Pango when bundled.
  'libicudata|libicuuc|libicui18n|libicutu|libicuio'

  # GPU / video acceleration — talks to host kernel + driver.
  'libvulkan|libvdpau|libva\.|libva-drm|libva-wayland|libva-x11'
  'libGLdispatch|libGLU|libnvidia'

  # Compiler runtimes + ELF tooling.
  'libgfortran|libgomp\.|libunwind|libdw\.|libquadmath'

  # Wayland decorations / theming — must match compositor.
  'libdecor-0|libdecor'

  # ncurses / terminal info — host's terminfo data is
  # /etc/terminfo, not bundlable.
  'libtinfo|libncurses|libslang'

  # GLib / gobject introspection extras (some pulled by
  # libgio in addition to the libglib- pattern above).
  'libgirepository|libgthread'

  # Misc gettext + libunistring + libidn2 — distros patch
  # these for locale data; bundling causes UTF-8 weirdness.
  'libgettext|libintl|libunistring|libidn2'

  # System crypto / TLS — distros patch these heavily.
  'libcrypto\.|libssl\.|libgcrypt|libgpg-error|libgnutls|libtasn1'
  'libnettle|libhogweed|libidn|libldap|libsasl|libkrb5|libcom_err'
  'libkeyutils|libk5crypto|libgssapi|libp11-kit'
  'libnss|libnspr|libplc4|libplds4|libsmime3|libnssutil3|libfreebl3|libsoftokn3'

  # Compression + utilities that are universally present.
  # libbz2 intentionally NOT here: Debian-flavored sonames
  # (libbz2.so.1.0) don't exist on Fedora (which ships
  # libbz2.so.1), so bundling is safer than relying on host.
  'libpcre|libffi|libelf|libz\.so|liblzma|liblzo|libzstd|libdatum'

  # Misc system libs.
  'libxml2|libxslt|libsqlite|libapparmor|libselinux|libacl|libattr'
  'libsoup|libsecret|libnotify|libcanberra|libbsd|libmd\.so|libusb'
)
DENY_RE="^($(IFS='|'; echo "${DENY_GROUPS[*]}"))"

# Bundle every transitive dep of libmpv + echo_app that isn't
# in DENY_RE.  Repeating safe — cp -n is no-clobber.
walk_deps() {
  local target="$1"
  [ -f "$target" ] || return 0
  ldd "$target" 2>/dev/null | awk '/=>/ {print $3}' \
    | while read -r dep; do
        [ -z "$dep" ] || [ ! -e "$dep" ] && continue
        base=$(basename "$dep")
        if echo "$base" | grep -qE "$DENY_RE"; then
          continue
        fi
        cp -Ln "$dep" Echo.AppDir/usr/bin/lib/ 2>/dev/null || true
      done
}

walk_deps "$LIBMPV_PATH"
walk_deps Echo.AppDir/usr/bin/echo_app
# Walk recursively over the bundled libs themselves so anything
# that ldd missed on the first pass (because LD_LIBRARY_PATH
# was system-only) gets caught.  Two passes is enough for our
# dep depth.
for _ in 1 2; do
  for lib in Echo.AppDir/usr/bin/lib/*.so*; do
    walk_deps "$lib"
  done
done

ls Echo.AppDir/usr/bin/lib/libmpv* > /dev/null  # sanity check
ls Echo.AppDir/usr/bin/lib/libjpeg* > /dev/null || {
  echo "::error::libjpeg not bundled; the deny list or ldd walk regressed."
  exit 1
}
echo "Bundled libs:"; ls -1 Echo.AppDir/usr/bin/lib/ | sort

# Validation: walk DT_NEEDED on echo_app + every bundled .so
# and confirm each soname is EITHER bundled OR matches the
# deny regex (= explicitly expected from user's host).
#
# We deliberately don't use `ldd` here: ldd resolves against
# the build host's installed packages, so a lib that happens
# to be on the Ubuntu CI runner via libmpv-dev's deps (e.g.
# libsndio) shows up as "resolved" even though the user's
# Fedora host doesn't have it.  That gap is what shipped
# broken v0.0.302 to a user.  DT_NEEDED checks the actual
# ELF dependency declarations, independent of the host.
echo "=== AppImage dep validation ==="
NEEDED=$(objdump -p Echo.AppDir/usr/bin/echo_app \
    Echo.AppDir/usr/bin/lib/*.so* 2>/dev/null \
    | awk '/NEEDED/ {print $2}' | sort -u)
MISSING=()
for soname in $NEEDED; do
  # In the bundle? OK.
  if [ -e "Echo.AppDir/usr/bin/lib/$soname" ]; then
    continue
  fi
  # Explicitly expected from user's host? OK.
  if echo "$soname" | grep -qE "$DENY_RE"; then
    continue
  fi
  MISSING+=("$soname")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "::error::Needed sonames neither bundled nor in DENY_RE:"
  printf '  %s\n' "${MISSING[@]}"
  echo "::error::Either let the deny list keep excluding these"
  echo "::error::(if every user host is guaranteed to have them)"
  echo "::error::OR remove the matching deny pattern so they get"
  echo "::error::bundled.  See the libsndio incident in v0.0.302."
  exit 1
fi
NEEDED_COUNT=$(printf '%s\n' "$NEEDED" | wc -l)
echo "All ${NEEDED_COUNT} needed sonames resolved against bundle or deny list ✓"
cat > Echo.AppDir/echo.desktop << 'EOF'
[Desktop Entry]
Name=Echo
Comment=Encrypted Messaging
Exec=echo_app
Icon=echo
Type=Application
Categories=Network;InstantMessaging;
StartupNotify=true
StartupWMClass=com.echo.echo_app
EOF
cp Echo.AppDir/echo.desktop Echo.AppDir/usr/share/applications/
# Placeholder icon
magick public/white_echo_icon.png -gravity center -background none -extent 1408x1408 -resize 256x256 Echo.AppDir/echo.png || \
cp public/white_echo_icon.png Echo.AppDir/echo.png
cp Echo.AppDir/echo.png Echo.AppDir/usr/share/icons/hicolor/256x256/apps/
# Slice 9: ship the same icon next to the binary so the GTK
# runner's gtk_window_set_icon_from_file("<exe>/data/echo-messenger.png")
# path resolves at runtime → alt-tab thumbnail.
mkdir -p Echo.AppDir/usr/bin/data
cp Echo.AppDir/echo.png Echo.AppDir/usr/bin/data/echo-messenger.png
cat > Echo.AppDir/AppRun << 'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${HERE}/usr/bin/lib:${LD_LIBRARY_PATH}"
exec "${HERE}/usr/bin/echo_app" "$@"
APPRUN
chmod +x Echo.AppDir/AppRun
ARCH=x86_64 ./appimagetool --no-appstream Echo.AppDir Echo-x86_64.AppImage || \
ARCH=x86_64 ./appimagetool Echo.AppDir Echo-x86_64.AppImage
