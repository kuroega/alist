# tvOS 本地后端与 App 验证手册

本手册在仓库根目录执行命令。它创建独立的本地数据目录，不修改已有 AList 数据库或凭据。

## 目标与前提

- Go 版本必须不低于 [`go.mod`](../go.mod) 中声明的版本（当前为 Go 1.25）。
- Xcode 必须安装 tvOS 17.0 或更高版本的平台支持；项目的最低部署目标为 tvOS 17.0。
- 在 Mac 的 Xcode `Settings → Accounts` 登录可用于开发签名的 Apple ID，并在项目 `AListTV` target 的 `Signing & Capabilities` 中选择对应的 `Team`。Apple TV 不需要登录同一 Apple ID。
- Debug App 允许连接 `localhost`、`.local`、回环、链路本地和 RFC 1918 私网地址上的 HTTP，供隔离局域网实机验证；Release App 仍只接受 HTTPS。不要把 Debug HTTP 放到公网。
- 只有验证 HTTPS 路径时才需要 [mkcert](https://github.com/FiloSottile/mkcert)。Simulator 可安装本地 CA；未受监管的真实 Apple TV 即使手动安装 profile，也可能不会授予根 CA 完全 TLS 信任。
- 下文的 `$RUN_ROOT` 是专用于此验证的目录。不要提交其中的数据库、证书私钥、日志或媒体文件。

## 1. 创建本地 AList

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

首次启动会在日志中输出随机生成的初始 `admin` 密码。

为方便调试，建议设置固定的 admin 密码。项目中提供了一个 `.env.example` 文件，请**不要直接修改或使用该 example 文件**。
请将其复制为被 git 忽略的 `.env` 文件，并在其中填入你想使用的密码：

```sh
cp .env.example .env
# 编辑 .env 文件，修改 ALIST_ADMIN_PASSWORD 的值
```

后续每次启动服务时（第 1.3 节），启动脚本会自动加载 `.env` 并在启动前强制设置为你指定的固定密码。由于 `.env` 已被忽略，密码不会被提交到代码库。

### 1.2 可选：验证 HTTPS 时生成开发证书

Debug 实机验证优先使用第 1.3 节的私网 HTTP，不需要安装根 CA。只有验证 HTTPS 路径时才执行本节。Simulator 使用 `localhost`；真实设备必须使用 Mac 在局域网内可解析的 Bonjour 主机名或证书 SAN 覆盖的私网 IP，不能使用 `localhost`。

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

若要在受监管或 MDM 管理的真实 Apple TV 上验证本地 HTTPS，可用 Apple Configurator 或 MDM 安装根 CA 配置描述文件：

1. 将 mkcert 根证书转换为 Apple Configurator 可导入的 DER 文件。只导入公钥证书，绝不导入 `localhost-key.pem`：

   ```sh
   openssl x509 \
     -in "$(mkcert -CAROOT)/rootCA.pem" \
     -outform der \
     -out "$RUN_ROOT/alist-tvos-root-ca.cer"
   ```

2. 安装并打开 Mac App Store 中的 **Apple Configurator**，选择 `File → New Profile`。在 `General` 填写名称（如 `AList tvOS Local CA`）和唯一标识（如 `dev.local.alist-tvos.ca`）。
3. 在左侧选择 `Certificates`，点击 `Configure`，导入 `$RUN_ROOT/alist-tvos-root-ca.cer`；选择 `File → Save`，保存为 `$RUN_ROOT/alist-tvos-root-ca.mobileconfig`。
4. 在 Apple Configurator 的 `Paired Devices` 确认 Apple TV 已连接；返回 `All Devices` 后选中该 Apple TV，选择 `Actions → Add → Profiles` 并选取该 `.mobileconfig`。若已配对但 `All Devices` 为空，重启 Apple Configurator 后重试。
5. 未受监管设备手动安装 profile 不保证该根 CA 获得完全 TLS 信任；不要重复删除、安装同一个 profile。必须以 `https://$HOST:5245` 在 App 中实际连接验证。若仍出现证书无效，改用第 1.3 节的 Debug 私网 HTTP，或改为受监管/MDM/设备已信任 CA；不得关闭证书校验。
6. Apple TV 与 Mac 必须处于同一局域网，Mac 防火墙必须允许入站 TCP 连接。若 Bonjour 解析失败，使用证书 SAN 覆盖的私网 IP，或配置局域网 DNS 后为该 DNS 名称重新签发证书。
7. 不要把 mkcert 根证书、描述文件或任何私钥分发到生产设备、仓库或公共位置；验证结束后删除 `$RUN_ROOT/alist-tvos-root-ca.cer` 与 `$RUN_ROOT/alist-tvos-root-ca.mobileconfig`。

### 1.3 启用 Debug 实机使用的私网 HTTP

编辑 `$RUN_ROOT/data/config.json`。设置顶层的 `site_url` 与 `dist_dir`，并设置 `scheme` 对象；保留其他字段。`site_url` 必须与真实 Apple TV 在 App 中使用的地址完全相同，因为 AList 会用它生成媒体播放 URL。所有文件路径必须是绝对路径：

```json
{
  "site_url": "http://10.0.0.2:5244",
  "dist_dir": "/Users/you/alist-tvos-local/dist",
  "scheme": {
    "address": "0.0.0.0",
    "http_port": 5244,
    "https_port": -1,
    "force_https": false,
    "cert_file": "",
    "key_file": ""
  }
}
```

将示例中的 `10.0.0.2` 替换为 Mac 当前私网 IP，并将 `/Users/you/alist-tvos-local` 替换为实际的 `$RUN_ROOT`。每次启动服务时，通过加载 `.env` 强制设置管理员密码，确保调试体验一致：

```sh
ALIST_ADMIN_PASSWORD=$(grep -m 1 '^ALIST_ADMIN_PASSWORD=' .env | sed 's/^ALIST_ADMIN_PASSWORD=//')
if [ -z "$ALIST_ADMIN_PASSWORD" ] || [ "$ALIST_ADMIN_PASSWORD" = "your_fixed_password_here" ]; then
  echo "错误: 请先在 .env 中设置 ALIST_ADMIN_PASSWORD"
  return 1 2>/dev/null || exit 1
fi
"$RUN_ROOT/alist" --data "$RUN_ROOT/data" admin set "$ALIST_ADMIN_PASSWORD"
"$RUN_ROOT/alist" --data "$RUN_ROOT/data" --log-std server
```

预期日志包含 `start HTTP server @ 0.0.0.0:5244`。保持该进程运行；以 `Ctrl-C` 正常停止。Debug App 只对私网/本地主机放行 HTTP；Release 构建以及公网 HTTP 仍会在发请求前被拒绝。

## 2. 配置可浏览的测试内容

1. 在 Mac 浏览器打开 `http://localhost:5244`。
2. 使用 `admin` 登录 AList 管理界面。
3. 添加一个本地存储，根目录选择一个只包含可公开测试媒体的目录；不要暴露家目录、密钥、数据库或工作区。
4. 确认根目录至少包含一个目录和一个可播放的 MP4。为验证分页，另建一个目录并放入超过 200 个文件。
5. 可选但推荐：新建一个非管理员验证用户，仅授予该测试存储的读取权限。不要复用生产密码。

应用使用 AList API 的 `POST /api/auth/login`、`GET /api/me`、`POST /api/fs/list` 和 `POST /api/fs/get`。`site_url` 生成的媒体地址必须能从 Apple TV 访问，且媒体服务器应支持 HTTP Range 请求。

## 3. 安装、启动与连接 tvOS App

### 3.1 配对真实 Apple TV

Apple TV 4K 仅通过局域网与 Xcode 配对；Apple TV HD（第 4 代）也可在无线发现失败时通过其 USB-C 端口有线连接。使用网络配对时，确保 Mac 与 Apple TV 在同一可互通局域网；不要使用访客网络、客户端隔离（AP isolation）或隔离 VLAN。局域网必须启用 IPv6，供设备发现使用。

1. 在 Mac 的 `系统设置 → 隐私与安全性 → 本地网络` 中允许 Xcode。若此前拒绝过 Xcode 的本地网络发现请求，必须在此重新允许。
2. 在 Apple TV 打开并停留在 `设置 → 遥控器与设备 → 远程 App 与设备`。
3. 在 Xcode 打开 `Window → Devices and Simulators`，选择 `Devices` 标签。
4. 在左侧 `Discovered` 分组选择 Apple TV，点击 `Connect`，输入电视显示的验证码；出现提示时信任此 Mac。
5. 成功后 Apple TV 会出现在设备列表中，并带有网络连接图标。若 `Discovered` 为空，先确认前述本地网络权限与网络条件，再重开该 Xcode 窗口；仍无设备时重启 Mac 与 Apple TV 后重试。

### 3.2 Xcode 构建、安装与连接

1. 打开 `tvos/AListTV.xcodeproj`。
2. 确认 `AListTV` target 的 `Signing & Capabilities` 使用第 1 节所述 `Team`。若 Bundle Identifier 已被该 Team 以外的团队占用，改为该 Team 下唯一的 identifier。
3. 顶部选择 `AListTV` scheme 和已配对的 Apple TV，点击 Run（`⌘R`）。Xcode 会构建、签名、安装并启动 Debug App。
4. 在连接页输入：
   - Debug Simulator：`http://localhost:5244`
   - Debug 真实 Apple TV：`http://<Mac 私网 IP>:5244`，例如 `http://10.0.0.2:5244`
   - Release 或 HTTPS 专项验证：设备信任证书后使用 `https://<证书 SAN 中的主机>:5245`
5. 输入第 2 节的非管理员用户（或仅在隔离的本地环境中使用 `admin`）并选择 **Connect**。

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
5. **安全负例**：Debug App 应接受本地主机和私网地址的 HTTP，但必须拒绝公网 HTTP；Release App 必须拒绝所有 HTTP。使用未受信任证书的 HTTPS 服务时，系统 TLS 校验必须失败，App 不得绕过证书校验。
6. **真实设备特有检查**：确认 Apple TV 能连接 Mac 私网地址、加载目录并播放媒体。Simulator 的解码能力不等同于真实 Apple TV；以真实设备验收目标编码（尤其 HEVC/4K）。

## 5. 故障定位

| 现象 | 检查与处理 |
| --- | --- |
| App 提示只允许安全连接 | Release 只接受完整 `https://` URL。Debug 额外接受本地主机与私网地址的 `http://` URL，但仍拒绝公网 HTTP、userinfo、query 和 fragment。 |
| Xcode 的 `Discovered` 中没有 Apple TV | 在 `系统设置 → 隐私与安全性 → 本地网络` 允许 Xcode；让电视停留在“远程 App 与设备”；确认同一可互通网络、未启用客户端隔离且 IPv6 已启用。Apple TV HD（第 4 代）还可改用 USB-C 有线连接。 |
| Apple TV 无法作为 Run Destination 选择 | 在 `Window → Devices and Simulators → Devices` 完成配对，等待设备状态准备完成；确认 Xcode 安装了匹配的 tvOS 平台支持。 |
| `Signing for "AListTV" requires a development team` | 在 Xcode `Settings → Accounts` 添加 Apple ID；回到 `AListTV` target 的 `Signing & Capabilities`，保持 `Automatically manage signing`，在 `Team` 选择该 Apple ID 对应的 `Personal Team` 或开发团队。若 `com.alist.tv` 已被占用，将 Bundle Identifier 改为该 Team 下唯一的值后重试。 |
| `buildPluginList` 无法加载 `RawCamera.bundle`，路径含 `Debug-appletvsimulator` 或 `.simruntime` | 当前运行目标是 Simulator，不是实机；选择 `Product → Destination`，在 `Devices` 分组重新选择已配对的 Apple TV（避免同名 Simulator），然后选择 `Product → Clean Build Folder` 并再次 Run。实机构建产物路径应为 `Debug-appletvos`。若 Apple TV 不在 `Devices` 分组，回到 `Window → Devices and Simulators → Devices` 确认其已配对且状态完成，并确认 Xcode 安装了匹配的 tvOS 平台支持。 |
| 未受监管 Apple TV 安装 mkcert profile 后仍提示证书无效 | 手动安装不保证根 CA 获得完全 TLS 信任；不要重复安装同一 profile。Debug 实机改用 `http://<Mac 私网 IP>:5244`，或使用受监管/MDM/设备已信任 CA 的 HTTPS。 |
| 能在 Mac 浏览器访问、设备不能访问 | 不要在设备上使用 `localhost`；使用 Mac 私网 IP 或局域网 DNS/Bonjour 主机名，检查防火墙和同一网络。 |
| 登录后立即回到连接页 | 查看服务日志中的 `/api/auth/login` 与 `/api/me` 响应；确认用户状态、密码和权限。 |
| 文件可见但无法播放 | 确认 `site_url` 与 App 输入的设备可访问地址相同；检查 `/api/fs/get` 返回的播放 URL，并确认媒体 Range 请求返回 `206`。 |
| 改完 `config.json` 无效 | AList 仅在进程启动时读取配置；停止后重新启动服务。 |

## 清理

停止服务。若 Apple TV 上安装过 `AList tvOS Local CA`，先在 Apple Configurator 中选中电视，选择 `Actions → Remove → Profiles` 并移除该 profile；Debug 私网 HTTP 不需要保留它。确认移除后删除 `$RUN_ROOT`；该目录包含 AList 数据库、日志、证书和 TLS 私钥。不要提交或共享其中任何内容。
