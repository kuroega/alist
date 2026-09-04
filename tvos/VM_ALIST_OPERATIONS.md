# VMware Alpine AList 运维手册

用于 `AListBackend` 虚拟机和 tvOS App 的日常使用。

## 1. 当前配置

- VMware Workstation：15.5.7
- 系统：Alpine Linux 3.24
- VM 配置：`D:\YW_VMWARE\AListBackend\AListBackend.vmx`
- 网络：桥接模式，网卡 `e1000`
- AList 地址：`http://10.127.1.109:5244`
- AList 数据：`/var/lib/alist`
- 程序：`/opt/alist/alist`
- 服务：OpenRC `alist`

`10.127.1.109` 是 DHCP 地址，可能变化。建议在路由器中为此 VM 保留该地址。

## 2. 启动 VM

1. 打开 VMware，启动 `AListBackend`。
2. CD/DVD 不要连接 Alpine ISO；启动时连接必须关闭。
3. Alpine 启动后，服务会自动启动。

登录控制台：

```text
用户名：kuroega
密码：安装时设置的密码
```

切换 root：

```sh
su -
```

## 3. 每次重启后的检查

```sh
ip -4 addr show eth0
rc-service alist status
wget -qO- http://127.0.0.1:5244/api/public/settings
```

正常结果：

- `eth0` 有 `10.127.1.x` 地址；
- 服务状态为 `started`；
- API 返回 JSON，且包含 `"code":200`。

Windows 或 tvOS 使用：

```text
http://<VM_IP>:5244
```

当前地址：

```text
http://10.127.1.109:5244
```

## 3.1 Windows 原生 SSH 命令行调试

Windows 端使用系统自带的 OpenSSH Client，不需要 PuTTY、WSL 或第三方隧道程序。脚本入口是仓库中的 `tools/windows/Invoke-AlistVmSsh.ps1`。VM 必须先开机，桥接网络继续使用当前 VM IP；脚本不会自动启动 VMware、修改 VMware 网络或绕过 SSH 认证。

### 3.1.1 在 Alpine VM 启用 SSH

第一次配置请在 VMware 控制台执行，而不是把密码写入脚本：

```sh
apk add --no-cache openssh
rc-update add sshd default
rc-service sshd start
rc-service sshd status
```

确认 SSH 服务监听 22 端口：

```sh
ss -lnt | grep ':22'
```

### 3.1.2 使用 Windows Ed25519 密钥

在 Windows PowerShell 执行。密钥口令由 `ssh-keygen` 交互读取，不要写入命令行或仓库：

```powershell
$key = Join-Path $env:USERPROFILE '.ssh\alist-vm_ed25519'
New-Item -ItemType Directory -Path (Split-Path $key) -Force | Out-Null
if (-not (Test-Path -LiteralPath $key)) {
  ssh-keygen -t ed25519 -f $key -C 'alist-vm-debug'
}
Get-Content "$key.pub"
```

将上条命令输出的**整行公钥**粘贴到 VM 控制台的 `/home/kuroega/.ssh/authorized_keys`，然后修正权限：

```sh
install -d -m 700 -o kuroega -g kuroega /home/kuroega/.ssh
vi /home/kuroega/.ssh/authorized_keys
chmod 600 /home/kuroega/.ssh/authorized_keys
chown -R kuroega:kuroega /home/kuroega/.ssh
```

首次连接前，在 VM 控制台查看 SSH host key 指纹：

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

在 Windows 读取同一主机的公钥并与控制台指纹人工核对；确认一致后才写入 Windows 的 known_hosts：

```powershell
ssh-keyscan -t ed25519 10.127.1.109
ssh-keyscan -t ed25519 10.127.1.109 | Out-File -FilePath "$env:USERPROFILE\.ssh\known_hosts" -Encoding ascii -Append
```

脚本固定使用 `StrictHostKeyChecking=yes`。如果指纹不一致，停止操作并检查 VM IP、网络和 known_hosts，不要改成 `StrictHostKeyChecking=no`。

### 3.1.3 Agent 命令行执行和 HTTP 隧道

这个入口面向 Agent 或其他自动化调用，不提供交互式 shell。默认模式是 `Exec`，每次调用只建立一个 SSH 连接、执行一条远程命令并退出。远端 stdout、stderr 会原样回传，SSH 的退出码也会作为脚本退出码返回；因此调用方可以直接根据退出码判断维护操作是否成功。

