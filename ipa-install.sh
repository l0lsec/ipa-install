#!/bin/bash
set -euo pipefail

# ipa-install.sh — Automate IPA patch/sign/install flow
# Usage:
#   ./ipa-install.sh <path-to-ipa> [options]
#
# Options:
#   --jailbroken         Skip patching/signing, install directly
#   --no-patch           Re-sign only (no Frida gadget injection)
#   --identity <hash>    Code signing identity (auto-detected if omitted)
#   --provision <path>   Path to .mobileprovision file
#   --attach             Attach Objection after install
#   --bundle-id <id>     Override bundle ID for attach (auto-detected from IPA)
#   --min-os <ver>       Lower MinimumOSVersion in Info.plist (e.g. 15.0)
#   --no-gadget-config   Skip writing FridaGadget.config.json (auto-enabled on iOS 26+)
#   --gadget-config <p>  Use a custom FridaGadget.config.json instead of the default

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1" >&2; exit 1; }

JAILBROKEN=false
NO_PATCH=false
ATTACH=false
IDENTITY=""
PROVISION=""
BUNDLE_ID=""
MIN_OS=""
NO_THIN=false
NO_GADGET_CONFIG=false
GADGET_CONFIG_PATH=""
IPA_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jailbroken)  JAILBROKEN=true; shift ;;
        --no-patch)    NO_PATCH=true; shift ;;
        --attach)      ATTACH=true; shift ;;
        --identity)    IDENTITY="$2"; shift 2 ;;
        --provision)   PROVISION="$2"; shift 2 ;;
        --bundle-id)   BUNDLE_ID="$2"; shift 2 ;;
        --min-os)      MIN_OS="$2"; shift 2 ;;
        --no-thin)     NO_THIN=true; shift ;;
        --no-gadget-config) NO_GADGET_CONFIG=true; shift ;;
        --gadget-config) GADGET_CONFIG_PATH="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,17p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            if [[ -z "$IPA_PATH" ]]; then
                IPA_PATH="$1"; shift
            else
                err "Unknown argument: $1"
            fi ;;
    esac
done

[[ -z "$IPA_PATH" ]] && err "Usage: $0 <path-to-ipa> [options]"
[[ ! -f "$IPA_PATH" ]] && err "IPA not found: $IPA_PATH"

log "Checking for connected device..."
UDID=$(idevice_id -l 2>/dev/null | head -1)
[[ -z "$UDID" ]] && err "No iOS device detected. Connect via USB and trust the host."
log "Device found: $UDID"

DEVICE_OS=$(ideviceinfo -k ProductVersion 2>/dev/null || true)
[[ -n "$DEVICE_OS" ]] && log "Device iOS version: $DEVICE_OS"

# Create workdir early so helpers can use it
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Peek at the app's Info.plist for bundle ID + MinimumOSVersion
APP_MIN_OS=""
TMPDIR=$(mktemp -d)
unzip -q "$IPA_PATH" "Payload/*/Info.plist" -d "$TMPDIR" 2>/dev/null
# Target the top-level .app Info.plist only (not nested frameworks)
PLIST=$(find "$TMPDIR/Payload" -maxdepth 2 -name "Info.plist" 2>/dev/null | head -1)
if [[ -n "$PLIST" ]]; then
    if [[ -z "$BUNDLE_ID" ]]; then
        BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST" 2>/dev/null || true)
        [[ -n "$BUNDLE_ID" ]] && log "Bundle ID: $BUNDLE_ID" || warn "Could not detect bundle ID"
    fi
    APP_MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$PLIST" 2>/dev/null || true)
    [[ -n "$APP_MIN_OS" ]] && log "App MinimumOSVersion: $APP_MIN_OS"
fi
rm -rf "$TMPDIR"

# Auto-detect MinimumOSVersion mismatches and patch in-place when safe.
# Skipped when --min-os was set explicitly (user value wins) or --jailbroken
# (no resign happens, so we can't patch the plist).
if [[ -z "$MIN_OS" && "$JAILBROKEN" == false && -n "$DEVICE_OS" && -n "$APP_MIN_OS" ]]; then
    if [[ "$DEVICE_OS" != "$APP_MIN_OS" ]]; then
        # `sort -V` puts the lower semver version first
        LOWER=$(printf '%s\n%s\n' "$DEVICE_OS" "$APP_MIN_OS" | sort -V | head -1)
        if [[ "$LOWER" == "$DEVICE_OS" ]]; then
            DEVICE_MAJOR="${DEVICE_OS%%.*}"
            APP_MAJOR="${APP_MIN_OS%%.*}"
            if [[ "$DEVICE_MAJOR" == "$APP_MAJOR" ]]; then
                log "Auto-lowering MinimumOSVersion: device $DEVICE_OS < app min $APP_MIN_OS (same major $DEVICE_MAJOR — safe)"
                MIN_OS="$DEVICE_OS"
            else
                warn "Device iOS $DEVICE_OS is older than app minimum $APP_MIN_OS (different majors: $DEVICE_MAJOR vs $APP_MAJOR)"
                warn "Skipping auto-patch — pass --min-os $DEVICE_OS to override (app likely to crash on launch due to missing symbols)"
            fi
        fi
    fi
fi

# Path A: Jailbroken — install directly
if [[ "$JAILBROKEN" == true ]]; then
    log "Jailbroken mode — installing directly..."
    ideviceinstaller install "$IPA_PATH"
    log "Install complete."

    if [[ "$ATTACH" == true && -n "$BUNDLE_ID" ]]; then
        warn "Open the app on device, then press Enter to attach..."
        read -r
        objection -g "$BUNDLE_ID" explore
    fi
    exit 0
fi

# Auto-detect signing identity (need the SHA-1 hash, not the friendly name)
if [[ -z "$IDENTITY" ]]; then
    log "Auto-detecting signing identity..."
    IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "iPhone Developer\|Apple Development\|iPhone Distribution" | head -1)
    if [[ -z "$IDENTITY_LINE" ]]; then
        IDENTITY_LINE=$(security find-identity -v -p codesigning | grep -v "CSSMERR\|valid identities" | head -1)
    fi
    IDENTITY=$(echo "$IDENTITY_LINE" | awk '{print $2}')
    IDENTITY_NAME=$(echo "$IDENTITY_LINE" | sed 's/.*"\(.*\)".*/\1/')
    [[ -z "$IDENTITY" ]] && err "No signing identity found. Pass --identity <hash> or set up Xcode."
    log "Using identity: $IDENTITY_NAME ($IDENTITY)"
