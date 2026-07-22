#!/bin/bash
# Version-aware auto-download wrapper for bestocr-mcp.
#
# Mirrors the bestASR / che-mcps family pattern: the plugin ships this small
# script; the real binary is a signed + notarized asset on GitHub Releases,
# fetched on first spawn.
#
# Design:
# - Reads desired version from plugin.json (plugin's intended binary version)
# - Compares against ~/bin/.bestocr-mcp.version sidecar
# - Re-downloads when the plugin has been updated but the binary is stale
# - Atomic file swap (.tmp + mv) so partial downloads never break things
# - Falls back to releases/latest if plugin.json unreadable or pinned tag missing
#
# Note for contributors: if you built bestocr-mcp from source, this wrapper
# will replace ~/bin/bestocr-mcp with the released (notarized) build on
# version mismatch. Rebuild + copy afterward to go back to your local build.

set -u

REPO="PsychQuant/bestOCR"
BINARY_NAME="bestocr-mcp"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in the MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# Read desired version from plugin.json (empty string on any failure → fallback to "latest").
DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
fi

# Read currently installed version from sidecar (empty string if file missing/unreadable).
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

# Decide whether to download.
NEED_DOWNLOAD=false
REASON=""
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    # Release asset URLs are deterministic — try the direct URL first (the
    # download host is not subject to the anonymous API rate limit, which can
    # otherwise break installs behind shared NAT/CI IPs). Fall back to API
    # discovery (pinned tag, then latest) only when the direct path fails.
    URL=""
    if [[ -n "$DESIRED_VERSION" ]]; then
        DIRECT_URL="https://github.com/$REPO/releases/download/v$DESIRED_VERSION/$BINARY_NAME"
        if curl -sfIL --max-time 30 "$DIRECT_URL" >/dev/null 2>&1; then
            URL="$DIRECT_URL"
        fi
    fi
    if [[ -z "$URL" ]]; then
        for API_URL in \
            "${DESIRED_VERSION:+https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION}" \
            "https://api.github.com/repos/$REPO/releases/latest"
        do
            [[ -z "$API_URL" ]] && continue
            URL=$(curl -sL --max-time 30 "$API_URL" 2>/dev/null \
                | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
                | sed 's/.*"\(https[^"]*\)".*/\1/')
            [[ -n "$URL" ]] && break
        done
    fi

    # Version-gap guard (#6 follow-through): when the plugin pins a version
    # with no matching binary release (plugin-shell-only bumps), the resolution
    # chain lands on an older release every spawn. If what it resolved is the
    # version we already have, skip the download instead of re-fetching ~50MB
    # per spawn. No negative caching (a transient 5xx must not block a future
    # real release) and a missing binary still falls through to download.
    CANDIDATE_VERSION=$(printf '%s' "$URL" | sed -n 's#.*/releases/download/v\([^/]*\)/.*#\1#p')
    if [[ -x "$BINARY" && -n "$CANDIDATE_VERSION" && "$CANDIDATE_VERSION" == "$INSTALLED_VERSION" ]]; then
        echo "$BINARY_NAME: plugin wants v${DESIRED_VERSION:-?} but resolvable release is v${CANDIDATE_VERSION} (already installed) — skipping download" >&2
        URL=""
        SKIP_REASON="up-to-date"
    fi

    if [[ -z "$URL" ]]; then
        if [[ "${SKIP_REASON:-}" == "up-to-date" ]]; then
            : # installed binary matches the resolvable release — nothing to do
        elif [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO." >&2
            echo "$BINARY_NAME: build from source instead: git clone https://github.com/$REPO && cd bestOCR && swift build -c release" >&2
            exit 1
        fi
    else
        # mktemp: concurrent sessions each spawn the wrapper; a fixed .tmp
        # path would let parallel downloads clobber each other mid-write.
        DL_TMP=$(mktemp "${BINARY}.XXXXXX")
        if curl -sL --max-time 300 "$URL" -o "$DL_TMP" 2>/dev/null; then
            # Integrity check (#8): every release ships a .sha256 sidecar next
            # to the binary asset (bare hash, one line). A fetched-but-mismatched
            # hash is a hard fail (corruption / tampering — discard, keep the
            # existing binary). An UNFETCHABLE sidecar is warn-and-proceed:
            # availability wins over strictness for transient network errors,
            # and the mismatch case is the actual attack/corruption signal.
            EXPECTED_HASH=$(curl -sL --max-time 30 "${URL}.sha256" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$EXPECTED_HASH" ]]; then
                ACTUAL_HASH=$(shasum -a 256 "$DL_TMP" | awk '{print $1}')
                if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
                    rm -f "$DL_TMP"
                    echo "$BINARY_NAME: ERROR — sha256 mismatch for $URL (expected $EXPECTED_HASH, got $ACTUAL_HASH). Discarding download." >&2
                    if [[ -x "$BINARY" ]]; then
                        echo "$BINARY_NAME: keeping existing binary" >&2
                    else
                        exit 1
                    fi
                    exec "$BINARY" "$@"
                fi
            else
                echo "$BINARY_NAME: WARNING — sha256 sidecar unavailable at ${URL}.sha256; proceeding unverified" >&2
            fi
            # Quarantine strip runs only AFTER the hash check above passed (or
            # was explicitly waived) — never on an unverified-and-mismatched blob.
            chmod +x "$DL_TMP"
            # Strip the download quarantine so Gatekeeper's online notarization
            # check runs clean on the notarized binary (bare executables can't be
            # stapled; the ticket lives on Apple's servers).
            xattr -d com.apple.quarantine "$DL_TMP" 2>/dev/null || true
            mv "$DL_TMP" "$BINARY"
            # Record the version we ACTUALLY installed, parsed from the chosen
            # release URL (both the direct and API-discovered forms contain
            # /releases/download/v<tag>/). Recording DESIRED_VERSION here broke
            # the up-to-date check whenever the fallback chain served an older
            # release (#6): the sidecar claimed the desired tag, so a real
            # future release under that tag would never be downloaded.
            ACTUAL_VERSION="$CANDIDATE_VERSION"
            echo "${ACTUAL_VERSION:-unknown}" > "$VERSION_FILE"
            echo "$BINARY_NAME: installed v${ACTUAL_VERSION:-unknown}" >&2
        else
            rm -f "$DL_TMP" 2>/dev/null
            if [[ -x "$BINARY" ]]; then
                echo "$BINARY_NAME: WARNING — download failed, keeping existing binary" >&2
            else
                echo "$BINARY_NAME: ERROR — download failed" >&2
                exit 1
            fi
        fi
    fi
fi

exec "$BINARY" "$@"
