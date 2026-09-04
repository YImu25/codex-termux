# Codex CLI for Termux

在 Android 的 Termux 中，通过独立的 `proot-distro + Ubuntu 22.04` 容器运行官方 Codex CLI，避免直接执行 Linux ELF 时出现 `unexpected e_type: 2`。容器名为 `codex-ubuntu`，不会删除或修改已有的 `ubuntu` 容器。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/YImu25/codex-termux/main/codex-install.sh | bash
```

安装后：

```bash
codex          # 安全启动，仅访问 Ubuntu 容器
cx             # 打开手机端总菜单
cx storage     # 明确授权后，从 /sdcard 启动 Codex
```

`cx` 菜单包含安全启动、手机存储启动、模型和中转站管理、查看版本、进入 Ubuntu 22.04 和一键更新。菜单提示全部使用中文；添加中转站时，密钥变量名称会自动生成。

脚本默认不启用 `danger-full-access`，不启用 Magisk/Android root，也不把手机共享存储加入普通启动路径。API Key 保存在 Ubuntu 容器内的 `~/.config/codex/env`，权限为 `600`。

## 测试方式

首次安装：

```bash
bash -n codex-install.sh
bash codex-install.sh
codex --version
```

重复安装（同版本应跳过三项组件下载）：

```bash
bash codex-install.sh
```

升级或安装指定版本：

```bash
CODEX_VERSION=rust-v0.153.2 bash codex-install.sh
```

强制重新下载同一版本的全部组件：

```bash
CODEX_FORCE=1 bash codex-install.sh
```

完全不修改 apt 镜像且不使用下载代理：

```bash
NO_MIRROR=1 bash codex-install.sh
```

架构测试：Android `aarch64/arm64` 会选择官方 `aarch64-unknown-linux-musl` 资产和 `ubuntu-ports` 镜像；`x86_64/amd64` 会选择 `x86_64-unknown-linux-musl` 资产和普通 Ubuntu 镜像。其他架构会在下载前退出。

## 安全和升级机制

- 从官方 GitHub Release API 获取稳定版本、下载地址和 SHA-256 digest。
- 所有下载只允许 HTTPS；镜像无效、返回 HTML 或摘要不符时自动换源。
- 检查 gzip、tar 路径穿越及符号/硬链接，只安装三个预期组件。
- 三个组件必须来自同一个 Release；暂存验证后再替换，失败时恢复旧版。
- 不覆盖已有 `AGENTS.md`；已有 `config.toml` 会先备份、解析验证并保留。
- 非本项目创建的 Termux `codex`、`cx` 包装器会先生成时间戳备份。

## 卸载与恢复

删除 Termux 包装命令：

```bash
rm "$PREFIX/bin/codex" "$PREFIX/bin/cx"
```

完整删除 Ubuntu 容器会删除其中的 Codex、配置和数据，请先自行备份，然后执行：

```bash
proot-distro remove codex-ubuntu
```

恢复包装器备份时，找到对应的时间戳文件后执行：

```bash
ls "$PREFIX/bin/codex.bak."* "$PREFIX/bin/cx.bak."* 2>/dev/null
cp "$PREFIX/bin/codex.bak.时间戳" "$PREFIX/bin/codex"
cp "$PREFIX/bin/cx.bak.时间戳" "$PREFIX/bin/cx"
```

Ubuntu 软件源备份保存在容器内的 `/var/backups/codex-termux/`；配置备份位于 `~/.codex/config.toml.bak.时间戳`。
