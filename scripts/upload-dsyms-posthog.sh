#!/bin/zsh
#
# upload-dsyms-posthog.sh
#
# Uploads the dSYMs this build produced to PostHog (project 444958, the
# dj-site project this app shares) so exceptions arrive symbolicated. Run by
# the "Upload Debug Symbols to PostHog" build phase on the WXYCDJ target, on
# every build, on every machine. Sits beside upload-debug-symbols.sh (Sentry),
# which stays until the Sentry exit completes (issue #235).
#
# Warn, never fail: when the upload cannot run (no posthog-cli, no API key) or
# fails, the phase prints an Xcode `warning:` line on every build and exits 0.
# This lasts until the release and credential work in issue #236 lands. A build
# with no dSYMs to upload (a Debug build) prints a `note:` instead and exits 0.
#
# Credentials come from POSTHOG_CLI_API_KEY in the environment, else from
# ~/.posthog-cli.env (POSTHOG_CLI_HOST and POSTHOG_CLI_API_KEY). The key is
# never echoed.
#
# Environment (supplied by Xcode, except where noted):
#   DWARF_DSYM_FOLDER_PATH       the folder Xcode wrote this build's dSYMs into
#   POSTHOG_CLI_API_KEY          optional; wins over ~/.posthog-cli.env
#   POSTHOG_CLI_SEARCH_DIRS      optional; extra dirs probed for posthog-cli
#                                (default: Homebrew's two prefixes; test seam)
#
# Tested by scripts/tests/test-upload-dsyms-posthog.sh.

set -uo pipefail

if [ -z "${POSTHOG_CLI_API_KEY:-}" ] && [ -r ~/.posthog-cli.env ]; then set -a; . ~/.posthog-cli.env; set +a; fi

export POSTHOG_CLI_PROJECT_ID="444958"

# Xcode build phases get a minimal PATH that omits Homebrew, so probe its
# prefixes after PATH.
resolve_posthog_cli() {
    command -v posthog-cli 2>/dev/null && return 0
    local dir
    for dir in ${=POSTHOG_CLI_SEARCH_DIRS:-/opt/homebrew/bin /usr/local/bin}; do
        [[ -x "$dir/posthog-cli" ]] && { echo "$dir/posthog-cli"; return 0; }
    done
    return 1
}

if ! posthog_cli=$(resolve_posthog_cli); then
    echo "warning: posthog-cli not found, skipping PostHog debug symbol upload; install with: brew install posthog/tap/posthog-cli"
    exit 0
fi

if [[ -z "${POSTHOG_CLI_API_KEY:-}" ]]; then
    echo "warning: POSTHOG_CLI_API_KEY is not set and ~/.posthog-cli.env did not provide it, skipping PostHog debug symbol upload"
    exit 0
fi

# posthog-cli exits 0 when the folder holds no dSYMs, which is every Debug
# build (DEBUG_INFORMATION_FORMAT = dwarf), and it rejects an empty
# --directory. Check for bundles first, as upload-debug-symbols.sh does, so the
# closing note only reports an upload that ran.
dsym_folder="${DWARF_DSYM_FOLDER_PATH:-}"
missing_dsyms=""
if [[ -z "$dsym_folder" ]]; then
    missing_dsyms="DWARF_DSYM_FOLDER_PATH is not set"
elif [[ ! -d "$dsym_folder" ]]; then
    missing_dsyms="${dsym_folder} does not exist"
else
    dsym_bundles=("$dsym_folder"/*.dSYM(N))
    if (( ${#dsym_bundles} == 0 )); then
        missing_dsyms="no .dSYM bundles in ${dsym_folder}"
    fi
fi

if [[ -n "$missing_dsyms" ]]; then
    echo "note: ${missing_dsyms}; skipping PostHog debug symbol upload"
    exit 0
fi

# stdout goes to the build log as is; stderr is captured so the failure reason
# rides on the one `warning:` line Xcode's issue navigator shows. The fd 3
# dance is what lets stdout escape the command substitution.
{
    upload_error=$("$posthog_cli" dsym upload --directory "$dsym_folder" --include-source 2>&1 >&3 3>&-)
    upload_status=$?
} 3>&1

if (( upload_status != 0 )); then
    echo "warning: posthog-cli dsym upload failed, PostHog exceptions from this build will be unsymbolicated: ${upload_error//$'\n'/ }"
    exit 0
fi

echo "note: uploaded debug symbols to PostHog (project ${POSTHOG_CLI_PROJECT_ID})"
exit 0
