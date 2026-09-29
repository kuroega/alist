# 真机 VLC 播放性能排查记录

## 当前结论

尚不能把瓶颈归因为 Go/AList、Quark 上游或 Apple TV 到 Mac 的局域网链路中的任一方。

已经确认：当前样本使用 VideoToolbox 硬解 H.264；VLC 的输入/解复用统计较低；AList 对该媒体持续收到并处理 HTTP Range 请求。仍缺少一个不被 VLC 主动取消的固定大 Range 下载测速，无法可靠比较 Quark → Mac 与 Mac → Apple TV 的实际持续吞吐。

### Web 兼容播放（2026-09-16）

已确认此前约 10 秒后归零不是播放器会话切换。10.01 秒的清单分片实际包含约
15 秒视频和 10 秒音频；Chrome 在第二段报
`DEMUXER_ERROR_COULD_NOT_PARSE`，Artplayer 随后自动重载 URL，因而从 0
重新播放。

修复包含三项：

- 在视频流复制阶段丢弃 seek 前导和下一个区间的视频包，保证分片视频、音频和
  `EXTINF` 覆盖同一区间；
- 使用 Matroska cue 的当前 GOP 内位置进行 FFmpeg 输入 seek，避免 B-frame
  seek 向前多读整个 GOP，再将输出时间轴平移到清单位置；
- Chromium 优先使用打包的 hls.js/MSE；原生 HLS 仅作为不支持 MSE 时的回退。

真实相邻分片和 Artplayer 已验证：旧输出的第二段视频结束于约 25.108 秒而音频
结束于约 20.041 秒；新输出每个 10.01 秒区间约 240 帧，并连续播放超过 60 秒，
没有媒体解析错误或归零。`internal/playback` 的 FFmpeg 回归测试会校验中间 GOP
及文件末尾短 GOP 的帧数、时间范围和解码内容；移除前导裁剪后该测试会失败。

这个时间轴修复本身不能消除该样本的冷缓存等待：直接从夸克读取时，线上仍需约
11–13 秒生成 10.01 秒媒体，主要时间消耗在云端读取而非 CPU；夸克低码率转码
接口对该文件返回 `plf_invalid`。提高 Range 并发和双路预取的 A/B 结果只会延后
卡顿或增加启动时间，因此没有保留。

### 持久原文件缓存（2026-09-17）

AList 现已启用磁盘后端的 read-through 原文件缓存。缓存以文件版本为键、按
32 MiB 分块，只允许本机 FFmpeg 通过 loopback 读取；完整分块使用原子重命名
提交，服务重启会扫描并复用已有分块。当前 VM 配置 16 GiB 上限。

本次验收使用同一份 13,327,141,231 字节的 4K HEVC Main 10 / TrueHD 7.1
样本。预热后缓存包含 398 个分块；服务重启前后缓存占用均为
13,327,165,861 字节。重启后的观测结果：

- 本地缓存 32 MiB Range：0.053696 秒，624,954,498 B/s；
- 冷生成第 200 个 10 秒分片：服务日志 1.345 秒，HTTP 完成 1.362 秒；
- 从约 2005 秒处连续播放 70.518 秒，媒体时间前进 68.874 秒，结束时仍有
  34.297 秒已缓冲；没有 `stalled` 或媒体错误；
- 跳转到 3900 秒后立即恢复，24.395 秒内媒体时间前进 24.350 秒，仍有
  28.702 秒已缓冲；随后一直生成到文件末尾，分片耗时不超过 1.690 秒。

HTML 媒体元素在分片切换时仍可能发出短暂 `waiting` 事件，但缓存后的生成速度
持续显著快于 10 秒分片时长，缓冲区净增长；原先由云端吞吐导致的累计欠载已经
消除。未预热的新文件仍受夸克冷读速度限制，首次读取完成后相同文件版本会复用
本地分块。

## 已验证事项

### 播放器与真机

- Apple TV 4K（第 2 代）已安装并启动 AListTV Debug build。
- 真机启动期 `VLCKit.framework` 动态链接失败已修复：App target 的 Debug 和 Release 都配置了：

  ```text
  LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"
  ```

