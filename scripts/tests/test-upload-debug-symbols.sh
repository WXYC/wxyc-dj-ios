#!/bin/zsh
#
# test-upload-debug-symbols.sh
#
# Black-box regression test for scripts/upload-debug-symbols.sh -- the script
# the "Upload Debug Symbols to Sentry" build phase runs.
#
# Adapted from wxyc-ios-64's scripts/tests/test-upload-debug-symbols.sh
# (issue #107). Most of its behavior carries over unchanged: dSYM-folder and
# credentials failures still split on CI/local exactly as there. Two things
# differ, both because this repo has no release pipeline:
#
#   sentry-cli is resolved from PATH only (no vendored .ci-tools/bin copy),
#   so the stub below is installed on PATH rather than at a fixed checkout-
#   relative path.
#
#   A missing sentry-cli is *always* a warning, never an error -- there is
#   no installer script for a CI failure message to point at yet, so Case 2
#   below has one shape instead of a CI/local pair. See
#   scripts/upload-debug-symbols.sh's resolve_sentry_cli() comment for when
#   that returns.
#
# wxyc-ios-64's suite also pins an on-disk `.ci-tools/ci-runner` CI marker
# (its Case 8); that marker exists to work around Xcode Cloud's uncertain
# environment-variable propagation into a nested run-script phase, which
# does not apply to this repo's GitHub-Actions-only CI, so there is no
# marker here and no equivalent case.
#
# The stub sentry-cli records its argv and the Sentry-relevant environment so
# the tests can assert the upload is invoked against the right org/project
# without touching the network or needing a real auth token.
#
# Run directly:
#   zsh scripts/tests/test-upload-debug-symbols.sh

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
REAL_SCRIPT="${REPO_ROOT}/scripts/upload-debug-symbols.sh"

if [[ ! -f "$REAL_SCRIPT" ]]; then
    echo "Cannot find scripts/upload-debug-symbols.sh at $REAL_SCRIPT" >&2
    exit 2
fi

source "${REPO_ROOT}/scripts/tests/harness.zsh"

# -----------------------------------------------------------------------
# Fixture
#
# Each case gets a throwaway SRCROOT and HOME. HOME matters: sentry-cli
# reads ~/.sentryclirc, and so does the credential precheck, so a developer
# running this suite on a machine with a real token must not have their own
# config decide the outcome of the "no credentials" cases.
# -----------------------------------------------------------------------

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

# A dSYM folder shaped like the one an archive produces.
DSYM_DIR="$FIXTURE/dsyms"
mkdir -p "$DSYM_DIR/WXYCDJ.app.dSYM/Contents/Resources/DWARF"
echo "not really mach-o" > "$DSYM_DIR/WXYCDJ.app.dSYM/Contents/Resources/DWARF/WXYCDJ"

# A dSYM folder path that the build setting names but that no build populated
# -- what a Debug build leaves behind.
EMPTY_DSYM_DIR="$FIXTURE/dsyms-empty"
mkdir -p "$EMPTY_DSYM_DIR"

# Stub sentry-cli. Writes its argv and the Sentry environment it was handed
# to $STUB_LOG, and fails when $STUB_FAIL is set so the failure paths can be
# exercised without a network. Installed at $CASE_STUB_BIN/sentry-cli, which
# run_script puts at the front of PATH -- resolve_sentry_cli() in the real
# script only ever checks PATH (there is no vendored .ci-tools/bin copy in
# this repo), so this is the one place a "resolvable" sentry-cli can come
# from in these tests.
make_stub() {
    local stub_path="$CASE_STUB_BIN/sentry-cli"
    mkdir -p "${stub_path:h}"
    cat > "$stub_path" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then
    echo "sentry-cli 9.9.9"
    exit 0
fi
{
    echo "argv: $*"
    echo "SENTRY_ORG=${SENTRY_ORG:-}"
    echo "SENTRY_PROJECT=${SENTRY_PROJECT:-}"
    echo "SENTRY_AUTH_TOKEN=${SENTRY_AUTH_TOKEN:-}"
} >> "$STUB_LOG"
if [ -n "${STUB_FAIL:-}" ]; then
    echo "an org auth token is required for this command" >&2
    echo "some chatter on stdout"
    exit 1
fi
echo "Uploaded 1 debug information file"
exit 0
STUB
    chmod +x "$stub_path"
}

