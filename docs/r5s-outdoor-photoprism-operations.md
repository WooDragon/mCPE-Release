# R5S Outdoor — PhotoPrism 操作手册

本文面向已经刷入含 PhotoPrism 集成的 `r5s-outdoor`。本文只描述操作者可执行的运行时操作；本仓库不会替操作者执行任何目标设备命令。

> **前置阅读**：本文假定操作者已为现有 SSD 创建并验证唯一的 `fstab.outdoor_backup_target`。配置或重新核验 UUID、`/mnt/ssd` 挂载和 `SDMirrors` 备份树前，必须先读取：
> [r5s-outdoor-backup-setup.md](r5s-outdoor-backup-setup.md)
>
> **前置阅读**：操作前需要理解存储保护、Docker 所有权、凭证四态、LuCI 文件管理器权限或真机验证边界时，必须先读取：
> [r5s-outdoor-photoprism.md](r5s-outdoor-photoprism.md)

## 1. 首次启动前的条件

操作者应先完成备份手册的 SSD 配置。预期结果是 `fstab.outdoor_backup_target` 的 `uuid` 为操作者确认的 SSD 文件系统 UUID，`target` 精确为 `/mnt/ssd`，且 `enabled` 为 `1`。

```sh
uci get fstab.outdoor_backup_target.uuid
uci get fstab.outdoor_backup_target.target
uci get fstab.outdoor_backup_target.enabled
mount | grep ' on /mnt/ssd '
block info
```

操作者应将 `block info` 中实际挂载 SSD 的 UUID 与 UCI 值逐字比较。普通目录 `/mnt/ssd` 存在不证明 SSD 已挂载。若 UUID、目标或挂载来源不一致，操作者应保持 PhotoPrism 停止状态，并先修复 SSD 配置。

PhotoPrism 只接受独立的 `ext4` 或 `btrfs` SSD。服务拒绝系统盘、无法证明为非系统盘的设备、只读挂载和不支持的文件系统。操作者不应通过格式化、重新分区、迁移已有 Docker 数据或改写设备路径来绕过这些拒绝。

## 2. 启动、状态和日志

新版预置镜像固件的首次启动不需要 WAN。若 SSD 条件正确，操作者应启动服务。预期结果是 worker 完成存储、凭证和 Docker 检查，再校验本地镜像；首次导入固件内归档需要等待，不能因初始状态未就绪而判定失败。

```sh
/etc/init.d/photoprism start
/etc/init.d/photoprism status
```

`status` 至少输出 `enabled`、`worker`、`stopping` 和 `container`。只有 `container=running` 表示 PhotoPrism 已运行。`worker=running` 只表示启动或停止过程仍在执行。若启动失败，worker 会退出；操作者应读取日志，而不应假设退出代表成功。

```sh
logread -e photoprism
logread -e photoprism-storage
/etc/init.d/photoprism status
```

常见的拒绝原因包括 SSD 未挂载、UUID 不一致、文件系统不受支持、SSD 不是独立非系统盘、已有 Docker 所有权、无效 LAN IPv4、镜像规范、本地镜像或固件内归档校验失败，以及已有数据库却缺失合法凭证记录。操作者修复已报告的前提后，可显式再次运行 `start`。服务不会自动循环重试。

