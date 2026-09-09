#!/bin/zsh
#
# upload-debug-symbols.sh
#
# Uploads the dSYMs this build produced to Sentry (org wxyc, project
# wxyc-dj-ios). Run by the "Upload Debug Symbols to Sentry" build phase on
# the WXYCDJ target, on every build, on every machine.
#
# Server-side symbolication of Release stacks rests entirely on this upload.
# Without it, Sentry has addresses and no function names, and anything that
# reasons about the symbolicated stack -- grouping rules, fingerprints,
# innermost-in-app-frame heuristics -- quietly goes inert.
#
# Adapted from wxyc-ios-64's scripts/upload-debug-symbols.sh (issue #107).
# The design carries over, but this repo has no release pipeline yet -- no
# Xcode Cloud, no archive-and-ship CI job, nothing that vendors sentry-cli
# onto a runner -- so a missed upload means one thing everywhere for now:
#
#   On a dev Mac, sentry-cli is optional. Somebody debugging a layout bug in
#   a Debug build should not be blocked because they never installed it, and
#   local builds are not what Sentry symbolicates anyway. Every failure path
#   is a `warning:` and the build continues.
#
#   ci.yml's `xcodebuild test` job never reaches any of the strict logic
#   below either: it always builds Debug, and Debug is never a shipping
#   configuration (see is_shipping_build()).
#
# The CI-fails-the-build half of the design (is_ci() / is_shipping_build() /
# fail_or_continue()) is kept intact and does still apply to the dSYM-folder
# and credentials checks below -- it is only resolve_sentry_cli()'s
# missing-tool case that is unconditionally a warning right now, because
# there is no installer script (wxyc-ios-64's ci_scripts/install-sentry-
# cli.sh has no counterpart here) for a CI failure message to point at. See
# that function's comment for what "returns" once a release pipeline lands.
#
# Environment (all supplied by Xcode, except where noted):
#   DWARF_DSYM_FOLDER_PATH  the folder Xcode wrote this build's dSYMs into
#   CONFIGURATION / ACTION  Release / install for an archive; selects strictness
#   SRCROOT                 repo root; where .sentryclirc lives
#   CI                      set by GitHub Actions; selects error-vs-warning
#   SENTRY_AUTH_TOKEN       optional, read by sentry-cli itself
#
# Tested by scripts/tests/test-upload-debug-symbols.sh.

set -uo pipefail

export SENTRY_ORG="wxyc"
export SENTRY_PROJECT="wxyc-dj-ios"

# sentry-cli resolves .sentryclirc relative to the working directory, so pin
# the working directory to the repo root rather than inheriting whatever
# Xcode happened to leave it at. This is how every dev Mac authenticates.
if [[ -d "${SRCROOT:-}" ]]; then
    cd "$SRCROOT" || exit 1
fi
readonly REPO_ROOT="$PWD"

