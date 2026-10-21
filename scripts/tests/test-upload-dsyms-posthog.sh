#!/bin/zsh
#
# test-upload-dsyms-posthog.sh
#
# Black-box regression test for scripts/upload-dsyms-posthog.sh -- the script
# the "Upload Debug Symbols to PostHog" build phase runs (issue #235).
#
# The stub posthog-cli records its argv and whether POSTHOG_CLI_API_KEY
# matches the key the case expects, without ever printing the key. HOME is a
# per-case temp dir, so the developer's real ~/.posthog-cli.env never decides
# an outcome.
#
# Run directly:
#   zsh scripts/tests/test-upload-dsyms-posthog.sh

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
REAL_SCRIPT="${REPO_ROOT}/scripts/upload-dsyms-posthog.sh"

if [[ ! -f "$REAL_SCRIPT" ]]; then
    echo "Cannot find scripts/upload-dsyms-posthog.sh at $REAL_SCRIPT" >&2
    exit 2
fi

source "${REPO_ROOT}/scripts/tests/harness.zsh"

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

DSYM_DIR="$FIXTURE/dsyms"
mkdir -p "$DSYM_DIR"

make_stub() {
    mkdir -p "$CASE_STUB_BIN"
    cat > "$CASE_STUB_BIN/posthog-cli" <<'STUB'
#!/bin/sh
{
    echo "argv: $*"
    echo "POSTHOG_CLI_PROJECT_ID=${POSTHOG_CLI_PROJECT_ID:-}"
    if [ "${POSTHOG_CLI_API_KEY:-}" = "${EXPECT_KEY:-}" ]; then echo "key: expected"; else echo "key: unexpected"; fi
} >> "$STUB_LOG"
if [ -n "${STUB_FAIL:-}" ]; then
    echo "upload rejected" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "$CASE_STUB_BIN/posthog-cli"
}

new_case() {
    CASE_HOME="$FIXTURE/$1/home"
    CASE_STUB_BIN="$FIXTURE/$1/bin"
    STUB_LOG="$FIXTURE/$1/stub.log"
    mkdir -p "$CASE_HOME" "$CASE_STUB_BIN"
    : > "$STUB_LOG"
    STUB_FAIL=""
    EXPECT_KEY=""
    unset CASE_ENV_KEY
}

# usage: run_script  -- reads CASE_ENV_KEY (unset = absent from the child env)
# PATH is narrowed to system dirs plus the case's stub dir, and the extra
# search dirs are pointed at the (empty) stub dir, so a real Homebrew
# posthog-cli can never satisfy a case meant to run without one.
run_script() {
    local -a key=()
    [[ -n "${CASE_ENV_KEY+set}" ]] && key+=("POSTHOG_CLI_API_KEY=${CASE_ENV_KEY}")
    env -i \
        PATH="${CASE_STUB_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$CASE_HOME" \
        DWARF_DSYM_FOLDER_PATH="$DSYM_DIR" \
        POSTHOG_CLI_SEARCH_DIRS="$CASE_STUB_BIN" \
        STUB_LOG="$STUB_LOG" STUB_FAIL="$STUB_FAIL" EXPECT_KEY="$EXPECT_KEY" \
        "${key[@]}" \
        /bin/zsh "$REAL_SCRIPT" 2>&1
}

new_case "cli-missing"
CASE_ENV_KEY="phx_key"
OUT=$(run_script); RC=$?
expect_exit "a missing posthog-cli exits 0" "$RC" "0" "$OUT"
expect_contains "a missing posthog-cli warns with the install command" "$OUT" "warning: posthog-cli not found"
expect_contains "the warning names the brew install" "$OUT" "brew install posthog/tap/posthog-cli"
expect_eq "no upload is attempted" "$(<"$STUB_LOG")" ""

new_case "no-key"
make_stub
OUT=$(run_script); RC=$?
expect_exit "no key anywhere exits 0" "$RC" "0" "$OUT"
expect_contains "no key warns" "$OUT" "warning: "
expect_contains "the warning names ~/.posthog-cli.env" "$OUT" "~/.posthog-cli.env"
expect_eq "no upload is attempted without a key" "$(<"$STUB_LOG")" ""

new_case "key-from-env-file"
make_stub
echo 'POSTHOG_CLI_API_KEY=phx_file' > "$CASE_HOME/.posthog-cli.env"
EXPECT_KEY="phx_file"
OUT=$(run_script); RC=$?
expect_exit "a key only in the env file exits 0" "$RC" "0" "$OUT"
expect_contains "the env file's key is loaded and the upload runs" "$(<"$STUB_LOG")" "key: expected"

new_case "env-key-wins"
make_stub
echo 'POSTHOG_CLI_API_KEY=phx_file' > "$CASE_HOME/.posthog-cli.env"
CASE_ENV_KEY="phx_env"
EXPECT_KEY="phx_env"
OUT=$(run_script); RC=$?
expect_exit "a key in both places exits 0" "$RC" "0" "$OUT"
expect_contains "the environment's key wins over the file's" "$(<"$STUB_LOG")" "key: expected"

new_case "upload-shape"
make_stub
CASE_ENV_KEY="phx_env"
EXPECT_KEY="phx_env"
OUT=$(run_script); RC=$?
LOG="$(<"$STUB_LOG")"
expect_contains "the upload argv is exactly dsym upload --directory <dir> --include-source" "$LOG" "argv: dsym upload --directory $DSYM_DIR --include-source"
expect_not_contains "no release flags are passed" "$LOG" "--release"
expect_contains "the project id is exported" "$LOG" "POSTHOG_CLI_PROJECT_ID=444958"
expect_not_contains "the key is never echoed" "$OUT" "phx_env"

new_case "upload-fails"
make_stub
CASE_ENV_KEY="phx_env"
EXPECT_KEY="phx_env"
STUB_FAIL=1
OUT=$(run_script); RC=$?
expect_exit "a failing upload still exits 0" "$RC" "0" "$OUT"
expect_contains "a failing upload warns" "$OUT" "warning: posthog-cli dsym upload failed"

summarize
