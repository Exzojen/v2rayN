#!/usr/bin/env bash
# Build a v2rayN .deb for Ubuntu 22.04 (jammy) and derivatives such as Pop!_OS 22.04.
#
# package-debian.sh only runs on Debian with kernel >= 6.12 and hard-codes Depends
# (libc6 >= 2.39, bash >= 5.2.21, coreutils >= 9.4, ...) that jammy cannot satisfy,
# so its .deb does not install on Pop!_OS 22.04. This script keeps the same package
# layout, builds the checked-out tree, lets dpkg-shlibdeps resolve Depends against
# the build system and refuses to package binaries that need a newer glibc.
#
# Run it from a clone with submodules on Ubuntu / Pop!_OS 22.04: ./package-ubuntu-jammy.sh --help
set -euo pipefail

WITH_CORE="both"
FORCE_NETCORE=0
XRAY_VER="${XRAY_VER:-}"
SING_VER="${SING_VER:-}"
OUTPUT_DIR="${HOME}/debbuild"
DEB_SUFFIX="${DEB_SUFFIX:-jammy1}"
DEB_MAINTAINER="${DEB_MAINTAINER:-v2rayN jammy build <noreply@github.com>}"
DEB_HOMEPAGE="${DEB_HOMEPAGE:-https://github.com/2dust/v2rayN}"

PKGROOT="v2rayN-publish"
PROJECT="v2rayN/v2rayN.Desktop/v2rayN.Desktop.csproj"

SUDO=""
WORKDIR=""
RID=""
DEB_ARCH=""
VERSION=""
DEB_VERSION=""

export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./package-ubuntu-jammy.sh [options]
  --output DIR          where to write the .deb (default: ~/debbuild)
  --netcore             download Xray / sing-box releases and rule files separately
                        instead of the 2dust/v2rayN-core-bin bundle
  --with-core NAME      with --netcore: xray, sing-box or both (default: both)
  --xray-ver X.Y.Z      with --netcore: Xray version (default: latest)
  --singbox-ver X.Y.Z   with --netcore: sing-box version (default: latest)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)      OUTPUT_DIR="${2:-}"; shift 2 ;;
      --netcore)     FORCE_NETCORE=1; shift ;;
      --with-core)   WITH_CORE="${2:-both}"; shift 2 ;;
      --xray-ver)    XRAY_VER="${2:-}"; shift 2 ;;
      --singbox-ver) SING_VER="${2:-}"; shift 2 ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage >&2; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "$OUTPUT_DIR" ]] || die "--output needs a directory"
  OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

  case "$WITH_CORE" in
    xray|sing-box|both) ;;
    *) die "--with-core must be xray, sing-box or both" ;;
  esac
}

detect_environment() {
  local -a os=()

  mapfile -t os < <(. /etc/os-release; printf '%s\n' "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-unknown}")

  case " ${os[0]} ${os[1]} " in
    *" ubuntu "*|*" debian "*) ;;
    *) die "Unsupported system: ${os[3]}. Use Ubuntu 22.04 or a derivative such as Pop!_OS 22.04." ;;
  esac

  if [[ "${os[2]}" != "22.04" ]]; then
    echo "[WARN] ${os[3]} is not 22.04: Depends will be resolved against this system, not jammy."
  fi

  case "$(uname -m)" in
    x86_64)  RID="linux-x64";   DEB_ARCH="amd64" ;;
    aarch64) RID="linux-arm64"; DEB_ARCH="arm64" ;;
    *)       die "Only supports aarch64 / x86_64" ;;
  esac

  echo "[OK] ${os[3]} on $(uname -m): RID=${RID}, DEB arch=${DEB_ARCH}"
}

has_dotnet10() {
  dotnet --list-sdks 2>/dev/null | grep '^10\.' >/dev/null
}

install_dependencies() {
  [[ "$(id -u)" -eq 0 ]] || SUDO="sudo"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found"

  $SUDO apt-get update
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
    curl unzip tar rsync ca-certificates git dpkg-dev binutils file desktop-file-utils \
    libicu-dev libfontconfig1 libfreetype6 libstdc++6 libgcc-s1 zlib1g

  if [[ -x "$HOME/.dotnet/dotnet" ]]; then
    export PATH="$HOME/.dotnet:$PATH"
    export DOTNET_ROOT="$HOME/.dotnet"
  fi

  if ! has_dotnet10; then
    echo "[+] Install .NET SDK 10 to $HOME/.dotnet"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$WORKDIR/dotnet-install.sh"
    bash "$WORKDIR/dotnet-install.sh" --channel 10.0.1xx --install-dir "$HOME/.dotnet"
    export PATH="$HOME/.dotnet:$PATH"
    export DOTNET_ROOT="$HOME/.dotnet"
  fi

  has_dotnet10 || die "dotnet SDK 10.x is not available"
}

