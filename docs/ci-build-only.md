# OpenWrt Builder：特性分支只构建

本文面向使用 GitHub Actions 和 `gh` 的维护者。入口是同一份 [OpenWrt Builder workflow](../.github/workflows/openwrt-builder.yml)，不是另一个精简编译流程。

## 输入与执行边界

`publish` 是 boolean 输入，默认 `true`。旧调用不传它时保留原发布和历史清理行为。**只构建应显式传 `publish=false`**；仅关闭 `UPLOAD_RELEASE` 不能禁止历史 workflow runs 删除。

| 输入 | 完整编译 | firmware artifact | Release/tag 发布 | 历史 runs、Release/tag 清理 |
|---|---|---|---|---|
| 不传或 `true` | 执行 | 上传 | 保留原资格条件 | 保留原资格条件 |
| `false` | 执行 | 上传 | 跳过 | 跳过 |

只构建仍使用正常的依赖安装、源码克隆、缓存、`build-firmware.sh` 和完整 make。`publish` 不控制编译。此模式仍向 Actions 写入日志、缓存及 artifact，不代表零远程写入。

firmware artifact 沿用原命名，并包含 `build-provenance.json`（构建来源记录）。它受仓库访问权限和 Actions 保留期约束，不承诺永久留存。public 仓库的 artifact 不应当作私密分发渠道；本入口不注入业务机密。

## 从指定特性分支启动

条件：目标分支已经包含本入口和待构建改动，且对应的提交、上传与 CI 已获授权。当前无线故障隔离验收只构建 `r5s-outdoor`，不发布、不删除历史、不合并、不刷机。

启动时应使用明确的分支名，并显式关闭发布。例如，目标分支为 `fix/mt7921-fail-stop` 时：

```bash
gh workflow run openwrt-builder.yml \
  --ref fix/mt7921-fail-stop \
  -f device=r5s-outdoor \
  -f openwrt_tag=v24.10.6 \
  -f publish=false
```

预期结果是目标分支产生一个新的 workflow_dispatch run。若目标分支尚无新 workflow，旧入口不能提供只构建合同；不应以省略参数或修改默认值代替核验。

启动后应定位此次 run，核对分支、SHA、触发事件与启动时间，不把旧 main run 当成目标构建：

```bash
gh run list --workflow openwrt-builder.yml \
  --branch fix/mt7921-fail-stop --event workflow_dispatch --limit 5 \
  --json databaseId,headBranch,headSha,event,createdAt,status,conclusion
```

这里的查询用于绑定新 run，不是定时监控。三个 checkout 都检出 run 的 `github.sha`，不跟随执行期间移动的分支 tip。build 在昂贵构建前比较实际 HEAD 与 dispatch SHA；不符时失败，不进入编译。

## 后台等待与完成核验

条件：已经核对目标 run ID。应只为该 run 启动后台等待进程，例如：

```bash
gh run watch <run-id> --interval 120 --exit-status
```

执行器应将该命令置于后台，并使用进程完成通知。CLI 的内部等待不需要模型反复查询；不创建 Cron，不每几分钟唤醒模型，也不派 agent 空等。若进程失败或监控异常，应读取具体错误，不盲重跑完整构建。

收到完成通知后，应核对实际 conclusion、job/step 状态和来源：

```bash
gh run view <run-id> --json headBranch,headSha,status,conclusion,jobs
gh run download <run-id> --name '<firmware-artifact-name>' --dir '<new-output-directory>'
```

预期结果：完整 compile 成功，来源记录与 firmware artifact 上传成功；以下四个步骤均为 `skipped`：

- Generate release tag
- Upload firmware to release
- Delete workflow runs
- Remove old Releases by device

下载目录应包含真实固件，而不只是来源记录或日志。`build-provenance.json` 的字段应满足：

| 字段 | 核验对象 |
|---|---|
| `repository`、`ref`、`source_sha` | 本仓库、目标分支，以及 run 的 `headSha` |
| `openwrt_sha`、`openwrt_tag` | 实际上游 checkout SHA 和请求的 tag；两者不互相替代 |
| `device` | 本次构建设备 |
| `run_id`、`run_attempt` | 此次 run 及重跑次数 |
| `publish` | 字符串 `false` |

来源记录在编译后再次比较实际本仓 HEAD、dispatch SHA 和编译前验证的 SHA；不符时不写成功输出。上游 SHA 从独立 OpenWrt Git checkout 读取。artifact 上传要求来源记录成功，无路径时失败。

run 的成功、完整 make 日志、下载的真实固件及匹配来源共同构成构建证据。本地 BDD 不运行完整固件编译或远程 action，不能代替这组证据。构建成功也不证明无线真机稳定性或 ownership 硬件根因已修复。

## 本地回归

在仓库根目录执行：

```bash
bash tests/bdd-ci-build-only.sh
```

suite 读取实际 workflow，执行来源核验、编译入口及来源记录的真实 run 块。编译边界使用临时目录中的替身，测试不调用远程 Release/DELETE API。它输出逐例结果及 `ran/passed/failed/expected`，用例缺失、未知相关语法或失败均返回非零；lint job 同样执行它。

## 撤回边界

workflow、独立 BDD/fixture 与本文属于同一个 CI 合同。撤回应经特性分支 revert 和 PR，不直接本地合并到 main。

撤回会恢复旧 workflow 的默认发布与历史清理。此后不应继续把 `publish=false` 当成安全入口；参数说明和 suite 应一并撤回。已经开始的 run 使用其原 revision 的 workflow，不受后续 revert 追溯修改。撤回不自动取消 run 或删除 artifact/Release/tag，这些操作需要各自授权。
