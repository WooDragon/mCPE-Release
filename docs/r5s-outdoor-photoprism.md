# R5S Outdoor — PhotoPrism 架构与运行边界

本文定义 `r5s-outdoor` 的 PhotoPrism 集成范围、存储所有权和安全边界。它不提供目标设备操作步骤。

> **前置阅读**：操作者配置 SSD 的唯一挂载身份与 `outdoor-backup` 数据树前，必须先读取：
> [r5s-outdoor-backup-setup.md](r5s-outdoor-backup-setup.md)
>
> **前置阅读**：操作者执行启停、恢复、升级或回滚前，必须先读取：
> [r5s-outdoor-photoprism-operations.md](r5s-outdoor-photoprism-operations.md)

## 适用范围与实现状态

本集成只适用于 `r5s-outdoor`。其他设备不会安装其运行时文件，也不受其必装包守卫约束。

构建将默认写入 `photoprism.main.enabled='1'`。默认启用不等于自动选择磁盘。服务只有在操作者已配置并启用唯一的 `fstab.outdoor_backup_target` 后才可启动。该 section 必须包含确认过的 SSD 文件系统 UUID、`target='/mnt/ssd'` 和 `enabled='1'`。

服务复用现有 SSD。服务不猜测设备名，不格式化、不分区、不迁移数据，也不复制 UUID 到自己的 UCI 配置。存储守卫拒绝无法证明为非系统盘的布局。它也拒绝普通目录、符号链接、只读挂载、UUID 不匹配和错误的文件系统。

本工作树的本地验证已覆盖 mock 接缝和真实交付 shell 的文件描述符保护。PhotoPrism BDD 有 20 个场景与 93 项断言，均通过。matrix BDD 的记录为 126 通过、0 失败、1 跳过；跳过项是旧 r2s 基线引用缺失。上述结果不证明 OpenWrt `defconfig`、完整编译、ARM64 冷启动、镜像拉取、PhotoPrism 索引、LuCI 浏览器或 fw4 数据包策略已经在真机验证。

## SSD 归属与数据树

PhotoPrism 只接受挂载在 `/mnt/ssd` 的独立 `ext4` 或 `btrfs` 文件系统。`exFAT` 和 `NTFS3` 可服务既有备份，但不被 PhotoPrism 视为 Docker 与 SQLite 的可接受数据根。

唯一的应用数据树如下：

```text
/mnt/ssd/PhotoPrism/
├── docker/                 # 受管 dockerd 的 data root
├── originals/              # PhotoPrism 照片原件库，初始为空
├── storage/                # SQLite index.db、缩略图、缓存
└── secrets/photoprism.env  # 初始管理员记录，root:root，0600
```

`/mnt/ssd/SDMirrors` 仍是 `outdoor-backup` 的备份根。PhotoPrism 不索引、导入、移动、删除或重命名其中的任何内容。照片应由操作者上传到 PhotoPrism，或写入 `PhotoPrism/originals` 后再由 PhotoPrism 索引。

普通文件描述符保护仅覆盖守卫能够保持的正常挂载语义。它不保证 lazy 或 forced 卸载、运行中物理掉盘、内核设备错误后的路径安全。操作者在卸载 SSD 前应停止所有使用该盘的容器及受管 `dockerd`，而不是只停止 PhotoPrism。

## Docker 所有权与启动模型

`dockerd.globals.data_root` 是 Docker 所有权的唯一事实源。只有以下条件同时成立时，PhotoPrism worker 才可声明 `/mnt/ssd/PhotoPrism/docker`：

- 当前 data root 缺失或精确为 `/opt/docker/`；
- `dockerd` 没有运行；
- `/opt/docker/` 不存在，或存在但为空；
- 没有外部 Docker JSON 配置；
- SSD 守卫已验证并准备数据树。

已有 Docker 自定义 data root、已有 Docker 数据、运行中的 daemon 或外部 JSON 配置均不受本服务接管。服务应拒绝启动，而不改写 Docker 配置、迁移容器、重启 daemon 或扫描现有容器。

受管 data root 已建立后，`dockerd` 是全局 daemon。存储守卫应在 daemon 启动前验证 SSD；`photoprism.main.enabled='0'` 只阻止本项目启动并停止本项目容器。它不应关闭受管 `dockerd`，因为该 daemon 仍可服务其他容器。