prepare_workspace() {
  cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -f .gitmodules ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    git submodule sync --recursive || true
    git submodule update --init --recursive || true
  fi

  [[ -f "$PROJECT" ]] || die "$PROJECT not found"
  [[ -f v2rayN/GlobalHotKeys/src/GlobalHotKeys/GlobalHotKeys.csproj ]] \
    || die "Submodule v2rayN/GlobalHotKeys is missing: git submodule update --init --recursive"
}

resolve_version() {
  VERSION="$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' v2rayN/Directory.Build.props | head -n1)"
  [[ -n "$VERSION" ]] || die "Cannot read <Version> from v2rayN/Directory.Build.props"
  DEB_VERSION="${VERSION}~${DEB_SUFFIX}"
  echo "[*] v2rayN ${VERSION}, package version ${DEB_VERSION}"
}

publish_binary() {
  local pubdir="$1"

  dotnet publish "$PROJECT" -c Release -r "$RID" -p:PublishSingleFile=false -p:SelfContained=true -o "$pubdir"
  find "$pubdir" -type f -name '*.pdb' -delete
}

xray_url_for_rid() {
  local rid="$1"
  local ver="$2"

  case "$rid" in
    linux-x64)   echo "https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-64.zip" ;;
    linux-arm64) echo "https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-arm64-v8a.zip" ;;
    *)           return 1 ;;
  esac
}

singbox_url_for_rid() {
  local rid="$1"
  local ver="$2"

  case "$rid" in
    linux-x64)   echo "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-amd64.tar.gz" ;;
    linux-arm64) echo "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-arm64.tar.gz" ;;
    *)           return 1 ;;
  esac
}

bundle_url_for_rid() {
  local rid="$1"

  case "$rid" in
    linux-x64)   echo "https://raw.githubusercontent.com/2dust/v2rayN-core-bin/refs/heads/master/v2rayN-linux-64.zip" ;;
    linux-arm64) echo "https://raw.githubusercontent.com/2dust/v2rayN-core-bin/refs/heads/master/v2rayN-linux-arm64.zip" ;;
    *)           return 1 ;;
  esac
}

download_xray() {
  local outdir="$1"
  local rid="$2"
  local ver="${XRAY_VER:-}"
  local url=""
  local tmp=""

  mkdir -p "$outdir"

  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
      | grep -Eo '"tag_name":\s*"v[^"]+"' \
      | sed -E 's/.*"v([^"]+)".*/\1/' \
      | head -n1)" || true
  fi

  [[ -n "$ver" ]] || { echo "[xray] Failed to get version"; return 1; }
  url="$(xray_url_for_rid "$rid" "$ver")" || { echo "[xray] Unsupported RID: $rid"; return 1; }

  echo "[+] Download xray: $url"

  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/xray.zip" || { rm -rf "$tmp"; return 1; }
  unzip -q "$tmp/xray.zip" -d "$tmp" || { rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp/xray" "$outdir/xray" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

download_singbox() {
  local outdir="$1"
  local rid="$2"
  local ver="${SING_VER:-}"
  local url=""
  local tmp=""
  local bin=""
  local cronet=""

  mkdir -p "$outdir"

  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
      | grep -Eo '"tag_name":\s*"v[^"]+"' \
      | sed -E 's/.*"v([^"]+)".*/\1/' \
      | head -n1)" || true
  fi

  [[ -n "$ver" ]] || { echo "[sing-box] Failed to get version"; return 1; }
  url="$(singbox_url_for_rid "$rid" "$ver")" || { echo "[sing-box] Unsupported RID: $rid"; return 1; }

  echo "[+] Download sing-box: $url"

  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/singbox.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -C "$tmp" -xzf "$tmp/singbox.tar.gz" || { rm -rf "$tmp"; return 1; }

  bin="$(find "$tmp" -type f -name 'sing-box' | head -n1 || true)"
  [[ -n "$bin" ]] || { echo "[!] sing-box unpack failed"; rm -rf "$tmp"; return 1; }

  install -m 755 "$bin" "$outdir/sing-box" || { rm -rf "$tmp"; return 1; }

  cronet="$(find "$tmp" -type f -name 'libcronet*.so*' | head -n1 || true)"
  [[ -n "$cronet" ]] && install -m 644 "$cronet" "$outdir/libcronet.so" || true

  rm -rf "$tmp"
}

