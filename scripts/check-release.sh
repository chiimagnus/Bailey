#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir "$temporary/bin"
cat > "$temporary/bin/git" <<'SCRIPT'
#!/bin/bash
case "$1" in
    rev-parse) printf '%s\n' 0123456789012345678901234567890123456789 ;;
    rev-list) printf '%s\n' "${TEST_TAG_COMMIT:-0123456789012345678901234567890123456789}" ;;
    fetch) exit 0 ;;
    merge-base) exit "${TEST_ANCESTRY_STATUS:-0}" ;;
    *) exit 99 ;;
esac
SCRIPT
cat > "$temporary/bin/gh" <<'SCRIPT'
#!/bin/bash
case "$*" in
    *actions/workflows/ci.yml/runs*)
        if [ "${TEST_API_FAILURE:-0}" = 1 ]; then exit 1; fi
        printf '%s\n' "$TEST_CI_RUNS"
        ;;
    *releases*)
        if [ "${TEST_RELEASE_API_FAILURE:-0}" = 1 ]; then exit 1; fi
        printf '%s\n' "${TEST_RELEASE_TAGS:-}"
        ;;
    *) exit 99 ;;
esac
SCRIPT
chmod +x "$temporary/bin/git" "$temporary/bin/gh"
export PATH="$temporary/bin:$PATH" GITHUB_REPOSITORY=fixture/kero
success='{"workflow_runs":[{"head_sha":"0123456789012345678901234567890123456789","event":"push","head_branch":"main","run_number":1,"status":"completed","conclusion":"success"}]}'
export TEST_CI_RUNS="$success"

expect() {
    local wanted="$1" tag="$2" result=0
    bash "$root/scripts/release-preflight.sh" "$tag" > "$temporary/output" 2>&1 || result=$?
    if { [ "$wanted" = pass ] && [ "$result" != 0 ]; } || { [ "$wanted" = fail ] && [ "$result" = 0 ]; }; then
        cat "$temporary/output" >&2
        echo "发布预检不符合预期：$wanted $tag" >&2
        exit 1
    fi
}

expect pass v1.2.3
expect fail v01.2.3
expect fail v1.2.3-beta
export TEST_TAG_COMMIT=9999999999999999999999999999999999999999
expect fail v1.2.3
unset TEST_TAG_COMMIT
export TEST_ANCESTRY_STATUS=1
expect fail v1.2.3
export TEST_ANCESTRY_STATUS=0 TEST_CI_RUNS='{"workflow_runs":[]}'
expect fail v1.2.3
export TEST_CI_RUNS="$(printf '%s' "$success" | sed 's/"success"/"failure"/')"
expect fail v1.2.3
export TEST_CI_RUNS="$(printf '%s' "$success" | jq '.workflow_runs += [.workflow_runs[0] | .run_number = 2 | .conclusion = "failure"]')"
expect fail v1.2.3
export TEST_CI_RUNS="$(printf '%s' "$success" | sed 's/"main"/"other"/')"
expect fail v1.2.3
export TEST_CI_RUNS="$(printf '%s' "$success" | sed 's/0123456789012345678901234567890123456789/9999999999999999999999999999999999999999/')"
expect fail v1.2.3
export TEST_CI_RUNS="$success" TEST_API_FAILURE=1
expect fail v1.2.3
export TEST_API_FAILURE=0 TEST_RELEASE_API_FAILURE=1
expect fail v1.2.3
export TEST_RELEASE_API_FAILURE=0 TEST_RELEASE_TAGS=v1.2.3
expect fail v1.2.3
export TEST_RELEASE_TAGS=v1.10.0
expect fail v1.2.3
export TEST_RELEASE_TAGS=v1.2.2
expect pass v1.2.3

if (unset SIGNING_IDENTITY SIGNING_TEAM; bash scripts/build-app.sh stable release) > "$temporary/signing" 2>&1; then
    echo '缺少签名凭据却继续构建' >&2; exit 1
fi
if SIGNING_IDENTITY=0000000000000000000000000000000000000000 SIGNING_TEAM=RDQHYSDFFG \
    bash scripts/build-app.sh stable release > "$temporary/signing" 2>&1; then
    echo '不存在的证书却继续构建' >&2; exit 1
fi
printf 'PASS: release tag, main ancestry, exact-SHA CI, API failures, duplicate/version order and missing signing credentials\n'
