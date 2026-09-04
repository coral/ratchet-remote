#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly APP_NAME="Ratchet Remote.app"
readonly EXECUTABLE_NAME="RatchetRemote"
readonly INSTALL_ROOT=${RATCHET_INSTALL_DIR:-/Applications}
readonly DESTINATION="${INSTALL_ROOT}/${APP_NAME}"

launch_after_install=false

usage() {
    /bin/cat <<'EOF'
Usage: ./install.sh [--launch]

Builds an optimized Ratchet Remote.app, signs it locally, and installs it in
/Applications. Pass --launch to open it after installation.

For testing only, RATCHET_INSTALL_DIR can select another absolute directory.
EOF
}

case ${1:-} in
    "") ;;
    --launch) launch_after_install=true ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

if [[ $(uname -s) != Darwin ]]; then
    print -u2 "error: Ratchet Remote can only be built as an app on macOS"
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    print -u2 "error: Swift is unavailable; install the Xcode command-line tools first"
    exit 1
fi

if [[ ${INSTALL_ROOT} != /* || ${INSTALL_ROOT} == / ]]; then
    print -u2 "error: install destination must be an absolute directory other than /"
    exit 1
fi

print "Building Ratchet Remote (release)..."
swift build --package-path "${SCRIPT_DIR}" -c release
readonly BIN_DIR=$(swift build --package-path "${SCRIPT_DIR}" -c release --show-bin-path)
readonly SOURCE_EXECUTABLE="${BIN_DIR}/${EXECUTABLE_NAME}"

if [[ ! -x ${SOURCE_EXECUTABLE} ]]; then
    print -u2 "error: release executable was not produced at ${SOURCE_EXECUTABLE}"
    exit 1
fi

readonly STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ratchet-remote-install.XXXXXX")
readonly STAGED_APP="${STAGING_ROOT}/${APP_NAME}"

cleanup() {
    /bin/rm -rf -- "${STAGING_ROOT}"
}
trap cleanup EXIT

/bin/mkdir -p "${STAGED_APP}/Contents/MacOS" "${STAGED_APP}/Contents/Resources"
/usr/bin/ditto "${SOURCE_EXECUTABLE}" "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
/usr/bin/ditto "${SCRIPT_DIR}/Packaging/Info.plist" "${STAGED_APP}/Contents/Info.plist"

# Embed every SwiftPM resource bundle in the standard signed macOS bundle
# location. This includes UI artwork and any resources added by library targets.
for source_resource_bundle in "${BIN_DIR}"/ratchet-remote_*.bundle(N); do
    resource_bundle_name=${source_resource_bundle:t}
    /usr/bin/ditto "${source_resource_bundle}" \
        "${STAGED_APP}/Contents/Resources/${resource_bundle_name}"
done

readonly ICON_SOURCE="${SCRIPT_DIR}/Sources/RatchetRemote/Resources/BMark.svg"
icon_renderer=$(command -v rsvg-convert || true)
if [[ -n ${icon_renderer} && -f ${ICON_SOURCE} ]]; then
    readonly ICONSET="${STAGING_ROOT}/RatchetRemote.iconset"
    /bin/mkdir -p "${ICONSET}"
    for size in 16 32 128 256 512; do
        doubled=$((size * 2))
        "${icon_renderer}" -w "${size}" -h "${size}" \
            -o "${ICONSET}/icon_${size}x${size}.png" "${ICON_SOURCE}"
        "${icon_renderer}" -w "${doubled}" -h "${doubled}" \
            -o "${ICONSET}/icon_${size}x${size}@2x.png" "${ICON_SOURCE}"
    done
    /usr/bin/iconutil -c icns "${ICONSET}" \
        -o "${STAGED_APP}/Contents/Resources/RatchetRemote.icns"
else
    print "Note: rsvg-convert is unavailable; installing with the generic app icon."
    /usr/bin/plutil -remove CFBundleIconFile "${STAGED_APP}/Contents/Info.plist"
fi

/bin/chmod -R u=rwX,go=rX "${STAGED_APP}"
/usr/bin/plutil -lint "${STAGED_APP}/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "${STAGED_APP}"
/usr/bin/codesign --verify --deep --strict "${STAGED_APP}"

install_bundle() {
    /bin/rm -rf -- "${DESTINATION}"
    /usr/bin/ditto "${STAGED_APP}" "${DESTINATION}"
}

print "Installing ${DESTINATION}..."
if [[ -d ${INSTALL_ROOT} && -w ${INSTALL_ROOT} ]]; then
    install_bundle
else
    print "Administrator permission is required to write to ${INSTALL_ROOT}."
    /usr/bin/sudo -v
    /usr/bin/sudo /bin/rm -rf -- "${DESTINATION}"
    /usr/bin/sudo /usr/bin/ditto "${STAGED_APP}" "${DESTINATION}"
fi

/usr/bin/codesign --verify --deep --strict "${DESTINATION}"
print "Installed ${DESTINATION}"

if [[ ${launch_after_install} == true ]]; then
    if /usr/bin/pgrep -x "${EXECUTABLE_NAME}" >/dev/null 2>&1; then
        print "RatchetRemote is already running; quit it before opening the installed app."
    else
        /usr/bin/open "${DESTINATION}"
    fi
fi