fi

# Determine effective team ID. The friendly name's parenthesized team can drift
# from the cert's actual OU on Personal Team accounts (Apple ID linked to a
# single-developer team). The OU is what Xcode and Apple's developer portal
# recognize, so prefer it when it differs.
IDENTITY_TEAM=""
IDENTITY_NAME_TEAM=""
IDENTITY_CERT_TEAM=""
if [[ -n "${IDENTITY_NAME:-}" ]]; then
    IDENTITY_NAME_TEAM=$(echo "$IDENTITY_NAME" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()')
    IDENTITY_CERT_TEAM=$(security find-certificate -c "$IDENTITY_NAME" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -oE 'OU=[A-Z0-9]+' | head -1 | cut -d= -f2)
fi
if [[ -n "$IDENTITY_CERT_TEAM" ]]; then
    IDENTITY_TEAM="$IDENTITY_CERT_TEAM"
    if [[ -n "$IDENTITY_NAME_TEAM" && "$IDENTITY_NAME_TEAM" != "$IDENTITY_CERT_TEAM" ]]; then
        warn "Identity name says team $IDENTITY_NAME_TEAM, but cert OU is $IDENTITY_CERT_TEAM (Personal Team)"
        warn "Using cert team $IDENTITY_CERT_TEAM (this is the team Xcode + Apple recognize)"
    fi
elif [[ -n "$IDENTITY_NAME_TEAM" ]]; then
    IDENTITY_TEAM="$IDENTITY_NAME_TEAM"
fi
[[ -n "$IDENTITY_TEAM" ]] && log "Identity team ID: $IDENTITY_TEAM"

# Helper: read a profile's team ID
get_profile_team() {
    local PROF="$1"
    local TMP_PLIST
    TMP_PLIST=$(mktemp)
    security cms -D -i "$PROF" > "$TMP_PLIST" 2>/dev/null
    local TEAM
    TEAM=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$TMP_PLIST" 2>/dev/null || true)
    rm -f "$TMP_PLIST"
    echo "$TEAM"
}

# Profile directories (Xcode 26 split them into two locations)
PROFILE_DIRS=(
    "$HOME/Library/MobileDevice/Provisioning Profiles"
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

# Get the cert UID (unique identifier) embedded in a .mobileprovision
get_profile_cert_uid() {
    local PROF="$1"
    local TMP
    TMP=$(mktemp)
    security cms -D -i "$PROF" > "$TMP" 2>/dev/null
    local CERT_DER="$TMP.cert"
    /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:0" "$TMP" > "$CERT_DER" 2>/dev/null
    local UID_VAL
    UID_VAL=$(openssl x509 -inform DER -in "$CERT_DER" -noout -subject 2>/dev/null | grep -oE 'UID=[A-Z0-9]+' | cut -d= -f2)
    rm -f "$TMP" "$CERT_DER"
    echo "$UID_VAL"
}

# Check if a provisioning profile includes a specific device UDID
profile_has_device() {
    local PROF="$1"
    local DEVICE_UDID="$2"
    local TMP
    TMP=$(mktemp)
    security cms -D -i "$PROF" > "$TMP" 2>/dev/null
    local LIST
    LIST=$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$TMP" 2>/dev/null || true)
    rm -f "$TMP"
    # Normalize: lowercase + strip hyphens + strip spaces for comparison
    local NORMALIZED_LIST
    NORMALIZED_LIST=$(echo "$LIST" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' | tr -d ' ' | tr -d '-')
    local NORMALIZED_TARGET
    NORMALIZED_TARGET=$(echo "$DEVICE_UDID" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' | tr -d ' ' | tr -d '-')
    echo "$NORMALIZED_LIST" | grep -q "$NORMALIZED_TARGET"
}

# Get the actual team ID (OU) from the cert embedded in a .mobileprovision
# (different from the profile's team-identifier entitlement for Personal Teams)
get_profile_cert_team() {
    local PROF="$1"
    local TMP
    TMP=$(mktemp)
    security cms -D -i "$PROF" > "$TMP" 2>/dev/null
    local CERT_DER="$TMP.cert"
    /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:0" "$TMP" > "$CERT_DER" 2>/dev/null
    local OU
    OU=$(openssl x509 -inform DER -in "$CERT_DER" -noout -subject 2>/dev/null | grep -oE 'OU=[A-Z0-9]+' | head -1 | cut -d= -f2)
    rm -f "$TMP" "$CERT_DER"
    echo "$OU"
}

# Check whether a given cert UID exists in our keychain (with its private key)
keychain_has_cert() {
    local TARGET_UID="$1"
    security find-identity -v -p codesigning | awk -F'"' 'NF>=2 {print $2}' | while read -r cert_name; do
        [[ -z "$cert_name" ]] && continue
        local SUBJECT
        SUBJECT=$(security find-certificate -c "$cert_name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
        local UID_VAL
        UID_VAL=$(echo "$SUBJECT" | grep -oE 'UID=[A-Z0-9]+' | cut -d= -f2)
        if [[ "$UID_VAL" == "$TARGET_UID" ]]; then
            echo "found"
            return 0
        fi
    done | grep -q "found"
}

# Find a profile that:
#   (a) matches the given team (via team-identifier entitlement OR cert OU), AND
#   (b) embeds a cert for which we have the private key in our keychain
# Returns the profile path via stdout.
find_usable_profile() {
    local TARGET_TEAM="$1"
    local BEST_PROFILE=""
    local BEST_MTIME=0

    for dir in "${PROFILE_DIRS[@]}"; do
        [[ ! -d "$dir" ]] && continue
        while IFS= read -r -d '' p; do
            local ENT_TEAM CERT_TEAM CERT_UID
            ENT_TEAM=$(get_profile_team "$p")
            CERT_TEAM=$(get_profile_cert_team "$p")
            CERT_UID=$(get_profile_cert_uid "$p")

            # Team must match either the entitlement team OR the cert's OU
            if [[ -n "$TARGET_TEAM" ]]; then
                if [[ "$ENT_TEAM" != "$TARGET_TEAM" && "$CERT_TEAM" != "$TARGET_TEAM" ]]; then
                    continue
                fi
            fi

            # Cert referenced by the profile must be in our keychain
            if ! keychain_has_cert "$CERT_UID"; then
                continue
            fi

            local MTIME
            MTIME=$(stat -f "%m" "$p" 2>/dev/null || echo 0)
            if [[ "$MTIME" -gt "$BEST_MTIME" ]]; then
                BEST_MTIME="$MTIME"
                BEST_PROFILE="$p"
            fi
        done < <(find "$dir" -maxdepth 1 -name "*.mobileprovision" -print0 2>/dev/null)
    done

    if [[ -n "$BEST_PROFILE" ]]; then
        echo "$BEST_PROFILE"
        return 0
    fi
    return 1
}

# Backwards-compat wrapper
find_matching_profile() {
    find_usable_profile "$1"
}

# Check whether a profile's application-identifier covers TARGET_BUNDLE.
# Returns 0 for exact match, full wildcard (`*`), or prefix wildcard (`com.foo.*`).
profile_covers_bundle() {
    local PROF="$1"
    local TARGET_BUNDLE="$2"
    local TMP
    TMP=$(mktemp)
    security cms -D -i "$PROF" > "$TMP" 2>/dev/null
    local TEAM_ID APP_ID PROFILE_BUNDLE
    TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$TMP" 2>/dev/null || true)
    APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$TMP" 2>/dev/null || true)
    rm -f "$TMP"
    PROFILE_BUNDLE="${APP_ID#${TEAM_ID}.}"

    if [[ "$PROFILE_BUNDLE" == "*" ]]; then
        return 0
    elif [[ "$PROFILE_BUNDLE" == "$TARGET_BUNDLE" ]]; then
        return 0
    elif [[ "$PROFILE_BUNDLE" == *"*" ]]; then
        local PREFIX="${PROFILE_BUNDLE%\*}"
        [[ "$TARGET_BUNDLE" == ${PREFIX}* ]] && return 0
    fi
    return 1
}

# Like find_usable_profile but additionally requires the profile to cover
# TARGET_BUNDLE (so signing won't trigger a bundle-ID rewrite later).
find_profile_for_bundle() {
    local TARGET_TEAM="$1"
    local TARGET_BUNDLE="$2"
    local BEST_PROFILE=""
    local BEST_MTIME=0

    for dir in "${PROFILE_DIRS[@]}"; do
        [[ ! -d "$dir" ]] && continue
        while IFS= read -r -d '' p; do
            local ENT_TEAM CERT_TEAM CERT_UID
            ENT_TEAM=$(get_profile_team "$p")
            CERT_TEAM=$(get_profile_cert_team "$p")
            CERT_UID=$(get_profile_cert_uid "$p")

            if [[ -n "$TARGET_TEAM" ]]; then
                if [[ "$ENT_TEAM" != "$TARGET_TEAM" && "$CERT_TEAM" != "$TARGET_TEAM" ]]; then
                    continue
                fi
            fi

            if ! keychain_has_cert "$CERT_UID"; then
                continue
            fi

            if ! profile_covers_bundle "$p" "$TARGET_BUNDLE"; then
                continue
            fi

            local MTIME
            MTIME=$(stat -f "%m" "$p" 2>/dev/null || echo 0)
            if [[ "$MTIME" -gt "$BEST_MTIME" ]]; then
                BEST_MTIME="$MTIME"
                BEST_PROFILE="$p"
            fi
        done < <(find "$dir" -maxdepth 1 -name "*.mobileprovision" -print0 2>/dev/null)
    done

    if [[ -n "$BEST_PROFILE" ]]; then
        echo "$BEST_PROFILE"
        return 0
    fi
    return 1
}

# Check Xcode prerequisites and warn about common issues up front
preflight_xcode() {
    local PROBLEMS=()

    # Check 1: is Xcode even installed and selected?
    if ! command -v xcodebuild &>/dev/null; then
        PROBLEMS+=("Xcode not installed. Get it from the Mac App Store.")
    fi

    # Check 2: is an Apple ID signed into Xcode?
    # `altool --list-providers` requires creds, but returns a specific error if logged in vs not.
    # A cleaner heuristic: check for the Xcode developer dir account plist.
    if [[ ! -d "$HOME/Library/Developer/Xcode" ]]; then
        PROBLEMS+=("Xcode has never been run. Open Xcode.app at least once.")
    fi

    # Check 3: is the device visible to Xcode's CoreDevice framework?
    # Unavailable status = Developer Mode off, device not trusted, or not paired
    if command -v xcrun &>/dev/null; then
        local DEVICE_STATE
        DEVICE_STATE=$(xcrun devicectl list devices 2>/dev/null | grep -iE "connected|available|paired" | head -1 || true)
        if [[ -z "$DEVICE_STATE" ]]; then
            local UNAVAIL_COUNT
            UNAVAIL_COUNT=$(xcrun devicectl list devices 2>/dev/null | grep -c "unavailable" || true)
            if [[ "$UNAVAIL_COUNT" -gt 0 ]]; then
                PROBLEMS+=("iOS device shows 'unavailable' to Xcode. Likely causes:
      - Developer Mode is OFF on the device
        Fix: Settings → Privacy & Security → Developer Mode → ON → reboot
      - Device is not trusted
        Fix: Unplug/replug and tap 'Trust This Computer'")
            fi
        fi
    fi

    if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
        warn "Xcode preflight detected issues:"
        for p in "${PROBLEMS[@]}"; do
            echo "    • $p" >&2
        done
        echo
    fi
}

# Auto-generate a provisioning profile via a stub Xcode project
# Uses xcodebuild -allowProvisioningUpdates to trigger profile creation
auto_generate_profile() {
    local TEAM_ID="$1"
    local DEVICE_UDID="$2"
    local TARGET_BUNDLE_ID="${3:-}"
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local STUB_SRC="$SCRIPT_DIR/stub-project"

    if [[ ! -d "$STUB_SRC" ]]; then
        warn "Stub project template not found at $STUB_SRC"
        return 1
    fi

    log "Auto-generating provisioning profile for team $TEAM_ID..."

    local STUB_TMP="$WORKDIR/stub"
    rm -rf "$STUB_TMP"
    cp -R "$STUB_SRC" "$STUB_TMP"

    # Use the target IPA's bundle ID when provided so the generated profile
    # matches exactly and signing won't have to rewrite CFBundleIdentifier.
    # Falls back to a unique stub bundle if no target was supplied.
    local STUB_BUNDLE
    if [[ -n "$TARGET_BUNDLE_ID" ]]; then
        STUB_BUNDLE="$TARGET_BUNDLE_ID"
        log "Targeting bundle ID: $STUB_BUNDLE (no rewrite will be needed)"
    else
        STUB_BUNDLE="com.ipainstall.stub$(date +%s)"
    fi
    local PBXPROJ="$STUB_TMP/Stub.xcodeproj/project.pbxproj"
    sed -i '' "s/__TEAM_ID__/$TEAM_ID/g" "$PBXPROJ"
    sed -i '' "s/__BUNDLE_ID__/$STUB_BUNDLE/g" "$PBXPROJ"

    # Step 1: try downloading any existing profiles Apple has for this team
    log "Step 1: Pulling existing profiles from Apple Developer Portal..."
    set +e
    xcodebuild -downloadAllProvisioningProfiles >/dev/null 2>&1
    set -e

    # Prefer a profile that covers our target bundle ID; fall back to any
    # profile for this team if no bundle target was given.
    local FOUND
    if [[ -n "$TARGET_BUNDLE_ID" ]]; then
        FOUND=$(find_profile_for_bundle "$TEAM_ID" "$TARGET_BUNDLE_ID" || true)
    else
        FOUND=$(find_matching_profile "$TEAM_ID" || true)
    fi
    if [[ -n "$FOUND" ]]; then
        log "Matching profile downloaded: $FOUND"
        PROVISION="$FOUND"
        return 0
    fi

    # Step 2: build the stub with -allowProvisioningUpdates to create a new profile
    # If a device UDID is supplied, target it so Xcode registers the device.
    # Otherwise use generic iOS.
    log "Step 2: Building stub project to create/refresh profile..."
    local BUILD_LOG="$WORKDIR/xcodebuild.log"
    local DEST
    if [[ -n "$DEVICE_UDID" ]]; then
        DEST="id=$DEVICE_UDID"
        log "Targeting connected device $DEVICE_UDID (will register with portal)"
    else
        DEST="generic/platform=iOS"
    fi

    set +e
    xcodebuild -project "$STUB_TMP/Stub.xcodeproj" \
        -scheme Stub \
        -sdk iphoneos \
        -destination "$DEST" \
        -allowProvisioningUpdates \
        -configuration Debug \
        clean build \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        > "$BUILD_LOG" 2>&1
    local RC=$?
    set -e

    # If device-targeted build failed (e.g. device unavailable in Xcode), fallback to generic
    if [[ $RC -ne 0 && -n "$DEVICE_UDID" ]]; then
        warn "Device-targeted build failed, retrying with generic iOS target..."
        set +e
        xcodebuild -project "$STUB_TMP/Stub.xcodeproj" \
            -scheme Stub \
            -sdk iphoneos \
            -destination "generic/platform=iOS" \
            -allowProvisioningUpdates \
            -configuration Debug \
            clean build \
            CODE_SIGN_STYLE=Automatic \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            > "$BUILD_LOG" 2>&1
        RC=$?
        set -e
    fi

    # Re-scan for profiles (xcodebuild may have succeeded at profile creation
    # even if the build itself failed later)
    if [[ -n "$TARGET_BUNDLE_ID" ]]; then
        FOUND=$(find_profile_for_bundle "$TEAM_ID" "$TARGET_BUNDLE_ID" || true)
    else
        FOUND=$(find_matching_profile "$TEAM_ID" || true)
    fi
    if [[ -n "$FOUND" ]]; then
        log "Fresh profile generated: $FOUND"
        PROVISION="$FOUND"
        return 0
    fi

    # Surface the xcodebuild failure reason so the user can diagnose
    warn "xcodebuild failed (exit $RC). Last 20 lines of log:"
    tail -20 "$BUILD_LOG" | sed 's/^/    /'

    return 1
}

# Re-pick the codesign identity to match the cert embedded in $PROVISION.
# Used by the Personal Team fallback when the chosen profile is signed by a
# different team than the auto-detected IDENTITY_TEAM.
repick_identity_for_profile() {
    local PROF_CERT_UID
    PROF_CERT_UID=$(get_profile_cert_uid "$PROVISION")
    while read -r line; do
        [[ -z "$line" ]] && continue
        local cert_name cert_hash subj uid_val
        cert_name=$(echo "$line" | awk -F'"' '{print $2}')
        cert_hash=$(echo "$line" | awk '{print $2}')
        [[ -z "$cert_name" ]] && continue
        subj=$(security find-certificate -c "$cert_name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
        uid_val=$(echo "$subj" | grep -oE 'UID=[A-Z0-9]+' | cut -d= -f2)
        if [[ "$uid_val" == "$PROF_CERT_UID" ]]; then
            IDENTITY="$cert_hash"
            IDENTITY_NAME="$cert_name"
            log "Matched identity for profile: $IDENTITY_NAME ($IDENTITY)"
            break
        fi
    done < <(security find-identity -v -p codesigning | grep -v "valid identities")
}

# Profile selection priority:
#   1. Existing profile that covers BUNDLE_ID exactly (no rewrite needed)
#   2. Same, across all teams (Personal Team fallback)
#   3. Auto-generate a fresh profile for BUNDLE_ID (no rewrite needed)
#   4. Any profile for the identity team (will trigger bundle ID rewrite)
#   5. Any profile across teams (will trigger rewrite, Personal Team fallback)
#   6. Last resort: auto-generate a stub-bundle profile (will trigger rewrite)
if [[ -z "$PROVISION" ]]; then
    log "Searching for a usable provisioning profile..."

    # 1. Bundle-matching profile for our identity team
    if [[ -n "$IDENTITY_TEAM" && -n "$BUNDLE_ID" ]]; then
        PROVISION=$(find_profile_for_bundle "$IDENTITY_TEAM" "$BUNDLE_ID" || true)
        [[ -n "$PROVISION" ]] && log "Found profile that covers $BUNDLE_ID exactly (no rewrite needed)"
    fi

    # 2. Bundle-matching profile from any team (Personal Team)
    if [[ -z "$PROVISION" && -n "$BUNDLE_ID" ]]; then
        PROVISION=$(find_profile_for_bundle "" "$BUNDLE_ID" || true)
        if [[ -n "$PROVISION" ]]; then
            EFFECTIVE_TEAM=$(get_profile_cert_team "$PROVISION")
            warn "Identity name says team $IDENTITY_TEAM, but using profile from team $EFFECTIVE_TEAM (cert OU)"
            IDENTITY_TEAM="$EFFECTIVE_TEAM"
            repick_identity_for_profile
            log "Found profile that covers $BUNDLE_ID exactly (no rewrite needed)"
        fi
    fi

    # 3. Auto-generate a fresh profile for our exact bundle ID
    if [[ -z "$PROVISION" && -n "$BUNDLE_ID" && -n "$IDENTITY_TEAM" ]]; then
        log "No existing profile covers $BUNDLE_ID — auto-generating one..."
        preflight_xcode
        if auto_generate_profile "$IDENTITY_TEAM" "$UDID" "$BUNDLE_ID"; then
            log "Generated profile for $BUNDLE_ID: $PROVISION"
        else
            warn "Per-bundle auto-gen failed (Apple may not allow this team to claim $BUNDLE_ID)"
            warn "Falling back to any usable profile (bundle ID will be rewritten)"
        fi
    fi

    # 4. Any profile for our identity team (will require rewrite)
    if [[ -z "$PROVISION" && -n "$IDENTITY_TEAM" ]]; then
        PROVISION=$(find_usable_profile "$IDENTITY_TEAM" || true)
        [[ -n "$PROVISION" ]] && warn "Using non-matching profile — bundle ID will be rewritten at sign time"
    fi

    # 5. Any profile across teams (Personal Team fallback, will require rewrite)
    if [[ -z "$PROVISION" ]]; then
        PROVISION=$(find_usable_profile "" || true)
        if [[ -n "$PROVISION" ]]; then
            EFFECTIVE_TEAM=$(get_profile_cert_team "$PROVISION")
            warn "Identity name says team $IDENTITY_TEAM, but using profile from team $EFFECTIVE_TEAM (cert OU)"
            IDENTITY_TEAM="$EFFECTIVE_TEAM"
            repick_identity_for_profile
            warn "Using non-matching profile — bundle ID will be rewritten at sign time"
        fi
    fi

    # 6. Last resort: auto-generate a stub profile (also requires rewrite)
    if [[ -n "$PROVISION" ]]; then
        log "Using profile: $PROVISION"
    else
        warn "No usable profile found — auto-generating a stub..."
        preflight_xcode
        if auto_generate_profile "$IDENTITY_TEAM" "$UDID"; then
            log "Using newly-generated profile: $PROVISION"
        else
            ERR_MSG="Could not auto-generate a provisioning profile for team $IDENTITY_TEAM.

Required one-time setup (GUI — cannot be scripted):

  1. Sign Xcode in to your Apple ID:
       Xcode → Settings (Cmd+,) → Accounts → (+) → Apple ID
       Sign in with the Apple ID tied to team $IDENTITY_TEAM
       Then click your team → Download Manual Profiles

  2. Enable Developer Mode on your iPhone:
       Settings → Privacy & Security → Developer Mode → ON
       Reboot the phone when prompted
       After reboot, tap Turn On at the Developer Mode prompt

  3. Trust the computer on the device:
       Unplug/replug your iPhone, unlock it, tap Trust This Computer
       Enter your passcode

  4. Verify with:
       xcrun devicectl list devices
       Device should show as connected/available, not unavailable

  5. Re-run this script.

Alternative paths that skip Xcode entirely:
  - AltStore:   https://altstore.io/
  - Sideloadly: https://sideloadly.io/"
            err "$ERR_MSG"
        fi
    fi
elif [[ -n "$IDENTITY_TEAM" ]]; then
    # User supplied a profile — validate it matches the identity's team
    PROFILE_TEAM=$(get_profile_team "$PROVISION")
    if [[ -n "$PROFILE_TEAM" && "$PROFILE_TEAM" != "$IDENTITY_TEAM" ]]; then
        warn "Supplied profile team ($PROFILE_TEAM) doesn't match identity team ($IDENTITY_TEAM)"
        warn "Auto-generating a matching profile instead..."
        if auto_generate_profile "$IDENTITY_TEAM" "$UDID" "$BUNDLE_ID"; then
            log "Using newly-generated profile: $PROVISION"
        else
            err "Could not generate matching profile. Pass a correct --provision or sign into Xcode."
        fi
    fi
fi

# Validate the profile covers THIS device's UDID; regenerate if not.
# Reuse the existing profile's bundle ID so we don't accidentally widen scope
# when the chosen profile already covers our target.
if ! profile_has_device "$PROVISION" "$UDID"; then
    warn "Profile does not include this device's UDID ($UDID)"
    warn "Regenerating profile to register this device..."
    preflight_xcode
    CURRENT_TEAM=$(get_profile_cert_team "$PROVISION")
    REGEN_BUNDLE=""
    if [[ -n "$BUNDLE_ID" ]] && profile_covers_bundle "$PROVISION" "$BUNDLE_ID"; then
        REGEN_BUNDLE="$BUNDLE_ID"
    fi
    if auto_generate_profile "$CURRENT_TEAM" "$UDID" "$REGEN_BUNDLE"; then
        if profile_has_device "$PROVISION" "$UDID"; then
            log "Device registered and profile updated"
        else
            warn "Profile regenerated but device UDID still not included"
            warn "You may need to manually register the device:"
            warn "  1. Open your NewTestApp project in Xcode"
            warn "  2. Plug in this device ($UDID)"
            warn "  3. Build to it (Cmd+R) — Xcode will register and refresh the profile"
            warn "  4. Re-run this script"
        fi
    else
        err "Failed to regenerate profile. Open Xcode, plug in device, and build any project to register it."
    fi
fi

BASENAME=$(basename "$IPA_PATH" .ipa)
OUTPUT_IPA="$WORKDIR/${BASENAME}-signed.ipa"

# Extract metadata from a provisioning profile:
#   PROFILE_TEAM_ID       — 10-char Apple Team ID
#   PROFILE_APP_ID        — full application-identifier (e.g. TEAM.com.foo.bar or TEAM.*)
#   PROFILE_BUNDLE_ID     — bundle ID portion (just com.foo.bar, or "*" for wildcard)
parse_profile() {
    local PROF="$1"
    local PLIST="$WORKDIR/profile.plist"
    security cms -D -i "$PROF" > "$PLIST" 2>/dev/null

    PROFILE_TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$PLIST" 2>/dev/null || true)
    PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$PLIST" 2>/dev/null || true)
    # Strip team ID prefix → leaves bundle ID pattern
    PROFILE_BUNDLE_ID="${PROFILE_APP_ID#${PROFILE_TEAM_ID}.}"
}

# Rewrite the app's bundle ID in Info.plist to match the provisioning profile
rewrite_bundle_id() {
    local APP_PATH="$1"
    local NEW_BUNDLE_ID="$2"
    local INFO_PLIST="$APP_PATH/Info.plist"
    local ORIG_BUNDLE_ID
    ORIG_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
    warn "Rewriting bundle ID: $ORIG_BUNDLE_ID → $NEW_BUNDLE_ID"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "$INFO_PLIST"
    BUNDLE_ID="$NEW_BUNDLE_ID"
}

# Lower MinimumOSVersion in the app + every framework + every plugin Info.plist
# so installd's preflight check passes on devices with older patch versions.
patch_min_os_version() {
    local APP_PATH="$1"
    local NEW_MIN="$2"
    local INFO="$APP_PATH/Info.plist"
    local OLD
    OLD=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$INFO" 2>/dev/null || echo "?")
    warn "Lowering MinimumOSVersion: $OLD → $NEW_MIN"
    /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $NEW_MIN" "$INFO" 2>/dev/null || true

    for sub in Frameworks PlugIns; do
        [[ -d "$APP_PATH/$sub" ]] || continue
        find "$APP_PATH/$sub" -name "Info.plist" 2>/dev/null | while read -r p; do
            /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $NEW_MIN" "$p" 2>/dev/null || true
        done
    done
}

# Unzip an IPA, thin its fat Mach-Os to the main exec's arch, drop a
# FridaGadget.config.json next to the embedded gadget when needed, then rezip.
# Echoes the path of the processed IPA on stdout. If both passes are skipped
# / no-op, echoes the original path.
pre_thin_ipa() {
    local SOURCE_IPA="$1"
    if [[ "$NO_THIN" == true && "$NO_GADGET_CONFIG" == true ]]; then
        echo "$SOURCE_IPA"
        return 0
    fi
    local THINDIR="$WORKDIR/thin_pre"
    rm -rf "$THINDIR"
    mkdir -p "$THINDIR"
    unzip -q "$SOURCE_IPA" -d "$THINDIR" >&2 || { echo "$SOURCE_IPA"; return 0; }
    local APP_PATH
    APP_PATH=$(find "$THINDIR/Payload" -maxdepth 1 -name "*.app" | head -1)
    if [[ -z "$APP_PATH" ]]; then
        echo "$SOURCE_IPA"
        return 0
    fi
    if [[ "$NO_THIN" != true ]]; then
        thin_fat_to_main_arch "$APP_PATH" >&2
    fi
    if [[ "$NO_GADGET_CONFIG" != true ]]; then
        write_gadget_config "$APP_PATH" >&2
    fi
    local PROCESSED_IPA
    PROCESSED_IPA="$WORKDIR/$(basename "$SOURCE_IPA" .ipa)-thinned.ipa"
    ( cd "$THINDIR" && zip -qry "$PROCESSED_IPA" Payload/ ) >&2
    if [[ -f "$PROCESSED_IPA" ]]; then
        echo "$PROCESSED_IPA"
    else
        echo "$SOURCE_IPA"
    fi
}

# Drop a FridaGadget.config.json next to the embedded FridaGadget.dylib.
# On iOS 26+, Apple tightened JIT-with-debugger restrictions, so a baked-in
# gadget panics with `brk #1337` during init unless `code_signing` is set to
# `required` (see https://github.com/frida/frida/issues/3650). We therefore
# default to required-mode codesigning whenever the device is iOS >= 26 (or
# unknown). On older iOS the field is harmless. If the user passes a custom
# config via --gadget-config, that file is copied verbatim instead.
write_gadget_config() {
    local APP_PATH="$1"
    local GADGET_PATH
    GADGET_PATH=$(find "$APP_PATH/Frameworks" -maxdepth 1 -name "FridaGadget.dylib" 2>/dev/null | head -1)
    if [[ -z "$GADGET_PATH" ]]; then
        return 0
    fi
    local CFG_PATH="${GADGET_PATH%.dylib}.config.json"

    if [[ -n "$GADGET_CONFIG_PATH" ]]; then
        if [[ ! -f "$GADGET_CONFIG_PATH" ]]; then
            warn "--gadget-config file not found: $GADGET_CONFIG_PATH (skipping)"
            return 0
        fi
        cp "$GADGET_CONFIG_PATH" "$CFG_PATH"
        log "Wrote custom FridaGadget.config.json from $GADGET_CONFIG_PATH"
        return 0
    fi

    # Decide whether code_signing must be required. iOS >= 26 always needs it.
    # If we can't detect the device version, err on the side of including it
    # (works on every iOS version: pre-26 just ignores the extra field).
    local NEEDS_REQUIRED=true
    if [[ -n "${DEVICE_OS:-}" ]]; then
        local DEV_MAJOR="${DEVICE_OS%%.*}"
        if [[ "$DEV_MAJOR" =~ ^[0-9]+$ ]] && (( DEV_MAJOR < 26 )); then
            NEEDS_REQUIRED=false
        fi
    fi

    if [[ "$NEEDS_REQUIRED" == true ]]; then
        cat > "$CFG_PATH" <<'JSON'
{
  "interaction": {
    "type": "listen",
    "address": "127.0.0.1",
    "port": 27042,
    "on_port_conflict": "fail",
    "on_load": "wait"
  },
  "code_signing": "required"
}
JSON
        log "Wrote FridaGadget.config.json with code_signing=required (iOS 26+ workaround for issue #3650)"
        warn "  -> Interceptor.attach() will be unavailable; ObjC swizzling/replacement still works."
        warn "  -> For full Interceptor support, sideload --no-patch and run: frida -U -n \"<app name>\" -l script.js"
    else
        cat > "$CFG_PATH" <<'JSON'
{
  "interaction": {
    "type": "listen",
    "address": "127.0.0.1",
    "port": 27042,
    "on_port_conflict": "fail",
    "on_load": "wait"
  }
}
JSON
        log "Wrote default FridaGadget.config.json (listen on 127.0.0.1:27042)"
    fi
}

# Strip every Mach-O in the unpacked .app down to the main executable's arch.
# Sideloaded apps re-signed with a non-distribution cert frequently crash with
# `brk #1337` inside an arm64e dylib's initializer because re-signing breaks
# arm64e pointer-authentication. iOS 17+ on A12+ devices will preferentially
# load the arm64e slice from a fat third-party dylib whenever it exists, so
# the safest fix is to thin every fat Mach-O down to the main exec's arch.
thin_fat_to_main_arch() {
    local APP_PATH="$1"
    local APP_BIN="$APP_PATH/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null)"
    [[ ! -f "$APP_BIN" ]] && APP_BIN=$(find "$APP_PATH" -maxdepth 1 -type f -perm +111 | head -1)
    [[ ! -f "$APP_BIN" ]] && return 0

    # Determine the main exec's arch(s).
    local MAIN_ARCHS
    MAIN_ARCHS=$(lipo -archs "$APP_BIN" 2>/dev/null || echo "")
    [[ -z "$MAIN_ARCHS" ]] && return 0

    # Pick the first arch (usually arm64). If main is arm64e (rare for sideload
    # targets), keep arm64e. Otherwise prefer arm64.
    local TARGET_ARCH
    if [[ " $MAIN_ARCHS " == *" arm64 "* ]]; then
        TARGET_ARCH="arm64"
    else
        TARGET_ARCH="${MAIN_ARCHS%% *}"
    fi
    log "Thinning fat Mach-Os in app bundle to $TARGET_ARCH (main exec is: $MAIN_ARCHS)"

    local thinned=0
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # Cheap Mach-O / fat detection: read first 4 bytes.
        local magic
        magic=$(xxd -p -l 4 "$f" 2>/dev/null || true)
        # Fat magic numbers: cafebabe, bebafeca (little-endian), cafebabf (fat64), bfbafeca
        case "$magic" in
            cafebabe|bebafeca|cafebabf|bfbafeca) ;;
            *) continue ;;
        esac
        # Confirm with lipo and skip if it's already thin or arch missing.
        local archs
        archs=$(lipo -archs "$f" 2>/dev/null || echo "")
        [[ -z "$archs" ]] && continue
        [[ " $archs " != *" $TARGET_ARCH "* ]] && continue
        # If only target arch is present, lipo -thin would be a no-op or fail.
        if [[ "$archs" == "$TARGET_ARCH" ]]; then
            continue
        fi
        if lipo "$f" -thin "$TARGET_ARCH" -output "$f.thin" 2>/dev/null; then
            mv "$f.thin" "$f"
            thinned=$((thinned + 1))
        fi
    done < <(find "$APP_PATH/Frameworks" "$APP_PATH/PlugIns" -type f \
                  \( -name "*.dylib" -o -perm +111 \) 2>/dev/null)

    log "Thinned $thinned fat Mach-O(s) to $TARGET_ARCH"
}

sign_ipa() {
    local SOURCE_IPA="$1"
    local DEST_IPA="$2"
    local APPLESIGN_OK=false

    # Try applesign first (fast path when profile & identity match cleanly).
    # Skip when --min-os is set: applesign would ship the IPA before we get a
    # chance to patch MinimumOSVersion in the unpacked Info.plists.
    if [[ -z "$MIN_OS" ]]; then
        set +e
        applesign "$SOURCE_IPA" \
            --identity "$IDENTITY" \
            --mobileprovision "$PROVISION" \
            -o "$DEST_IPA" \
            --clone-entitlements 2>&1 | grep -v "^$" | head -5
        [[ ${PIPESTATUS[0]} -eq 0 ]] && APPLESIGN_OK=true
        set -e

        if [[ "$APPLESIGN_OK" == true && -f "$DEST_IPA" ]]; then
            log "applesign succeeded"
            return 0
        fi
        warn "applesign failed, falling back to manual codesign..."
    else
        log "--min-os set, skipping applesign and going straight to manual codesign"
    fi
    local SIGNDIR="$WORKDIR/sign_tmp"
    rm -rf "$SIGNDIR"
    mkdir -p "$SIGNDIR"
    unzip -q "$SOURCE_IPA" -d "$SIGNDIR"

    local APP_PATH
    APP_PATH=$(find "$SIGNDIR/Payload" -maxdepth 1 -name "*.app" | head -1)
    [[ -z "$APP_PATH" ]] && err "No .app found inside IPA"
    log "Signing app: $(basename "$APP_PATH")"

    # Parse the provisioning profile to check bundle ID compatibility
    parse_profile "$PROVISION"
    log "Profile team: $PROFILE_TEAM_ID, allows bundle ID: $PROFILE_BUNDLE_ID"

    local APP_BUNDLE_ID
    APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist")

    # Check if we need to rewrite the bundle ID
    if [[ "$PROFILE_BUNDLE_ID" == "*" ]]; then
        log "Wildcard profile — any bundle ID works"
    elif [[ "$PROFILE_BUNDLE_ID" == "$APP_BUNDLE_ID" ]]; then
        log "Bundle ID matches profile exactly"
    elif [[ "$PROFILE_BUNDLE_ID" == *"*" ]]; then
        # Wildcard prefix match (e.g., com.foo.* matches com.foo.bar)
        local PREFIX="${PROFILE_BUNDLE_ID%\*}"
        if [[ "$APP_BUNDLE_ID" == ${PREFIX}* ]]; then
            log "Bundle ID matches wildcard profile"
        else
            rewrite_bundle_id "$APP_PATH" "${PREFIX}${APP_BUNDLE_ID//./}"
        fi
    else
        # Exact mismatch — rewrite to match the profile
        rewrite_bundle_id "$APP_PATH" "$PROFILE_BUNDLE_ID"
    fi

    [[ -n "$MIN_OS" ]] && patch_min_os_version "$APP_PATH" "$MIN_OS"

    # Embed provisioning profile
    cp "$PROVISION" "$APP_PATH/embedded.mobileprovision"

    # Extract entitlements and update application-identifier to match new bundle ID
    local ENTITLEMENTS="$WORKDIR/entitlements.plist"
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORKDIR/profile.plist" > "$ENTITLEMENTS" 2>/dev/null || true

    if [[ ! -s "$ENTITLEMENTS" ]]; then
        warn "Could not extract entitlements, signing without them"
        ENTITLEMENTS=""
    else
        log "Extracted entitlements from profile"
    fi

    # Sign frameworks/dylibs first (no entitlements for these)
    if [[ -d "$APP_PATH/Frameworks" ]]; then
        log "Signing frameworks..."
        find "$APP_PATH/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) | while read -r fw; do
            codesign --force --sign "$IDENTITY" "$fw" 2>/dev/null || true
        done
    fi

    # Sign plugins/extensions
    if [[ -d "$APP_PATH/PlugIns" ]]; then
        log "Signing plugins..."
        find "$APP_PATH/PlugIns" -name "*.appex" | while read -r ext; do
            if [[ -n "$ENTITLEMENTS" ]]; then
                codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$ext" 2>/dev/null || true
            else
                codesign --force --sign "$IDENTITY" "$ext" 2>/dev/null || true
            fi
        done
    fi

    # Sign the main app bundle
    log "Signing main bundle..."
    if [[ -n "$ENTITLEMENTS" ]]; then
        codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH"
    else
        codesign --force --sign "$IDENTITY" "$APP_PATH"
    fi

    # Verify the signature
    log "Verifying signature..."
    if codesign --verify --deep --strict "$APP_PATH" 2>&1 | grep -v "^$" | head -3; then
        :
    fi

    # Repackage
    (cd "$SIGNDIR" && zip -qry "$DEST_IPA" Payload/)
    log "Manual codesign complete"
}

if [[ "$NO_PATCH" == true ]]; then
    log "Re-signing IPA (no patch)..."
    sign_ipa "$IPA_PATH" "$OUTPUT_IPA"
else
    log "Patching IPA with Frida gadget..."
    # objection patchipa has no -o flag; it writes
    # "<source-stem>-frida-codesigned.ipa" into the current working directory.
    # Run it from $WORKDIR so the output lands there.
    PATCH_OUTDIR="$WORKDIR/objection_out"
    mkdir -p "$PATCH_OUTDIR"
    PATCHED_IPA="$PATCH_OUTDIR/${BASENAME}-frida-codesigned.ipa"

    OBJECTION_ARGS=(
        patchipa
        --source "$IPA_PATH"
        --codesign-signature "$IDENTITY"
    )
    if [[ -n "$PROVISION" && -f "$PROVISION" ]]; then
        OBJECTION_ARGS+=(--provision-file "$PROVISION")
    fi
    if [[ -n "$BUNDLE_ID" ]]; then
        OBJECTION_ARGS+=(--bundle-id "$BUNDLE_ID")
    fi

    set +e
    ( cd "$PATCH_OUTDIR" && objection "${OBJECTION_ARGS[@]}" )
    OBJ_RC=$?
    set -e

    if [[ $OBJ_RC -ne 0 ]]; then
        warn "objection patchipa exited with code $OBJ_RC"
    fi

    # Some objection versions sanitise spaces in the output filename. Pick the
    # newest *-frida-codesigned.ipa in the output dir as a fallback.
    if [[ ! -f "$PATCHED_IPA" ]]; then
        FOUND_IPA=$(ls -1t "$PATCH_OUTDIR"/*-frida-codesigned.ipa 2>/dev/null | head -1 || true)
        if [[ -n "$FOUND_IPA" && -f "$FOUND_IPA" ]]; then
            PATCHED_IPA="$FOUND_IPA"
        fi
    fi

    if [[ -f "$PATCHED_IPA" ]]; then
        log "Pre-processing patched IPA (thin arm64e + write gadget config)..."
        PATCHED_IPA=$(pre_thin_ipa "$PATCHED_IPA")
        log "Re-signing patched IPA..."
        sign_ipa "$PATCHED_IPA" "$OUTPUT_IPA"
    else
        warn "Objection patch output not found, signing original..."
        warn "(make sure 'applesign' is installed: npm install -g applesign)"
        sign_ipa "$IPA_PATH" "$OUTPUT_IPA"
    fi
fi

[[ ! -f "$OUTPUT_IPA" ]] && err "Signing failed — no output IPA produced."
log "Signed IPA: $OUTPUT_IPA"

log "Installing provisioning profile on device..."
set +e
PROV_OUT=$(ideviceprovision install "$PROVISION" 2>&1)
PROV_RC=$?
set -e
if [[ $PROV_RC -ne 0 ]]; then
    echo "$PROV_OUT" | head -3
    warn "Profile install returned non-zero (may already be installed)"
else
    log "Profile installed"
fi

# List installed profiles for visibility
if command -v ideviceprovision &>/dev/null; then
    log "Profiles currently on device:"
    ideviceprovision list 2>/dev/null | sed 's/^/    /' | head -10 || true
fi

log "Installing IPA on device..."
ideviceinstaller install "$OUTPUT_IPA"
log "Install complete!"

FINAL_COPY="./${BASENAME}-installed.ipa"
cp "$OUTPUT_IPA" "$FINAL_COPY"
log "Signed IPA saved to: $FINAL_COPY"

if [[ "$ATTACH" == true && -n "$BUNDLE_ID" ]]; then
    warn "Open the app on device, then press Enter to attach..."
    read -r
    objection -g "$BUNDLE_ID" explore
fi
