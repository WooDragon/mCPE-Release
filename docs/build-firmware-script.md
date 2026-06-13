# 构建脚本契约文档

把原先散落在 `openwrt-builder.yml` 各 step 里的构建核心收敛为可复用脚本，使私有 CI（mCPE-luci-app）能"反向 checkout mCPE-Release → overlay 向导包/provision 文件/机密 → 一次调用出私有镜像"。

---

## 脚本分层

```
scripts/
├── build-lib.sh       # 纯函数库 (零副作用)
├── build-firmware.sh  # 构建入口 (顶层 set -euo pipefail + trap)
└── gen-matrix.sh      # prepare job 薄壳
```

**为何分离库与入口**：`build-lib.sh` 被三方共同 source：`build-firmware.sh`、`gen-matrix.sh`、`tests/bdd-matrix-build.sh`。若库本身带 `set -e`/`trap`，source 进 BDD 进程会把错误陷阱灌进测试框架——纯函数返回非零即杀死整套测试，哪怕是 `[ -f ... ]` 的"期望失败"用例。库的责任边界是函数定义，副作用由入口脚本承载。

### build-lib.sh 暴露的函数

| 函数 | 签名 | 说明 |
|------|------|------|
| `gen_matrix` | `<device>` | 空/"all" → 全设备 JSON 数组；其余 → 单元素数组。prepare job 与 BDD B07-B09 共用 |
| `assemble_config` | `<common> <seed> [extra...]` | 顺序 cat 到 stdout：common（全设备交集）→ seed（设备 delta）→ extra（私有注入支点，后写覆盖前写） |
| `clash_arch` | `<config-file>` | grep `CONFIG_TARGET_x86=y` → `amd64`；否则 → `arm64` |
| `prune_residual_dl` | `<dl-dir>` | `-maxdepth 1 -type f -size -1024c` 只清 dl/ 顶层残缺包（<1 KB）；**严禁递归**，详见下方 |
| `clone_openwrt` | `<repo-url> <branch> <tag> <dest>` | 浅克隆 ImmortalWRT；tag 非空则 fetch + checkout |

---

## build-firmware.sh 参数表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--device <dev>` | **必填** | 设备标识，对应 `devices/<dev>/seed.config`；不存在则立即 exit 1 |
| `--tag <tag>` | `v24.10.6` | ImmortalWRT 源码 tag，传给 `clone_openwrt` |
| `--repo-root <path>` | 见"repo 根解析"节 | mCPE-Release 仓库根目录的绝对路径 |
| `--openwrt-dir <path>` | `./openwrt` | OpenWrt 源码树落点（相对于调用者 cwd，内部立即转绝对路径） |
| `--extra-config <file>` | 空 | 追加到 `.config` 尾部的额外符号文件（私有注入支点）；非空时文件必须存在 |
| `--vars-out <file>` | `build-vars.env` | emit KEY=val 的环境变量文件；详见"接缝设计"节 |
| `--skip-clone` | 不传 = 0 | 跳过 `clone_openwrt`，假定 `--openwrt-dir` 已存在（公开 CI 用，见下方） |

### vars-out 文件的 KEY 列表

脚本在不同阶段逐步 emit 到 `--vars-out` 文件：

| KEY | 来源时机 | 说明 |
|-----|----------|------|
| `VERSION_DIST` | 拼装 .config 后（defconfig 前） | grep `CONFIG_VERSION_DIST=` |
| `VERSION_NUMBER` | 同上 | grep `CONFIG_VERSION_NUMBER=` |
| `VERSION_CODE` | 同上 | grep `CONFIG_VERSION_CODE=` |
| `DEVICE_NAME` | make 完成后 | `_` 前缀 + 从 .config 抽取的上游设备符号（固件重命名用） |
| `FILE_DATE` | make 完成后 | `_` 前缀 + `date +"%Y%m%d%H%M"` |
| `BUILD_STATUS` | make 成功后末尾 | 固定值 `success`；make 失败脚本直接 exit，此行不会出现 |

---

## 三条绝对防御

私有 CI 不跑本仓 BDD 套件，脚本内部必须内建守门逻辑，不能依赖外部测试保障。

### 防御 1：设备强校验

```bash
if [ ! -f "$MCPE_REPO_ROOT/devices/$DEVICE/seed.config" ]; then
  echo "ERROR: Invalid device: $DEVICE (no $SEED)" >&2; exit 1
fi
```

**为何**：`make defconfig` 会静默丢弃无效 `CONFIG_TARGET_*DEVICE*` 符号并回退到上游默认设备（r68s 历史教训：`friendlyarm_nanopi-r68s` 无效，默认出了 `ariaboard_photonicat` 废固件，构建成功但产物不对）。脚本在拼装前校验 seed 存在，无效设备在最早阶段 fail-loud。