可选地在 Windows Agent 进程的环境中设置连接参数；不设置时脚本默认使用本手册中的 VM 地址和 `kuroega` 用户：

```powershell
$env:ALIST_VM_HOST = '10.127.1.109'
$env:ALIST_VM_USER = 'kuroega'
$env:ALIST_VM_IDENTITY_FILE = "$env:USERPROFILE\.ssh\alist-vm_ed25519"
```

先做连通性检查，再执行远程命令。`-Command` 是 `-RemoteCommand` 的别名，命令作为一个字符串传给 VM 内的远程 shell：

```powershell
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Mode Doctor
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Mode Exec -Command 'rc-service alist status'
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Command 'tail -n 100 /var/log/alist.log'
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Command 'cd /opt/alist && go test ./...'
```

`Exec` 和 `Tunnel` 使用 `BatchMode=yes`、`-T` 和 `StrictHostKeyChecking=yes`，不会等待密码输入，也不会分配 TTY。调用方应先完成公钥认证和 known_hosts 配置；不应把密码拼接到 `-Command` 或任何环境变量中。远端命令中的 `&&`、管道和重定向由 VM 的 shell 解释，不会在 Windows 本地执行。

需要从 Windows Agent 访问 VM 内 AList 或临时 debug/pprof 进程时，用独立的长生命周期 Agent 任务运行隧道命令：

```powershell
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Mode Tunnel
```

`Tunnel` 会保持前台 SSH 进程，调用方应保存该进程句柄并在任务结束时终止它。隧道两端都显式绑定回环地址，将 Windows `127.0.0.1:15244` 转发到 VM `127.0.0.1:5244`；隧道建立后，其他 Agent 命令可以请求：

```powershell
Invoke-WebRequest 'http://127.0.0.1:15244/api/public/settings'
```

脚本不向标准输出混入连接提示，便于 Agent 直接消费远端命令输出。`-DryRun` 可用于检查最终 OpenSSH 参数而不执行连接：

```powershell
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Mode Tunnel -DryRun
```

如果要临时采集 Go pprof，Agent 需要先通过 `Exec` 停止 OpenRC 服务，再启动一个受管理的长生命周期 debug 命令；不要把 debug 服务作为公网服务运行：

```powershell
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Mode Exec -Command 'rc-service alist stop'
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Mode Tunnel
```

然后由 VM 端的受管理命令启动：

```sh
/opt/alist/alist --debug --data /var/lib/alist --log-std server
```

通过隧道访问：

```powershell
Invoke-WebRequest 'http://127.0.0.1:15244/debug/pprof/'
```

采集完成后停止 debug 进程并执行：

```powershell
& .\tools\windows\Invoke-AlistVmSsh.ps1 -Mode Exec -Command 'rc-service alist start'
```

当前代码只有在 `--debug` 或 `--dev` 下注册 `/debug/pprof/*`，且这些路由没有 AList 用户认证；隧道是必要的访问边界。

### 3.1.4 VMware NAT 网络

当前 VM 使用桥接模式，直接连接 `10.127.1.109:22`。如果改为 VMware NAT，必须先在 VMware Virtual Network Editor 中配置宿主机端口到 VM `22` 的映射；例如宿主机 `127.0.0.1:2222` 映射到 VM `22`，然后使用：

```powershell
& .\tools\windows\Invoke-AlistVmSsh.ps1 -VmHost 127.0.0.1 -SshPort 2222 -Mode Exec -Command 'rc-service alist status'
```

AList HTTP 隧道的远端目标仍是 VM 内的 `127.0.0.1:5244`，不需要额外暴露 5244。NAT 映射、VM 电源状态、Windows 防火墙和 DHCP 地址不由脚本管理。

## 4. 服务操作

```sh
# 启动
rc-service alist start

# 停止
rc-service alist stop

# 重启
rc-service alist restart

# 查看状态
rc-service alist status

# 查看日志
tail -n 100 /var/log/alist.log
```

开机启动已配置：

```sh
rc-update show | grep alist
```

## 5. 修改管理员密码

不要把密码发到聊天，也不要把密码写入命令历史。使用隐藏输入：

```sh
printf 'New admin password: '
read -s ADMIN_PASSWORD
echo
/opt/alist/alist --data /var/lib/alist admin set "$ADMIN_PASSWORD"
unset ADMIN_PASSWORD
```

