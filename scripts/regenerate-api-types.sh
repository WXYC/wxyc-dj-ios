#!/bin/zsh
#
# regenerate-api-types.sh
# WXYC DJ
#
# Regenerates Packages/WXYCAPIModels/Sources/WXYCAPIModels from wxyc-shared's
# OpenAPI spec (api.yaml). Clones wxyc-shared at the commit pinned in
# Packages/WXYCAPIModels/contract-version.json into a gitignored scratch dir,
# runs its `generate:swift` codegen target (the swift6 generator), then
# rsyncs the generated Models/ and Infrastructure/ directories over the
# vendored package. Infrastructure/ is required even though only Models/ is
# "the point" -- generated models depend on Infrastructure support types
# (JSONValue, CaseIterableDefaultsLast, NumericRule, CodableHelper, date
# formatting). APIs/ (the endpoint clients) is intentionally dropped -- this
# package is models-only; the app's hand-written APIClient stays.
#
# Mirrors wxyc-ios-64's scripts/regenerate-api-types.sh (see its
# docs/code-generation.md) -- ported here for wxyc-dj-ios#75, adjusted for
# this repo's package name (Packages/WXYCAPIModels, not Shared/WXYCAPIModels).
#
# Usage:
#   scripts/regenerate-api-types.sh [options]
#
# Options:
#   --work-dir <path>   Scratch clone location. Default: .build/wxyc-shared-codegen.
#   --remote <url>      wxyc-shared remote to clone. Default: git@github.com:WXYC/wxyc-shared.git.
#   --dest-dir <path>   Where to rsync Models/ + Infrastructure/ into. Default:
#                       Packages/WXYCAPIModels/Sources/WXYCAPIModels (the committed
#                       tree). scripts/verify-api-types.sh overrides this to a
#                       scratch dir so it never touches the committed tree.
#   --keep-work-dir     Don't delete the scratch clone when done (skips a full
#                       re-clone on the next run -- useful for iterating).
#   -h, --help          Show this message.
#
# Reads the pinned commit from Packages/WXYCAPIModels/contract-version.json's
# `wxycSharedSha` field, which is the authoritative pin (the exact commit the
# vendored tree is generated from). `wxycSharedTag` is a human-readable label
# for where that commit lives (e.g. "main" or a "vX.Y.Z" release once one
# includes it) and is NOT read by this script. To vendor a newer wxyc-shared
# contract, update `wxycSharedSha` (and, for legibility, `wxycSharedTag` /
# `apiYamlVersion`) first, then run this script and commit the diff.
#
# Requires: git, npm (+ node), java (openapi-generator-cli runs on the JVM),
# rsync.
#

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
cd "$REPO_ROOT"

PACKAGE_DIR="Packages/WXYCAPIModels"
CONTRACT_FILE="$PACKAGE_DIR/contract-version.json"
DEST_DIR="$PACKAGE_DIR/Sources/WXYCAPIModels"
WORK_DIR=".build/wxyc-shared-codegen"
REMOTE="git@github.com:WXYC/wxyc-shared.git"
KEEP_WORK_DIR=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log()  { print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { print -ru2 -- "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"; exit 1; }

usage() {
    cat <<'EOF'
regenerate-api-types.sh

Regenerates Packages/WXYCAPIModels/Sources/WXYCAPIModels from the wxyc-shared
commit pinned in Packages/WXYCAPIModels/contract-version.json.

Usage:
  scripts/regenerate-api-types.sh [options]

Options:
  --work-dir <path>   Scratch clone location. Default: .build/wxyc-shared-codegen.
  --remote <url>      wxyc-shared remote to clone. Default: git@github.com:WXYC/wxyc-shared.git.
  --dest-dir <path>   Sync destination. Default: Packages/WXYCAPIModels/Sources/WXYCAPIModels.
  --keep-work-dir     Don't delete the scratch clone when done.
  -h, --help          Show this message.
EOF
}

require_value() {
    local flag="$1"
    local remaining="$2"
    if (( remaining < 2 )); then
        fail "option $flag requires a value"
    fi
}

while (( $# > 0 )); do
    case "$1" in
        --work-dir)       require_value "$1" "$#"; WORK_DIR="$2"; shift 2 ;;
        --remote)         require_value "$1" "$#"; REMOTE="$2"; shift 2 ;;
        --dest-dir)       require_value "$1" "$#"; DEST_DIR="$2"; shift 2 ;;
        --keep-work-dir)  KEEP_WORK_DIR=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

for tool in git npm node java rsync; do
    command -v "$tool" > /dev/null 2>&1 || fail "'$tool' is required but not found on PATH"
done

[[ -f "$CONTRACT_FILE" ]] || fail "contract manifest not found: $CONTRACT_FILE"

