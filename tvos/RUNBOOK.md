# tvOS 本地后端与 App 验证手册

本手册在仓库根目录执行命令。它创建独立的本地数据目录，不修改已有 AList 数据库或凭据。

## 目标与前提

- Go 版本必须不低于 [`go.mod`](../go.mod) 中声明的版本（当前为 Go 1.25）。
- Xcode 必须包含 tvOS 17.0 或更高版本 Simulator；项目的最低部署目标为 tvOS 17.0。
- tvOS 客户端只接受 HTTPS。不要把 `http://localhost:5244` 填入 App。
- 安装 [mkcert](https://github.com/FiloSottile/mkcert)；Simulator 使用的证书必须受其信任。真实 Apple TV 还必须安装并信任该本地 CA，或使用设备已信任的证书颁发机构签发的证书。
- 下文的 `$RUN_ROOT` 是专用于此验证的目录。不要提交其中的数据库、证书私钥、日志或媒体文件。

## 1. 创建 HTTPS 本地 AList

### 1.1 下载前端资源、构建并初始化独立数据目录

源码树中的 `public/dist` 不包含可运行的 Web 前端。AList 启动时仍会加载 `index.html`，因此即使只供 tvOS API 使用，也必须先下载该资源包。

```sh
export RUN_ROOT="$HOME/alist-tvos-local"
mkdir -p "$RUN_ROOT"
curl -fL \
  https://github.com/alist-org/alist-web/releases/latest/download/dist.tar.gz \
  -o "$RUN_ROOT/dist.tar.gz"
tar -xzf "$RUN_ROOT/dist.tar.gz" -C "$RUN_ROOT"
rm "$RUN_ROOT/dist.tar.gz"
test -f "$RUN_ROOT/dist/index.html"

go build -o "$RUN_ROOT/alist" .

# `admin` 会生成 $RUN_ROOT/data/config.json 和 SQLite 数据库，但不会加载 Web 静态资源。
"$RUN_ROOT/alist" --data "$RUN_ROOT/data" --log-std admin
```

首次启动会在日志中输出初始 `admin` 密码。将其保存在密码管理器；不要把它写入终端记录、截图或本仓库。若需要重设：

```sh
read -rs ALIST_ADMIN_PASSWORD
printf '\n'
"$RUN_ROOT/alist" --data "$RUN_ROOT/data" admin set "$ALIST_ADMIN_PASSWORD"
unset ALIST_ADMIN_PASSWORD
```

### 1.2 生成并安装仅供本地开发使用的证书

Simulator 使用 `localhost`；真实设备应使用 Mac 在局域网内可解析的 Bonjour 主机名，不能使用 `localhost`。

```sh
mkcert -install
HOST="$(scutil --get LocalHostName).local"
mkcert \
  -cert-file "$RUN_ROOT/localhost.pem" \
  -key-file "$RUN_ROOT/localhost-key.pem" \
  localhost 127.0.0.1 "$HOST"
```

在 Xcode 中先启动目标 tvOS Simulator 一次，然后将本地 CA 安装到这个已启动的 Simulator。仅运行 `mkcert -install` 不会把 CA 加入 Simulator：

```sh
xcrun simctl keychain booted add-root-cert "$(mkcert -CAROOT)/rootCA.pem"
```

若 `booted` 没有目标，先在 Xcode 启动一个 tvOS Simulator；使用 `xcrun simctl list devices booted` 确认。需要移除本地 CA 时，重置专用 Simulator（会清空其 App 和数据）：`xcrun simctl erase booted`。

若要在真实 Apple TV 上验证：

1. 将 `$(mkcert -CAROOT)/rootCA.pem` 安全地传到设备，并按 tvOS 的证书安装流程安装和信任它；或者改用设备已信任 CA 签发的证书。
2. 让 Apple TV 与 Mac 处于同一局域网，允许入站 TCP 连接，并使用 `https://$HOST:5245`。若 Bonjour 解析失败，配置局域网 DNS 后为该 DNS 名称重新签发证书。
3. 不要把 mkcert 根证书或其私钥分发到生产设备、仓库或公共位置。

### 1.3 启用 AList HTTPS 监听
编辑 `$RUN_ROOT/data/config.json`。设置顶层的 `dist_dir`，并设置 `scheme` 对象；保留其他字段。所有路径必须是绝对路径：

```json
{
  "dist_dir": "/Users/you/alist-tvos-local/dist",
  "scheme": {
    "address": "0.0.0.0",
    "http_port": -1,
    "https_port": 5245,
    "force_https": true,
    "cert_file": "/Users/you/alist-tvos-local/localhost.pem",
    "key_file": "/Users/you/alist-tvos-local/localhost-key.pem"
  }
}
```

将示例中的 `/Users/you/alist-tvos-local` 替换为实际的 `$RUN_ROOT`。然后启动服务：

```sh
"$RUN_ROOT/alist" --data "$RUN_ROOT/data" --log-std server
```

预期日志包含 `start HTTPS server @ 0.0.0.0:5245`。保持该进程运行；以 `Ctrl-C` 正常停止。

## 2. 配置可浏览的测试内容

1. 在 Mac 浏览器打开 `https://localhost:5245`，接受由 mkcert 签发的本地开发证书。
2. 使用 `admin` 登录 AList 管理界面。
3. 添加一个本地存储，根目录选择一个只包含可公开测试媒体的目录；不要暴露家目录、密钥、数据库或工作区。
4. 确认根目录至少包含一个目录和一个可播放的 MP4。为验证分页，另建一个目录并放入超过 200 个文件。
5. 可选但推荐：新建一个非管理员验证用户，仅授予该测试存储的读取权限。不要复用生产密码。

应用使用 AList API 的 `POST /api/auth/login`、`GET /api/me`、`POST /api/fs/list` 和 `POST /api/fs/get`；播放地址必须是 HTTPS，且媒体服务器应支持 HTTP Range 请求。

## 3. 启动与连接 tvOS App

### Xcode

1. 打开 `tvos/AListTV.xcodeproj`。
2. 选择 `AListTV` scheme 和 tvOS Simulator，点击 Run；真实设备则选择已配对的 Apple TV。
3. 在连接页输入：
   - Simulator：`https://localhost:5245`
   - 真实 Apple TV：`https://$HOST:5245`
4. 输入第 2 节的非管理员用户（或仅在隔离的本地环境中使用 `admin`）并选择 **Connect**。

连接成功后应进入根目录。启动恢复会使用已保存 token 调用 `GET /api/me`；若改动了用户、服务器地址或证书，先在 App 中退出登录再重新连接。

### 命令行构建和单元测试

若本机有多个 Apple TV Simulator，先运行 `xcrun simctl list devices available`，并在命令中使用目标设备的 UDID：

```sh
xcodebuild \
  -project tvos/AListTV.xcodeproj \
  -scheme AListTV \
  -destination 'platform=tvOS Simulator,id=<SIMULATOR_UDID>' \
  test
```

项目的 UI 测试使用内置 fixture，不会连接本地 Go 后端；真实后端验收必须按下一节手工执行。

## 4. 真实后端验收清单

服务日志保持可见，并使用未启用 fixture 的 Debug App。

1. **认证与会话**：登录后进入根目录；强制退出并重新打开 App，确认仍能进入根目录。日志应显示登录请求和后续的 `/api/me` 请求。
2. **目录浏览**：打开目录、返回根目录；确认条目不重复，焦点回到刚才打开的目录卡片。对超过 200 项的目录持续滚动，确认页面继续加载而没有重复条目。
3. **播放**：打开 MP4，验证开始、暂停、遥控器拖动和退出；日志应先出现 `/api/fs/get`，随后出现媒体 URL 的 Range 请求，响应应为 `206 Partial Content`。
4. **进度**：播放超过 30 秒后退出并重新打开，确认从接近原位置恢复；播放超过总时长的 90% 后退出，再打开时不应恢复旧进度。
5. **安全负例**：输入 `http://localhost:5244`，App 必须在发请求前拒绝；使用未受信任证书的 HTTPS 服务，系统 TLS 校验必须失败，App 不得绕过证书校验或降级为 HTTP。
6. **真实设备特有检查**：确认 Apple TV 能解析 `$HOST`、信任证书、加载目录并播放媒体。Simulator 的解码能力不等同于真实 Apple TV；以真实设备验收目标编码（尤其 HEVC/4K）。

## 5. 故障定位

| 现象 | 检查与处理 |
| --- | --- |
| App 提示只允许安全连接 | URL 必须是完整 `https://` URL；不要使用 HTTP、userinfo、query 或 fragment。 |
| TLS 连接失败 | 确认证书 SAN 包含所用主机名；Simulator/Apple TV 已信任签发 CA；不要使用 `curl -k` 作为通过标准。 |
| 能在 Mac 浏览器访问、设备不能访问 | 不要在设备上使用 `localhost`；使用局域网 DNS 或 Bonjour 主机名，检查防火墙和同一网络。 |
| 登录后立即回到连接页 | 查看服务日志中的 `/api/auth/login` 与 `/api/me` 响应；确认用户状态、密码和权限。 |
| 文件可见但无法播放 | 检查 `/api/fs/get` 返回的播放 URL 是绝对 HTTPS URL；检查媒体服务对 `Range` 请求返回 `206`。 |
| 改完 `config.json` 无效 | AList 仅在进程启动时读取配置；停止后重新启动服务。 |

## 清理

停止服务后，如不再需要该环境，删除 `$RUN_ROOT` 即可。该目录包含 AList 数据库、日志和 TLS 私钥；删除前不要把其中任何内容提交或共享。