## 6. IP 地址变化后的处理

先查看新地址：

```sh
ip -4 addr show eth0
```

假设新地址是 `10.127.1.110`，更新 AList 配置：

```sh
VM_IP=10.127.1.110
jq --arg site_url "http://${VM_IP}:5244" --arg dist_dir "/opt/alist/public/dist" '.site_url=$site_url | .dist_dir=$dist_dir | .scheme.address="0.0.0.0" | .scheme.http_port=5244 | .scheme.https_port=-1 | .scheme.force_https=false' /var/lib/alist/config.json > /var/lib/alist/config.json.tmp && mv /var/lib/alist/config.json.tmp /var/lib/alist/config.json
rc-service alist restart
```

同时修改 tvOS App 中的后端地址。

## 7. AList Web 管理

在电脑浏览器打开：

```text
http://<VM_IP>:5244
```

使用 `admin` 登录后：

1. 添加存储。
2. 只选择需要暴露的媒体目录。
3. 不要暴露家目录、SSH 密钥、数据库或工作区。
4. tvOS App 使用同一个地址连接。

## 8. tvOS 使用

Debug App 填写：

```text
http://<VM_IP>:5244
```

连接后使用 AList 用户登录并浏览媒体。

播放链接由 AList 根据 `site_url` 生成，因此以下两项必须一致：

- `/var/lib/alist/config.json` 中的 `site_url`；
- tvOS App 中输入的地址。

## 9. 重新编译（仅源码变化时）

VM 当前已经有编译好的二进制。只有需要重新编译时才执行。

```sh
cd /opt/alist
export HTTP_PROXY=http://10.127.1.247:7897
export HTTPS_PROXY=http://10.127.1.247:7897
export ALL_PROXY=http://10.127.1.247:7897
export GOPROXY=https://proxy.golang.org,direct
mkdir -p /opt/alist/.gotmp /opt/alist/.gocache
rm -rf /opt/alist/.gotmp/*
GOTMPDIR=/opt/alist/.gotmp GOCACHE=/opt/alist/.gocache GOMAXPROCS=1 CGO_ENABLED=1 go build -p 1 -tags=jsoniter -o /opt/alist/alist .
chown alist:alist /opt/alist/alist
rc-service alist restart
```

编译时必须存在：

```text
/opt/alist/public/dist/index.html
```

## 10. 常见问题

### 10.1 服务是 `crashed`

```sh
rc-service alist stop
rm -f /run/alist.pid
tail -n 100 /var/log/alist.log
```

### 10.2 `No space left on device`

编译临时文件不要使用容量约 1 GB 的 `/tmp`，使用上面的 `GOTMPDIR=/opt/alist/.gotmp`。确认空间：

```sh
df -h / /tmp
```

### 10.3 `load config error` 或 JSON 错误

先备份配置，再删除并让 AList 生成默认配置；不要删除 `/var/lib/alist` 整个目录，因为其中包含数据库：

```sh
cp /var/lib/alist/config.json /var/lib/alist/config.json.bad
rm /var/lib/alist/config.json
/opt/alist/alist --data /var/lib/alist --log-std admin
jq empty /var/lib/alist/config.json
```

然后重新写入 `site_url` 和 `scheme`，最后重启服务。

### 10.4 `Exec format error`

修复服务脚本的首行和换行符：

```sh
sed -i 's/\r$//' /etc/init.d/alist
sed -i '1c#!/sbin/openrc-run' /etc/init.d/alist
chmod +x /etc/init.d/alist
```

### 10.5 `group 'alist' not found`

```sh
addgroup -S alist 2>/dev/null || true
adduser alist alist 2>/dev/null || true
chown -R alist:alist /opt/alist /var/lib/alist
```

### 10.6 日志权限错误

```sh
touch /var/log/alist.log
chown alist:alist /var/log/alist.log
chmod 640 /var/log/alist.log
```

## 11. 安全注意

- 不要把任何密码提交到仓库或发到聊天。
- 不要把 AList 端口暴露到公网。
- 不要连接 Alpine 安装 ISO 后再启动，除非要重装系统。
- 修改 `config.json` 后必须重启 AList。
- `site_url` 使用 VM 的局域网地址，不要写 `localhost`。