### 防御 2：`--skip-clone` 时先 git clean

```bash
git -C "$OPENWRT_DIR" clean -fdx -e dl -e .ccache
```

**为何**：复用已 clone 的源码树时，上次构建残留的 `.config` 碎片、临时包补丁等会污染本次构建。`-e dl -e .ccache` 保留缓存，其余全清，保证构建幂等。不加这一步，多轮调试跑下来几乎必出玄学问题。

### 防御 3：`build-vars.env` 启动即 rm

```bash
rm -f "$VARS_OUT"
emit() { printf '%s=%s\n' "$1" "$2" >> "$VARS_OUT"; }
```

**为何**：脚本在任何校验/退出之前就清空 vars 文件，包括早期 exit 路径。若不清，多轮调试下旧 KEY 残留堆积，`cat >> $GITHUB_ENV` 会把过期值（如上次的 `VERSION_CODE`）灌进当前 step，排查时极难定位。即使校验失败，留下的也是干净（空）文件而非垃圾堆。

---

## repo 根解析优先级

```
--repo-root CLI 参数  >  $MCPE_REPO_ROOT 环境变量  >  脚本物理位置 ($SELF_DIR/..)
```

**严禁 `$(pwd)` 的原因**：反向调用时，私有 CI 在私有 repo 根目录执行 `./mCPE-Release/scripts/build-firmware.sh`，此时 `$(pwd)` 是私有 repo 根（比如 `/workspace/mCPE-luci-app`）。若用 `$(pwd)` 推导 repo 根，脚本会去私有 repo 里找 `devices/<dev>/seed.config`，触发防御 1 强校验误杀构建，更严重的是 `diy-part1.sh`/`diy-part2.sh` 也会找错路径，静默执行私有 repo 里不存在的钩子逻辑。

脚本基于 `BASH_SOURCE[0]` 物理位置（`$SELF_DIR = scripts/`，`$SELF_DIR/..` = mCPE-Release 根）硬寻址，无论从哪个目录调用都正确。`MCPE_REPO_ROOT` 经 `export` 传给下游 `diy-part1.sh`/`diy-part2.sh` 里的设备钩子，它们也需要定位 `devices/<dev>/*.sh`。

---

## 接缝设计：build-vars.env + GHA `cat >> $GITHUB_ENV`

脚本与 CI 之间**不共享进程**，通过文件传递状态：

```bash
# build-firmware.sh 内部
emit VERSION_DIST "MCPE-251228"
emit BUILD_STATUS success

# openwrt-builder.yml build step 末尾
cat "$GITHUB_WORKSPACE/build-vars.env" >> "$GITHUB_ENV"
```

**为何不能 source**：GitHub Actions 每个 step 在独立子进程里执行，`source build-vars.env` 设置的环境变量在 step 结束时随进程销毁，后续 step 看不到。`cat >> $GITHUB_ENV` 是 GHA 官方的跨 step 环境传递机制，写入后当前 job 的所有后续 step 均可通过 `env.KEY` 或 `$KEY` 引用。

---

## 公开 CI 用法（--skip-clone 模式）

公开 CI 用 `--skip-clone` 的原因：GitHub Actions 的 `cache action` 必须**夹在 clone 与 download 之间**才能有效恢复 dl/ 缓存。如果让脚本自己 clone，cache restore 就没有插入点，dl/ 缓存形同虚设（每次全量重下载，构建时间倍增）。

所以公开 CI 把 clone 独立成一个 step，在 clone 和 `build-firmware.sh` 之间插入 `cache action`，然后传 `--skip-clone`：

```yaml
- name: Clone openwrt source code
  working-directory: /workdir
  run: |
    git clone $REPO_URL -b $REPO_BRANCH openwrt --depth=1
    cd openwrt && git fetch --depth=1 origin tag ${{ env.OPENWRT_TAG }}
    git checkout tags/${{ env.OPENWRT_TAG }}

- name: Cache OpenWrt dl & ccache
  uses: actions/cache@v4
  with:
    path: |
      openwrt/dl
      openwrt/.ccache
    key: openwrt-${{ env.OPENWRT_TAG }}-${{ matrix.device }}-...

- name: Build firmware core (build-firmware.sh)
  run: |
    scripts/build-firmware.sh \
      --device "$DEVICE" \
      --tag "$OPENWRT_TAG" \
      --repo-root "$GITHUB_WORKSPACE" \
      --openwrt-dir "$GITHUB_WORKSPACE/openwrt" \
      --skip-clone \
      --vars-out "$GITHUB_WORKSPACE/build-vars.env"
    cat "$GITHUB_WORKSPACE/build-vars.env" >> "$GITHUB_ENV"
```

---

## 私有 CI 反向 checkout 完整用法