- VLC console 对当前样本输出：

  ```text
  libvlc decoder: Using Video Toolbox to decode 'h264'
  ```

  因此当前样本不是 `avcodec` 软件视频解码。不能根据这一条推断其他 HEVC/MKV 样本也一定走同一解码路径。

### VLC 运行时统计

Debug build 在 `VLCPlayerControllerAdapter.refreshTiming()` 中每 5 秒打印一次 `VLCMedia.statistics`。采样字段包括：

```text
inputBitrate
demuxBitrate
decodedVideo
displayedPictures
latePictures
lostPictures
lostAudioBuffers
```

已观察到的样本：

```text
inputBitrate=0.106–0.140
demuxBitrate=0.084–0.183
```

VLC 上游的实现以累计字节差除以微秒差计算这两个 rate；按该定义，以上约为：

- 输入约 `0.85–1.12 Mbit/s`；
- 解复用约 `0.67–1.46 Mbit/s`。

同一窗口内解码帧增长不稳定，例如曾出现 5 秒仅增长 5–6 帧的区间。`latePictures` 与 `lostPictures` 均为 0，但这不能证明流畅：当输入不足时，视频输出可能没有足够帧可丢弃。

另有两类日志：

```text
libvlc audio output error: too low audio sample frequency (0)
AttributeGraph: cycle detected ...
```

第一项表明当前媒体的音频输出初始化异常；第二项表明播放器 SwiftUI 控制层存在状态图循环。两者都应后续处理，但现有证据不足以将当前持续卡顿主要归因于它们。

### AList 服务与存储配置

本机 AList 进程在运行，服务地址为局域网 HTTP 端口 5244。

`/kk` 存储配置：

| 字段 | 值 |
| --- | --- |
| driver | `Quark` |
| web_proxy | `1` |
| proxy_range | `0` |
| down_concurrency | `3` |
| down_part_size | `10 MB` |

因此 Apple TV 访问 `/p/kk/...` 时，实际链路为：

```text
Apple TV → 本机 AList Go 代理 → Quark 上游
```

AList 配置的 `max_server_download_speed` 为 `-1`，即没有配置 Go 服务端下载限速。

### AList 请求日志

`data/log/log.log` 中相同 REMUX 的记录显示：

- 返回 HTTP `206 Partial Content`；
- 请求声明的 Range 可从当前位置延续至文件末尾，剩余大小可达数十 GB；
- 很多请求在写出约 `31–195 KB` 后由客户端取消；
- 随后 AList 记录 `context canceled` / `local proxy error: context canceled`，且客户端快速重开新的 Range 请求。

示例模式：

```text
written bytes: 97202, sendSize: 34925598249
local proxy error: context canceled
206 ... GET /p/kk/...
```

这些记录证明 VLC 的 MKV 探测、读取或 seek 行为与 AList/Quark Range 代理存在频繁的请求取消和重开；但**不能**把每次仅写出的 31–195 KB 当作 AList、Quark 或局域网的持续吞吐。请求已被客户端主动取消，采样本身不是带宽测试。

## 尚未完成的隔离测试

### 1. 固定大 Range 持续测速

对同一媒体 raw URL 进行一个不被 VLC 取消的固定大 Range 下载，例如 100 MB，记录：

- HTTP 状态和 `Content-Range`；
- 完整下载耗时与平均吞吐；
- 是否发生重定向；
- AList 日志中对应请求的完成情况。

这一步才能区分：

- Quark → Mac 上游慢或受限；
- AList Range 代理实现/配置问题；
- Apple TV → Mac 局域网问题；
- VLC 对大 MKV 的请求模式问题。

### 2. 本地存储对照

使用本机 Local 存储中的同一高码率样本播放。

- 若本地样本流畅，说明 VLC/Apple TV 解码与 Apple TV → Mac 链路基本可用，重点检查 Quark 上游与代理 Range 行为。
- 若本地样本也卡顿，重点检查 Apple TV → Mac 的 Wi-Fi/以太网链路及播放器 UI 主线程问题。

### 3. 解码器归因

当前仅确认当前 H.264 样本使用 VideoToolbox。若固定 Range 测速显示吞吐充足、但仍持续出现迟到或卡顿，再启用 VLC 更详细的模块日志或成功获取 Time Profiler / CPU profile，以确认 HEVC 样本是否退回 `avcodec` 软件解码。