unify_geo_layout() {
  local outroot="$1"
  local n
  local names=(
    geosite.dat
    geoip.dat
    geoip-only-cn-private.dat
    Country.mmdb
    geoip.metadb
  )

  mkdir -p "$outroot/bin"

  for n in "${names[@]}"; do
    if [[ -f "$outroot/bin/xray/$n" ]]; then
      mv -f "$outroot/bin/xray/$n" "$outroot/bin/$n"
    fi
  done
}

download_geo_assets() {
  local outroot="$1"
  local bin_dir="$outroot/bin"
  local srss_dir="$bin_dir/srss"
  local f=""

  mkdir -p "$bin_dir" "$srss_dir"

  echo "[+] Download Xray Geo to ${bin_dir}"
  curl -fsSL -o "$bin_dir/geosite.dat" "https://github.com/Loyalsoldier/V2ray-rules-dat/releases/latest/download/geosite.dat"
  curl -fsSL -o "$bin_dir/geoip.dat" "https://github.com/Loyalsoldier/V2ray-rules-dat/releases/latest/download/geoip.dat"
  curl -fsSL -o "$bin_dir/geoip-only-cn-private.dat" "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip-only-cn-private.dat"
  curl -fsSL -o "$bin_dir/Country.mmdb" "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country.mmdb"

  echo "[+] Download sing-box rule DB & rule-sets"
  curl -fsSL -o "$bin_dir/geoip.metadb" "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb"

  for f in geoip-private.srs geoip-cn.srs geoip-facebook.srs geoip-fastly.srs geoip-google.srs geoip-netflix.srs geoip-telegram.srs geoip-twitter.srs; do
    curl -fsSL -o "$srss_dir/$f" "https://raw.githubusercontent.com/2dust/sing-box-rules/refs/heads/rule-set-geoip/$f"
  done

  for f in geosite-cn.srs geosite-gfw.srs geosite-google.srs geosite-greatfire.srs geosite-geolocation-cn.srs geosite-category-ads-all.srs geosite-private.srs; do
    curl -fsSL -o "$srss_dir/$f" "https://raw.githubusercontent.com/2dust/sing-box-rules/refs/heads/rule-set-geosite/$f"
  done

  unify_geo_layout "$outroot"
}

populate_assets_zip_mode() {
  local outroot="$1"
  local rid="$2"
  local url=""
  local tmp=""
  local nested_dir=""

  url="$(bundle_url_for_rid "$rid")" || { echo "[!] Bundle unsupported RID: $rid"; return 1; }

  echo "[+] Try v2rayN bundle archive: $url"

  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/v2rayn.zip" || { echo "[!] Bundle download failed"; rm -rf "$tmp"; return 1; }
  unzip -q "$tmp/v2rayn.zip" -d "$tmp" || { echo "[!] Bundle unzip failed"; rm -rf "$tmp"; return 1; }

  if [[ -d "$tmp/bin" ]]; then
    mkdir -p "$outroot/bin"
    rsync -a "$tmp/bin/" "$outroot/bin/"
  else
    rsync -a "$tmp/" "$outroot/"
  fi

  rm -f "$outroot/v2rayn.zip" 2>/dev/null || true
  find "$outroot" -type d -name "mihomo" -prune -exec rm -rf {} + 2>/dev/null || true

  nested_dir="$(find "$outroot" -maxdepth 1 -type d -name 'v2rayN-linux-*' | head -n1 || true)"
  if [[ -n "$nested_dir" && -d "$nested_dir/bin" ]]; then
    mkdir -p "$outroot/bin"
    rsync -a "$nested_dir/bin/" "$outroot/bin/"
    rm -rf "$nested_dir"
  fi

  unify_geo_layout "$outroot"
  rm -rf "$tmp"

  echo "[+] Bundle extracted to $outroot"
}

populate_assets_netcore_mode() {
  local outroot="$1"
  local rid="$2"

  mkdir -p "$outroot/bin/xray" "$outroot/bin/sing_box"

  if [[ "$WITH_CORE" == "xray" || "$WITH_CORE" == "both" ]]; then
    download_xray "$outroot/bin/xray" "$rid" || echo "[!] xray download failed (skipped)"
  fi

  if [[ "$WITH_CORE" == "sing-box" || "$WITH_CORE" == "both" ]]; then
    download_singbox "$outroot/bin/sing_box" "$rid" || echo "[!] sing-box download failed (skipped)"
  fi

  download_geo_assets "$outroot" || echo "[!] Geo rules download failed (skipped)"
}

