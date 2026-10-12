# P1：两种应用身份

## P1-T1 两种构建及完整数据隔离

保持单 Target 和 kero 可执行文件/模块。Debug 构建 Kero Dev.app / chiimagnus.kero.dev，新增优化 Release 构建 Kero.app / chiimagnus.kero；分别使用 kero-dev 和 kero scheme。本机一次性直接迁移旧 ID 的偏好与隧道 PID 目录，安装两种新包并清理旧包；不新增兼容代码。

修改工程、scheme 和 Info.plist，移除覆盖 Dev 名称的本地化名字，补 Dev Finder 服务双语。AppIdentity 汇聚数据目录与隔离 suite，接入 AppSettings、SessionStore、TerminalHistoryStore、TunnelPIDFile；TunnelStore 已跟随配置目录，不重复修复。修改原生检查链接 Dev Debug dylib，补最小身份检查。同步 README、SETTINGS 和 AGENTS。

验证：身份/设置/快照检查、两种 Apple Development 签名构建、codesign、实际 App 检查、隔离启动退出。锁屏时只报告进程证据。原子提交不含计划或用户文件。

## 阶段审计

完成后按 plan-task-auditor 创建 audit-p1.md，核对正式路径兼容、所有存储汇聚点、名称及共享 helper，给出 Go / No-Go。
