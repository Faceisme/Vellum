# Vellum 代码逻辑与性能审查报告

审查日期：2026-05-29

## 1. 项目代码逻辑梳理

Vellum 是一个原生 macOS 剪贴板管理器，主流程如下：

1. `VellumMain.swift` 创建 `NSApplication`，以 accessory 模式运行。
2. `AppDelegate.swift` 在启动时创建 `ClipboardMonitor`、`HotKeyManager`、`ClipboardPanelController`，注册全局快捷键，绑定设置变化，启动剪贴板监听，并预热底部面板。
3. `ClipboardMonitor.swift` 负责核心数据流：
   - 启动时从 `HistoryStore` 加载历史。
   - 用 `Timer` 每 0.7 秒检查 `NSPasteboard.changeCount`。
   - 剪贴板变化后按文件、图片、URL、文本顺序解析为 `ClipboardItem`。
   - 新项目插入数组头部，触发链接预览、历史裁剪、防抖保存。
   - 点击卡片时把历史项恢复到系统剪贴板，必要时保留 RTF。
4. `HistoryStore.swift` 负责持久化：
   - `history.json` 存文本、文件路径、链接、RTF base64、元数据。
   - 图片写入 `Application Support/Vellum/images`，JSON 只保存图片文件名。
   - 每次保存都会重建 JSON，并清理无引用图片。
5. `ClipboardPanelController.swift` 管理底部 `NSPanel`：
   - 创建 SwiftUI 面板。
   - 控制显示/隐藏动画。
   - 安装本地键盘和全局鼠标事件监听。
   - 支持选中后复制并模拟 `Command + V` 粘贴回前台 App。
6. `ClipboardPanelView.swift` 和 `ClipboardCardView.swift` 渲染面板：
   - 面板顶部包含搜索、模式切换、收藏过滤和更多菜单。
   - 横向滚动时间线展示剪贴板卡片。
   - 卡片根据类型渲染文本、代码、链接、颜色、文件、图片。
7. `SettingsView.swift` 提供开机启动、菜单栏图标、粘贴模式、保留时长、快捷键等设置。

当前架构清晰，核心功能集中在 `ClipboardMonitor`、`HistoryStore` 和面板视图层。主要性能风险不在算法复杂度，而在“主线程同步处理剪贴板大对象、图片、磁盘 I/O、SwiftUI 重布局”。

## 2. 优先级总览

| 优先级 | 问题 | 影响范围 | 建议处理 |
| --- | --- | --- | --- |
| P0 | 主线程同步加载/保存历史、图片转码和文件读取 | 启动、复制大图、删除/收藏、退出 | 必须优先拆到后台 actor/queue |
| P0 | 剪贴板内容和收藏项缺少硬上限 | 内存、磁盘、搜索、保存耗时 | 增加单项大小、总量、收藏上限和降级策略 |
| P1 | 每次保存全量重写 JSON、扫描图片目录 | 高频保存、删除、收藏、链接预览 | 改为后台原子写入，降低清理频率 |
| P1 | 图片指纹用尺寸 + TIFF 字节数，既昂贵又可能碰撞 | 图片历史、图片文件复用 | 改为稳定 hash，并复用原始 pasteboard 数据 |
| P1 | 链接预览无去重、无缓存、无取消 | 多链接复制、网络慢、重复链接 | 加 URL 缓存、并发限制、删除后取消 |
| P2 | 搜索过滤在 SwiftUI 计算属性中重复执行 | 搜索输入、键盘导航、重绘 | 建立搜索索引，减少重复 filter |
| P2 | 横向滚动容器每次更新都重算 `fittingSize` | hover、选中、搜索、列表变更 | 固定内容尺寸或按数据变化更新 |
| P2 | 每个卡片重绘时重复计算相对时间和来源颜色 | hover/selection 高频变化 | 把稳定派生字段缓存到模型 |
| P3 | 轮询时每 0.7 秒都执行过期清理 | 空闲 CPU、主线程小抖动 | 清理改为低频或事件触发 |
| P3 | `try?` 吞掉持久化错误 | 数据可靠性、排障成本 | 增加错误日志和可观测性 |

