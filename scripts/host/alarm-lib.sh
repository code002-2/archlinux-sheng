#!/usr/bin/env bash
# alarm-lib.sh —— 宿主侧 ALARM chroot 公共库
#
# 被 host/01-bootstrap-arch.sh 与 host/20-alarm-chroot.sh 共同 source：
#   * 下载 ALARM aarch64 tarball（多候选地址：官方 os.archlinuxarm.org + 镜像）
#   * 支持用 tarball 形式缓存 chroot（GitHub Actions 的 actions/cache 无法直接
#     缓存 /mnt/alarm 下的 root:root 文件，缓存 tar.zst 更可靠；tar 由宿主的
#     root 解包，权限/所有者天然正确）
#   * chroot 内执行命令的包装（用于 pacman-key / pacman -Syu / pacstrap 等）
#
# 本文件不定义 set -euo pipefail（由调用方设置），也不自己注册 trap：
# 临时目录由调用方通过 _ALARM_TMP 管理，避免同一 shell 里多个 trap 互相覆盖。
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# 下载 ALARM tarball 到指定路径（已存在且非空则跳过，便于缓存复用）
#   用法: alarm_fetch_tarball <目标路径>
# ---------------------------------------------------------------------------
alarm_fetch_tarball() {
  local dest="${1:?用法: alarm_fetch_tarball <目标路径>}"
  local dir
  dir="$(dirname "$dest")"
  install -d "$dir"

  if [[ -s "$dest" ]]; then
    log "复用已下载的 tarball: $dest ($(du -h "$dest" | cut -f1))"
    return 0
  fi

  local -a candidates=()
  # 允许用 ALARM_TARBALL_URL 直接覆盖候选列表（与 ubuntu 版的 UBUNTU_BASE_URL 对应）
  candidates+=("${ALARM_TARBALL_URL}")
  candidates+=(
    "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
    "https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz"
    "https://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
  )

  local url ok=0
  for url in "${candidates[@]}"; do
    [[ -n "$url" ]] || continue
    log "尝试下载: $url"
    if curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$dest.part" "$url"; then
      mv -f "$dest.part" "$dest"
      ok=1
      break
    fi
    warn "该地址不可用，换下一个"
    rm -f "$dest.part"
  done
  [[ "$ok" -eq 1 ]] || die "无法下载 ALARM tarball（候选地址都失败）"

  # 基本健全性校验：确认是可解压的归档，防止把 HTML 错误页当成 tarball 解包。
  # 官方 ALARM tarball 是 gzip；这里也接受 zstd（社区镜像有 .tar.zst 变体）。
  if ! gzip -t "$dest" >/dev/null 2>&1 && ! zstd -t "$dest" >/dev/null 2>&1; then
    rm -f "$dest"
    die "下载到的文件既不是 gzip 也不是 zstd 归档: $dest"
  fi
  log "已下载 ALARM tarball: $dest ($(du -h "$dest" | cut -f1))"
}

# ---------------------------------------------------------------------------
# 解包 tarball 到目标目录（优先 bsdtar，可保留 device node / xattr）
#   用法: alarm_extract_tarball <tarball> <目标目录>
# ---------------------------------------------------------------------------
alarm_extract_tarball() {
  local tarball="${1:?需要 tarball}" dest="${2:?需要目标目录}"
  [[ -f "$tarball" ]] || die "tarball 不存在: $tarball"
  install -d "$dest"
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xpf "$tarball" -C "$dest"
  else
    tar -xpf "$tarball" -C "$dest"
  fi
}

# ---------------------------------------------------------------------------
# 宿主路径 → chroot 内路径 的映射
#   用法: alarm_host_path <chroot 根目录> <chroot 内绝对路径>
# ---------------------------------------------------------------------------
alarm_host_path() {
  local root="${1:?需要 chroot 根目录}" inner="${2:?需要 chroot 内路径}"
  printf '%s' "${root%/}/${inner#/}"
}

# ---------------------------------------------------------------------------
# 在 chroot 内执行命令（不自动清空环境；调用方需要时自行 env -i）
#   返回被执行命令的退出码；调用方自行决定失败是否致命（加 `|| die ...`）。
#   注意：chroot 会交换 stdout/stdin，这里的 `die` 不会在子 shell 里执行，
#   所以必须由调用方处理退出码。
#   用法: alarm_chroot_run <chroot 根目录> <命令...>
# ---------------------------------------------------------------------------
alarm_chroot_run() {
  local root="${1:?需要 chroot 根目录}"
  shift
  [[ "$#" -gt 0 ]] || return 0
  chroot "$root" "$@"
}

