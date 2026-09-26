#!/usr/bin/env bash
# 05-patch-bootimg-cmdline.sh —— 原地给 boot.img 的 cmdline 追加启动参数
#
# 用途：SteamOS 底包在图形阶段黑屏（背光亮但没画面、Ctrl+Alt+F2 也没反应）时，需要
#   「更啰嗦的内核/系统日志 + 强制屏蔽图形会话」才能把失败原因显示在屏幕上。
#   内核 cmdline 由 boot.img 携带，而 Android boot image 的 cmdline 字段是**明文**，
#   可以原地替换（v0~v4 头的偏移都是 64、长度 512 字节）。
#
# 用法: 05-patch-bootimg-cmdline.sh <boot.img> <追加参数...>
#   例: 05-patch-bootimg-cmdline.sh boot.img loglevel=7 systemd.show_status=1 systemd.mask=sddm.service
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

IMG="${1:?用法: 05-patch-bootimg-cmdline.sh <boot.img> <追加参数...>}"
shift
[[ $# -gt 0 ]] || die "没有要追加的参数"
[[ -f "$IMG" ]] || die "找不到 $IMG"
[[ "$(head -c 8 "$IMG")" == "ANDROID!" ]] || die "$IMG 不是 Android boot image"

# cmdline 字段：偏移 64，长度 512（含结尾 NUL）
CUR="$(dd if="$IMG" bs=1 skip=64 count=512 status=none | tr -d '\0')"
log "原 cmdline: '${CUR}'"
NEW="$CUR"
set_root() {  # 替换（而不是追加）root= —— 内核只认一个 root=，且这样能换成与分区标签无关的 root=UUID=
  local val="$1" t out=() replaced=0
  read -r -a toks <<< "$NEW"
  for t in "${toks[@]}"; do
    if [[ "$t" == root=* ]]; then out+=("$val"); replaced=1; else out+=("$t"); fi
  done
  [[ "$replaced" -eq 1 ]] || out=("$val" "${out[@]}")
  NEW="${out[*]}"
}
for a in "$@"; do
  case "$a" in
    root=*) set_root "$a"; log "root= → $a"; continue;;
  esac
  case " $NEW " in *" $a "*) log "已有参数，跳过: $a"; continue;; esac
  NEW="$NEW $a"
done
NEW="${NEW# }"
log "新 cmdline: '$NEW'"
# 512 字节上限（含 NUL）
[[ "${#NEW}" -lt 511 ]] || die "新 cmdline 太长（${#NEW} 字节 ≥ 511），无处安放"
[[ "$NEW" != "$CUR" ]] || { log "无需修改"; exit 0; }

printf '%s' "$NEW" > "$IMG.cmdline"
# 用 NUL 补齐到 512 字节再原地写回
dd if=/dev/zero of="$IMG.cmdline" bs=1 seek="${#NEW}" count=$(( 512 - ${#NEW} )) conv=notrunc status=none
dd if="$IMG.cmdline" of="$IMG" bs=1 seek=64 conv=notrunc status=none
rm -f "$IMG.cmdline"

VERIFY="$(dd if="$IMG" bs=1 skip=64 count=512 status=none | tr -d '\0')"
[[ "$VERIFY" == "$NEW" ]] || die "写回校验失败: '$VERIFY'"
log "已写回并校验通过（boot.img 大小不变: $(stat -c %s "$IMG") 字节）"
