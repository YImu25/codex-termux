#!/data/data/com.termux/files/usr/bin/bash
# Codex CLI 一键安装脚本 — Termux / Android（proot-distro + Ubuntu 22.04）
# 用法：curl -fsSL https://raw.githubusercontent.com/YImu25/codex-termux/main/codex-install.sh | bash
# 可选：CODEX_VERSION=rust-v0.153.2、CODEX_FORCE=1、NO_MIRROR=1
set -Eeuo pipefail

C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
say() { printf '%b\n' "$*"; }
die() { say "${R}错误：$*${N}" >&2; exit 1; }
stage='启动'
tmp_outer=''
on_error() { local rc=$?; say "${R}失败阶段：${stage}（退出码 ${rc}）${N}" >&2; exit "$rc"; }
cleanup() { [ -z "$tmp_outer" ] || rm -f -- "$tmp_outer"; }
trap on_error ERR
trap cleanup EXIT INT TERM

[ -n "${PREFIX:-}" ] || die '请在 Termux 中运行此脚本。'
case "$(uname -m)" in
  aarch64|arm64) target='aarch64-unknown-linux-musl'; apt_kind='ports' ;;
  x86_64|amd64) target='x86_64-unknown-linux-musl'; apt_kind='main' ;;
  *) die "当前架构 $(uname -m) 没有受支持的官方 Codex 二进制。" ;;
esac
mirror=1; [ "${NO_MIRROR:-0}" = 1 ] && mirror=0

say "${C}Codex CLI Termux 安装器（安全修订版）${N}"
say "架构：${target}"

stage='安装 Termux 依赖'
pkg update -y -o Dpkg::Use-Pty=0
pkg install -y proot-distro curl ca-certificates -o Dpkg::Use-Pty=0
command -v proot-distro >/dev/null || die 'proot-distro 安装失败。'

stage='安装 Ubuntu'
DISTRO=codex-ubuntu
if ! proot-distro login "$DISTRO" -- /bin/true >/dev/null 2>&1; then
  say "${Y}首次安装独立的 Ubuntu 22.04 容器：${DISTRO}${N}"
  say "${Y}现有的 ubuntu 容器不会被删除或修改。${N}"
  proot-distro install ubuntu:22.04 --name "$DISTRO"
fi

stage='生成容器安装程序'
tmp_outer="$(mktemp)"
cat >"$tmp_outer" <<'UBUNTU_SCRIPT'
#!/bin/bash
set -Eeuo pipefail
MIRROR=$1
TARGET=$2
APT_KIND=$3
VERSION=${CODEX_VERSION:-latest}
FORCE=${CODEX_FORCE:-0}
stage='初始化'
work=''; rollback=''; changed=0
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
on_error() {
  local rc=$?
  printf '安装失败：%s（退出码 %s）\n' "$stage" "$rc" >&2
  if [ "$changed" = 1 ] && [ -n "$rollback" ] && [ -d "$rollback" ]; then
    printf '正在恢复旧版组件……\n' >&2
    for n in codex codex-code-mode-host codex-app-server; do
      [ ! -e "$rollback/$n" ] || install -m 0755 "$rollback/$n" "/usr/local/bin/$n"
    done
  fi
  exit "$rc"
}
cleanup() { [ -z "$work" ] || rm -rf -- "$work"; [ -z "$rollback" ] || rm -rf -- "$rollback"; }
trap on_error ERR
trap cleanup EXIT INT TERM

stage='配置 Ubuntu 软件源'
if [ "$MIRROR" = 1 ]; then
  stamp=$(date +%Y%m%d-%H%M%S)
  backup_dir=/var/backups/codex-termux
  mkdir -p "$backup_dir"
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    src=/etc/apt/sources.list.d/ubuntu.sources
    if [ -e "${src}.codex-original" ] && [ ! -e "$backup_dir/ubuntu.sources.original" ]; then
      cp -a "${src}.codex-original" "$backup_dir/ubuntu.sources.original"
    fi
    [ -e "$backup_dir/ubuntu.sources.original" ] || cp -a "$src" "$backup_dir/ubuntu.sources.original"
    cp -a "$src" "$backup_dir/ubuntu.sources.${stamp}"
    if [ "$APT_KIND" = ports ]; then uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports'; else uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu'; fi
    sed -E "s|^URIs:[[:space:]]+.*|URIs: $uri|" "$src" >"${src}.tmp"
    mv "${src}.tmp" "$src"
  elif [ -f /etc/apt/sources.list ]; then
    src=/etc/apt/sources.list
    [ -e "$backup_dir/sources.list.original" ] || cp -a "$src" "$backup_dir/sources.list.original"
    cp -a "$src" "$backup_dir/sources.list.${stamp}"
    if [ "$APT_KIND" = ports ]; then uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports'; else uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu'; fi
    sed -E "s|https?://[^ ]+/ubuntu(-ports)?|$uri|g" "$src" >"${src}.tmp"
    mv "${src}.tmp" "$src"
  fi