# ---------------------------------------------------------------------------
# 虚拟文件系统挂载 / 卸载（幂等）
#   为什么需要：chroot 内没有 systemd，/proc /sys /dev 必须显式挂载。ALARM tarball
#   自带的 /dev 对非 root 用户不可用（实测 non-root 下 `> /dev/null` 报 Permission denied），
#   而 makepkg/fakeroot 大量使用重定向 → 必须把宿主的 /dev bind 进去。
#   ⚠️ 每个用到 chroot 的步骤都要自己挂一次：20-alarm-chroot.sh 在打包快照前会卸载
#   （否则 /proc /sys 与宿主 /dev 会被打进缓存），因此 21-build-pkg.sh 是另一个进程，
#   拿到的 chroot 是"干净"的，必须重新挂载。
#   用法: alarm_mount_virtfs <chroot 根目录> / alarm_umount_virtfs <chroot 根目录>
# ---------------------------------------------------------------------------
alarm_mount_virtfs() {
  local root="${1:?需要 chroot 根目录}"
  install -d "$root/proc" "$root/sys" "$root/dev/pts"
  mountpoint -q "$root/proc"     || mount -t proc  proc "$root/proc"     2>/dev/null || warn "挂载 proc 失败: $root/proc"
  mountpoint -q "$root/sys"      || mount -t sysfs sys  "$root/sys"      2>/dev/null || warn "挂载 sys 失败: $root/sys"
  mountpoint -q "$root/dev"      || mount --bind /dev     "$root/dev"      2>/dev/null || warn "bind /dev 失败: $root/dev"
  mountpoint -q "$root/dev/pts"  || mount --bind /dev/pts "$root/dev/pts"  2>/dev/null || warn "bind /dev/pts 失败: $root/dev/pts"
}

alarm_umount_virtfs() {
  local root="${1:?需要 chroot 根目录}" d
  for d in dev/pts dev proc sys; do
    if mountpoint -q "$root/$d"; then
      umount "$root/$d" 2>/dev/null || umount -l "$root/$d" 2>/dev/null || true
    fi
  done
}

# ---------------------------------------------------------------------------
# 关闭 pacman 7.x 的下载沙箱（chroot / 容器内不可用）
#   ALARM 的 pacman.conf 带 `DownloadUser = alpm`；pacman 7 会为下载用户建立
#   Landlock + bind-mount 沙箱，并需要判定 cachedir 的挂载点。在 chroot 内判定失败，
#   实测报错：
#       error: could not determine cachedir mount point /var/cache/pacman/pkg/download-XXXX
#       error: failed to commit transaction (not enough free disk space)   ← 空间检查被连带误判
#   修法：① 注释掉 DownloadUser（回到 6.x 的"以 root 下载"路径，不需要沙箱）
#         ② 补上 DisableSandbox（pacman 7.0+ 的配置项；未知项只会 warning，不会致命）
#   注意：ALARM 的 pacman 实测**不支持** `--disable-sandbox` 命令行开关（能力探测已证实），
#   因此只能走配置文件这条路。
#   用法: alarm_tune_pacman_for_chroot <chroot 根目录> [--no-checkspace]
# ---------------------------------------------------------------------------
alarm_tune_pacman_for_chroot() {
  local root="${1:?需要 chroot 根目录}"
  local no_checkspace="${2:-}"
  local conf="$root/etc/pacman.conf"

  # ① /etc/mtab 必须是 → /proc/self/mounts 的软链。
  #    pacman 判定"cachedir 的挂载点"依赖它；ALARM tarball 里 /etc/mtab 可能是
  #    缺失或空普通文件 → getmntent 读不到任何挂载点 → 判定失败。
  if [[ ! -L "$root/etc/mtab" ]]; then
    rm -f "$root/etc/mtab"
    ln -s /proc/self/mounts "$root/etc/mtab"
    log "已修正 $root/etc/mtab → /proc/self/mounts"
  fi

  [[ -f "$conf" ]] || { warn "找不到 $conf，跳过 pacman 调优"; return 0; }

  # ② 下载沙箱：chroot 内建不起来（见上）
  if ! grep -qE '^[[:space:]]*DisableSandbox' "$conf"; then
    sed -i '/^\[options\]/a DisableSandbox' "$conf"
  fi
  if grep -qE '^[[:space:]]*DownloadUser' "$conf"; then
    sed -i -E 's|^([[:space:]]*)DownloadUser[[:space:]]*=.*|\1# DownloadUser 已由 archlinux-sheng 注释：chroot 内无法建立下载沙箱|' "$conf"
  fi

  # ③ CheckSpace：pacman 会在事务前做磁盘空间检查，而该检查同样需要挂载点信息。
  #    即使在 /proc 已挂载、mtab 已修正的情况下，构建 chroot 里仍实测失败：
  #      error: could not determine cachedir mount point /var/cache/pacman/pkg
  #      error: failed to commit transaction (not enough free disk space)
  #    因此构建 chroot 直接关掉该检查（镜像内保留，见调用方是否传 --no-checkspace）。
  if [[ "$no_checkspace" == "--no-checkspace" ]] && grep -qE '^[[:space:]]*CheckSpace' "$conf"; then
    sed -i -E 's|^([[:space:]]*)CheckSpace.*|\1# CheckSpace 已由 archlinux-sheng 注释：chroot 内无法判定挂载点|' "$conf"
    log "已在构建 chroot 关闭 CheckSpace（避免 chroot 内的挂载点判定失败）"
  fi

  log "pacman 已在 chroot 下调优: $conf"
}

