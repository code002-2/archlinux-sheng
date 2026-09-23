#!/usr/bin/env bash
# 01-bootstrap-arch.sh —— 往已挂载的镜像里铺 Arch Linux ARM（aarch64）基础系统
#
# 与 ubuntu-sheng 的 01-bootstrap.sh 对应，差异：
#   * ALARM 没有 ubuntu-base 那样的「按版本发布的 rootfs tarball」，只有一个
#     滚动更新的 ArchLinuxARM-aarch64-latest.tar.gz，因此不需要版本参数
#   * ALARM 的 tarball 里自带 /etc/pacman.conf（[core] [extra] [alarm]）与
#     /etc/pacman.d/mirrorlist，这里只做「写入国内可用镜像 + 段与架构校验」，
#     并显式启用 [extra]（部分 ALARM 镜像默认注释掉）
#   * 首次 pacman 需要密钥环：pacman-key --init && pacman-key --populate archlinuxarm
#
# 环境变量：
#   ALARM_TARBALL_URL  可选，直接指定 tarball 地址（覆盖候选列表）
#   ALARM_MIRROR       包镜像（默认 http://mirror.archlinuxarm.org）
#   ALARM_TARBALL_PATH 可选，复用已下载的 tarball（跳过网络下载）
#
# 用法: sudo scripts/host/01-bootstrap-arch.sh [挂载点]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
# shellcheck source=alarm-lib.sh
source "$HERE/alarm-lib.sh"
require_root

MOUNT="${1:-/mnt/rootfs}"
[[ -d "$MOUNT" ]] || die "挂载点不存在: $MOUNT"

# ---------------------------------------------------------------------------
# 1) 取 ALARM tarball
# ---------------------------------------------------------------------------
ALARM_TARBALL_PATH="${ALARM_TARBALL_PATH:-}"
if [[ -z "$ALARM_TARBALL_PATH" ]]; then
  _ALARM_TMP="$(mktemp -d)"
  trap 'rm -rf "$_ALARM_TMP"' EXIT
  ALARM_TARBALL_PATH="$_ALARM_TMP/ArchLinuxARM-aarch64-latest.tar.gz"
fi
alarm_fetch_tarball "$ALARM_TARBALL_PATH"

# ---------------------------------------------------------------------------
# 2) 解包到挂载点（bsdtar 才能正确还原 device node / xattr）
# ---------------------------------------------------------------------------
log "解包 Arch Linux ARM 到 $MOUNT"
alarm_extract_tarball "$ALARM_TARBALL_PATH" "$MOUNT"
[[ -x "$MOUNT/usr/bin/pacman" ]] || die "解包后找不到 $MOUNT/usr/bin/pacman，tarball 可能不完整"

# ---------------------------------------------------------------------------
# 3) 镜像源：Server = $mirror/$arch/$repo（ALARM 的 mirrorlist 用 $arch 变量，pacman 会展开）
# ---------------------------------------------------------------------------
log "写入 pacman 镜像源: $ALARM_MIRROR/\$arch/\$repo"
install -d "$MOUNT/etc/pacman.d"
# 多 Server 故障切换：pacman 对每个文件按 Server 顺序逐个尝试，单个镜像抖动不会打挂整批作业
cat > "$MOUNT/etc/pacman.d/mirrorlist" <<EOF
# archlinux-sheng：由 scripts/host/01-bootstrap-arch.sh 生成
# 可用镜像列表见 https://archlinuxarm.org/about/mirrors
Server = ${ALARM_MIRROR}/\$arch/\$repo
Server = http://il.us.mirror.archlinuxarm.org/\$arch/\$repo
Server = http://ca.us.mirror.archlinuxarm.org/\$arch/\$repo
Server = http://de.mirror.archlinuxarm.org/\$arch/\$repo
Server = http://sg.mirror.archlinuxarm.org/\$arch/\$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/\$arch/\$repo
EOF

# ---------------------------------------------------------------------------
# 4) 校验 /etc/pacman.conf：Architecture = aarch64 + [core] [extra] [alarm]
# ---------------------------------------------------------------------------
PACMAN_CONF="$MOUNT/etc/pacman.conf"
[[ -f "$PACMAN_CONF" ]] || die "缺少 $PACMAN_CONF（ALARM tarball 不完整）"

if ! grep -qE '^[[:space:]]*Architecture[[:space:]]*=[[:space:]]*aarch64' "$PACMAN_CONF"; then
  warn "pacman.conf 中未显式声明 Architecture = aarch64，已补写（aarch64 与 armv7 的包不通用）"
  sed -i 's/^[[:space:]]*#\?[[:space:]]*Architecture[[:space:]]*=.*/Architecture = aarch64/' "$PACMAN_CONF"
  grep -qE '^Architecture[[:space:]]*=[[:space:]]*aarch64' "$PACMAN_CONF" \
    || sed -i '1i Architecture = aarch64' "$PACMAN_CONF"