fi

stage='安装 Ubuntu 依赖'
export DEBIAN_FRONTEND=noninteractive
apt_log=$(mktemp)
if ! apt-get update 2>&1 | tee "$apt_log" \
   || grep -Eqi 'Failed to fetch|certificate verify failed|Some index files failed' "$apt_log"; then
  printf '镜像更新失败，自动切换 Ubuntu 官方源后重试。\n' >&2
  if [ "${src:-}" = /etc/apt/sources.list.d/ubuntu.sources ]; then
    if [ "$APT_KIND" = ports ]; then official='http://ports.ubuntu.com/ubuntu-ports'; else official='http://archive.ubuntu.com/ubuntu'; fi
    sed -E "s|^URIs:[[:space:]]+.*|URIs: $official|" "$src" >"${src}.tmp"
    mv "${src}.tmp" "$src"
  elif [ "${src:-}" = /etc/apt/sources.list ]; then
    if [ "$APT_KIND" = ports ]; then official='http://ports.ubuntu.com/ubuntu-ports'; else official='http://archive.ubuntu.com/ubuntu'; fi
    sed -E "s|https?://[^ ]+/ubuntu(-ports)?|$official|g" "$src" >"${src}.tmp"
    mv "${src}.tmp" "$src"
  else
    fail '找不到可恢复的 Ubuntu 软件源配置。'
  fi
  apt-get update
fi
rm -f "$apt_log"
apt-get install -y -q curl ca-certificates python3 python3-tomlkit tar gzip coreutils

stage='查询官方 Release'
work=$(mktemp -d)
api="$work/release.json"
if [ "$VERSION" = latest ]; then release_api='https://api.github.com/repos/openai/codex/releases/latest'; else release_api="https://api.github.com/repos/openai/codex/releases/tags/$VERSION"; fi
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 20 \
  "$release_api" -o "$api"
meta_file="$work/release-meta.txt"
printf 'Release 元数据：%s 字节\n' "$(wc -c <"$api")"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); target=sys.argv[2]
if d.get("draft") or d.get("prerelease"):
    raise SystemExit("拒绝安装草稿或预发布版本")
print(d["tag_name"])
for prefix in ("codex","codex-code-mode-host","codex-app-server"):
    name=f"{prefix}-{target}.tar.gz"
    asset=next((x for x in d.get("assets",[]) if x.get("name")==name),None)
    if not asset or not str(asset.get("digest","")).startswith("sha256:"):
        raise SystemExit("官方 Release 缺少资产或 SHA-256："+name)
    print("\t".join((prefix,name,asset["browser_download_url"],asset["digest"][7:])))
' "$api" "$TARGET" >"$meta_file" || fail 'Release JSON 解析失败。'
readarray -t meta <"$meta_file"
tag=${meta[0]:-}; [ -n "$tag" ] || fail '无法解析官方版本。'
printf '已解析官方版本：%s（%s 个组件）\n' "$tag" "$((${#meta[@]} - 1))"

current=''
[ ! -f /usr/local/share/codex-termux/release ] || current=$(cat /usr/local/share/codex-termux/release)
if [ "$FORCE" != 1 ] && [ "$current" = "$tag" ] && command -v codex >/dev/null \
   && command -v codex-code-mode-host >/dev/null && command -v codex-app-server >/dev/null; then
  printf '已是最新/指定版本 %s，跳过组件下载。\n' "$tag"