## 3. 详细问题与改进方案

### P0. 主线程承担了过多 I/O 和图片处理

涉及代码：

- `ClipboardMonitor` 标注 `@MainActor`。
- 启动时 `items = store.load()` 同步加载历史。
- `flushNow()` 和防抖保存中直接调用 `store.save(items)`。
- `HistoryStore.load()` 同步读取 JSON、解码、加载图片。
- `HistoryStore.save()` 同步编码 JSON、写图片 PNG、扫描图片目录。
- `ClipboardMonitor.makeImageItem()` 使用 `image.tiffRepresentation` 计算指纹。
- `ClipboardMonitor.makeFileItem()` 对图片文件直接 `NSImage(contentsOf:)`。

风险：

- 复制大截图、高分辨率图片、网络盘图片文件时，主线程可能明显卡顿。
- 删除、收藏、清空、退出时 `flushNow()` 是同步落盘，可能阻塞 UI。
- 启动阶段一次性加载历史图片，面板预热前就可能被 I/O 拖慢。

改进方案：

1. 新增 `HistoryStoreActor` 或后台串行队列，负责 JSON 读写、图片转码、孤儿文件清理。
2. `ClipboardMonitor` 只在主线程维护轻量状态；保存时传不可变快照到后台。
3. 图片保存只生成缩略图，不保存完整 `NSImage`；建议最大边 512 或 768 px。
4. 加载历史时先加载文本和元数据，图片缩略图懒加载或后台补齐。
5. `flushNow()` 在退出场景可等待后台保存完成，普通删除/收藏走异步保存。

### P0. 历史项大小和收藏项数量缺少硬上限

涉及代码：

- `ClipboardMonitor.maxItems = 36` 只限制普通项目。
- 超限时只删除最旧的非收藏项，收藏项可以让 `items` 持续超过上限。
- 文本、代码、RTF、文件路径数组没有单项大小限制。
- `StoredItem` 把 `richRTFData` 以 base64 写入 JSON。

风险：

- 用户复制超大文本、富文本或大量收藏后，内存、JSON 文件、搜索和保存耗时会持续增长。
- RTF base64 会比原始数据更大，且每次保存都参与 JSON 编码。
- 收藏项越多，`maxItems` 越失效，后续所有 UI 和保存路径都会变慢。

改进方案：

1. 增加单项限制：
   - 文本预览保留完整内容前先判断大小，例如超过 512 KB 只保存摘要或提示。
   - RTF 单独设上限，例如 1 MB，超过则降级为纯文本。
   - 图片缩略图设像素和字节上限。
2. 增加总量限制：
   - 收藏项也要有最大数量或最大存储空间。
   - 超限时给出明确策略：拒绝新增、替换最旧、或提示用户清理。
3. 把大型 blob 从 JSON 中拆出去，JSON 只存索引和文件名。
4. 在设置页暴露“最大历史数量 / 最大存储空间”会更可控。

### P1. 每次保存全量重写历史并扫描图片目录

涉及代码：

- `HistoryStore.save(_:)` 每次保存都会：
  - `items.map` 生成全部 `StoredItem`。
  - 遍历所有图片项并检查文件是否存在。
  - 编码整个历史 JSON。
  - 扫描 `imagesDirectory` 并删除孤儿图片。

风险：

- 当前 36 条历史时可以接受，但一旦收藏突破上限或 blob 变大，保存会线性变慢。
- 链接预览、收藏、删除、过期清理都可能触发保存。
- 直接写文件缺少原子替换，崩溃或断电时可能留下半写 JSON。

改进方案：

1. 保存放到后台，并使用 `.atomic` 或“临时文件 + rename”。
2. 孤儿图片清理改为低频任务，例如启动后、清空后、每天一次或后台空闲时。
3. 短期保留 JSON，但把大型 RTF / 图片缩略图拆成文件。
4. 中期改为 SQLite 或文件分片索引：
   - 单条变更只更新一条记录。
   - 搜索字段可建索引。
   - 清理和迁移更安全。

### P1. 图片指纹策略性能高且存在碰撞风险

涉及代码：

