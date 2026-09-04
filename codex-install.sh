#!/data/data/com.termux/files/usr/bin/bash
# Codex CLI 一键安装脚本 — Termux / Android（proot-distro + Ubuntu 22.04）
# 用法：curl -fsSL https://raw.githubusercontent.com/YImu25/codex-termux/main/codex-install.sh | bash
# 可选：CODEX_VERSION=rust-v0.153.2、CODEX_FORCE=1、NO_MIRROR=1
set -Eeuo pipefail

C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
say() { printf '%b\n' "$*"; }
die() { say "${R}错误：$*${N}" >&2; exit 1; }
stage='启动'
tmp_outer=''; wrapper_tmp=''
on_error() { local rc=$?; say "${R}失败阶段：${stage}（退出码 ${rc}）${N}" >&2; exit "$rc"; }
cleanup() {
  [ -z "$tmp_outer" ] || rm -f -- "$tmp_outer"
  [ -z "$wrapper_tmp" ] || rm -f -- "$wrapper_tmp"
}
on_signal() { trap - EXIT ERR INT TERM; cleanup; exit 130; }
trap on_error ERR
trap cleanup EXIT
trap on_signal INT TERM

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
CODEX_UPDATE_ONLY=${CODEX_UPDATE_ONLY:-0}
stage='初始化'
work=''; rollback=''; apt_log=''; cx_tmp=''; changed=0
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
if [ "$VERSION" != latest ] && ! [[ "$VERSION" =~ ^rust-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail 'CODEX_VERSION 只能是 latest 或 rust-v主版本.次版本.修订版本'
fi
on_error() {
  local rc=$?
  printf '安装失败：%s（退出码 %s）\n' "$stage" "$rc" >&2
  if [ "$changed" = 1 ] && [ -n "$rollback" ] && [ -d "$rollback" ]; then
    printf '正在恢复旧版组件……\n' >&2
    for n in codex codex-code-mode-host codex-app-server; do
      if [ -e "$rollback/$n" ]; then
        install -m 0755 "$rollback/$n" "/usr/local/bin/$n"
      elif [ -e "$rollback/$n.absent" ]; then
        rm -f "/usr/local/bin/$n"
      fi
    done
  fi
  exit "$rc"
}
cleanup() {
  [ -z "$work" ] || rm -rf -- "$work"
  [ -z "$rollback" ] || rm -rf -- "$rollback"
  [ -z "$apt_log" ] || rm -f -- "$apt_log"
  [ -z "$cx_tmp" ] || rm -f -- "$cx_tmp"
}
on_signal() { trap - EXIT ERR INT TERM; cleanup; exit 130; }
trap on_error ERR
trap cleanup EXIT
trap on_signal INT TERM

stage='配置 Ubuntu 软件源'
if [ "$MIRROR" = 1 ]; then
  stamp=$(date +%Y%m%d-%H%M%S)
  backup_dir=/var/backups/codex-termux
  mkdir -p "$backup_dir"
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    src=/etc/apt/sources.list.d/ubuntu.sources
    legacy_original="${src}.codex-original"
    if [ -e "$legacy_original" ]; then
      [ -e "$backup_dir/ubuntu.sources.original" ] || cp -a "$legacy_original" "$backup_dir/ubuntu.sources.original"
      mv "$legacy_original" "$backup_dir/ubuntu.sources.legacy-original.${stamp}"
    fi
    for legacy_backup in "${src}.bak."*; do
      [ -e "$legacy_backup" ] || continue
      mv "$legacy_backup" "$backup_dir/$(basename "$legacy_backup").legacy.${stamp}"
    done
    [ -e "$backup_dir/ubuntu.sources.original" ] || cp -a "$src" "$backup_dir/ubuntu.sources.original"
    if [ "$APT_KIND" = ports ]; then uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports'; else uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu'; fi
    if ! grep -Fq "URIs: $uri" "$src"; then
      cp -a "$src" "$backup_dir/ubuntu.sources.${stamp}"
      sed -E "s|^URIs:[[:space:]]+.*|URIs: $uri|" "$src" >"${src}.tmp"
      mv "${src}.tmp" "$src"
    fi
  elif [ -f /etc/apt/sources.list ]; then
    src=/etc/apt/sources.list
    [ -e "$backup_dir/sources.list.original" ] || cp -a "$src" "$backup_dir/sources.list.original"
    if [ "$APT_KIND" = ports ]; then uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports'; else uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu'; fi
    if ! grep -Fq "$uri" "$src"; then
      cp -a "$src" "$backup_dir/sources.list.${stamp}"
      sed -E "s|https?://[^ ]+/ubuntu(-ports)?|$uri|g" "$src" >"${src}.tmp"
      mv "${src}.tmp" "$src"
    fi
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
  if not (m.isfile() or m.isdir()):
   raise SystemExit('压缩包包含不允许的特殊文件：'+m.name)
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
  for n in codex codex-code-mode-host codex-app-server; do
    if [ -e "/usr/local/bin/$n" ]; then
      cp -a "/usr/local/bin/$n" "$rollback/$n"
    else
      : >"$rollback/$n.absent"
    fi
  done
  changed=1
  for n in codex codex-code-mode-host codex-app-server; do install -m 0755 "$work/stage/$n" "/usr/local/bin/.${n}.new"; mv -f "/usr/local/bin/.${n}.new" "/usr/local/bin/$n"; done
  mkdir -p /usr/local/share/codex-termux
  printf '%s\n' "$tag" >/usr/local/share/codex-termux/release.tmp
  mv /usr/local/share/codex-termux/release.tmp /usr/local/share/codex-termux/release
  changed=0
fi

if [ "$CODEX_UPDATE_ONLY" = 1 ]; then
  printf 'Codex 组件更新完成：%s\n' "$tag"
  exit 0
fi

stage='安装 cx 助手'
cx_tmp=$(mktemp /usr/local/bin/.cx.XXXXXX)
cat >"$cx_tmp" <<'CX'
#!/bin/bash
set -euo pipefail
CFG=${HOME}/.codex/config.toml
ENVF=${HOME}/.config/codex/env
MODELF=${HOME}/.config/codex/models.tsv
mkdir -p "$(dirname "$CFG")" "$(dirname "$ENVF")"
[ -f "$CFG" ] || : >"$CFG"
[ -f "$MODELF" ] || : >"$MODELF"
chmod 600 "$MODELF"
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
model_store() {
 python3 - "$MODELF" "$@" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); op=sys.argv[2]
rows=[]
for line in p.read_text().splitlines():
    parts=line.split('\t',1)
    if len(parts)==2 and parts[0] and parts[1]: rows.append(parts)
def save():
    tmp=p.with_suffix('.tmp')
    tmp.write_text(''.join(a+'\t'+b+'\n' for a,b in rows))
    tmp.chmod(0o600); tmp.replace(p)
if op=='add':
    row=[sys.argv[3],sys.argv[4]]
    if row not in rows: rows.append(row); save()
elif op=='list':
    for i,(a,b) in enumerate(rows,1): print(f'  （{i}）{a}/{b}')
elif op=='get':
    i=int(sys.argv[3])-1
    if i<0 or i>=len(rows): raise SystemExit(2)
    print(rows[i][0]+'\t'+rows[i][1])
elif op=='edit':
    i=int(sys.argv[3])-1
    if i<0 or i>=len(rows): raise SystemExit(2)
    old=rows[i]; new=[sys.argv[4],sys.argv[5]]
    rows[i]=new
    rows[:]=[r for n,r in enumerate(rows) if r!=new or n==i]
    save(); print(old[0]+'\t'+old[1])
PY
}
valid_model() {
 local p=$1 m=$2
 [[ "$p" =~ ^[A-Za-z0-9_-]+$ ]] || { echo '中转站代号只能包含英文字母、数字、下划线和短横线'; return 1; }
 [ -n "$m" ] && [[ "$m" != *$'\n'* ]] && [[ "$m" != *$'\t'* ]] || { echo '模型名无效'; return 1; }
}
remember_model() { model_store add "$1" "$2"; }
list() { python3 - "$CFG" <<'PY'
import sys,tomlkit
d=tomlkit.parse(open(sys.argv[1]).read() or '')
print('当前：%s/%s'%(d.get('model_provider','(默认)'),d.get('model','(默认)')))
for p in d.get('model_providers',{}): print(' ·',p)
PY
}
use_model() {
 local spec=${1:-} p m
 [[ "$spec" == */* ]] || { echo '格式：cx use <中转站代号>/<模型名称>'; return 1; }
 p=${spec%%/*}; m=${spec#*/}
 valid_model "$p" "$m" || return 1
 toml_set model "$p" "$m"; remember_model "$p" "$m"; echo "已切换：$p/$m"
}
show_models() {
 echo '已添加的模型：'
 if [ ! -s "$MODELF" ]; then echo '  （暂无）'; else model_store list; fi
}
choose_model() {
 local n row p m
 show_models; [ -s "$MODELF" ] || return 0
 read -rp '输入模型序号（0 返回）：' n
 [ "$n" = 0 ] && return 0
 row=$(model_store get "$n") || { echo '无效序号。'; return 1; }
 IFS=$'\t' read -r p m <<<"$row"; use_model "$p/$m"
}
edit_model() {
 local n row oldp oldm p m
 show_models; [ -s "$MODELF" ] || return 0
 read -rp '输入要编辑的模型序号（0 返回）：' n; [ "$n" = 0 ] && return 0
 row=$(model_store get "$n") || { echo '无效序号。'; return 1; }
 IFS=$'\t' read -r oldp oldm <<<"$row"
 read -rp "中转站代号 [$oldp]：" p; p=${p:-$oldp}
 read -rp "模型名称 [$oldm]：" m; m=${m:-$oldm}
 valid_model "$p" "$m" || return 1
 model_store edit "$n" "$p" "$m" >/dev/null
 python3 - "$CFG" "$oldp" "$oldm" "$p" "$m" <<'PY'
import pathlib,sys,tomlkit
f,op,om,np,nm=sys.argv[1:]; path=pathlib.Path(f); d=tomlkit.parse(path.read_text() or '')
if d.get('model_provider')==op and d.get('model')==om:
 d['model_provider']=np; d['model']=nm
 t=path.with_suffix('.tmp'); t.write_text(tomlkit.dumps(d)); t.replace(path)
PY
 echo "已修改：$oldp/$oldm → $p/$m"
}
delete_model() {
 local n row p m current
 show_models; [ -s "$MODELF" ] || return 0
 read -rp '输入要删除的模型序号（0 返回）：' n; [ "$n" = 0 ] && return 0
 row=$(model_store get "$n") || { echo '无效序号。'; return 1; }
 IFS=$'\t' read -r p m <<<"$row"
 current=$(python3 - "$CFG" <<'PY'
import sys,tomlkit
d=tomlkit.parse(open(sys.argv[1]).read() or '')
print(str(d.get('model_provider',''))+'\t'+str(d.get('model','')))
PY
)
 [ "$row" != "$current" ] || { echo '不能删除当前正在使用的模型，请先切换到其他模型。'; return 1; }
 read -rp "确认删除 $p/$m？请输入 y：" answer
 [ "$answer" = y ] || { echo '已取消。'; return 0; }
 python3 - "$MODELF" "$n" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); i=int(sys.argv[2])-1; rows=p.read_text().splitlines()
if i<0 or i>=len(rows): raise SystemExit(2)
rows.pop(i); t=p.with_suffix('.tmp'); t.write_text(''.join(x+'\n' for x in rows)); t.chmod(0o600); t.replace(p)
PY
 echo "已删除：$p/$m"
}
model_menu() {
 local n s
 while true; do
  echo; echo '────────── 切换与管理模型 ──────────'
  echo '  （1）查看并切换已添加的模型'
  echo '  （2）手动添加并切换模型'
  echo '  （3）编辑已添加的模型'
  echo '  （4）删除已添加的模型'
  echo '  （0）返回'
  read -rp '请选择 [0-4]：' n
  case "$n" in
   1) choose_model || true ;;
   2) read -rp '请输入“中转站代号/模型名称”：' s; use_model "$s" || true ;;
   3) edit_model || true ;;
   4) delete_model || true ;;
   0) break ;;
   *) echo '无效选择，请重新输入。' ;;
  esac
 done
}
save_key_value() {
 local key=$1 value=$2 tmp
 [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo '密钥变量名称无效'; return 1; }
 [ -n "$value" ] || { echo '密钥不能为空'; return 1; }
 tmp=$(mktemp "${ENVF}.XXXXXX")
 if [ -f "$ENVF" ]; then
   grep -vE "^export ${key}=" "$ENVF" >"$tmp" || true
 fi
 printf 'export %s=%q\n' "$key" "$value" >>"$tmp"
 chmod 600 "$tmp"; mv "$tmp" "$ENVF"
}
REMOTE_MODELS=()
fetch_provider_models() {
 local url=$1 token=$2 tmp
 REMOTE_MODELS=()
 tmp=$(mktemp)
 if ! curl --proto '=https' --tlsv1.2 -fsS --retry 2 --connect-timeout 15 --max-time 30 \
   -H "Authorization: Bearer $token" -H 'Accept: application/json' \
   "${url%/}/models" -o "$tmp"; then
   rm -f "$tmp"
   echo '自动获取模型列表失败，将改为手动输入模型名称。'
   return 1
 fi
 mapfile -t REMOTE_MODELS < <(python3 - "$tmp" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(2)
items=d.get('data',[]) if isinstance(d,dict) else []
seen=set()
for item in items:
    if isinstance(item,dict):
        mid=item.get('id')
        if isinstance(mid,str) and mid and mid not in seen and '\n' not in mid and '\t' not in mid:
            seen.add(mid); print(mid)
PY
 )
 rm -f "$tmp"
 [ "${#REMOTE_MODELS[@]}" -gt 0 ] || {
   echo '接口已响应，但没有解析到标准 OpenAI /v1/models 列表，将改为手动输入。'
   return 1
 }
 return 0
}
select_remote_model() {
 local n i
 SELECTED_MODEL=''
 echo
 echo "已自动获取 ${#REMOTE_MODELS[@]} 个模型："
 for i in "${!REMOTE_MODELS[@]}"; do printf '  （%d）%s\n' "$((i+1))" "${REMOTE_MODELS[$i]}"; done
 echo '  （0）手动输入模型名称'
 echo
 echo '注意：新版 Codex 仅支持 Responses API；中转站列表里的模型不一定全部兼容 Codex。'
 read -rp "请选择模型 [0-${#REMOTE_MODELS[@]}]：" n
 if [ "$n" = 0 ]; then
   read -rp '模型名称：' SELECTED_MODEL
 elif [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#REMOTE_MODELS[@]}" ]; then
   SELECTED_MODEL=${REMOTE_MODELS[$((n-1))]}
 else
   echo '无效选择。'; return 1
 fi
 [ -n "$SELECTED_MODEL" ] || { echo '模型名称不能为空。'; return 1; }
}
set_provider_preset() {
 local kind=$1
 PRESET_WARN=''
 case "$kind" in
   1) PRESET_PID='tokenrhythm'; PRESET_NAME='基元律动 TokenRhythm'; PRESET_URL='https://tokenrhythm.studio/v1'; PRESET_OK=1 ;;
   2) PRESET_PID='openai_official'; PRESET_NAME='OpenAI 官方'; PRESET_URL='https://api.openai.com/v1'; PRESET_OK=1 ;;
   3) PRESET_PID='deepseek'; PRESET_NAME='DeepSeek 官方'; PRESET_URL='https://api.deepseek.com'; PRESET_OK=1 ;;
   4) PRESET_PID='doubao'; PRESET_NAME='火山方舟 / 豆包'; PRESET_URL='https://ark.cn-beijing.volces.com/api/v3'; PRESET_OK=1 ;;
   5) PRESET_PID='gemini'; PRESET_NAME='Google Gemini'; PRESET_URL='https://generativelanguage.googleapis.com/v1beta/openai'; PRESET_OK=0; PRESET_WARN='Google 当前公开 OpenAI 兼容文档主要为 Chat Completions，当前 Codex 可能无法使用。' ;;
   6) PRESET_PID='qwen'; PRESET_NAME='阿里云百炼 / Qwen（中国）'; PRESET_URL='https://dashscope.aliyuncs.com/compatible-mode/v1'; PRESET_OK=0; PRESET_WARN='百炼 OpenAI 兼容端点并不代表支持 Responses API，当前 Codex 兼容性取决于服务端。' ;;
   7) PRESET_PID='qwen_intl'; PRESET_NAME='阿里云百炼 / Qwen（新加坡）'; PRESET_URL='https://dashscope-intl.aliyuncs.com/compatible-mode/v1'; PRESET_OK=0; PRESET_WARN='百炼 OpenAI 兼容端点并不代表支持 Responses API，当前 Codex 兼容性取决于服务端。' ;;
   8) PRESET_PID='zhipu'; PRESET_NAME='智谱 GLM'; PRESET_URL='https://open.bigmodel.cn/api/paas/v4'; PRESET_OK=0; PRESET_WARN='智谱公开 OpenAI 兼容文档目前以 Chat Completions 为主，当前 Codex 可能无法使用。' ;;
   9) PRESET_PID='kimi'; PRESET_NAME='Moonshot / Kimi'; PRESET_URL='https://api.moonshot.cn/v1'; PRESET_OK=0; PRESET_WARN='Kimi 是否支持 Codex 所需 Responses API 请以当前服务端能力为准。' ;;
   10) PRESET_PID='minimax'; PRESET_NAME='MiniMax'; PRESET_URL='https://api.minimaxi.com/v1'; PRESET_OK=0; PRESET_WARN='MiniMax 是否支持 Codex 所需 Responses API 请以当前服务端能力为准。' ;;
   11) PRESET_PID='siliconflow'; PRESET_NAME='硅基流动 SiliconFlow'; PRESET_URL='https://api.siliconflow.cn/v1'; PRESET_OK=0; PRESET_WARN='硅基流动是否支持 Codex 所需 Responses API 请以当前服务端能力为准。' ;;
   *) return 1 ;;
 esac
}
add_provider() {
 local kind pid name url key token model answer
 echo
 echo '────────── 添加中转站 / Provider ──────────'
 echo '  支持当前 Codex Responses API：'
 echo '  （1）基元律动 TokenRhythm'
 echo '  （2）OpenAI 官方'
 echo '  （3）DeepSeek 官方'
 echo '  （4）火山方舟 / 豆包'
 echo
 echo '  常用预设（可能仅支持 Chat Completions）：'
 echo '  （5）Google Gemini'
 echo '  （6）阿里云百炼 / Qwen（中国）'
 echo '  （7）阿里云百炼 / Qwen（新加坡）'
 echo '  （8）智谱 GLM'
 echo '  （9）Moonshot / Kimi'
 echo '  （10）MiniMax'
 echo '  （11）硅基流动 SiliconFlow'
 echo '  （12）自定义 OpenAI Responses 兼容中转站'
 echo '  （0）返回'
 read -rp '请选择 [0-12]：' kind
 if [ "$kind" = 0 ]; then return 0; fi
 if [ "$kind" = 12 ]; then
   read -rp '中转站代号（例如：myrelay）：' pid
   [[ "$pid" =~ ^[A-Za-z0-9_-]+$ ]] || { echo '代号只能包含英文字母、数字、下划线和短横线'; return 1; }
   case "$pid" in openai|ollama|lmstudio) echo '该代号由 Codex 保留，请换一个中转站代号'; return 1;; esac
   read -rp '中转站名称（可填中文）：' name; [ -n "$name" ] || return 1
   read -rp '接口地址（例如：https://example.com/v1）：' url
   [[ "$url" =~ ^https:// ]] || [[ "$url" =~ ^http://(localhost|127\.0\.0\.1)([:/]|$) ]] || { echo '接口地址必须以 https:// 开头；本机地址可以使用 http://'; return 1; }
 else
   set_provider_preset "$kind" || { echo '无效选择。'; return 1; }
   pid=$PRESET_PID; name=$PRESET_NAME; url=$PRESET_URL
   echo "已选择：$name"
   echo "接口地址：$url"
   if [ "$PRESET_OK" != 1 ]; then
     echo
     echo "⚠️ 兼容提醒：$PRESET_WARN"
     echo '新版 Codex 自定义 Provider 使用 Responses API。'
     read -rp '仍要添加这个预设吗？请输入 y：' answer
     [ "$answer" = y ] || { echo '已取消。'; return 0; }
   fi
 fi
 key=$(printf 'CODEX_%s_API_KEY' "$pid" | tr '[:lower:]-' '[:upper:]_')
 echo '请输入该服务的 API Key。'
 read -rsp '密钥（输入时不会显示）：' token; echo
 [ -n "$token" ] || { echo '密钥不能为空。'; return 1; }
 save_key_value "$key" "$token" || { unset token; return 1; }
 echo '密钥已安全保存，正在自动获取模型列表……'
 if fetch_provider_models "$url" "$token"; then
   select_remote_model || { unset token; return 1; }
   model=$SELECTED_MODEL
 else
   read -rp '模型名称（必须与服务商提供的一致）：' model
   [ -n "$model" ] || { unset token; return 1; }
 fi
 unset token
 toml_set provider "$pid" "$name" "${url%/}" "$key"
 use_model "$pid/$model"
 echo 'Provider 添加完成。'
 [ "$kind" = 1 ] && echo 'TokenRhythm：请选择其文档中标注支持 Responses API 的模型。'
}
set_key() {
 local key=${1:-} value
 if [ -z "$key" ]; then
   read -rp '密钥变量名称：' key
 fi
 [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo '密钥变量名称无效'; return 1; }
 read -rsp '中转站密钥（输入时不会显示）：' value; echo
 save_key_value "$key" "$value" || { unset value; return 1; }
 unset value; echo '密钥已安全保存。'
}
menu() {
 while true; do
  echo
  list
  echo
  echo '════════════════════════════════════'
  echo '  模型与中转站管理'
  echo '════════════════════════════════════'
  echo '  （1）切换模型'
  echo '  （2）添加中转站 / 自动获取模型'
  echo '  （3）修改中转站密钥'
  echo '  （4）编辑高级配置'
  echo '  （5）启动 Codex'
  echo '  （0）返回上一级'
  echo '════════════════════════════════════'
  read -rp '请选择 [0-5]：' n
  case "$n" in
   1) model_menu ;;
   2) add_provider || true ;;
   3) set_key || true ;;
   4) "${EDITOR:-vi}" "$CFG" ;;
   5) exec codex ;;
   0) break ;;
   *) echo '无效选择，请重新输入。' ;;
  esac
 done
}
current_row=''
if [ -s "$CFG" ]; then current_row=$(python3 - "$CFG" <<'PY'
import sys,tomlkit
d=tomlkit.parse(open(sys.argv[1]).read() or '')
p=d.get('model_provider'); m=d.get('model')
if p and m: print(str(p)+'\t'+str(m))
PY
); fi
if [ -n "$current_row" ]; then IFS=$'\t' read -r current_p current_m <<<"$current_row"; remember_model "$current_p" "$current_m"; fi
case ${1:-menu} in menu) menu;; list) list; show_models;; use) use_model "${2:-}";; add) add_provider;; key) set_key;; edit) exec "${EDITOR:-vi}" "$CFG";; *) echo '可用命令：cx list（查看）、cx use（切换）、cx add（添加）、cx key（密钥）、cx edit（高级配置）'; exit 1;; esac
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
CODEX_UPDATE_ONLY=${CODEX_UPDATE_ONLY:-0} \
  proot-distro login "$DISTRO" --shared-tmp -- bash "$tmp_outer" "$mirror" "$target" "$apt_kind"