## 当前调优原则

- 不要仅通过增大 `:network-caching=3000` 试图修复持续带宽不足；缓存只能吸收短时抖动。
- 不要在未完成固定 Range 测速前把问题确定为 Quark、Go 或局域网任一方。
- `down_concurrency` 从 3 提高到 5 或 6 是后续可测的 Quark 上游调优项；必须通过持续吞吐对照验证，不能盲目修改。
- `AttributeGraph` 循环应修复，但不应被误判为当前低输入速率的唯一原因。

## 已解决：播放数分钟后音频逐渐落后于画面（2026-09-29）

用户在 tvOS 26.5 Simulator 上播放 MKV 时报告：开始同步，约 3–5 分钟后逐渐失步，**音频比视频慢**。这是独立于上文冷缓存带宽问题的待查现象；不要把既有结论套用到此次样本。此前提交 `05e5ea2b` 修改了 `internal/playback/manager.go` 的 AAC 分片裁剪和原文件缓存预取，但没有验证能解决这一现象。tvOS App 通过 `PlayerCoordinator` 播放 `/api/fs/get` 返回的 `raw_url`；后端可能返回兼容播放 HLS，也可能回退为原始 MKV，尚未确认本次实际 URL 类型或 VM 部署版本。

已获得的证据：Simulator 中 `AListTV` 连接 `10.127.1.109:5244`，正在播放。`simctl` 的 CoreMedia 视频队列日志在 16:35:55–16:47:49 间显示媒体时间 11729.648→12443.648，恰好前进 714 秒（墙钟亦为 714 秒），每 6 秒约入队 179–181 帧。这说明观察窗口内视频时间正常推进，**不能**据此判断音频时钟或证明某个组件导致失步。现有构建的 `VLCKitStats` 使用 `print`，未能在采集到的统一日志中获得音频 PTS / A-V offset；也未取得正在播放文件的相邻分片或后端日志。Mac 上对 VM 的 SSH 严格主机密钥校验失败（未核验主机密钥），不要绕过验证。未经认证的 `/playback/nonexistent/index.m3u8` 返回 410 仅表明路由存在，不能证明当前文件经过该路由。

**候选问题，尚非根因结论：** `internal/playback/manager.go` 对每个分片独立编码 AAC，`aresample=48000:async=1:first_pts=0` 后裁去 1024/48000 秒（约 21.33 ms）的滤镜输入来匹配 EXTINF。现有 `TestEncodedSegmentsExcludeSeekPreroll` 只验证视频帧及音频轨道报告的结束时间，不验证跨分片的实际音频内容连续性、起始静音、AAC priming 或播放时钟。若当前流是 HLS，这里值得优先用实际样本验证；若是原始 MKV，则不能把后端分片裁剪归咎于问题。

接手时先确认 VM 上部署的 commit 和 `/api/fs/get` 对**该文件**实际返回的是 `.m3u8` 还是 MKV（勿记录 token、签名 URL 或文件私人路径）。经用户核验 SSH 主机密钥后采集 AList 分片生成耗时/失败日志；从有权限的样本导出相邻分片，比较音视频 PTS/DTS、解码后的音频内容与原始 MKV，在开始、3 分钟和 5 分钟处测量同一事件的 A-V 偏差。同时通过 VLC 诊断记录播放时的音频缓冲丢失、时钟/PTS 和视频丢帧；区分持续线性漂移与分片交界的阶梯式漂移。若是原始 MKV，优先检查源流时间戳、VLC 解复用/音频输出及网络断流，不要修改 HLS 转码参数。取得这些证据前不要宣称已确定根因或已修复。

### 历史结论与修复（2026-09-29，已在 VM 部署；关于长期同步的结论已被文末连续解码实验推翻）

**根因：** 每个分片独立编码 AAC 时，编码器会在分片起始插入 1024 采样（48 kHz 下 21.333 ms）的 priming 帧。输出 fMP4 没有 edit list，因此该分片音频轨实际长度是 `EXTINF + 1024/48000` 秒，而视频轨严格等于 `EXTINF`。播放器按 `EXTINF` 推进时间轴，于是每个分片音频落后约 21.33 ms；3–5 分钟（约 30–50 个分片）后累计到 0.6–1.1 秒，与用户报告的“音频比视频慢”一致。