else
  stage='下载并校验组件'
  mkdir -p "$work/stage"
  for line in "${meta[@]:1}"; do
    IFS=$'\t' read -r command asset official digest <<<"$line"
    archive="$work/$asset"; ok=0
    urls=("$official")
    if [ "$MIRROR" = 1 ]; then urls=("https://gh-proxy.com/$official" "https://ghproxy.net/$official" "$official"); fi
    for url in "${urls[@]}"; do
      rm -f "$archive"
      printf '下载 %s：%s\n' "$asset" "$url"
      if curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 20 -o "$archive" "$url" \
         && printf '%s  %s\n' "$digest" "$archive" | sha256sum -c - \
         && gzip -t "$archive"; then ok=1; break; fi
      printf '该地址无效或校验失败，尝试下一地址。\n' >&2
    done
    [ "$ok" = 1 ] || fail "所有下载地址均失败：$asset"
    python3 - "$archive" <<'PY'
import pathlib,sys,tarfile
with tarfile.open(sys.argv[1],'r:gz') as t:
 for m in t.getmembers():
  p=pathlib.PurePosixPath(m.name)
  if p.is_absolute() or '..' in p.parts or m.issym() or m.islnk():
   raise SystemExit('压缩包包含不安全路径或链接：'+m.name)
PY
    mkdir -p "$work/unpack"; rm -rf "$work/unpack"/*
    tar -xzf "$archive" --no-same-owner -C "$work/unpack"
    found=$(find "$work/unpack" -type f -name "${command}-${TARGET}" -print -quit)
    [ -n "$found" ] || fail "压缩包内找不到预期文件：${command}-${TARGET}"
    install -m 0755 "$found" "$work/stage/$command"
  done
  "$work/stage/codex" --version | grep -F "${tag#rust-v}" >/dev/null || fail 'Codex 自检版本与 Release 不一致。'
  stage='原子替换组件'
  rollback=$(mktemp -d)
  for n in codex codex-code-mode-host codex-app-server; do [ ! -e "/usr/local/bin/$n" ] || cp -a "/usr/local/bin/$n" "$rollback/$n"; done
  changed=1
  for n in codex codex-code-mode-host codex-app-server; do install -m 0755 "$work/stage/$n" "/usr/local/bin/.${n}.new"; mv -f "/usr/local/bin/.${n}.new" "/usr/local/bin/$n"; done
  mkdir -p /usr/local/share/codex-termux
  printf '%s\n' "$tag" >/usr/local/share/codex-termux/release.tmp
  mv /usr/local/share/codex-termux/release.tmp /usr/local/share/codex-termux/release
  changed=0
fi

stage='安装 cx 助手'
cx_tmp=$(mktemp /usr/local/bin/.cx.XXXXXX)
cat >"$cx_tmp" <<'CX'
#!/bin/bash
set -euo pipefail
CFG=${HOME}/.codex/config.toml
ENVF=${HOME}/.config/codex/env
mkdir -p "$(dirname "$CFG")" "$(dirname "$ENVF")"
[ -f "$CFG" ] || : >"$CFG"
toml_set() {
 python3 - "$CFG" "$@" <<'PY'
import pathlib,sys,tomlkit
p=pathlib.Path(sys.argv[1]); d=tomlkit.parse(p.read_text() or '')
op=sys.argv[2]
if op=='model': d['model']=sys.argv[4]; d['model_provider']=sys.argv[3]
elif op=='provider':
 pid,name,url,key=sys.argv[3:7]
 t=d.setdefault('model_providers',tomlkit.table()).setdefault(pid,tomlkit.table())
 t['name']=name; t['base_url']=url; t['env_key']=key; t['wire_api']='responses'
tmp=p.with_suffix('.tmp'); tmp.write_text(tomlkit.dumps(d)); tomlkit.parse(tmp.read_text()); tmp.replace(p)
PY
}
list() { python3 - "$CFG" <<'PY'
import sys,tomlkit
d=tomlkit.parse(open(sys.argv[1]).read() or '')
print('当前：%s/%s'%(d.get('model_provider','(默认)'),d.get('model','(默认)')))
for p in d.get('model_providers',{}): print(' ·',p)
PY
}
use_model() {
 local spec=${1:-} p m
 [[ "$spec" == */* ]] || { echo '格式：cx use <provider>/<model>'; return 1; }
 p=${spec%%/*}; m=${spec#*/}
 [[ "$p" =~ ^[A-Za-z0-9_-]+$ ]] || { echo '中转站代号只能包含英文字母、数字、下划线和短横线'; return 1; }
 [ -n "$m" ] && [[ "$m" != *$'\n'* ]] || { echo '模型名无效'; return 1; }
 toml_set model "$p" "$m"; echo "已切换：$p/$m"
}
add_provider() {
 local pid name url key model
 echo '提示：中转站必须支持 /v1/responses 接口。'
 read -rp '中转站代号（例如：myrelay）：' pid
 [[ "$pid" =~ ^[A-Za-z0-9_-]+$ ]] || { echo '代号只能包含英文字母、数字、下划线和短横线'; return 1; }
 read -rp '中转站名称（可填中文）：' name; [ -n "$name" ] || return 1
 read -rp '接口地址（例如：https://example.com/v1）：' url
 [[ "$url" =~ ^https:// ]] || [[ "$url" =~ ^http://(localhost|127\.0\.0\.1)([:/]|$) ]] || { echo '接口地址必须以 https:// 开头；本机地址可以使用 http://'; return 1; }
 read -rp '模型名称（必须与中转站提供的一致）：' model; [ -n "$model" ] || return 1
 key=$(printf '%s_API_KEY' "$pid" | tr '[:lower:]-' '[:upper:]_')
 toml_set provider "$pid" "$name" "$url" "$key"
 use_model "$pid/$model"
 echo '现在请输入该中转站的密钥。'
 set_key "$key"
}
set_key() {
 local key=${1:-} value tmp
 if [ -z "$key" ]; then
   read -rp '密钥变量名称：' key
 fi
 [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo '密钥变量名称无效'; return 1; }
 read -rsp '中转站密钥（输入时不会显示）：' value; echo
 tmp=$(mktemp "${ENVF}.XXXXXX")
 [ ! -f "$ENVF" ] || grep -vE "^export ${key}=" "$ENVF" >"$tmp"
 printf 'export %s=%q\n' "$key" "$value" >>"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$ENVF"
 unset value; echo "密钥已安全保存。"
}
menu() { while true; do echo; list; printf '\n1) 切换模型  2) 添加中转站  3) 修改中转站密钥  4) 编辑高级配置  5) 启动 Codex  0) 返回\n'; read -rp '请选择：' n; case "$n" in 1) read -rp '请输入“中转站代号/模型名称”：' s; use_model "$s";; 2) add_provider;; 3) set_key;; 4) "${EDITOR:-vi}" "$CFG";; 5) exec codex;; 0) break;; *) echo '无效选择，请重新输入。';; esac; done; }
case ${1:-menu} in menu) menu;; list) list;; use) use_model "${2:-}";; add) add_provider;; key) set_key;; edit) exec "${EDITOR:-vi}" "$CFG";; *) echo '可用命令：cx list（查看）、cx use（切换）、cx add（添加）、cx key（密钥）、cx edit（高级配置）'; exit 1;; esac
CX
chmod 0755 "$cx_tmp"; mv -f "$cx_tmp" /usr/local/bin/cx