# ---------------------------------------------------------------------------
# pacman 网络抖动重试包装（构建 chroot 用）
#   实测失败：单个镜像抖动 → "Operation too slow. Less than 1 bytes/sec" →
#             "failed to commit transaction (download library error)"
#             → makepkg 报 "'pacman' failed to install missing dependencies" 直接挂掉。
#   两层防护：① mirrorlist 写多个 Server（pacman 自己会故障切换，见 20-alarm-chroot.sh）
#             ② 这里再重试 3 次，并加 --disable-download-timeout 放宽低速中断判定
#                （pacman 5.2+ 支持；chroot 里的 pacman 版本远高于此）
#   用法: alarm_pacman_retry <chroot 根目录> <pacman 参数...>
# ---------------------------------------------------------------------------
alarm_pacman_retry() {
  local root="${1:?需要 chroot 根目录}"; shift
  local i
  for i in 1 2 3; do
    if alarm_chroot_run "$root" pacman --disable-download-timeout "$@"; then
      return 0
    fi
    warn "pacman $* 第 $i 次失败（疑似镜像抖动），10s 后重试"
    sleep 10
  done
  return 1
}

# ---------------------------------------------------------------------------
# 把 chroot 打成可缓存的 tarball（供 GitHub Actions actions/cache 使用）
#   用法: alarm_pack_chroot <chroot 根目录> <输出 tarball>
# ---------------------------------------------------------------------------
alarm_pack_chroot() {
  local root="${1:?需要 chroot 根目录}" out="${2:?需要输出 tarball}"
  [[ -d "$root" ]] || die "chroot 目录不存在: $root"
  install -d "$(dirname "$out")"
  log "打包 chroot 以复用: $out"
  # --zstd：优先选 zstd（速度快），失败则退回 gzip
  # 即使调用方已卸载虚拟文件系统，也显式排除 proc/sys/run 与 dev 下的挂载点子目录，
  # 避免缓存快照里混入宿主内容
  local -a excl=(
    --exclude=./proc/*
    --exclude=./sys/*
    --exclude=./run/*
    --exclude=./dev/pts/*
    --exclude=./dev/shm/*
  )
  if ! tar -C "$root" -c -f "$out" --zstd "${excl[@]}" . 2>/dev/null; then
    tar -C "$root" -c -f "$out" -z "${excl[@]}" .
  fi
  log "chroot 已打包: $out ($(du -h "$out" | cut -f1))"
}

# ---------------------------------------------------------------------------
# 通过环境变量取任意命令的路径（不依赖 which/command -v）
#   与 21-build-pkg.sh 里的 _host_cmd 行为一致，但用于 chroot 内（无 $PATH 干扰）
# ---------------------------------------------------------------------------
alarm_cmd_path() {
  local name="${1:?需要命令名}" val
  val="$(env | awk -F= -v n="$name" '$1==n {sub("^[^=]*=",""); print; exit}')"
  printf '%s' "${val:-$name}"
}

# ---------------------------------------------------------------------------
# 列出 packages/ 下真正的包目录（跳过 _shared 之类以 _ 开头的目录）
#   用法: mapfile -t dirs < <(alarm_list_pkg_dirs <packages 目录>)
# ---------------------------------------------------------------------------
alarm_list_pkg_dirs() {
  local root="${1:?需要 packages 目录}" d name
  [[ -d "$root" ]] || die "packages 目录不存在: $root"
  for d in "$root"/*/; do
    name="${d%/}"
    name="${name##*/}"
    case "$name" in
      _*) continue ;;
    esac
    [[ -f "$d/PKGBUILD" ]] || continue
    printf '%s\n' "$d"
  done
}

# ---------------------------------------------------------------------------
# 从 PKGBUILD 的 source=() 里抽出条目（含单行与多行写法；去掉引号）
# 仅供「找出 PKGBUILD 期望的本地载荷文件名」使用，不做完整 shell 解析。
#   用法: pkgbuild_local_sources <PKGBUILD 路径>
# ---------------------------------------------------------------------------
pkgbuild_local_sources() {
  local pkgbuild="${1:?需要 PKGBUILD 路径}"
  [[ -f "$pkgbuild" ]] || return 0
  grep -oE 'source(_[a-zA-Z0-9_]+)?=\([^)]*\)' "$pkgbuild" 2>/dev/null \
    | sed -e 's/^source\(_[a-zA-Z0-9_]*\)\?=(//' -e 's/)$//' -e "s/[\"']//g" \
    | tr ' \t' '\n\n' || true
}