**验证方法（VM，ffmpeg 8.1.2）：** 用有权限的真实样本按生产参数连续生成 40 个分片：视频时长对所有分片都精确等于 `EXTINF`，音频时长恒为 `EXTINF + 21.333 ms`；跨分片互相关显示音频内容整体前移同一常量，说明是每分片固定 offset 而非后端累计漂移。

**修复（step 1，`05e5ea2b`）：** `-af` 末尾追加 `atrim=duration=EXTINF-1024/48000`，把音频裁到与 `EXTINF` 一致。验证：`audio duration == EXTINF`，整条播放列表 `audio == video == 40.000 s`，ffmpeg 解码无告警。

**修复（step 2，同时修复 fMP4/HLS 一致性）：** 之前每个分片自带 `ftyp+moov`，播放列表没有 `#EXT-X-MAP`，且每个分片的 `mfhd` 序号都从 1 重新开始。VLC 4 的 `mp4` 解复用器在 `FragPrepareChunk` 收到序号不连续时会执行一次被动 seek 并重置帧间预测，产生 H.264 参考帧错误。现在：
- mp4 muxer 改为 `-movflags +empty_moov+default_base_moof` 且 `-frag_duration` 大于分片时长，使每个分片恰好一个 `moof`；
- 播放列表增加 `#EXT-X-MAP:URI="init.mp4"`，新增 `/playback/{id}/init.mp4` 返回共享的 `ftyp+moov`；
- `.m4s` 响应剥离 `ftyp/moov` 只留媒体，并把唯一的 `mfhd` 序号改写为全局连续的 `n+1`。

**端到端验证：** VM 上用 `ffmpeg 8.1.2` 构建新二进制并以临时实例实测：播放列表含 `EXT-X-MAP`；`init.mp4` 只有 `ftyp+moov`；`0..6.m4s` 各恰好一个 `moof`，`mfhd` 序号 `1..7` 连续；每个分片 `audio duration == video duration == EXTINF`；整条列表 `audio == video == 40.000 s`；桌面 VLC 4.0.0-dev 完整播放 7 个分片，H.264 解码错误为 0（仅有开头正常的 `Fragment sequence discontinuity 1 != 0`）。`go test ./internal/playback/...` 在 VM（ffmpeg 8.1.2）与本地均通过。

**部署：** VM 二进制更新为 sha256 `76c7335748e80a2720309f2a0de93dd9a1242945d7268a71ac8dce4781384b93`（2026-09-29），旧二进制备份于 `/opt/alist/alist.pre-extmap`，源缓存未动。

**遗留：** `Manager.Init` 在会话内尚无分片时会编码分片 0 以取得 `moov`；从中间位置恢复播放时会多做一次分片 0 编码（源缓存热时约 0.2–0.5 s）。另外 `atrim` 只对齐了分片边界时长，未补偿分片起始的解码 priming；连续播放不受影响，但若要逐分片拼接解码，需 edit list 或丢弃解码 priming 才能完全无损。

**当时的客户端验证（2026-09-29）：** 用户在 Mac 上短时复测时未观察到漂移；后续长时间 Chrome 播放和文末连续解码实验证实音频仍会逐片变慢，不能再视作彻底修复。

## 已定位：E20 "playback segment 14" 转换失败（2026-09-29）

现象：日志中 E20 在 17:08:57 和 17:12:36 两次出现 `playback segment 14: 0 bytes in ~330ms err=playback segment conversion failed`；`encode()` 当时用 `cmd.Stderr = io.Discard`，失败原因完全不可见。

定位：同一旧二进制在 17:41:07 对同一分片 14 成功编码（`2278553 bytes in 5.518s`），且此后（18:54–19:03）多文件连续播放全部成功。说明这是**首次播放冷缓存填充期间的瞬时上游分片读取失败**，不是编解码/封装缺陷：`sourceStore.fetchChunk` 当时对上游错误不做重试，`Range` 响应提前结束，ffmpeg 在 `-xerror` 下立即以非零退出并产出 0 字节。

