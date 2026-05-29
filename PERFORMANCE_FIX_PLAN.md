# Vellum 性能修复执行计划

日期：2026-05-29
基于：`PERFORMANCE_REVIEW.md`（用户报告） + 本次代码梳理新发现。

本文件记录"已改 / 待确认"，防止漏改或重复改。

---

## A. 本次梳理新发现（用户报告之外的补充）

| 编号 | 问题 | 严重度 | 处理 |
| --- | --- | --- | --- |
| N1 | `clampedSelection` 是计算属性，内部全量执行 `filteredItems` 过滤。在 `body` 与 `ForEach` 每张卡片里都读它 → 每次 body（含每次 hover）会对历史做 **N+ 次全量 filter**（36 卡 ≈ 36 次）。这是 hover/选中掉帧的主因之一。 | 高 | ✅ 直接改 |
| N2 | `SmoothHorizontalScrollView.updateNSView` 每次更新都 `hostingView.fittingSize`（强制整树布局测量）。hover 改 `selectedIndex` 也会触发。 | 高 | ✅ 直接改（按公式算宽度） |
| N3 | 过期清理 `pruneExpired()` 跟随 0.7s 轮询每次执行（含 `AppSettings.shared` 访问 + 全量扫描），常驻后台空转。 | 中 | ✅ 直接改 |
| N4 | `HistoryStore.save()` 全程在主线程：PNG 转码 + JSON 编码 + 写盘 + 扫描整个 images 目录删孤儿。删除/收藏/链接预览回填都会触发。 | 高 | ✅ 直接改（拆后台 + 原子写 + 降低孤儿清理频率，保留退出同步落盘） |
| N5 | 图片项在内存里持有**全分辨率** `NSImage`（卡片只显示 232pt）。36 张 4K 截图常驻 → 几百 MB。降采样会影响"粘贴回原图"的保真度。 | 高（内存） | ⏸ 待确认（见下方 Q1） |
| N6 | `ClipboardItem.fingerprint` 用 `尺寸 + tiffRepresentation.count`，既要在主线程对大图做 tiff 转码，又可能不同图碰撞同名文件→预览错图。改 hash 会让旧图片文件名失配（一次性孤儿）。 | 中 | ⏸ 待确认（见下方 Q2） |
| N7 | `ClipboardItem.==` 只比较 `id + isFavorite`，忽略 `previewTitle/previewImage` 等。当前未接 `EquatableView` 暂不致错，但是个隐患。 | 低 | 暂不动，记录 |

## B. 用户报告中本次直接处理的项

- P2「搜索过滤重复计算」→ 与 N1 合并修复（一次 body 只算一次 filtered + 选中钳制）。
- P2「横向滚动每次 `fittingSize`」→ N2。
- P3「过期清理频率过高」→ N3。
- P1「每次保存全量重写 + 扫描图片目录」→ N4（后台 + 原子写 + 降频清理）。
- P3「`try?` 吞错」→ 关键写盘失败加 `NSLog`。

## C. 需确认项（已获批准，均已实现）

- **Q1（内存，影响最大）→ ✅ 已实现**：内存只留缩略图（最长边 512px），原图完整留盘，粘贴时按需从磁盘加载原图。
- **Q2（图片指纹）→ ✅ 已实现**：图片指纹改为剪贴板原始字节的 SHA256（截断 16 字节十六进制）。旧图片文件名失配将作为孤儿被清理重建。
- **Q3（上限）→ ✅ 部分实现**：RTF >1MB 降级纯文本；收藏数量上限 100。文本"超大存摘要"未做（见说明）。

---

## D. 变更日志（已落地）

> 状态：以下均已实现，`swift build -c release --arch arm64` 通过。

1. **N1 + P2 搜索/选中重复过滤** — `ClipboardPanelView`
   - `clampedSelection` 由"每次读都全量 filter 的计算属性"改为 `clampedSelection(count:)` 函数。
   - `body` 开头一次性 `let items = filteredItems` / `let selection = ...`，向下透传，`ForEach` 内 `isSelected` 不再每张卡片重算 filter。
   - `timeline(items:)` 改为 `timeline(items:selection:)`。
   - `moveSelection/deleteSelected/selectCurrent` 各自只算一次 `filteredItems`。
   - 效果：一次 body（含每次 hover）从约 N+ 次全量过滤降到 1 次。

2. **N2 + P2 横向滚动布局测量** — `SmoothHorizontalScrollView`
   - 新增 `itemCount` 入参，按 `count*width + (count-1)*spacing + padding*2` 公式算内容宽。
   - `updateNSView` 不再调用 `hostingView.fittingSize`（不再强制整树布局测量）；仅在宽/高变化时改 frame。
   - 效果：hover/选中变化不再触发整条时间线的布局测量。

3. **N3 + P3 过期清理降频** — `ClipboardMonitor`
   - 0.7s 高频定时器只做 `pollPasteboard()`（changeCount 检测）。
   - 新增 60s 低频 `pruneTimer` 跑 `pruneExpired()`；启动时仍清理一次。

4. **N4 + P1 保存搬后台 + 原子写 + 降频清理** — `HistoryStore`（标 `@MainActor`）/ `ClipboardMonitor` / `AppDelegate`
   - 新增串行 `ioQueue`，JSON 编码 + 写盘 + 孤儿清理全部移到后台。
   - 主线程只做"准备快照 + 仅对新图片 PNG 转码一次"（NSImage 非线程安全，转码必须留主线程）。
   - 新增 `writtenImageFilenames` 内存缓存，避免每次保存在主线程 `fileExists` stat 磁盘。
   - 索引与图片均 `.atomic` 写，避免半写损坏。
   - 孤儿图片清理降频：每 12 次保存一次；清空历史时立即清理。
   - 写盘失败由静默 `try?` 改为 `NSLog`（P3）。
   - 退出路径：`flushNow()`（异步）+ 新增 `flushAndWait()`（`ioQueue.sync` 等待），`applicationWillTerminate` 用后者确保不丢数据。