新版预置镜像固件在正确 SSD 配置后，先在本地校验并按需导入归档，再启动 Compose。它不需要 WAN。已部署的旧固件不含该归档；离线传入物料时，操作者应使用 [issue #59 的传入方法](https://github.com/WooDragon/mCPE-Release/issues/59#issuecomment-5809205574)。该方法只传入物料，不安装、不导入也不启动服务，不能视为修复已经完成。

### 2.1 经审阅存储守卫补丁的受限热修

本节是已部署旧固件的存储守卫离线救援路径，不替代新版预置镜像固件的本地初始化。当前补丁尚未发布，本文不提供远端下载地址。操作者应只将经审阅的本工作树文件 `devices/r5s-outdoor/photoprism/files/usr/libexec/photoprism/storage-guard.sh` 通过可信传输放到设备的 `/tmp/storage-guard.sh.new`。

操作者只应在确认本次拒绝属于该存储拓扑误拒绝时执行以下脚本。此热修只适用于原本未运行 PhotoPrism 且 `dockerd` inactive 的状态。`dockerd.globals.data_root` 应仍精确为 `/opt/docker/`，且不应设置 `dockerd.globals.alt_config_file`。设备上的 `/usr/libexec/photoprism/storage-guard.sh` 必须是常规非符号链接文件。

```sh
(
    set -eu

    service=/etc/init.d/photoprism
    target=/usr/libexec/photoprism/storage-guard.sh
    candidate=/tmp/storage-guard.sh.new
    staged=''

    fail() {
        printf '%s\n' "$1" >&2
        exit 1
    }
    # shellcheck disable=SC2329
    cleanup() {
        [ -z "${staged:-}" ] || rm -f -- "$staged"
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    for command in timeout flock pidof; do
        command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
    done
    exec 8>/var/run/photoprism.lock
    timeout 5 flock 8 || fail 'cannot acquire the PhotoPrism runtime lock'
    [ ! -e /var/run/photoprism.stopping ] && [ ! -L /var/run/photoprism.stopping ] || fail 'PhotoPrism stopping marker is present'
    [ ! -e /var/run/photoprism.cancel ] && [ ! -L /var/run/photoprism.cancel ] || fail 'PhotoPrism cancel marker is present'

    if /etc/init.d/dockerd running >/dev/null 2>&1 || pidof dockerd >/dev/null 2>&1; then
        fail 'dockerd is active'
    fi

    data_root=$(uci -q get dockerd.globals.data_root || true)
    [ "$data_root" = '/opt/docker/' ] || fail 'dockerd data_root is not the default'
    alt_config_file=$(uci -q get dockerd.globals.alt_config_file || true)
    [ -z "$alt_config_file" ] || fail 'dockerd has alt_config_file'

    [ -f "$target" ] && [ ! -L "$target" ] || fail 'installed guard is not a regular non-symlink file'
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || fail 'candidate is not a regular non-symlink file'
    sh -n "$candidate"
    sh "$candidate" verify

    backup_dir=$(mktemp -d /root/photoprism-storage-guard.backup.XXXXXX)
    cp -p "$target" "$backup_dir/storage-guard.sh"
    printf 'storage-guard backup: %s\n' "$backup_dir"

    target_dir=${target%/*}
    staged=$(mktemp "$target_dir/.storage-guard.sh.XXXXXX")
    cp "$candidate" "$staged"
    chown root:root "$staged"
    chmod 0755 "$staged"
    mv -f "$staged" "$target"
    staged=''

    flock -u 8
    exec 8>&-
    "$service" start
)
```

脚本在替换前运行 `sh -n` 和 `sh /tmp/storage-guard.sh.new verify`。脚本以 FD 8 取得运行时锁，并在锁持有期间拒绝活跃 worker、停止标记或 cancel 标记。任一步失败时，子 shell 会终止，并保留已安装的旧脚本。热修遇到活跃 worker 或停止标记时，操作者应先排查状态，不应强行停止服务或清除标记。脚本在替换后释放 FD 8，再只启动 `photoprism`。脚本不单独启动 Docker，也不改写 `data_root`。

脚本成功退出后，操作者应检查服务和日志：

```sh
/etc/init.d/photoprism status
logread -e photoprism-storage
logread -e photoprism
uci get network.lan.ipaddr
```

本节热修只替换旧固件的存储守卫，不安装 `stat`，也不增加离线镜像导入逻辑。随后执行的 `start` 仍使用旧 worker；运行依赖缺失、镜像尚未按其引用导入或缺少联网拉取条件时，服务仍可能启动失败。仅替换守卫或传入 #59 的离线物料不等于完成离线恢复。只有确认 `container=running` 后，操作者才应从 LAN 核验 `http://<LAN IPv4>:2342/`。

### 2.2 回滚受限热修

操作者应先停止 PhotoPrism。若 `stop` 失败，回滚脚本应退出，且不覆盖守卫文件。操作者应核对热修脚本打印的备份目录。然后操作者可将该目录代入以下脚本，恢复同一个守卫文件。该脚本在目标目录创建暂存文件，再原子替换目标文件。当前回滚脚本仅在 Docker 查询成功且本项目容器不存在、因而 init stop 能成功时可继续。已有项目容器时，当前停止流程会被自身标记拦截；在 [issue #58](https://github.com/WooDragon/mCPE-Release/issues/58) 修复前，不能将下述脚本视为已启动系统的可用回滚方案。操作者不应手工清除停止标记，也不应停止全局 Docker 来绕过该限制。

```sh
BACKUP_DIR='/root/photoprism-storage-guard.backup.XXXXXX'
(
    set -eu

    service=/etc/init.d/photoprism
    target=/usr/libexec/photoprism/storage-guard.sh
    backup="$BACKUP_DIR/storage-guard.sh"
    staged=''

    fail() {
        printf '%s\n' "$1" >&2
        exit 1
    }
    # shellcheck disable=SC2329
    cleanup() {
        [ -z "${staged:-}" ] || rm -f -- "$staged"
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    "$service" stop
    [ -f "$target" ] && [ ! -L "$target" ] || fail 'installed guard is not a regular non-symlink file'
    [ -f "$backup" ] && [ ! -L "$backup" ] || fail 'backup is not a regular non-symlink file'

    target_dir=${target%/*}
    staged=$(mktemp "$target_dir/.storage-guard.sh.XXXXXX")
    cp -p "$backup" "$staged"
    chown root:root "$staged"
    chmod 0755 "$staged"
    mv -f "$staged" "$target"
    staged=''
)
```

操作者不应删除 SSD 数据，不应改写 Docker data root，也不应停止其他消费者。回滚守卫脚本不会撤销热修启动后已经产生的数据或已接管的配置。恢复旧守卫后，该存储布局仍可能被拒绝。

## 3. LAN 访问与照片导入

服务从当前 `network.lan.ipaddr` 读取有效 LAN IPv4，并监听该地址的 TCP 2342。操作者应先读取该地址，再从 LAN 内的浏览器访问对应 URL。

```sh
uci get network.lan.ipaddr
```

例如，若输出为 `192.168.233.1` 或 `192.168.233.1/24`，访问地址为 `http://192.168.233.1:2342/`。

Compose 使用 host network，且不发布 Docker 端口。集成没有新增 WAN 规则、redirect 或 ACCEPT 规则。当前尚未在真机执行 fw4／nft 数据包测试；操作者不应把“host network”视为 WAN 隔离已经验收。后续真机验收应分别从 LAN 和 WAN 侧测试 TCP 2342。

照片库目录为 `/mnt/ssd/PhotoPrism/originals`。操作者可通过 PhotoPrism 上传照片，也可使用 LuCI 文件管理器把照片放入该目录。`/mnt/ssd/SDMirrors` 是 `outdoor-backup` 专用备份树，操作者不应把它设为照片库，也不应让 PhotoPrism 索引它。

LuCI 的 `luci-app-filemanager` 向已认证 LuCI 管理员开放全文件系统 `/*` 的读、写和执行权限。它不是 SSD 限定的安全沙箱。操作者应只授予受信任管理员该 LuCI 访问权。现有 `luci-app-filetransfer` 仍保留；它不替代文件浏览器。

## 4. 启用、停用和停止

要暂时停止 PhotoPrism，但保留 SQLite、原图和初始凭证记录，操作者应先设置 UCI 开关，再停止服务。预期结果是 `mcpe-photoprism` 容器停止，数据树不被删除。

```sh
uci set photoprism.main.enabled='0'
uci commit photoprism
/etc/init.d/photoprism stop
/etc/init.d/photoprism status
```

`enabled='0'` 不会关闭受管 `dockerd`。`dockerd` 是全局 daemon，仍可被其他容器使用。操作者不应以停用 PhotoPrism 为由删除 Docker data root 或停止不属于 `mcpe-photoprism` 的容器。

要重新启用 PhotoPrism，操作者应先确认 SSD 的 UUID 与挂载仍正确，然后恢复开关并显式启动。预期结果是 `container=running`。

```sh
uci set photoprism.main.enabled='1'
uci commit photoprism
/etc/init.d/photoprism start
/etc/init.d/photoprism status
```

仅执行 `/etc/init.d/photoprism enable` 不能替代 UCI `enabled='1'`。前者控制 init 启动链接，后者控制 worker 是否执行 Compose。

## 5. 安全卸载 SSD

在卸载 SSD 前，操作者应先识别所有使用 `/mnt/ssd` 的容器和服务。然后操作者应停止所有这些容器以及使用该盘的受管 `dockerd`。预期结果是没有容器或 daemon 继续持有 SSD 数据树。

```sh
/etc/init.d/photoprism stop
docker ps -a
/etc/init.d/dockerd stop
```

仅停止 PhotoPrism 不足以安全卸载 SSD，因为受管 `dockerd` 或其他容器可能仍使用 `/mnt/ssd/PhotoPrism/docker`。操作者应只在确认所有该盘消费者停止后执行正常卸载。

操作者不应在服务运行时使用 lazy 卸载、forced 卸载或物理拔盘。普通文件描述符保护不保证这些操作后的路径安全。若发生掉盘或设备错误，操作者应停止依赖该盘的服务，恢复正确挂载后再显式启动服务。

## 6. 凭证恢复

首次启动时，若 SQLite `storage/index.db` 和 secret 都不存在，服务会创建 root:root、`0600` 的单行初始凭证记录。操作者应在安全位置保存该记录。该记录只用于 bootstrap，不保证等于管理员后来改过的当前密码。

若 `index.db` 已存在但 `secrets/photoprism.env` 缺失、权限错误、不是普通文件或内容不合法，服务应拒绝启动。操作者不应删除数据库，也不应期待服务自动生成新记录来重设数据库管理员密码。

恢复时，root 应先恢复此前保存的合法初始记录；若无法找回，root 可创建合法 bootstrap 记录，仅用于通过 `env_file` 门禁。然后操作者应启动容器。只有 `container=running` 后，操作者才可在容器内重设当前管理员密码：

```sh
(
    set -eu
    unset DOCKER_HOST DOCKER_CONTEXT
    ids=$(docker -H unix:///var/run/docker.sock ps -q \
        --filter label=com.docker.compose.project=mcpe-photoprism \
        --filter label=com.docker.compose.service=photoprism) || {
        printf '%s\n' 'cannot list the PhotoPrism container' >&2
        exit 1
    }
    count=$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l)
    case "$count" in
        1) id=$(printf '%s\n' "$ids" | sed '/^$/d') ;;
        0) printf '%s\n' 'PhotoPrism container is absent' >&2; exit 1 ;;
        *) printf '%s\n' 'PhotoPrism container is ambiguous' >&2; exit 1 ;;
    esac
    exec docker -H unix:///var/run/docker.sock exec -it "$id" photoprism passwd admin
)
```

该命令需要交互输入。它不读取 Compose 文件、不依赖 `PHOTOPRISM_HTTP_HOST`，且不会打印凭证。容器缺失或存在多个匹配容器时，命令应向标准错误输出原因并以非零状态退出。容器未运行时，操作者不应使用容器内密码重设作为恢复手段。

## 7. 升级、回滚和数据保留

镜像升级与回滚的唯一版本来源是 `/usr/share/photoprism/image-spec.sh`。升级镜像时，维护者应更新该规范，并重新准备匹配的归档和校验文件。操作者不应手改 Compose 镜像引用，也不应使用 `latest`。当前集成不自动执行 SQLite schema 回滚。

正常 sysupgrade 会通过 `/lib/upgrade/keep.d/photoprism` 保留 `/etc/config/photoprism`。因此，操作者设置的 `enabled='0'` 应被保留。`/mnt/ssd/PhotoPrism` 位于独立 SSD，固件升级不应删除其中的数据。

若操作者需要保留数据地回滚集成或镜像，顺序应如下：

1. 停止 PhotoPrism。
2. 保留 `/mnt/ssd/PhotoPrism`、`/mnt/ssd/SDMirrors`、SQLite、原图和 secret。
3. 回退固件集成及其匹配的镜像规范与归档。
4. 重新核验 SSD 的 UUID 与挂载。
5. 显式启动 PhotoPrism 并检查 `container=running`。

操作者不应执行 `docker compose down -v`、宽泛 Docker cleanup、格式化、分区重建或删除 SQLite／`SDMirrors` 作为回滚步骤。

## 8. 可选 4 GB swap

集成不会自动创建 swap。操作者可在明确需要额外内存、SSD 空间充足且已有备份时，手工规划 4 GB swap。此操作会写入 SSD，但不应修改分区表或销毁已有数据。

在 ext4 上，操作者应先核实设备实际提供的 swapfile 创建与启用工具，再执行与该工具匹配的步骤。在 btrfs 上，操作者必须先确认 NOCOW、预分配、单设备和单一 data profile 等条件，并验证 `btrfs filesystem mkswapfile` 与 `btrfs inspect-internal map-swapfile` 可用且成功。若工具缺失、条件不满足或验证失败，操作者应停止，不应尝试未经验证的通用 `fallocate`、`dd` 或压缩文件绕过方案。

没有 swap 时，服务以 `PHOTOPRISM_WORKERS=1` 运行，但大 RAW 文件或大型索引仍可能耗尽内存。操作者应通过实际内存压力与日志判断是否需要手工 swap，而不应假定 4 GB 对所有照片库都足够。