修复：
- `encode()` 改为保留 16 KiB 的 ffmpeg stderr 尾部，经脱敏（源 URL、任意 http(s) URL、`sign/token/api_key/authorization/cookie/password` 参数）后随错误日志输出；ffmpeg 提到 `-loglevel warning`，保证根因可见且签名能力不泄漏。
- `sourceStore.fetchChunk` 对瞬时失败最多重试 3 次（线性退避 200/400 ms）；分片自身 60 s 超时不重试，避免耗尽编码预算。

验证：`go test ./internal/playback/...` 在 VM（ffmpeg 8.1.2）与本地均通过，新增脱敏、stderr 尾部边界、端到端错误可见性与分片重试测试。二进制更新为 sha256 `9f98c0394838f73ea70a344e65555a9167133c0ad519f5a1e72ba2fa1b9124b1`（2026-09-29），旧二进制备份于 `/opt/alist/alist.pre-retry`。

## 视频略落后于音频：后端时间戳偏移排查

VM 当前运行的二进制仍为上述 sha256，FFmpeg 为 8.1.2。在 VM 上用与生产相同的视频复制、B-frame H.264、AC3→AAC、`-avoid_negative_ts make_non_negative`、`+empty_moov+default_base_moof` 和单 moof 参数生成合成分片（未访问用户媒体）。原 MKV 第一帧视频 PTS 为 0；输出 fMP4 的第一帧视频 PTS 为 **0.083 s**、DTS 为 0，音频轨起点则为 **0**。视频轨报告的 `duration=4.999 s`，但时间范围实际上是约 0.083–5.082 s；音频轨为 0–5.000 s。即先前仅检查轨道 *duration* 相等，遗漏了轨道 *start_time* 差异。另用非周期噪声源在本地复现相同参数：输出音频解码内容在时间 t 对应源音频约 t−16.33 ms；即使考虑这一音频内容延迟，视频仍比音频内容落后约 67 ms（示例的实际音频内容/源编解码器会改变此数值）。

机制：视频流复制保留 B-frame 重排所需的负 DTS；MP4 muxer 将首个视频 DTS 归零时把同轨 PTS 一起推迟（此例为两帧、约 83 ms），却没有同样推迟从 0 开始的重编码音频。`shiftSegmentTimeline` 对两个轨道只加同一个分片起始偏移，因此不会消除此相对差。`atrim` 修复的是每片末端 AAC priming 导致的累计重叠，**不修正起点**；`EXT-X-MAP` 修复使视频可持续解码，也不会修正 PTS。用旧的 `+frag_keyframe` 参数对照仍有相同 83 ms 起点差，故不是新 `-frag_duration` 单独造成。此为 VM 转换路径的可复现**候选**，尚未从用户正在播放的文件取样或在 tvOS 上直接测量绝对 A/V offset；不能据合成样本断言其精确毫秒数，也不能确定播放器会呈现相同的错位。修复前应以真实相邻分片核对首帧 PTS、首音频 PTS 和解码内容，并防止仅调整 `duration` 再次掩盖起点差。

**新增对照证据及纠正：** 用户最初以为 Windows Chrome Web UI 正常，后来在 Chrome 的 `.m4s` 流中也观察到**音频逐渐落后**；所以不能归咎于 tvOS/VLCKit 独有问题。曾试验直接改写 fMP4 的 composition offset 或移动音轨 tfdt，但前者被解复用器负 CTS 归一化影响，后者破坏跨片末端对齐；均已撤销，未部署。上面的 83 ms 合成样本起点 PTS 差是另一种静态偏移，不解释这次音频累计变慢。

### 已定位：独立 AAC 编码的最后一帧实际解码长度超过分片时长

在运行中 VM（ffmpeg 8.1.2）上，从最新的本地**只读缓存**重建了一份 H.264/AC3 MKV 样本（596,695,754 字节，2747.077 秒；尚未用文件名证明与用户所指 E21 完全一致），使用与已部署二进制相同的当前 `internal/playback` 代码按原始 GOP 边界生成 40 个相邻 HLS fMP4 分片，播放列表累计时长 354.921 秒。未改动服务、源缓存或已部署二进制；临时样本及诊断程序已删除。

