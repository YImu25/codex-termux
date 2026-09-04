#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/codex-install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

extract_heredoc() {
  local marker=$1 input=$2 output=$3
  awk -v marker="$marker" '
    $0 == marker { exit }
    active { print }
    index($0, "<<\047" marker "\047") { active=1 }
  ' "$input" >"$output"
  [ -s "$output" ] || { echo "无法提取 $marker" >&2; return 1; }
}

bash -n "$script"
extract_heredoc UBUNTU_SCRIPT "$script" "$work/ubuntu.sh"
extract_heredoc CX "$work/ubuntu.sh" "$work/cx-inner.sh"
extract_heredoc CODEX_WRAPPER "$script" "$work/codex-wrapper.sh"
extract_heredoc CX_WRAPPER "$script" "$work/cx-wrapper.sh"

for file in "$work/ubuntu.sh" "$work/cx-inner.sh" "$work/codex-wrapper.sh" "$work/cx-wrapper.sh"; do
  bash -n "$file"
done

if grep -En '<[[:space:]]*<\(' "$script"; then
  echo '不允许使用 proot 下不稳定的进程替换。' >&2
  exit 1
fi

grep -Fq '已悉知，后果自负' "$work/cx-wrapper.sh"
grep -Fq 'CODEX_UPDATE_ONLY=1' "$work/cx-wrapper.sh"
grep -Fq 'CODEX_VERSION="$version"' "$work/cx-wrapper.sh"
grep -Fq "wire_api']='responses'" "$work/cx-inner.sh"
grep -Fq '默认不写入 danger-full-access' "$script"

test_home="$work/home"
mkdir -p "$test_home"
printf 'TEST_API_KEY\nfirst\n' | HOME="$test_home" bash "$work/cx-inner.sh" key >/dev/null
printf 'TEST_API_KEY\nsecond\n' | HOME="$test_home" bash "$work/cx-inner.sh" key >/dev/null
[ "$(grep -c '^export TEST_API_KEY=' "$test_home/.config/codex/env")" -eq 1 ]
grep -Fq 'export TEST_API_KEY=second' "$test_home/.config/codex/env"
[ "$(stat -c '%a' "$test_home/.config/codex/env")" = 600 ]

if CODEX_VERSION=main bash "$work/ubuntu.sh" 0 aarch64-unknown-linux-musl ports >/dev/null 2>&1; then
  echo '非法 CODEX_VERSION 未被拒绝。' >&2
  exit 1
fi

echo '全部静态检查通过。'