stage='初始化安全配置'
mkdir -p "$HOME/.codex" "$HOME/.config/codex"
if [ -s "$HOME/.codex/config.toml" ]; then
  cp -a "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.bak.$(date +%Y%m%d-%H%M%S)"
  python3 -c 'import sys,tomlkit; tomlkit.parse(open(sys.argv[1]).read())' "$HOME/.codex/config.toml" || fail '已有 config.toml 无法解析，已保留且未修改。'
else
  printf '# Codex 配置；默认保留官方权限策略\n' >"$HOME/.codex/config.toml"
fi
if [ ! -e "$HOME/.codex/AGENTS.md" ]; then
  printf '# 全局指令\n\n请始终使用简体中文回复用户。\n' >"$HOME/.codex/AGENTS.md"
fi

stage='验证安装'
for n in codex codex-code-mode-host codex-app-server cx; do command -v "$n" >/dev/null && [ -x "$(command -v "$n")" ] || fail "$n 不存在或不可执行"; done
python3 -c 'import sys,tomlkit; tomlkit.parse(open(sys.argv[1]).read())' "$HOME/.codex/config.toml"
codex --version
codex features list >/dev/null
codex mcp list >/dev/null
printf '容器内安装与验证完成：%s\n' "$tag"
UBUNTU_SCRIPT
chmod 700 "$tmp_outer"