服务使用固定 Compose project `mcpe-photoprism`，只操作带该 project 和 `photoprism` service labels 的唯一容器。停止服务不会执行 `down -v`，不会删除原图、SQLite、secret 或其他容器。

## 应用、镜像与网络合同

Compose 文件 `/usr/share/photoprism/compose.yaml` 是唯一镜像版本真相源。它固定一个 ARM64 PhotoPrism tag 和 manifest digest；升级或回滚应以该文件中的完整镜像引用为准，不应使用 `latest` 或另行猜测 tag。

Compose 只声明一个 PhotoPrism 容器。容器使用 SQLite，不部署 MariaDB、PostgreSQL 或 Redis。容器关闭 Faces、Classification 与 TensorFlow，并将 worker 数固定为 1。它不设置 hard memory limit。

容器使用 host network，不声明 Docker `ports` 发布规则。worker 仅接受有效的当前 LAN IPv4，并把 PhotoPrism 绑定到该地址的 TCP 2342 端口。服务不新增 WAN 防火墙规则、redirect 或 ACCEPT 规则。

此设计避免 Docker published-port DNAT 绕过宿主机 INPUT/WAN 策略，但尚未进行 fw4 或 nft 数据包真机测试。LAN 可访问和 WAN 不可访问 2342 均属于后续真机验收项，不能从 Compose 配置推断为已验证事实。

初次启动需要网络拉取固定镜像。拉取或 Compose 启动失败时，worker 会记录失败并退出，不会无界重试。操作者可在网络恢复后显式重新启动服务。

## 凭证状态与访问边界

`/mnt/ssd/PhotoPrism/secrets/photoprism.env` 只允许 root 拥有的普通文件，权限必须为 `0600`。文件只允许一行 `PHOTOPRISM_ADMIN_PASSWORD=` 和 32 个十六进制字符。服务不会将该值写入 UCI、日志、Compose 文件或镜像。

凭证处理按 SQLite `storage/index.db` 与 secret 的存在性分为四态：

| `index.db` | secret | 服务行为 |
|---|---|---|
| 不存在 | 不存在 | 在受保护的 SSD 目录中创建一个新的合法初始记录，然后允许首次启动。 |
| 不存在 | 合法 | 复用该记录，然后允许首次启动。 |
| 存在 | 缺失或不合法 | 拒绝启动，不生成也不覆盖凭证。 |
| 存在 | 合法 | 正常启动，但不把该记录视为当前数据库密码。 |

初始记录仅代表 bootstrap。管理员日后通过 `photoprism passwd admin` 改密后，env 文件不再证明当前数据库密码。数据库已存在而记录丢失时，操作者应先放入合法记录以通过 env-file 门禁，再启动容器，最后在容器运行时执行密码重设。服务不应自动假定新记录会重设既有数据库密码。

host root 与 Docker 管理员可检查容器环境。这是 Docker 的固有信任边界，不构成凭证隔离机制。

`luci-app-filemanager` 是轻量文件浏览器。LuCI 已认证管理员具有全文件系统 `/*` 的读、写和执行权限。它不是 `/mnt/ssd` 沙箱。现有 `luci-app-filetransfer` 保持不变，二者用途不同。

## 内存与 swap

服务不会自动创建 swap，也不会修改分区或现有数据。没有 swap 时，固定 `workers=1` 仍可能在大 RAW 文件或大规模索引时发生内存不足。

操作者可在确认 SSD 空间、备份策略和文件系统条件后手工配置 4 GB swap。ext4 与 btrfs 的条件不同。btrfs swapfile 必须满足 NOCOW、预分配和 `map-swapfile` 可验证等条件。若设备未安装所需工具，操作者应先核实可用工具与文件系统条件，而不应套用未经验证的一键命令。任何前提不满足时，操作者应保持分区数据不变。

## 升级保留与真机验收

升级保留列表明确保留 `/etc/config/photoprism`。因此已设置的 `enabled='0'` 在正常保留配置的 sysupgrade 后仍应保持。PhotoPrism 数据树位于独立 SSD；固件升级不应删除它。

后续真机验收应至少证明以下事实：正确 SSD 冷启动后 Docker data root 与 driver 矩阵正确；缺盘或错盘不会写入 overlay；LAN 能访问 2342，WAN 不能访问；首次密码与重启行为正确；上传照片能够生成缩略图；以及 WiFi、ASPM、netdata 与 `outdoor-backup` 没有回归。当前本地结果不替代这些验收。