stage_runtime_assets() {
  local outroot="$1"
  local rid="$2"

  mkdir -p "$outroot/bin/xray" "$outroot/bin/sing_box"

  if [[ "$FORCE_NETCORE" -eq 0 ]]; then
    if populate_assets_zip_mode "$outroot" "$rid"; then
      echo "[*] Using v2rayN bundle bin assets."
    else
      echo "[*] Bundle failed, fallback to separate core + rules."
      populate_assets_netcore_mode "$outroot" "$rid"
    fi
  else
    echo "[*] --netcore specified: use separate core + rules."
    populate_assets_netcore_mode "$outroot" "$rid"
  fi
}

write_launcher_file() {
  local stage="$1"

  install -m 755 /dev/stdin "$stage/usr/bin/v2rayn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="/opt/v2rayN"
cd "$DIR"

if [[ -x "$DIR/v2rayN" ]]; then
  exec "$DIR/v2rayN" "$@"
fi

for dll in v2rayN.Desktop.dll v2rayN.dll; do
  if [[ -f "$DIR/$dll" ]]; then
    exec /usr/bin/dotnet "$DIR/$dll" "$@"
  fi
done

echo "v2rayN launcher: no executable found in $DIR" >&2
ls -l "$DIR" >&2 || true
exit 1
EOF
}

write_desktop_file() {
  local stage="$1"

  install -m 644 /dev/stdin "$stage/usr/share/applications/v2rayn.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=v2rayN
Comment=v2rayN GUI client for Xray and sing-box
Exec=v2rayn
Icon=v2rayn
Terminal=false
Categories=Network;
EOF
}

write_maintainer_scripts() {
  local debian_dir="$1"

  install -m 755 /dev/stdin "$debian_dir/postinst" <<'EOF'
#!/bin/sh
set -e
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF

  install -m 755 /dev/stdin "$debian_dir/postrm" <<'EOF'
#!/bin/sh
set -e
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF
}

# dpkg-shlibdeps cannot express a glibc newer than the build system's, it only warns,
# so a binary built against e.g. glibc 2.39 would install fine and then fail to start.
check_glibc() {
  local root="$1"
  local host=""
  local need=""
  local f=""
  local bad=0

  host="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"

  while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
      ELF*) ;;
      *) continue ;;
    esac

    need="$(objdump -T "$f" 2>/dev/null \
      | grep -Eo 'GLIBC_[0-9]+(\.[0-9]+)+' \
      | sed 's/^GLIBC_//' \
      | sort -Vu \
      | tail -n1 || true)"
    [[ -n "$need" ]] || continue

    if [[ "$(printf '%s\n%s\n' "$need" "$host" | sort -V | tail -n1)" != "$host" ]]; then
      echo "[!] ${f#"$root"/} needs GLIBC_${need}, this system has ${host}" >&2
      bad=1
    fi
  done < <(find "$root" -type f -print0)

  [[ "$bad" -eq 0 ]] || die "Some binaries need a newer glibc than ${host}; the package would not start here."
  echo "[OK] All bundled ELF files run with glibc ${host}"
}