# Runs the real script in a hermetic environment. Every knob the script reads
# is passed explicitly; PATH is narrowed to the system directories (plus this
# case's stub directory) so a real sentry-cli in /usr/local/bin can never
# satisfy a case that is meant to run without one.
#
# CONFIGURATION and ACTION default to an archive's values (Release/install),
# because that is the build the strict behavior is about. Cases that want a
# Debug or plain-build environment set CASE_CONFIGURATION / CASE_ACTION; a case
# that unsets them gets a child environment with those variables genuinely
# absent, which is a distinct branch in the script and needs a distinct
# fixture. Building the assignments into an array is the only way to express
# that through `env -i`: a `CONFIGURATION="${CASE_CONFIGURATION-Release}"`
# argument substitutes the default *precisely when the variable is unset*, so
# the absent case would silently test the same thing as the default one.
run_script() {
    # usage: run_script <dsym-folder> <CI value> <token>. HOME and SRCROOT come
    # from whichever case new_case just set up -- every call site passed them
    # straight back, which buried the two arguments that actually vary.
    local dsym_folder="$1" ci="$2" token="$3"
    local -a build_settings=()
    [[ -n "${CASE_CONFIGURATION+set}" ]] && build_settings+=("CONFIGURATION=${CASE_CONFIGURATION}")
    [[ -n "${CASE_ACTION+set}" ]] && build_settings+=("ACTION=${CASE_ACTION}")

    env -i \
        PATH="${CASE_STUB_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$CASE_HOME" \
        SRCROOT="$CASE_SRCROOT" \
        DWARF_DSYM_FOLDER_PATH="$dsym_folder" \
        CI="$ci" \
        SENTRY_AUTH_TOKEN="$token" \
        "${build_settings[@]}" \
        STUB_LOG="$STUB_LOG" \
        STUB_FAIL="$STUB_FAIL" \
        /bin/zsh "$REAL_SCRIPT" 2>&1
}

new_case() {
    local name="$1"
    CASE_HOME="$FIXTURE/$name/home"
    CASE_SRCROOT="$FIXTURE/$name/srcroot"
    CASE_STUB_BIN="$FIXTURE/$name/stub-bin"
    mkdir -p "$CASE_HOME" "$CASE_SRCROOT"
    STUB_LOG="$FIXTURE/$name/stub.log"
    : > "$STUB_LOG"
    STUB_FAIL=""
    CASE_CONFIGURATION="Release"
    CASE_ACTION="install"
}

# =========================================================================
# Case 1: no dSYMs.
#
# Locally, and on any CI build that cannot ship, this is unremarkable: there
# is nothing to upload, so there is nothing to say. On a CI build that *does*
# ship it is the opposite -- WXYCDJ's Release configuration builds with the
# Xcode default DEBUG_INFORMATION_FORMAT = dwarf-with-dsym, so an archive
# with an empty DWARF_DSYM_FOLDER_PATH means something upstream broke (a
# flipped build setting, a dsymutil failure, a moved path) and the archive is
# about to ship unsymbolicated. Skipping quietly there would be the same
# silent-failure shape this script exists to close, wearing a different hat.
# =========================================================================

echo "=== Case 1: build produced no dSYMs ==="

new_case "no-dsyms-local"
OUT=$(run_script "$EMPTY_DSYM_DIR" "" ""); RC=$?
expect_exit "empty dSYM folder locally exits 0" "$RC" "0" "$OUT"
expect_not_contains "empty dSYM folder locally emits no error:" "$OUT" "error:"
expect_not_contains "empty dSYM folder locally emits no warning:" "$OUT" "warning:"

new_case "no-dsym-path-local"
OUT=$(run_script "" "" ""); RC=$?
expect_exit "unset DWARF_DSYM_FOLDER_PATH locally exits 0" "$RC" "0" "$OUT"
expect_not_contains "unset DWARF_DSYM_FOLDER_PATH locally emits no error:" "$OUT" "error:"