# Am I on a build runner? wxyc-ios-64's version of this check also consults
# an on-disk marker file, because it can't fully trust $CI to reach a
# run-script phase nested inside xcodebuild on an Xcode Cloud runner. This
# repo has no Xcode Cloud and no ci_post_clone.sh to write such a marker --
# its only CI is GitHub Actions running `xcodebuild test` as an ordinary
# shell step, where $CI is inherited environment all the way down into this
# build phase like any other variable. Re-add a marker (see wxyc-ios-64's
# is_ci() for the pattern) if this repo ever runs on Xcode Cloud.
#
# GitHub Actions sets CI=true, Xcode Cloud sets CI=TRUE, and some tools set
# CI=false to mean "not CI" -- which a bare emptiness test would read
# backwards.
is_ci() {
    case "${${CI:-}:l}" in
        "" | false | 0 | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

# Every failure below has the same shape: on CI it stops the build, locally it
# does not. Writing that out at each site is how the asymmetry this script
# exists to establish would end up holding at only some of them.
#
# $1 is the CI diagnostic -- long, and it names the fix, because Xcode's issue
# navigator shows one line and nothing around it. $2 is the whole local line,
# prefix included, since some of these are a `note:` rather than a `warning:`.
fail_or_continue() {
    if is_ci; then
        echo "error: $1"
        exit 1
    fi
    echo "$2"
    exit 0
}

# Can this build reach a user? xcodebuild sets ACTION=install when archiving,
# and every configuration that ships anything is named without a Debug
# prefix. WXYCDJ has just Debug and Release today, but this matches by
# prefix rather than equality -- the pattern wxyc-ios-64 needed for its
# "Debug TestFlight" scheme configuration -- so any future Debug-flavored
# configuration is classified correctly with no script change.
#
# The presence of dSYMs is NOT the test either. A Debug build with
# DEBUG_INFORMATION_FORMAT switched to dwarf-with-dsym would populate
# DWARF_DSYM_FOLDER_PATH exactly like an archive does.
#
# No CONFIGURATION at all is treated as shipping. A spurious CI failure is
# loud and gets fixed in an afternoon; a skipped upload is silent and is the
# whole reason this script exists.
is_shipping_build() {
    [[ "${ACTION:-}" == "install" ]] && return 0
    [[ "${CONFIGURATION:-}" == Debug* ]] && return 1
    return 0
}

# Where the binary might be. Unlike wxyc-ios-64, nothing here vendors a copy
# into the checkout -- there is no ci_scripts/install-sentry-cli.sh, because
# there is no runner that needs one yet -- so this only ever checks PATH,
# which is how sentry-cli gets onto a dev Mac (Homebrew, or the upstream
# installer).
resolve_sentry_cli() {
    command -v sentry-cli 2>/dev/null
}

# sentry-cli takes credentials from SENTRY_AUTH_TOKEN or from a .sentryclirc in
# the working directory or the home directory. Checking first only buys a
# better diagnostic than the CLI's own -- but "no token" and "token rejected"
# have completely different fixes, and the build log is where that gets read.
#
# An rc file counts only when it actually carries a token: an empty or
# [defaults]-only file otherwise reaches the upload and dies with sentry-
# cli's generic message instead of the one naming the fix.
has_credentials() {
    [[ -n "${SENTRY_AUTH_TOKEN:-}" ]] && return 0
    local rc
    for rc in "${REPO_ROOT}/.sentryclirc" "${HOME:-}/.sentryclirc"; do
        [[ -f "$rc" ]] && grep -q '^[[:space:]]*token[[:space:]]*=' "$rc" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 1. Is this a build whose symbols anyone will need?
#
# A CI runner's Debug build reports no events to Sentry, so uploading its
# dSYMs only pads the debug-file list. Skip outright rather than upload-and-
# ignore-failures, which would put a network call on the critical path of
# every test workflow. Locally the upload still runs on every build: a
# developer's simulator crashes do reach Sentry and are worth symbolicating.
#
# This comes before the dSYM check, not after, so that everything below can
# read "is_ci" as "is_ci and this build ships".
# ---------------------------------------------------------------------------

if is_ci && ! is_shipping_build; then
    echo "note: ${CONFIGURATION:-unknown}/${ACTION:-unknown} build on CI does not ship; skipping Sentry debug-symbol upload"
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Did this build produce anything to upload?
#
# Locally this is unremarkable -- nothing to upload, nothing to say. On a
# shipping CI build it is a failure: WXYCDJ's Release configuration builds
# with the Xcode default DEBUG_INFORMATION_FORMAT = dwarf-with-dsym, so an
# archive with an empty folder means a build setting moved, dsymutil failed,
# or the path changed. Passing that through as a note would reintroduce the
# same silent-failure shape this script exists to close.
# ---------------------------------------------------------------------------

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
    fail_or_continue \
        "this build ships but produced no debug symbols to upload (${missing_dsyms}), so its Sentry events would arrive unsymbolicated. WXYCDJ's Release configuration builds with the Xcode default DEBUG_INFORMATION_FORMAT = dwarf-with-dsym, so an empty dSYM folder means something upstream of this phase changed." \
        "note: ${missing_dsyms}; skipping Sentry debug-symbol upload"
fi

# ---------------------------------------------------------------------------
# 3. Is there a binary to run?
#
# This check does not split on is_ci the way the others here do -- there is
# no CI job in this repo that ships a build yet, and no installer script for
# a CI failure message to point at, so failing a build over a tool nobody
# has a way to install automatically would only be noise. It always warns
# and continues, on a dev Mac and in CI alike.
#
# When a release pipeline is added to this repo -- with its own way of
# getting sentry-cli onto the runner, the way wxyc-ios-64's ci_scripts/
# install-sentry-cli.sh does -- swap this block for a fail_or_continue call
# like the checks above and below it, so a shipping CI build that still
# can't find sentry-cli fails loudly instead of shipping silently
# unsymbolicated.
# ---------------------------------------------------------------------------

if ! sentry_cli=$(resolve_sentry_cli); then
    echo "warning: sentry-cli not installed, skipping debug symbol upload. Install it with \`brew install getsentry/tools/sentry-cli\` -- see https://docs.sentry.io/cli/installation/."
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Is there anything to authenticate with?
# ---------------------------------------------------------------------------

if ! has_credentials; then
    fail_or_continue \
        "no Sentry credentials available (neither SENTRY_AUTH_TOKEN nor a .sentryclirc carrying a token), so this build's dSYMs cannot reach Sentry. Set SENTRY_AUTH_TOKEN as a secret environment variable on the CI workflow that builds this configuration; see README.md's dSYM upload section." \
        "warning: no Sentry credentials (SENTRY_AUTH_TOKEN or .sentryclirc), skipping debug symbol upload"
fi

# ---------------------------------------------------------------------------
# 5. Upload.
# ---------------------------------------------------------------------------

# Split the streams: sentry-cli's stdout (what it uploaded, which debug IDs)
# belongs in the build log unconditionally, while its stderr is captured so
# the failure message can ride on the `error:`/`warning:` line itself -- Xcode's
# issue navigator shows that one line and nothing around it, and "upload
# failed, see above" is exactly the kind of diagnostic that gets ignored.
# The fd 3 dance is what makes stdout escape the command substitution.
{
    upload_error=$("$sentry_cli" debug-files upload --include-sources "$dsym_folder" 2>&1 >&3 3>&-)
    upload_status=$?
} 3>&1

if (( upload_status != 0 )); then
    # Collapse to one line: a multi-line diagnostic only prefixes its first
    # line, so everything after the newline would lose the error: marker.
    summary="${upload_error//$'\n'/ }"
    fail_or_continue "sentry-cli - ${summary}" "warning: sentry-cli - ${summary}"
fi

# No count here: sentry-cli walks the whole folder and uploads every debug
# file it recognizes, not just the .dSYM bundles this script counted to decide
# whether to run at all. Its own output above is the accurate inventory.
echo "note: uploaded debug symbols to Sentry (${SENTRY_ORG}/${SENTRY_PROJECT})"
exit 0