- `makeImageItem()` 使用 `"image:\(width)×\(height):\(image.tiffRepresentation?.count ?? 0)"`。
- `HistoryStore.imageFilename(for:)` 基于 fingerprint 生成图片文件名。
- 保存图片时如果文件已存在就不再写入。

风险：

- `tiffRepresentation` 对大图成本高，会发生在主线程。
- 两张不同图片只要尺寸和 TIFF 字节数相同，就可能共享同一个文件名，导致预览错图。
- 当前 fingerprint 同时承担“去重判断”和“文件名生成”，碰撞影响会放大。

改进方案：

1. 优先从 `NSPasteboard` 读取原始 PNG/TIFF/JPEG 数据，对数据做 hash。
2. hash 放到后台计算，使用 `SHA256` 或轻量非加密 hash。
3. 指纹区分用途：
   - `contentHash` 用于去重。
   - `assetId` 或 UUID 用于文件名。
4. 图片预览使用缩略图文件，不以完整图片尺寸和 TIFF 转码结果作为唯一依据。

### P1. 链接预览缺少缓存、并发限制和取消

涉及代码：

- 每次捕获链接都创建新的 `LPMetadataProvider`。
- 只按当前 item id 回填结果，没有 URL 级别去重。
- 删除项目后 provider 仍可能继续运行。
- 预览图只回填内存，标题触发保存，图片未持久化为独立缓存。

风险：

- 连续复制多个链接时会并发请求元数据，慢网络下容易拖累体验。
- 重复链接每次都重新请求。
- 被删除或过期的 item 仍可能有后台回调，虽然回填会找不到 id，但资源已经消耗。

改进方案：

1. 增加 `LinkPreviewService`：
   - 以 URL 或 content hash 去重。
   - 限制并发数，例如 2。
   - 对失败结果设置短期负缓存。
2. item 删除或清空时取消对应请求。
3. 预览标题、摘要、缩略图统一缓存，重启后不重复抓取。
4. 对内网、file、过长 URL、重复 URL 直接跳过或降级。

### P2. 搜索过滤重复计算，后续规模增大后会拖慢输入

涉及代码：

- `ClipboardPanelView.filteredItems` 是计算属性。
- `body`、`clampedSelection`、`moveSelection()`、`deleteSelected()`、`selectCurrent()` 多处重复读取。
- 搜索时每个 item 都临时组装 `[title, detail, rawText, previewTitle, ...]` 并做 `localizedCaseInsensitiveContains`。

风险：

- 当前 36 条时影响有限。
- 大文本、富文本摘要、收藏突破上限后，搜索输入和键盘导航会频繁扫描长字符串。
- SwiftUI body 重算时容易重复 filter。

改进方案：

1. 在 `ClipboardItem` 或 ViewModel 中维护 `searchTextIndex`，预先 lowercased / folded。
2. 搜索输入加 100-150ms debounce。
3. 在一次事件处理中只计算一次 filtered result，不要在同一函数多次读计算属性。
4. 搜索只匹配摘要和元数据，超大 rawText 只保存单独摘要字段参与搜索。

### P2. 横向滚动容器每次更新都计算 `fittingSize`

涉及代码：

- `SmoothHorizontalScrollView.updateNSView()` 每次更新都设置 `hostingView.rootView = content` 并读取 `hostingView.fittingSize`。
- hover、选中、搜索文本变化都会触发 SwiftUI 更新。

风险：

- `fittingSize` 会触发布局测量，卡片多或图片多时成本上升。
- hover 只改变选中态，也会走完整更新路径。

改进方案：

1. 内容宽度可按公式计算：`itemCount * itemWidth + (itemCount - 1) * spacing + padding`，避免每次 `fittingSize`。
2. 区分“数据列表变化”和“选中态变化”，只有前者重建 rootView 和尺寸。
3. 如果保留 NSScrollView 桥接，Coordinator 保存上次 item count / content width，避免无意义重算。
4. 如果系统版本允许，可评估 SwiftUI 原生 `ScrollView` + `ScrollViewReader`，减少桥接维护成本。

### P2. 卡片渲染存在可缓存的重复计算

涉及代码：