package_binary() {
  local pubdir="$1"
  local stage="$WORKDIR/${PKGROOT}_${DEB_VERSION}_${DEB_ARCH}"
  local debian_dir="$stage/DEBIAN"
  local multiarch=""
  local shlibs_depends=""
  local extra_depends=""
  local final_depends=""
  local installed_size=""
  local deb_out=""
  local f=""
  local -a elf_files=()
  local -a private_libdirs=()

  mkdir -p "$stage/opt/v2rayN" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/256x256/apps" "$debian_dir"
  cp -a "$pubdir/." "$stage/opt/v2rayN/"
  install -m 644 "$(dirname "$PROJECT")/v2rayN.png" "$stage/usr/share/icons/hicolor/256x256/apps/v2rayn.png"

  stage_runtime_assets "$stage/opt/v2rayN" "$RID"
  write_launcher_file "$stage"
  write_desktop_file "$stage"
  write_maintainer_scripts "$debian_dir"
  desktop-file-validate "$stage/usr/share/applications/v2rayn.desktop"

  # Executables must carry the x bit in the package: ordinary users cannot chmod
  # the root-owned files installed by dpkg.
  find "$stage/opt/v2rayN" -type d -exec chmod 0755 {} +
  find "$stage/opt/v2rayN" -type f -exec chmod 0644 {} +
  while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
      ELF*executable*) chmod 0755 "$f"; elf_files+=("$f") ;;
      ELF*)            elf_files+=("$f") ;;
    esac
  done < <(find "$stage/opt/v2rayN" -type f -print0)

  for f in v2rayN bin/xray/xray bin/sing_box/sing-box; do
    if [[ -f "$stage/opt/v2rayN/$f" ]]; then
      chmod 0755 "$stage/opt/v2rayN/$f"
    fi
  done

  check_glibc "$stage/opt/v2rayN"

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  mkdir -p "$WORKDIR/debian"
  printf 'Source: v2rayn\n\nPackage: v2rayn\nArchitecture: %s\n' "$DEB_ARCH" > "$WORKDIR/debian/control"
  : > "$WORKDIR/substvars"

  # libcoreclrtraceptprovider.so needs liblttng-ust, which .NET loads only when present.
  mapfile -t elf_files < <(printf '%s\n' "${elf_files[@]}" | grep -v '/libcoreclrtraceptprovider\.so$')
  mapfile -t private_libdirs < <(find "$stage/opt/v2rayN" -type f -name '*.so*' -printf '-l%h\n' | sort -u)

  if ! (
    cd "$WORKDIR"
    dpkg-shlibdeps \
      "${private_libdirs[@]}" \
      -l"/lib/$multiarch" \
      -l"/usr/lib/$multiarch" \
      -T"$WORKDIR/substvars" \
      "${elf_files[@]}"
  ) 2>"$WORKDIR/shlibdeps.log"; then
    cat "$WORKDIR/shlibdeps.log" >&2
    die "dpkg-shlibdeps failed"
  fi
  grep -v 'no dependency information found' "$WORKDIR/shlibdeps.log" | sed 's/^/    /' >&2 || true

  shlibs_depends="$(sed -n 's/^shlibs:Depends=//p' "$WORKDIR/substvars" | head -n1)"
  [[ -n "$shlibs_depends" ]] || die "dpkg-shlibdeps produced no Depends"

  # Loaded at runtime with dlopen, so dpkg-shlibdeps cannot see them: ICU and OpenSSL
  # (.NET), X11 (Avalonia). The rest mirrors package-debian.sh with jammy's versions.
  extra_depends="libicu70 | libicu72 | libicu74 | libicu76, libssl3 | libssl3t64, libx11-6, libice6, libsm6, libxi6, libxrandr2, libxcursor1, fontconfig (>= 2.13.1), libfreetype6 (>= 2.11), desktop-file-utils (>= 0.26), xdg-utils (>= 1.1.3), coreutils (>= 8.32), bash (>= 5.1)"
  final_depends="${shlibs_depends}, ${extra_depends}"

  installed_size="$(du -sk "$stage/opt" "$stage/usr" | awk '{s += $1} END {print s}')"

  cat > "$debian_dir/control" <<EOF
Package: v2rayn
Version: ${DEB_VERSION}
Architecture: ${DEB_ARCH}
Maintainer: ${DEB_MAINTAINER}
Installed-Size: ${installed_size}
Homepage: ${DEB_HOMEPAGE}
Section: net
Priority: optional
Depends: ${final_depends}
Description: v2rayN (Avalonia) GUI client for Linux
 Support vless / vmess / Trojan / http / socks / Anytls / Hysteria2 /
 Shadowsocks / tuic / WireGuard.
 .
 Built for Ubuntu 22.04 (jammy) and derivatives such as Pop!_OS 22.04.
EOF

  mkdir -p "$OUTPUT_DIR"
  deb_out="$OUTPUT_DIR/v2rayn_${DEB_VERSION}_${DEB_ARCH}.deb"
  dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb_out"

  echo ""
  dpkg-deb --info "$deb_out"
  echo ""
  echo "Build done. DEB at:"
  echo "  $deb_out"
}

main() {
  local pubdir=""

  parse_args "$@"
  detect_environment

  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT

  install_dependencies
  prepare_workspace
  resolve_version

  pubdir="$WORKDIR/publish"
  echo "[*] Publish v2rayN ${VERSION} for ${RID}"
  publish_binary "$pubdir"
  package_binary "$pubdir"
}

main "$@"
