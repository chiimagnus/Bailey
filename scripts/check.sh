#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = "--help" ]; }; then
    cat <<'USAGE'
用法：bash scripts/check.sh <检查名称> [更多检查名称]

独立检查：
  dock-workspace  session-snapshot  file-tree-navigation  settings
  git-execution  git-panel-state  remote-commands  remote-lifetime
  panel-targets  tree-row-hit-testing

需要先构建 Debug App：
  workspace-identity  pane-retention

检查使用临时数据或受控后端；不连接真实 SSH 主机。
tree-row-hit-testing 和 pane-retention 需要 macOS 图形会话。
USAGE
    exit 0
fi

compile_and_run() {
    local name="$1"
    shift
    xcrun swiftc -swift-version 5 -o "build/check-$name" "$@" "scripts/check-$name.swift"
    "build/check-$name"
}

mkdir -p build
for name in "$@"; do
    printf '\n检查：%s\n' "$name"
    case "$name" in
        dock-workspace)
            compile_and_run "$name" kero/Workspace/DockWorkspaceModel.swift
            ;;
        session-snapshot)
            compile_and_run "$name" kero/Workspace/DockWorkspaceModel.swift kero/Workspace/SessionStore.swift
            ;;
        file-tree-navigation)
            compile_and_run "$name" kero/Workspace/WorkspaceBackend.swift kero/Workspace/LocalWorkspaceBackend.swift \
                kero/Shared/Tree/TreeDisplayModel.swift kero/Files/FileTreeModel.swift
            ;;
        settings)
            compile_and_run "$name" kero/App/AppSettings.swift kero/Workspace/DockWorkspaceModel.swift
            ;;
        git-execution)
            compile_and_run "$name" kero/Workspace/WorkspaceBackend.swift kero/Workspace/LocalWorkspaceBackend.swift \
                kero/Git/GitCommandExecution.swift
            ;;
        git-panel-state)
            compile_and_run "$name" kero/Workspace/WorkspaceBackend.swift kero/Workspace/LocalWorkspaceBackend.swift \
                kero/Remote/RemoteCommands.swift kero/Shared/Tree/TreeDisplayModel.swift \
                kero/Git/GitCommandExecution.swift kero/Git/GitStatusModel.swift
            ;;
        remote-commands)
            compile_and_run "$name" kero/Workspace/WorkspaceBackend.swift kero/Workspace/LocalWorkspaceBackend.swift \
                kero/Remote/RemoteCommands.swift
            ;;
        remote-lifetime)
            compile_and_run "$name" kero/Workspace/WorkspaceBackend.swift kero/Workspace/LocalWorkspaceBackend.swift \
                kero/Remote/RemoteCommands.swift kero/Remote/SSHWorkspaceBackend.swift \
                kero/Remote/RemoteConnection.swift kero/Remote/PortForwardController.swift
            ;;
        panel-targets)
            compile_and_run "$name" kero/Workspace/WorkspaceBackend.swift kero/Workspace/LocalWorkspaceBackend.swift \
                kero/Workspace/PanelContext.swift kero/Remote/RemoteCommands.swift kero/Remote/SSHWorkspaceBackend.swift \
                kero/Remote/RemoteConnection.swift kero/Remote/PortForwardController.swift \
                kero/Shared/Tree/TreeDisplayModel.swift kero/Files/FileTreeModel.swift
            ;;
        tree-row-hit-testing)
            compile_and_run "$name" kero/Shared/Tree/TreeDisplayModel.swift kero/Shared/Tree/TreeRowStyle.swift
            ;;
        workspace-identity|pane-retention)
            if [ ! -f build/DerivedData/Build/Products/Debug/Kero.app/Contents/MacOS/kero.debug.dylib ]; then
                printf '请先按 AGENTS.md 构建 Debug App。\n' >&2
                exit 1
            fi
            bash "scripts/check-$name.sh"
            ;;
        *)
            printf '未知检查：%s；用 --help 查看名称。\n' "$name" >&2
            exit 2
            ;;
    esac
done