if [ "${CODEX_UPDATE_ONLY:-0}" = 1 ]; then
  say "${G}Codex 程序更新完成；菜单脚本未修改。${N}"
  exit 0
fi

install_wrapper_file() {
  local name source dst stamp t
  name=$1
  source=$2
  dst="$PREFIX/bin/$name"
  if [ -e "$dst" ] && ! grep -q 'codex-termux-managed' "$dst" 2>/dev/null; then
    stamp=$(date +%Y%m%d-%H%M%S); cp -a "$dst" "${dst}.bak.${stamp}"
    say "${Y}已备份原有 $dst → ${dst}.bak.${stamp}${N}"
  fi
  t=$(mktemp "${dst}.XXXXXX")
  cp "$source" "$t"
  chmod 0755 "$t"
  mv -f "$t" "$dst"
}
stage='写入 Termux 包装命令'
wrapper_tmp=$(mktemp)
cat >"$wrapper_tmp" <<'CODEX_WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
# codex-termux-managed
exec proot-distro login --isolated codex-ubuntu -- bash -lc '[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; exec codex "$@"' bash "$@"
CODEX_WRAPPER
install_wrapper_file codex "$wrapper_tmp"

cat >"$wrapper_tmp" <<'CX_WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
# codex-termux-managed
safe_codex() {
  proot-distro login --isolated codex-ubuntu -- bash -lc '[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; exec codex "$@"' bash "$@"
}
storage_codex() {
  [ -d "$HOME/storage/shared" ] || { echo "请先运行 termux-setup-storage 并允许授权"; return 1; }
  proot-distro login codex-ubuntu --bind "$HOME/storage/shared:/sdcard" -- bash -lc '[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; cd /sdcard; exec codex "$@"' bash "$@"
}
inner_cx() {
  proot-distro login --isolated codex-ubuntu -- bash -lc '[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; exec cx "$@"' bash "$@"
}
root_codex() {
  local answer root_command
  echo
  echo '⚠️  高风险警告：Android Root 开发者模式'
  echo '此功能会通过 Magisk/tsu 以 Android 系统最高权限启动 Codex。'
  echo 'Codex 可能读取、修改或删除系统文件，错误操作可能导致：'
  echo '  · 手机数据永久丢失'
  echo '  · 系统损坏或无法开机'
  echo '  · 应用及账号敏感信息泄露'
  echo
  echo '这不是 Ubuntu 容器里的模拟 root，而是真实的 Android Root 权限。'
  echo '仅供清楚了解 Android Root 风险的开发者使用。'
  echo '────────────────────────────────────'
  read -rp '请输入“已悉知，后果自负”继续：' answer
  if [ "$answer" != '已悉知，后果自负' ]; then
    echo '输入不匹配，已取消 Root 启动。'
    return 1
  fi
  if ! command -v tsu >/dev/null 2>&1; then
    echo '未检测到 tsu。手机必须已通过 Magisk Root，再运行：pkg install tsu'
    return 1
  fi
  printf -v root_command '%q ' "$PREFIX/bin/proot-distro" login codex-ubuntu -- bash -lc '[ ! -f ~/.config/codex/env ] || source ~/.config/codex/env; exec codex'
  echo '正在以 Android Root 权限启动 Codex……'
  tsu -c "$root_command"
}
run_installer_update() {
  local mode=$1 version=${2:-} installer rc
  installer=$(mktemp)
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 20 \
    "https://raw.githubusercontent.com/YImu25/codex-termux/main/codex-install.sh?update=$(date +%s)" \
    -o "$installer"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$installer"
    return "$rc"
  fi
  if ! bash -n "$installer"; then
    echo '下载到的安装脚本语法检查失败，已取消执行。'
    rm -f "$installer"
    return 1
  fi
  if [ "$mode" = codex ]; then
    CODEX_UPDATE_ONLY=1 bash "$installer"; rc=$?
  else
    CODEX_VERSION="$version" bash "$installer"; rc=$?
  fi
  rm -f "$installer"
  return "$rc"
}
update_codex() { run_installer_update codex; }
update_helper() {
  local installed_version
  installed_version=$(proot-distro login --isolated codex-ubuntu -- cat /usr/local/share/codex-termux/release 2>/dev/null) || {
    echo '无法读取当前 Codex 版本，请先完成 Codex 安装。'
    return 1
  }
  echo "保持 Codex 版本 $installed_version 不变，仅更新菜单脚本。"
  run_installer_update script "$installed_version"
}
show_menu() {
  local choice
  while true; do
    echo
    echo "════════════════════════════════════"
    echo "  Codex Termux 助手"
    echo "════════════════════════════════════"
    echo "  （1）启动 Codex（安全模式）"
    echo "  （2）启动 Codex（读写手机存储）"
    echo "  （3）模型、中转站与密钥管理"
    echo "  （4）查看 Codex 版本"
    echo "  （5）进入 Ubuntu 22.04"
    echo "  （6）只更新 Codex 程序"
    echo "  （7）只更新菜单脚本"
    echo "  （8）Android Root 启动（开发者/高风险）"
    echo "  （0）退出"
    echo "════════════════════════════════════"
    read -rp "请选择 [0-8]：" choice
    case "$choice" in
      1) safe_codex ;;
      2) storage_codex ;;
      3) inner_cx ;;
      4) proot-distro login --isolated codex-ubuntu -- codex --version ;;
      5) proot-distro login codex-ubuntu ;;
      6) update_codex ;;
      7) update_helper ;;
      8) root_codex ;;
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
  root) root_codex ;;
  update|update-codex) update_codex ;;
  update-script) update_helper ;;
  help|-h|--help)
    echo "用法：cx [menu|start|storage|root|version|ubuntu|update-codex|update-script|list|use|add|key|edit]" ;;
  *) inner_cx "$@" ;;
esac
CX_WRAPPER
install_wrapper_file cx "$wrapper_tmp"
rm -f "$wrapper_tmp"

say "${G}安装完成。${N}"
say '  codex       安全启动（仅容器）'
say '  cx          打开中文功能菜单'
say '  cx storage  主动授权后读写手机共享存储'
say "${Y}默认不启用 Android/Magisk Root；仅在菜单明确确认后启动 Root 模式。${N}"
say "${Y}默认不写入 danger-full-access。${N}"