# Pass the manifest path as argv (not string-interpolated into the JS source),
# so a repo path containing a quote or backslash can't corrupt the program.
SHA=$(node -e 'process.stdout.write(require(process.argv[1]).wxycSharedSha || "")' "$REPO_ROOT/$CONTRACT_FILE")
[[ -n "$SHA" ]] || fail "wxycSharedSha missing or empty in $CONTRACT_FILE"
# Must be a full 40-hex-char commit SHA, not a branch/tag name.
# contract-version.json's sibling `wxycSharedTag` field (e.g. "main") is a
# human-readable label only, deliberately NOT read by this script -- but it
# sits right next to `wxycSharedSha` in the same file, which invites pasting
# a branch name into the wrong field by mistake. `git checkout` accepts a
# branch name just as happily as a SHA, so that mistake wouldn't fail here;
# it would silently turn the pin into a moving target that reddens unrelated
# PRs indistinguishably from real api.yaml drift the next time main advances.
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "wxycSharedSha in $CONTRACT_FILE is not a 40-character hex commit SHA: '$SHA' -- did a branch/tag name (e.g. \"main\") end up in wxycSharedSha instead of wxycSharedTag?"

log "Pinned wxyc-shared commit: $SHA"
log "Remote: $REMOTE"
log "Work dir: $WORK_DIR"

# ---------------------------------------------------------------------------
# Clone (or reuse) wxyc-shared at the pinned commit
# ---------------------------------------------------------------------------

if [[ -d "$WORK_DIR/.git" ]]; then
    log "Reusing existing clone at $WORK_DIR"
    git -C "$WORK_DIR" fetch --quiet origin || fail "fetch in $WORK_DIR failed"
else
    log "Cloning $REMOTE into $WORK_DIR"
    rm -rf "$WORK_DIR"
    mkdir -p "${WORK_DIR:h}"
    git clone --quiet "$REMOTE" "$WORK_DIR" || fail "clone of $REMOTE failed"
fi

log "Checking out $SHA"
git -C "$WORK_DIR" checkout --quiet "$SHA" || fail "checkout of $SHA in $WORK_DIR failed -- does the commit exist on $REMOTE?"

# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------

log "Installing wxyc-shared dependencies (npm ci)"
(cd "$WORK_DIR" && npm ci --silent) || fail "npm ci failed in $WORK_DIR"

# generated/ is gitignored in wxyc-shared, so a --keep-work-dir-reused clone
# never has it cleaned by `git checkout`. The generator itself doesn't prune
# stale output either -- a schema deleted upstream since the last run would
# linger here and get rsynced into the vendored tree below as if it were
# still current.
rm -rf "$WORK_DIR/generated"

log "Running npm run generate:swift"
(cd "$WORK_DIR" && npm run generate:swift) || fail "npm run generate:swift failed in $WORK_DIR"

GENERATED_ROOT="$WORK_DIR/generated/swift/Sources/WXYCAPI"
[[ -d "$GENERATED_ROOT/Models" ]] || fail "generated Models/ not found at $GENERATED_ROOT -- did the generator's SPM file layout change?"
[[ -d "$GENERATED_ROOT/Infrastructure" ]] || fail "generated Infrastructure/ not found at $GENERATED_ROOT"

# ---------------------------------------------------------------------------
# Sync Models/ into the vendored package (APIs/ intentionally excluded --
# this package is models-only)
# ---------------------------------------------------------------------------

log "Syncing Models/ into $DEST_DIR"
mkdir -p "$DEST_DIR/Models"
rsync -a --delete "$GENERATED_ROOT/Models/" "$DEST_DIR/Models/" || fail "rsync of Models/ failed"

# HealthCheckResponse is vendored like every other api.yaml schema (this
# package doesn't hand-pick a subset of Models/ -- see the CLAUDE.md "Code
# Generation" section) with one narrow exception: it's the only schema in
# the entire spec whose `additionalProperties: true` support needs a
# String-keyed container (`encoder.container(keyedBy: String.self)`), which
# only compiles if `String` conforms to `CodingKey` -- and that conformance
# (previously supplied by Infrastructure/Extensions.swift's
# `extension String: @retroactive CodingKey`) is unsafe (see the
# Infrastructure/ curation comment below). wxyc-dj-ios never calls a
# `/health`-shaped endpoint, so rather than reintroducing the unsafe
# conformance to satisfy one irrelevant schema, HealthCheckResponse is
# dropped here. Re-evaluate if this app ever needs it.
rm -f "$DEST_DIR/Models/HealthCheckResponse.swift"