5. **GlassEffectView / VisualEffectView updateNSView 加变更判等**
   - 仅在属性实际变化时赋值，避免每次 body 重算（hover）都重设 `tintColor` 等触发玻璃/材质层重绘。

6. **Q1 图片内存：内存只留缩略图，原图留盘** — 新增 `ImageThumbnail.swift` / `HistoryStore` / `ClipboardMonitor`
   - 新增 `NSImage.vellumThumbnail(maxPixel:512)`（高质量降采样）。
   - 加载历史（`HistoryStore.makeItem`）与文件图片捕获（`makeFileItem`）只放缩略图，不再常驻全分辨率位图。
   - 粘贴时 `restore` 对图片项调用 `store.fullImage(for: fingerprint)` 从磁盘读原图，保真度不变（新复制项尚未落盘时回退到内存图）。
   - 文件→图片的尺寸 detail 改用保存时记录的原始尺寸，不用缩略图尺寸。
   - 链接预览图也降采样（最长边 160px，卡片只显示 56pt）。
   - 收益：历史含大图时的常驻内存从几百 MB 量级降到几 MB 量级。

7. **Q2 图片指纹改内容 hash** — `ClipboardMonitor` / `ImageThumbnail.swift`
   - `makeImageItem` 指纹 = `"image:" + SHA256(剪贴板原始字节).prefix(16)`，优先复用 `.png/.tiff` 原始数据，避免主线程额外 TIFF 转码。
   - 去重更准、消除"不同图同名碰撞导致预览错图"，文件名也由 hash 决定。

8. **Q3 大小/数量上限** — `ClipboardMonitor`
   - `maxRTFBytes = 1MB`：RTF 超限丢弃，降级为纯文本（纯文本仍可粘贴，仅丢格式）。
   - `maxFavorites = 100`：收藏达上限时拒绝新增并提示音，防止收藏豁免 `maxItems` 导致无界增长。
   - 文本"超大转摘要"未实现：会破坏"完整粘贴大段文本"的功能（如粘贴大文件内容会被截断），属功能回退，故保留完整文本。如需仍可加，请告知阈值。

9. **搜索框聚焦蓝环左侧被切（视觉）** — `ClipboardPanelView.searchControl`
   - 聚焦描边由 `.stroke`（描边跨边缘，外半部分在 frame 之外）改为 `.strokeBorder`（描边画在形状内侧）。
   - 原因：父容器 `toolbarCluster` 有 `.clipped()`，搜索框左边缘正好在裁剪边界，跨边缘的描边外半部分被切掉，看起来左侧圆角边框缺一块。`strokeBorder` 全部画在内侧即不会被裁。未改任何坐标，点击命中检测不受影响。

10. **搜索框打字掉帧** — `ClipboardPanelView`
   - 新增 `debouncedQuery`，过滤改用它；`.task(id: searchText)` 做 150ms 防抖（清空立即生效）。
   - 原因：原来每敲一个字符都立即重算过滤 + 重建整条卡片时间线（NSHostingView 重新布局），输入越快掉帧越明显。防抖后打字过程不触发卡片重建，停顿 150ms 后才过滤一次。

11. **面板弹出动画掉帧** — `ClipboardPanelController.makePanel`
   - 在内容 `hostingView.layer` 上设 `allowsGroupOpacity = false`。
   - 原因：入场动画对整层做 `opacity` 0→1 渐变，而内容层有子图层（玻璃+卡片+阴影，整层约 1400×330 retina）。开启组透明度时，每帧都要把整棵图层树离屏重合成一次再统一应用透明度——这是弹出掉帧的主因。关掉后透明度按各子图层独立应用，不再每帧离屏 flatten，滑入+淡入仍保留。

12. **搜索过滤后卡片错位（bug）** — `SmoothHorizontalScrollView` / `VellumSmoothScrollView`
   - 现象：搜索框输入文字再退格删除后，卡片出现错位/残留。
   - 根因：文档视图尺寸原本在 `updateNSView` 里按 clip view 高度即时设置，但 `updateNSView` 只在 SwiftUI 状态变化时触发。空搜索结果会把时间线换成空状态视图，退格又换回时间线（重新 `makeNSView`），首个 `updateNSView` 可能在 clip view 尚无有效高度时跑，把内容定成错误尺寸且之后无更新自愈；另外列表过滤导致内容宽变化时，横向滚动偏移没被钳回有效范围。
   - 修法：尺寸改由 `VellumSmoothScrollView.layout()` 统一处理——文档视图高度始终跟随可视区高度、宽度取内容宽与可视宽较大者，并在每次布局把横向偏移钳回 `[0, maxX]`。`updateNSView` 只负责赋 `rootView` 和设置 `contentWidth`（触发重新布局）。比改动前更健壮。

## E. 仍建议但本次未动（低优先或需确认）

- 卡片 `compositingGroup()` + 阴影：每卡一次离屏合成，36 卡在动画时是 GPU 成本。改动会影响视觉，建议先用 Instruments 量化再决定，故未动。
- `ClipboardCardView.relativeTime` 每次重绘取 `Date()`、`sourceAccent` 每次重算字符串：均为极小开销，未做缓存（避免引入静态缓存的并发复杂度）。
- hover 改 `selectedIndex` 仍会触发整个面板 body 重算：彻底消除需把"选中态"抽到独立 ObservableObject 仅由卡片观察，属较大重构，未动。
- `load()` 仍在启动时同步读盘 + 全量加载图片（与 Q1 绑定）。
</content>
