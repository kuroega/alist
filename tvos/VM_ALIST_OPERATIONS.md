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
