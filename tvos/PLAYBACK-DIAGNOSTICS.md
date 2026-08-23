# 真机 VLC 播放性能排查记录

## 当前结论

尚不能把瓶颈归因为 Go/AList、Quark 上游或 Apple TV 到 Mac 的局域网链路中的任一方。

已经确认：当前样本使用 VideoToolbox 硬解 H.264；VLC 的输入/解复用统计较低；AList 对该媒体持续收到并处理 HTTP Range 请求。仍缺少一个不被 VLC 主动取消的固定大 Range 下载测速，无法可靠比较 Quark → Mac 与 Mac → Apple TV 的实际持续吞吐。

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