这是本脚本抽取的核心价值。mCPE-luci-app 的 CI 反向 checkout mCPE-Release，overlay 向导包/provision 文件/机密后，调同一套脚本出私有镜像。

```yaml
# mCPE-luci-app/.github/workflows/build-private.yml (示意)

jobs:
  build:
    runs-on: ubuntu-22.04
    strategy:
      matrix:
        device: [r2s, r5s-outdoor, x86]  # 按需
    env:
      DEVICE: ${{ matrix.device }}

    steps:
      # 1. checkout 私有 repo 自身 (向导源码 + uci 模板)
      - name: Checkout mCPE-luci-app
        uses: actions/checkout@v4
        with:
          path: mCPE-luci-app

      # 2. 反向 checkout 公开 mCPE-Release (构建脚本单一真相源)
      - name: Checkout mCPE-Release
        uses: actions/checkout@v4
        with:
          repository: WooDragon/mCPE-Release
          path: mCPE-Release

      # 3. overlay wizard app 到 package/
      #    build-firmware.sh 的 diy-part1 会 source devices/<dev>/pre-feeds.sh,
      #    故向导包只需落在 mCPE-Release/package/ 下，feeds install 会纳入
      - name: Overlay wizard package
        run: |
          cp -a mCPE-luci-app/luci-app-mcpe-wizard \
            mCPE-Release/package/luci-app-mcpe-wizard

      # 4. 生成 extra.config 声明 wizard 包符号 (--extra-config 殿后, 后写覆盖)
      - name: Generate extra.config
        run: |
          cat > extra.config <<'EOF'
          CONFIG_PACKAGE_luci-app-mcpe-wizard=y
          EOF

      # 5. 把 provision 文件/uci 模板放 files/ (build-firmware.sh 会 cp 进 openwrt/files)
      - name: Overlay provision files
        run: |
          cp -a mCPE-luci-app/files mCPE-Release/files

      # 6. 用 Actions Secrets 渲染机密占位符 (C 类机密必须走 Secrets)
      #    sed 内联替换模板里的 __FRP_TOKEN__ 等占位符
      - name: Render secrets into templates
        env:
          FRP_TOKEN: ${{ secrets.FRP_TOKEN }}
          PUSHBOT_TOKEN: ${{ secrets.PUSHBOT_TOKEN }}
        run: |
          find mCPE-Release/files -type f \( -name "*.conf" -o -name "*.sh" \) | xargs \
            sed -i "s|__FRP_TOKEN__|${FRP_TOKEN}|g; s|__PUSHBOT_TOKEN__|${PUSHBOT_TOKEN}|g"

      # 7. 调 build-firmware.sh —— 不传 --skip-clone, 让脚本自己 clone
      #    (私有 CI 无 cache action 约束, 无需分离 clone step)
      - name: Build private firmware
        run: |
          chmod +x mCPE-Release/scripts/build-firmware.sh
          mCPE-Release/scripts/build-firmware.sh \
            --device "$DEVICE" \
            --tag "v24.10.6" \
            --repo-root "./mCPE-Release" \
            --openwrt-dir "./openwrt" \
            --extra-config "./extra.config" \
            --vars-out "./build-vars.env"

      # 8. 产物发私有 S3 (固件烤进了 C 类机密, 绝对不发公开 GitHub Release)
      - name: Upload to private S3
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.S3_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.S3_SECRET }}
        run: |
          source ./build-vars.env
          # 固件路径由 make 产出; 替换为实际 S3 桶名
          aws s3 cp openwrt/bin/targets/ \
            "s3://<私有桶名>/firmware/${DEVICE}/${FILE_DATE}/" \
            --recursive --exclude "packages/*"
```

---

## 安全铁律

### C 类机密必须走 GitHub Actions Secrets

GitHub Actions 的公开 run log 对所有人可见。Secrets 在 log 里自动 mask 为 `***`，但**从私有 repo checkout 进来的文件内容不是 secret**，不会被 mask。任何 `set -x`、`cat`、`echo` 都会把文件里的明文机密打进公开 log。

机密（frp token/sk、pushbot pp_token、clash 面板密码）必须在 `mCPE-Release` 的 Actions Secrets 中声明，私有 repo 文件里只放占位符（如 `__FRP_TOKEN__`），由 action step 6 在构建时填充。

### 烤进机密的固件必须发私有 S3，禁止发公开 GitHub Release

这是物理事实，不是策略：`binwalk` 解包公开 Release 中的固件 → 直接读出所有烤进去的明文机密。Secrets 只保护构建日志，保护不了已公开的产物。公开 mCPE-Release 的 GitHub Release 只发干净基础固件（零业务配置，无机密）；私有镜像（含 C 类机密）必须发私有 S3。