stage='在 Ubuntu 内安装 Codex'
CODEX_VERSION=${CODEX_VERSION:-latest} CODEX_FORCE=${CODEX_FORCE:-0} \
  proot-distro login "$DISTRO" --shared-tmp -- bash "$tmp_outer" "$mirror" "$target" "$apt_kind"

install_wrapper() {
  local name content dst stamp
  name=$1
  content=$2
  dst="$PREFIX/bin/$name"
  if [ -e "$dst" ] && ! grep -q 'codex-termux-managed' "$dst" 2>/dev/null; then
    stamp=$(date +%Y%m%d-%H%M%S); cp -a "$dst" "${dst}.bak.${stamp}"
    say "${Y}已备份原有 $dst → ${dst}.bak.${stamp}${N}"
  fi
  local t; t=$(mktemp "${dst}.XXXXXX"); printf '%s\n' "$content" >"$t"; chmod 0755 "$t"; mv -f "$t" "$dst"
}
stage='写入 Termux 包装命令'
install_wrapper codex '#!/data/data/com.termux/files/usr/bin/bash
# codex-termux-managed
exec proot-distro login --isolated codex-ubuntu -- bash -lc '\''[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; exec codex "$@"'\'' bash "$@"'
install_wrapper cx '#!/data/data/com.termux/files/usr/bin/bash
# codex-termux-managed
safe_codex() {
  proot-distro login --isolated codex-ubuntu -- bash -lc '\''[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; exec codex "$@"'\'' bash "$@"
}
storage_codex() {
  [ -d "$HOME/storage/shared" ] || { echo "请先运行 termux-setup-storage 并允许授权"; return 1; }
  proot-distro login codex-ubuntu --bind "$HOME/storage/shared:/sdcard" -- bash -lc '\''[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; cd /sdcard; exec codex "$@"'\'' bash "$@"
}
inner_cx() {
  proot-distro login --isolated codex-ubuntu -- bash -lc '\''[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; exec cx "$@"'\'' bash "$@"
}
show_menu() {
  local choice
  while true; do
    echo
    echo "════════════════════════════════════"
    echo "  Codex Termux 助手"
    echo "════════════════════════════════════"
    echo "  1) 启动 Codex（安全模式）"
    echo "  2) 启动 Codex（读写手机存储）"
    echo "  3) 模型、中转站与密钥管理"
    echo "  4) 查看 Codex 版本"
    echo "  5) 进入 Ubuntu 22.04"
    echo "  6) 更新 Codex 与助手"
    echo "  0) 退出"
    echo "════════════════════════════════════"
    read -rp "请选择 [0-6]：" choice
    case "$choice" in
      1) safe_codex ;;
      2) storage_codex ;;
      3) inner_cx ;;
      4) proot-distro login --isolated codex-ubuntu -- codex --version ;;
      5) proot-distro login codex-ubuntu ;;
      6) curl -fL "https://raw.githubusercontent.com/YImu25/codex-termux/main/codex-install.sh?update=$(date +%s)" | bash ;;
      0) echo "再见"; break ;;
      *) echo "无效选择，请重新输入。" ;;
    esac
  done
}
case "${1:-}" in
  ""|menu) show_menu ;;
  start) shift; safe_codex "$@" ;;
  storage) shift; storage_codex "$@" ;;
  ubuntu) exec proot-distro login codex-ubuntu ;;
  version) exec proot-distro login --isolated codex-ubuntu -- codex --version ;;
  update) exec bash -c '\''curl -fL "https://raw.githubusercontent.com/YImu25/codex-termux/main/codex-install.sh?update=$(date +%s)" | bash'\'' ;;
  help|-h|--help)
    echo "用法：cx [menu|start|storage|version|ubuntu|update|list|use|add|key|edit]" ;;
  *) inner_cx "$@" ;;
esac'

say "${G}安装完成。${N}"
say '  codex       安全启动（仅容器）'
say '  cx          模型与 Provider 管理'
say '  cx storage  主动授权后读写手机共享存储'
say "${Y}本脚本不启用 Android/Magisk root，也不默认写入 danger-full-access。${N}"