new_case "no-dsyms-ci-nonshipping"
CASE_CONFIGURATION="Debug"
CASE_ACTION="build"
OUT=$(run_script "$EMPTY_DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "empty dSYM folder on a non-shipping CI build exits 0" "$RC" "0" "$OUT"
expect_not_contains "empty dSYM folder on a non-shipping CI build emits no error:" "$OUT" "error:"

new_case "no-dsyms-ci-archive"
OUT=$(run_script "$EMPTY_DSYM_DIR" "TRUE" "sntrys_fake"); RC=$?
expect_exit "an archive that produced no dSYMs fails the build" "$RC" "1" "$OUT"
expect_contains "an archive with no dSYMs is an error:" "$OUT" "error:"
expect_contains "the error names the folder it found empty" "$OUT" "$EMPTY_DSYM_DIR"

new_case "no-dsym-path-ci-archive"
OUT=$(run_script "" "TRUE" "sntrys_fake"); RC=$?
expect_exit "an archive with no DWARF_DSYM_FOLDER_PATH at all fails the build" "$RC" "1" "$OUT"
expect_contains "the missing dSYM folder is an error:" "$OUT" "error:"

new_case "missing-dsym-dir-ci-archive"
OUT=$(run_script "$FIXTURE/does-not-exist" "TRUE" "sntrys_fake"); RC=$?
expect_exit "an archive whose dSYM folder does not exist fails the build" "$RC" "1" "$OUT"

# =========================================================================
# Case 2: dSYMs exist but sentry-cli does not.
#
# Unlike wxyc-ios-64, this is always a warning, never an error: this repo has
# no installer script vendoring sentry-cli onto a CI runner, so there is
# nothing actionable to tell a failed build about. See
# scripts/upload-debug-symbols.sh's resolve_sentry_cli() comment for when
# this should split on CI like the checks around it.
# =========================================================================

echo ""
echo "=== Case 2: dSYMs present, sentry-cli absent ==="

new_case "no-cli-ci"
OUT=$(run_script "$DSYM_DIR" "TRUE" "sntrys_fake"); RC=$?
expect_exit "missing sentry-cli in CI still exits 0" "$RC" "0" "$OUT"
expect_contains "missing sentry-cli in CI is a warning:" "$OUT" "warning:"
expect_not_contains "missing sentry-cli in CI is not an error:" "$OUT" "error:"
expect_contains "the warning names sentry-cli" "$OUT" "sentry-cli"

new_case "no-cli-local"
OUT=$(run_script "$DSYM_DIR" "" "sntrys_fake"); RC=$?
expect_exit "missing sentry-cli locally still exits 0" "$RC" "0" "$OUT"
expect_contains "missing sentry-cli locally is a warning:" "$OUT" "warning:"
expect_not_contains "missing sentry-cli locally is not an error:" "$OUT" "error:"

# =========================================================================
# Case 3: sentry-cli present but no credentials.
#
# The second independent way the old phase went quiet: .sentryclirc is
# gitignored, so a clean checkout has no token and `debug-files upload` had
# nothing to authenticate with.
# =========================================================================

echo ""
echo "=== Case 3: dSYMs present, sentry-cli present, no credentials ==="

new_case "no-token-ci"
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "missing token in CI fails the build" "$RC" "1" "$OUT"
expect_contains "missing token in CI is an error:" "$OUT" "error:"
expect_contains "the error names the env var to set" "$OUT" "SENTRY_AUTH_TOKEN"
NOTOKEN_LOG=$(<"$STUB_LOG")
expect_not_contains "sentry-cli is not invoked at all without credentials" "$NOTOKEN_LOG" "debug-files"

new_case "no-token-local"
make_stub
OUT=$(run_script "$DSYM_DIR" "" ""); RC=$?
expect_exit "missing token locally still exits 0" "$RC" "0" "$OUT"
expect_contains "missing token locally is a warning:" "$OUT" "warning:"
expect_not_contains "missing token locally is not an error:" "$OUT" "error:"

# A repo-root .sentryclirc is how every dev Mac authenticates today. It must
# keep counting as credentials, with no SENTRY_AUTH_TOKEN in the environment.
new_case "sentryclirc-in-srcroot"
make_stub
printf '[auth]\ntoken=sntrys_from_srcroot\n' > "$CASE_SRCROOT/.sentryclirc"
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a .sentryclirc in SRCROOT counts as credentials" "$RC" "0" "$OUT"
expect_contains "the upload runs on the strength of .sentryclirc alone" "$(<"$STUB_LOG")" "debug-files"

# ~/.sentryclirc is a second place a developer's token can live.
new_case "sentryclirc-in-home"
make_stub
printf '[auth]\ntoken=sntrys_from_home\n' > "$CASE_HOME/.sentryclirc"
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a ~/.sentryclirc counts as credentials" "$RC" "0" "$OUT"
expect_contains "the upload runs on the strength of ~/.sentryclirc alone" "$(<"$STUB_LOG")" "debug-files"

# The file existing is not the same claim as a credential existing. Without
# this check, this build reaches the upload and dies with sentry-cli's
# generic "an org auth token is required" instead of the line naming the fix.
new_case "sentryclirc-without-token"
make_stub
printf '[defaults]\norg=wxyc\n' > "$CASE_SRCROOT/.sentryclirc"
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a token-less .sentryclirc does not count as credentials" "$RC" "1" "$OUT"
expect_contains "the token-less rc file still names the variable to set" "$OUT" "SENTRY_AUTH_TOKEN"
expect_not_contains "sentry-cli is never invoked against a token-less rc file" "$(<"$STUB_LOG")" "debug-files"

# =========================================================================
# Case 4: the happy path -- what the upload is actually invoked with.
# =========================================================================

echo ""
echo "=== Case 4: successful upload ==="

new_case "upload-ok"
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" "sntrys_supersecret"); RC=$?
LOG=$(<"$STUB_LOG")
expect_exit "a successful upload exits 0" "$RC" "0" "$OUT"
expect_contains "sentry-cli is resolved from PATH" "$LOG" "argv:"
expect_contains "the subcommand is debug-files upload" "$LOG" "debug-files upload"
expect_contains "sources are included so Sentry can show source context" "$LOG" "--include-sources"
expect_contains "the dSYM folder is passed through" "$LOG" "$DSYM_DIR"
expect_contains "the org is wxyc" "$LOG" "SENTRY_ORG=wxyc"
expect_contains "the project is wxyc-dj-ios" "$LOG" "SENTRY_PROJECT=wxyc-dj-ios"
expect_contains "the token reaches sentry-cli" "$LOG" "SENTRY_AUTH_TOKEN=sntrys_supersecret"
# A build log is an artifact other people read. The token must never be in it.
expect_not_contains "the token is never echoed into the build log" "$OUT" "sntrys_supersecret"

# =========================================================================
# Case 5: sentry-cli runs and rejects the upload.
#
# The third silent path: a token that is expired, revoked, or scoped wrong
# produces a nonzero exit from a binary that is present, and folding that
# into a warning everywhere would hide it in CI too.
# =========================================================================

echo ""
echo "=== Case 5: sentry-cli itself fails ==="

new_case "upload-fails-ci"
make_stub
STUB_FAIL=1
OUT=$(run_script "$DSYM_DIR" "TRUE" "sntrys_expired"); RC=$?
expect_exit "a rejected upload fails the CI build" "$RC" "1" "$OUT"
expect_contains "a rejected upload in CI is an error:" "$OUT" "error:"
expect_contains "sentry-cli's own message survives into the diagnostic" "$OUT" "org auth token is required"

new_case "upload-fails-local"
make_stub
STUB_FAIL=1
OUT=$(run_script "$DSYM_DIR" "" "sntrys_expired"); RC=$?
expect_exit "a rejected upload locally still exits 0" "$RC" "0" "$OUT"
expect_contains "a rejected upload locally is a warning:" "$OUT" "warning:"
expect_not_contains "a rejected upload locally is not an error:" "$OUT" "error:"

# =========================================================================
# Case 6: what counts as CI.
#
# GitHub Actions sets CI=true. Xcode Cloud sets CI=TRUE. Neither of those is
# a value anyone should be pattern-matching by hand, and a bare `[ -n "$CI" ]`
# would read the literal string "false" as CI -- which some tools do set.
#
# Missing credentials (not missing sentry-cli, which is unconditionally a
# warning in this repo -- see Case 2) is the signal used here, since it is
# the cheapest check left that still splits on is_ci().
# =========================================================================

echo ""
echo "=== Case 6: CI detection ==="

for ci_value in TRUE true True 1 YES; do
    new_case "ci-truthy-$ci_value"
    make_stub
    OUT=$(run_script "$DSYM_DIR" "$ci_value" ""); RC=$?
    expect_exit "CI=$ci_value is treated as CI (missing credentials fails)" "$RC" "1" "$OUT"
done

for ci_value in "" false FALSE 0 NO; do
    new_case "ci-falsy-${ci_value:-empty}"
    make_stub
    OUT=$(run_script "$DSYM_DIR" "$ci_value" ""); RC=$?
    expect_exit "CI='${ci_value}' is treated as local (missing credentials warns)" "$RC" "0" "$OUT"
done

# =========================================================================
# Case 7: which CI builds are strict. See is_shipping_build() for the rule
# and why it is a "Debug" prefix rather than an equality.
#
# Local builds are unaffected either way. A developer's Debug dSYMs are worth
# uploading -- Sentry symbolicates simulator events from dev machines -- and
# that behavior predates this script.
# =========================================================================

echo ""
echo "=== Case 7: strictness is scoped to shipping builds ==="

new_case "ci-debug-build"
CASE_CONFIGURATION="Debug"
CASE_ACTION="build"
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a CI Debug build with dSYMs but no credentials still exits 0" "$RC" "0" "$OUT"
expect_not_contains "a CI Debug build does not error" "$OUT" "error:"
expect_not_contains "a CI Debug build does not warn either" "$OUT" "warning:"

new_case "ci-debug-build-skips-upload"
CASE_CONFIGURATION="Debug"
CASE_ACTION="build"
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" "sntrys_fake"); RC=$?
expect_exit "a CI Debug build exits 0 even with everything available" "$RC" "0" "$OUT"
expect_not_contains "a CI Debug build uploads nothing" "$(<"$STUB_LOG")" "debug-files"

# WXYCDJ has only one Debug configuration today, but is_shipping_build()
# matches by prefix rather than equality, so a future Debug-flavored
# configuration -- the pattern wxyc-ios-64 hit with its "Debug TestFlight"
# scheme -- is classified correctly with no script change. Getting this
# wrong would turn every `xcodebuild test` run into a build failure
# demanding a Sentry token nobody gave a test workflow.
new_case "ci-debug-testflight-test"
CASE_CONFIGURATION="Debug TestFlight"
CASE_ACTION="build"
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a CI 'Debug TestFlight' test build with no token still exits 0" "$RC" "0" "$OUT"
expect_not_contains "a CI 'Debug TestFlight' build does not error" "$OUT" "error:"

new_case "ci-debug-testflight-skips-upload"
CASE_CONFIGURATION="Debug TestFlight"
CASE_ACTION="build"
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" "sntrys_fake"); RC=$?
expect_exit "a CI 'Debug TestFlight' build exits 0 with everything available" "$RC" "0" "$OUT"
expect_not_contains "a CI 'Debug TestFlight' build uploads nothing" "$(<"$STUB_LOG")" "debug-files"

# TestFlight (no Debug prefix) is a distribution configuration and must stay
# strict -- the prefix rule must not be read as "anything with TestFlight in
# the name". make_stub is required here (and below) so the strict failure
# comes from the credentials check rather than the always-warns cli check.
new_case "ci-testflight-build"
CASE_CONFIGURATION="TestFlight"
CASE_ACTION="build"
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a CI TestFlight build is strict" "$RC" "1" "$OUT"

new_case "ci-release-build"
CASE_CONFIGURATION="Release"
CASE_ACTION="build"
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a CI Release build is strict even without the archive action" "$RC" "1" "$OUT"

new_case "ci-archive-debug-config"
CASE_CONFIGURATION="Debug"
CASE_ACTION="install"
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a CI archive is strict even at the Debug configuration" "$RC" "1" "$OUT"

# xcodebuild always sets both, but a hand-run script or a future CI change
# might not. An unknown build is treated as shipping: a spurious CI failure
# is loud and gets fixed, a skipped upload is silent and does not.
new_case "ci-unset-build-settings"
unset CASE_CONFIGURATION
unset CASE_ACTION
make_stub
OUT=$(run_script "$DSYM_DIR" "TRUE" ""); RC=$?
expect_exit "a CI build with neither setting is treated as shipping" "$RC" "1" "$OUT"

new_case "local-debug-build"
CASE_CONFIGURATION="Debug"
CASE_ACTION="build"
make_stub
OUT=$(run_script "$DSYM_DIR" "" "sntrys_fake"); RC=$?
expect_exit "a local Debug build still exits 0" "$RC" "0" "$OUT"
expect_contains "a local Debug build still uploads, as it did before" "$(<"$STUB_LOG")" "debug-files"

summarize