# ---------------------------------------------------------------------------
# Sync a curated Infrastructure/ subset (wxyc-dj-ios#75 review finding F3)
# ---------------------------------------------------------------------------
#
# The generator emits ~2,171 lines under Infrastructure/, of which ~1,600 are
# an unused HTTP client this models-only package never calls:
# URLSessionImplementations.swift (URLSession request builder, a URLSession
# auth-challenge delegate, and a process-global mutable credential store)
# plus its supporting cast APIs.swift, APIHelper.swift, JSONDataEncoding.swift,
# JSONEncodingHelper.swift, and SynchronizedDictionary.swift.
#
# Infrastructure/Extensions.swift is worse than merely unused: it declares
# `extension String: @retroactive CodingKey`, which adds a
# `String.init?(intValue: Int)` that unconditionally returns nil. That
# initializer silently wins Swift's overload resolution over the normal
# `String.init<Subject: CustomStringConvertible>(_:)` wherever `String.init`
# is referenced as a bare function value over an Int -- e.g.
# `[1, 2, 3].map(String.init)` becomes `[nil, nil, nil]`, verified empirically
# (`swift -e` against the exact generated conformance body). It compiles
# clean and produces silently wrong data, and the conformance leaks to every
# file in the app the moment WXYCAPIModels is linked in (no import required
# at the use site, since Swift conformances are visible process-wide once the
# defining module is anywhere in the build graph). Zero of the 257 Models/
# files reference anything else Extensions.swift provides
# (`ParameterConvertible` and friends), so it is excluded outright.
#
# Infrastructure/Models.swift (confusingly the same name as the Models/
# directory -- this is the generator's static support-type file, emitted
# unconditionally regardless of api.yaml content, distinct from the
# per-schema files under Models/) supplies CaseIterableDefaultsLast,
# UnknownCaseCheckable, and NullEncodable, which Models/ genuinely needs
# (115 references). It also declares a trailing `RequestTask` class that
# exists only to support the excluded APIs/ output -- it references
# `URLSessionDataTaskProtocol`, declared only in the also-excluded
# URLSessionImplementations.swift, and grep confirms zero callers anywhere
# in Models/. Rather than pull the whole HTTP client back in to satisfy one
# dead class, RequestTask is stripped from the vendored copy below (a
# scripted, reproducible transform -- never a hand-edit of the committed
# tree).
INFRA_KEEP=(Models.swift Validation.swift JSONValue.swift CodableHelper.swift OpenAPIMutex.swift OpenISO8601DateFormatter.swift)
log "Syncing curated Infrastructure/ subset into $DEST_DIR: ${INFRA_KEEP[*]}"
rm -rf "$DEST_DIR/Infrastructure"
mkdir -p "$DEST_DIR/Infrastructure"
for f in "${INFRA_KEEP[@]}"; do
    [[ -f "$GENERATED_ROOT/Infrastructure/$f" ]] || fail "expected generated Infrastructure/$f not found -- did the generator's output change?"
    cp "$GENERATED_ROOT/Infrastructure/$f" "$DEST_DIR/Infrastructure/$f"
done

MODELS_INFRA="$DEST_DIR/Infrastructure/Models.swift"
REQUEST_TASK_MARKER='public final class RequestTask: @unchecked Sendable {'
if ! grep -qF "$REQUEST_TASK_MARKER" "$MODELS_INFRA"; then
    fail "RequestTask class not found at its expected declaration in $MODELS_INFRA -- generator output changed; update the strip logic in $0"
fi
# RequestTask is the last top-level declaration the generator emits in this
# file; truncate at its declaration line, dropping the blank line
# immediately before it too. (A one-line-delayed buffer, tracked with an
# explicit `have_buffered` flag rather than the buffered line's truthiness --
# the file has other blank lines mid-file that a truthiness check would
# also, wrongly, eat.)
awk -v marker="$REQUEST_TASK_MARKER" '
    $0 == marker { exit }
    { if (have_buffered) print buffered; buffered = $0; have_buffered = 1 }
' "$MODELS_INFRA" > "$MODELS_INFRA.stripped"
mv "$MODELS_INFRA.stripped" "$MODELS_INFRA"
if grep -qE 'RequestTask|URLSessionDataTaskProtocol' "$MODELS_INFRA"; then
    fail "RequestTask strip left a dangling reference in $MODELS_INFRA -- generator output changed; update the strip logic in $0"
fi

if (( KEEP_WORK_DIR == 0 )); then
    log "Cleaning up $WORK_DIR"
    rm -rf "$WORK_DIR"
else
    log "Leaving scratch clone in place at $WORK_DIR (--keep-work-dir)"
fi

FILE_COUNT=$(find "$DEST_DIR" -name '*.swift' | wc -l | tr -d ' ')
(( FILE_COUNT > 0 )) || fail "0 Swift files vendored into $DEST_DIR -- an empty generate would otherwise have just rsync --delete'd the committed tree away"
log "Done. $FILE_COUNT Swift files vendored into $DEST_DIR"
