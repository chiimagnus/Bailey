# Audit P1 - app-variants-release

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/app-variants-release/`
- 粒度：`phase`

## 任务看板

- [x] P1-T1 两种构建及完整数据隔离

## 任务到文件的映射

- P1-T1
  - `kero/App/AppIdentity.swift`、AppSettings、SessionStore、TerminalHistoryStore、TunnelPIDFile
  - `kero.xcodeproj`、Info.plist、InfoPlist/ServicesMenu 双语目录、scripts/check*.sh

## 发现项

无阻塞发现。所有数据汇聚点已沿源码核对，旧 dispatch queue 标签不参与应用身份或存储。

## 修复日志

- 无需额外修复；安装迁移在应用外一次性执行，旧身份未进入兼容代码。

## 验证日志

- 两种 xcodebuild -> PASS，build/variants-{dev,release}-build.log。
- codesign --verify --deep --strict 两种构建和安装包 -> PASS。
- check.sh app-identity settings session-snapshot workspace-identity pane-retention -> PASS。
- check-app-identity 两种实际包 -> PASS：ID、名称、双语名称、Finder 服务、最低系统与可执行文件。
- defaults export/import -> PASS：正式、Dev、正式隔离 suite 内容一致后才删除旧域。
- /Applications 两个隔离实例启动、AppleEvent quit、进程退出 -> PASS，build/variants-launch.log。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：两种身份与独立数据路径成立，已完成本机迁移、安装及相称验证。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：锁屏不能做视觉交互或正式项目窗口恢复验收，不宣称其已通过。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