- `ClipboardCardView.relativeTime(from:)` 每次 body 重绘都调用 `Date()`。
- `sourceAccent` 每次重绘都拼接、lowercased 并匹配来源字符串。
- 每张卡片使用 `compositingGroup()`、阴影、Material overlay。

风险：

- hover 和键盘选择会频繁触发卡片重绘。
- 卡片数量增加后，重复字符串处理和离屏合成成本会上升。

改进方案：

1. `sourceAccent` 在创建 item 时确定，或作为轻量缓存字段。
2. 相对时间改为按分钟级定时刷新，不在每次 body 里取当前时间。
3. 只对选中卡片使用更重的阴影或合成效果，普通卡片保持轻量。
4. 用 Instruments 的 Core Animation / SwiftUI template 验证实际瓶颈后再细调视觉效果。

### P3. 过期清理执行频率过高

涉及代码：

- `Timer` 每 0.7 秒执行 `pollPasteboard()` 和 `pruneExpired()`。
- `pruneExpired()` 每次都计算 cutoff 并扫描 `items`。

风险：

- 当前列表短，影响小。
- 但剪贴板管理器常驻后台，空闲时仍持续做不必要工作。

改进方案：

1. `pruneExpired()` 改为启动时、设置变化时、新增 item 后执行。
2. 额外低频定时清理即可，例如 5-10 分钟一次。
3. `Timer` 只负责 pasteboard changeCount 检查。

### P3. 持久化错误被静默忽略

涉及代码：

- `HistoryStore` 中大量使用 `try?`。

风险：

- 磁盘权限、空间不足、JSON 损坏、图片写入失败时用户无感知。
- 后续排查会缺少证据。

改进方案：

1. 关键读写失败至少输出 `NSLog`，包含路径和错误。
2. 保存失败时保留内存状态并安排重试。
3. JSON 解码失败时备份坏文件，再初始化空历史。

## 4. 建议实施顺序

### 第一阶段：先解决卡顿源

1. 新建后台存储 actor，迁移 `HistoryStore.load/save/pngData`。
2. 图片统一生成缩略图，避免主线程 `tiffRepresentation`。
3. 增加单项大小限制和收藏总量限制。
4. 保存改为原子写入，孤儿图片清理降频。

验收建议：

- 复制 10 MB 文本、20 MB RTF、4K/8K 截图，面板呼出不卡顿。
- 删除/收藏/退出时 UI 不出现明显停顿。
- 历史 JSON 不再因为 RTF 或图片元数据异常膨胀。

### 第二阶段：优化搜索和预览

1. 增加 `searchTextIndex`，搜索只扫预处理字段。
2. 加 `LinkPreviewService`，做 URL 去重、缓存、并发限制、取消。
3. 链接预览缩略图持久化，重启后不重复请求。

验收建议：

- 连续复制 20 个链接不会出现请求堆积。
- 搜索输入连续敲字时无明显掉帧。
- 重复链接不会重复抓取 metadata。

### 第三阶段：降低 SwiftUI 重绘成本

1. 优化 `SmoothHorizontalScrollView`，避免每次更新都读取 `fittingSize`。
2. 缓存卡片来源颜色和相对时间展示。
3. 用 Instruments 验证卡片阴影、玻璃效果、合成层的实际成本。

验收建议：

- 快速左右键切换选中时动画稳定。
- hover 大量卡片时 CPU 和 WindowServer 占用不过高。

## 5. 测试与验证建议

建议补充以下验证场景：

1. 大文本：复制 100 KB、1 MB、10 MB 文本。
2. 富文本：从网页或 Word 复制含图片/样式的内容。
3. 图片：复制普通截图、4K 截图、透明 PNG、超大 JPEG。
4. 文件：复制本地图片文件、外接盘/网络盘图片文件、多文件选择。
5. 链接：连续复制多个不同域名、重复 URL、不可访问 URL。
6. 历史增长：收藏超过 36 条后的保存、搜索、启动速度。
7. 异常存储：历史 JSON 损坏、图片文件丢失、磁盘不可写。

本次已执行：

- `swift build -c release --arch arm64`：通过。

未执行：

- Instruments 性能采样。
- 真实大剪贴板样本压力测试。
- UI 自动化滚动/搜索帧率验证。

