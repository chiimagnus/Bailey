# P3｜阶段审查

审查对象：[P3 实施计划](plan-p3.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go（本轮授权范围）。
- **依据**：独立复审两项任务及真实调用链；F-01 经 Red/Green 修复于 `96caf548`，十万行退役同步清空原生投影。最新核心宿主 52/52，真实文件切换和资源释放通过；不运行完整 App GUI。

## 任务与改动

- **P3-T1 原型式主题与自适应列宽**：`82f0070d`。当前主题经 `CSVTableView → NativeDelimitedGrid → DelimitedGrid`
  只更新实际样式，不触发重新索引或替换编辑器。删除固定 140 pt、系统交替行背景以及重复传入的控件状态。
- **P3-T2 行号、整行／整列选区与表头操作**：`e177ec30`。文件控件持有当前解析快照；
  展示租用完整请求，原生菜单与事件在消费时校验。固定行号与数据共用一个滚动位置；
  独立表头排序移除了 `sortDescriptors` 双轨，查找按动作读取真实选区。

## 2026-11-26 独立逐提交复审

重新核对 `82f0070d`、`e177ec30` 的真实实现与现有调用，不依赖历史验收结论。
- P3-T1 `82f0070d`：`CSVTableView` → `NativeDelimitedGrid` → `DelimitedGrid.applyTheme`／`installColumns`，按主题更新颜色与有限样本初始列宽，不重置原生编辑、选区、原文。主题/输入身份、极值表、100 次挂载回归通过。
- P3-T2 `e177ec30`：`DelimitedTableControls`、`DisplayRequest`、`DelimitedNativeTable` 与固定记录 gutter 共享物理行映射；实际网格菜单、选区、粘贴拒绝旧投影。F-01 Red 显示真关闭后保留网格仍有十万行；`96caf548` 在 FileTab 退役时调用已有 `clearProjection()`，不等待 SwiftUI 卸载；Green 确认原生行与选区清空、正文释放、磁盘原字节不变。
- 实测 100000 行网格末格揭示约 7.1 ms；4095 列新增安装约 3.34 s（仍有原生宽表首屏成本）；100 次挂载 0.49 s，进程峰值 RSS 前后相同。证据 `/tmp/bailey-csv-audit-green.b8rGMPOC`。
- 清理核对：`sortDescriptors` 旧排序轨已不存在；新增退役修复复用既有清理入口，不另加生命周期状态。当前投影身份校验防止用户排序、筛选或变更分隔符后向旧物理格写入，保留。

## 发现项

## 发现 F-01

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/CSVTableView.swift:88,834-846; Bailey/Editor/FileViewerView.swift:155-180`
- 摘要：`FileTab 退役仅清空 controls.parsed，仍被 AppKit 缓存的原生 grid 保留 snapshot/source/presentation/选区和复制任务`
- 风险：`实际关闭或外部替换后旧大表继续占用内存并留有过期原生行；依赖 SwiftUI 延迟卸载才释放`
- 预期修复：`在文件所有者退役时复用已有 grid.clearProjection()，同步释放不可变源快照、展示和复制任务；不增加生命周期状态`
- 验证：`真实项目关闭前保留已挂载十万行 grid，关闭后立即检查行数、选区、旧文档清空且磁盘不变；复用现有重挂载回归`
- 解决证据：`96caf548755a13faaee2aeab41bee35c6397b161；Red /tmp/bailey-csv-audit-red.mPfINPoJ，3 条退役断言失败；Green /tmp/bailey-csv-audit-green.b8rGMPOC，保留原生网格的十万行真关闭、选区和磁盘字节通过。`


## 验证与未覆盖

- macOS 27.3 / Xcode 27.2 / arm64。独立 CSV 快照用原 Makefile 和签名 Dev scheme；
  已接入的目标文件与提交逐字比较，未把并发 Git 任务未提交内容包含在证据中。
  宿主 50/50、零跳过，退出 0：`/tmp/bailey-csv-p3-recheck.5enxtoOj`。
  `make build` 退出 0，Debug 严格验签通过：`/tmp/bailey-csv-p3-build-verified.pKvBQuog`。
- C15：按当前目录枚举全部 60 个可选主题，真实 FileViewerView 挂载、同外观换主题和窗口明暗变化；
  检查表格、活动编辑器、marked range、焦点、手调列宽、滚动和原文代次。
  2× 原生快照对照 920 px 原型（原型 `/tmp/bailey-csv-prototype.gZEsuIcM`，原生
  `/tmp/bailey-csv-p3-audit-render.cmAJWgFT/native-dark.png`），检查 30 pt 行头、固定 #／记录号、
  换行提示、条纹删除、数值着色和原位输入的背景与边界；实际列宽随内容而非仿制等宽拉伸。
  真实行号及表头检查 920／480／360／260／220／150 pt。
- C16：空与单列、十万行、2501／4095／4096／4097 列、字段和索引码元上限及取消；
  验证末格可见、AX 选中且 480×330 宿主实现行少于 100。
  十万行原生安装和末格揭示约 7 ms；首装新增 2501 列约 2.1 s，后续增至 4095 列约 3.3 s，
  同表达到／超过显示上限约 0.67 s。宽表的 AppKit 列安装仍有可见首屏成本；
  不把原生控件本身等同于列虚拟化。全列原生竖线曾耗时超过 100 s，采样定位 AppKit 排序，
  拆除后末格全部通过；100 次挂载约 0.52 s，进程峰值 RSS 前后 376471552 B。
- C17：原生表头选择和排序菜单、AX 全选和整行、扩展和离散选区、排序后原记录号、
  双轴滚动、半可见行、旧 AX 元素、粘贴引入分号后保留已用逗号分隔符、混合换行最终磁盘与 Undo。
  原排序改动后旧网格实际改写 `Beta`，Red：`/tmp/bailey-csv-p3-stale-red.MOlR5MZk`；
  Green 覆盖排序、筛选、表头及分隔符在 SwiftUI 重绘前的旧粘贴拒绝。
  审查复验修正了 flipped 行号坐标和远距横滚后的复用字段选中状态。
- 未执行完整 App 的系统外观切换、实体中文候选键盘、多窗组合及真实列边界拖动，原因是用户排除完整 GUI；
  替代证据为活动 AppKit 输入、真实像素、布局、原生命令及窗口所有权宿主，
  不计为 E2E 或实机系统外观验收。恢复独占桌面授权后可补；
  独立 1×／旧系统与系统睡眠无设备，不冒称覆盖，不阻塞本轮源码门禁。
- 纯主题变更／只读操作无写入；`docs/features/editor.md` 已同步。
  P3 不改保存后端，P4 最终宿主整合承接受影响共享回归；本阶段不以历史全量结果为当前全量通过。
- 获授权 `windows-tailscale` 的重新连接、已发布原字节、同长同 mtime 修改和过期覆盖确认两项
  实际 SSH 回归通过，退出 0、零跳过：`/tmp/bailey-csv-p3-ssh.p7onRDf4`。

## 2026-11-27 后续回归

以下为此前本地提交的补验记录（从任务备注迁移），原阶段审计结论不变。

2026-11-27 补齐列方向虚拟化：512 列 200 行首屏从 13824 个数据格／275 MiB 额外物理内存降为 459 个／10.4 MiB；
4096 列 200 行在 800×500 pt 视口中仅实现 621 格，额外物理内存 9.5 MiB，32 次双轴定位后增量 1.2 MiB。
逐格核对值和选区，十万行缩窗末行定位、真实文件末列编辑／字号调整／原字节 Undo/Redo 均通过。
批量更新列宽时暂停旧数据格布局，视口变化后由原生 tile 重算文档尺寸。
Debug 宿主 70/70，真实 Windows SSH 2/2，正式 Debug 构建验签通过；
AppKit 仍遍历全部列，4096 列跨区定位中位数约 228–272 ms。
Release 测试编译在未修改的 PublicationAcknowledgementRunner.swift 遇到 Swift nonisolated 诊断，未执行性能样本；
完整 GUI、最低系统与其他硬件本轮未测。日志 /tmp/bailey-csv-viewport.QE04aR/。

后续 34b0fe89 将 Release 产品优化与测试驱动分离。批量列变更只执行一次原生 tile，
4096 列 × 200 行 Release 首屏布局 4.871→0.994 s，真实文件打开 5.743→1.158 s，
32 次连续横滚／纵滚中位 2.27／27.71 ms，跨区定位中位 258.68 ms（原生行建立仍遍历列）。
Debug 70 项均通过（新增边界断言修正后单独通过）；真实 SSH CSV 两项及共用发布机制一项通过；最新 Release 70/70。
用户明确排除最低系统与其他硬件复测。日志 /tmp/bailey-csv-final.4Bfsya/。
