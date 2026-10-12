#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?需要 vX.Y.Z 标签}"
repository="${GITHUB_REPOSITORY:?需要指定 GitHub 仓库}"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo '只发布 vX.Y.Z 正式版本标签。' >&2; exit 2;
}
commit=$(git rev-parse HEAD)
[ "$(git rev-list -n 1 "$tag")" = "$commit" ]
git fetch --no-tags origin main
git merge-base --is-ancestor "$commit" origin/main || {
    echo '发布提交必须属于 main。' >&2; exit 1;
}
runs=$(gh api "repos/$repository/actions/workflows/ci.yml/runs?event=push&branch=main&head_sha=$commit&per_page=100")
state=$(printf '%s\n' "$runs" | jq -r --arg sha "$commit" \
    '[.workflow_runs[] | select(.head_sha == $sha and .event == "push" and .head_branch == "main")] | sort_by(.run_number) | last | "\(.status):\(.conclusion)"')
[ "$state" = completed:success ] || {
    echo "同一提交的 main CI 尚未成功：$state" >&2; exit 1;
}
tags=$(gh api --paginate "repos/$repository/releases?per_page=100" --jq '.[].tag_name')
printf '%s\n' "$tags" | python3 -c '
import re, sys
tag = sys.argv[1]
version = tuple(map(int, tag[1:].split(".")))
for existing in sys.stdin.read().splitlines():
    if existing == tag or (re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", existing)
                           and tuple(map(int, existing[1:].split("."))) >= version):
        sys.exit("拒绝重复或倒退发布：" + existing)
' "$tag"
printf '发布预检通过：%s @ %s\n' "$tag" "$commit"
