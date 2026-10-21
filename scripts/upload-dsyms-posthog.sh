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
# This lasts until the release and credential work in issue #236 lands.
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

if ! "$posthog_cli" dsym upload --directory "${DWARF_DSYM_FOLDER_PATH:-}" --include-source; then
    echo "warning: posthog-cli dsym upload failed, PostHog exceptions from this build will be unsymbolicated"
    exit 0
fi

echo "note: uploaded debug symbols to PostHog (project ${POSTHOG_CLI_PROJECT_ID})"
exit 0