fi

for repo in core extra alarm; do
  if grep -qE "^[[:space:]]*#?[[:space:]]*\[${repo}\]" "$PACMAN_CONF"; then
    # 形如 `# [extra]` 的注释掉仓库必须放开（部分镜像的 pacman.conf 会注释 extra）
    sed -i "s/^[[:space:]]*#[[:space:]]*\[${repo}\][[:space:]]*$/[${repo}]/" "$PACMAN_CONF"
    grep -qE "^\[${repo}\]" "$PACMAN_CONF" || die "pacman.conf 的 [${repo}] 段处理失败"
    log "仓库 [${repo}] 已启用"
  else
    warn "pacman.conf 中缺少 [${repo}] 段（继续，但该仓库的包将不可用）"
  fi
done

# ---------------------------------------------------------------------------
# 5) chroot 内需要能解析域名才能下载包与密钥
# ---------------------------------------------------------------------------
if [[ -f /etc/resolv.conf ]]; then
  # 与 02-mount-chroot.sh 同理：若镜像里的 /etc/resolv.conf 是软链（指向
  # /run/systemd/resolve/stub-resolv.conf 之类），cp -f 会跟随软链写入不存在的目录并失败，
  # 在 set -e 下直接终止引导。因此先删再装。
  rm -f "$MOUNT/etc/resolv.conf"
  install -m644 /etc/resolv.conf "$MOUNT/etc/resolv.conf"
else
  warn "宿主缺少 /etc/resolv.conf，写入公共 DNS 兜底"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$MOUNT/etc/resolv.conf"
fi

# ---------------------------------------------------------------------------
# 5.5) 让镜像里的 pacman 也能在 chroot 里工作
#   实现与说明见 alarm-lib.sh 的 alarm_tune_pacman_for_chroot：
#   修正 /etc/mtab 软链（pacman 判定挂载点要用）、关闭下载沙箱。
#   这里**不**关闭 CheckSpace：镜像内的 /proc 由 02-mount-chroot.sh 挂载，
#   mtab 修好后空间检查可正常工作，保留它对设备侧也更安全。
# ---------------------------------------------------------------------------
alarm_tune_pacman_for_chroot "$MOUNT"

# ---------------------------------------------------------------------------
# 6) 初始化 pacman 密钥环并同步数据库
#    Arch 与 Debian/Ubuntu 的关键差异：ALARM 的包用 archlinuxarm 密钥签名，
#    首次使用必须 init + populate，否则 pacman -Sy 会报「签名未知」。
#    幂等性两处注意：
#      * gnupg 2.1+ 的密钥环是 pubring.kbx（老版本是 pubring.gpg），两者都要探测，
#        否则会误判为"没有密钥环"而对已存在的密钥环再跑 --populate（会 key already exists 失败）
#      * --populate 失败不致命：真正的判据是随后的 pacman -Sy（签名不可用时会失败），
#        因此这里降级为警告，避免因 ALARM 的密钥环形态差异误杀构建
# ---------------------------------------------------------------------------
if [[ -f "$MOUNT/etc/pacman.d/gnupg/pubring.gpg" || -f "$MOUNT/etc/pacman.d/gnupg/pubring.kbx" ]]; then
  log "密钥环已存在（$MOUNT/etc/pacman.d/gnupg），跳过 pacman-key --init"
else
  log "初始化 pacman 密钥环（pacman-key --init / --populate archlinuxarm）"
  alarm_chroot_run "$MOUNT" pacman-key --init || die "pacman-key --init 失败"
  alarm_chroot_run "$MOUNT" pacman-key --populate archlinuxarm \
    || warn "pacman-key --populate archlinuxarm 失败（密钥环可能已部分存在）；由随后的 pacman -Sy 做最终校验"
fi

log "同步包数据库（pacman -Sy）"
alarm_chroot_run "$MOUNT" pacman -Sy --noconfirm || die "pacman -Sy 失败（检查镜像源与密钥环）"

# 若 pacman 在 -Sy 过程中产生了 .pacnew（tarball 里的配置落后于包内版本），
# 不要静默覆盖：镜像内配置由本仓库的脚本生成，出现 .pacnew 说明 ALARM 布局有变动，
# 必须人工确认后更新本脚本（宁可构建失败，也不要产出源不可用的镜像）。
for f in pacman.conf pacman.d/mirrorlist; do
  if [[ -f "$MOUNT/etc/$f.pacnew" ]]; then
    die "出现 /etc/$f.pacnew：ALARM 的默认配置已变动，请人工核对后更新 scripts/host/01-bootstrap-arch.sh"
  fi
done

log "引导完成：Arch Linux ARM ($ARCH)"
sed 's/^/    /' "$MOUNT/etc/os-release" 2>/dev/null || true