`ffprobe` 报告 HLS 音频轨截止 354.921 秒，包的标称 duration 总和约 354.915 秒；但 `ffmpeg` 解码整个 HLS 后得到 **355.413 秒**、比播放列表多约 **0.492 秒**的 PCM。同一个原 MKV 的 PCM 与 HLS PCM 在 4、70、175、280、345 秒处进行 8 kHz、1 秒窗口互相关，最佳的 `源时间 − HLS 时间` 分别为 −0.021、−0.123、−0.234、−0.383、**−0.486 秒**（相关系数分别约 0.858、0.944、0.886、0.957、0.983）。即媒体内容确实逐片越来越晚，绝非仅 VLC 时钟或主观感觉。

具体机制：此前 `manager.go` 中 `atrim=duration=EXTINF−1024/48000` 让 **MP4 标称轨道时长**等于 `EXTINF`，但每次新开的 AAC 编码器仍产出整数个 1024-sample 帧；MP4 最后一包的 `duration` 被截短，解码器却输出**完整的 AAC 帧**。例如第 0 段标称 8.342 秒，共 392 包，最后一包声明仅 0.000667 秒；完整解码为 `392×1024/48000 = 8.362667` 秒，多约 20.7 ms。第 1 段标称 12.846 秒、603 包，实际解码 12.864 秒，多约 18 ms。每段残余约 0–21 ms，经 40 段累计约 0.49 秒；之前仅校验 `ffprobe stream.duration` / `packet.duration`，没有连续解码后与源文件做内容互相关，因此误判「已修复」。

### 修复：跨分片全局 AAC 帧网格（2026-09-29）

现在每个边界 `t` 都量化为 `round(t×48000/1024)` 个 AAC 帧；第 `n` 段实际输出帧数是相邻量化边界之差。`atrim=end_sample=(帧数−1)×1024` 精确向 AAC 编码器送整数采样（多出来的一帧是 encoder priming），不再生成 duration 不足一帧的最后一包；输出超时延长最多两帧，视频仍由原 bitstream filter 严格裁在 GOP 边界。fMP4 音轨的 `tfdt` 设置为量化后**全局**样本起点，确保相邻片 AAC 解码后时钟连续、累计舍入误差不增长；单片音频边界相对 `EXTINF` 可差不超过约半帧，而不是伪造部分 AAC 包。保留原有 H.264/HEVC stream copy 和共享 `EXT-X-MAP`。

VM FFmpeg 8.1.2 上另以 616,644,992 字节、2667.198 秒的 H.264/AC3 缓存源做同源旧/新对照（与用户指定的 E21 在日志访问时间一致，但没有依文件名验证缓存身份）：相邻 **60 片 / 544.411 秒**，旧版 HLS 音频解码长度 **545.1094 秒**，音频内容在 4/175/345/510 秒相对原件分别落后约 0.021/0.251/0.462/0.677 秒；新版音频解码长度 **544.4054 秒**，同一位置仅落后约 0.021/0.016/0.014/0.016 秒，没有累积漂移。另一份 596,695,754 字节的 60 片样本新版在 4–510 秒偏差也保持约 0.011–0.032 秒。新版各检测片的 AAC 包全是 1024/48000 秒完整帧；60 片完整视频解码无报错。`go test ./internal/playback/...` 在本地和 VM（ffmpeg 8.1.2）通过，新增相邻/末片的音频帧数、首帧时间、全帧 duration 及 tfdt v0/v1 回归测试。

部署：VM 原二进制 sha256 `9f98c0394838f73ea70a344e65555a9167133c0ad519f5a1e72ba2fa1b9124b1` 备份于 `/opt/alist/alist.pre-aac-grid`；当前运行二进制 sha256 `debc65871dd13726cfb023a16ecc1ad963b13332d15bed4a458717a6e1283015`。服务重启后 HTTP 首页 200、`rc-service alist status` 为 started；VM `/opt/alist` Go 源同步并通过播放包测试，旧源码备份于 `/opt/alist.source-pre-aac-grid.tgz`。原文件缓存未动，临时诊断媒体已删除。**浏览器/Simulator 仍需用户重新打开播放并主观确认**；重启会使旧 HLS session URL 失效。
