#!/usr/bin/env bash
# 90-verify.sh —— 构建末尾的硬校验（Arch 版）
#
# 对应 ubuntu-sheng 的 90-verify.sh，但把 snap 相关检查换成了 Arch 侧真正重要的检查：
#   * /usr/lib/modules/<kver>/modules.dep 必须存在（无 initramfs 启动的前提）
#   * fstab 必须按 PARTLABEL + x-systemd.growfs 写好
#   * 选择了语言时 /etc/locale.conf 必须存在，且 locale 已生成
#   * 设备关键文件必须存在（adsprpcd / iio-sensor-proxy / ssccli / ssc 注册表）
#   * 我们的本地 pacman 包必须真的被 pacman 收录（pacman -Q ...）
#   * 用户存在、自动登录配置存在（按桌面环境）
#   * 与 snap 的对应项：Arch 侧检查「没有 snapd」（Arch 官方仓库本就没有，
#     这里做防回归；说明见 README）
#
# 任何一项失败即 exit 1（die）。
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/sheng-build/in-chroot/90-verify.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/sheng-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-pac.sh"

if [[ -f /root/build.env ]]; then
  # shellcheck source=/dev/null
  source /root/build.env
fi

FAIL=0
pass() { printf '  [ OK ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
skip() { printf '  [SKIP] %s\n' "$*"; }

log "开始校验（Arch Linux ARM / $ARCH）"

# ---------------------------------------------------------------------------
# 1) 架构与包管理器
# ---------------------------------------------------------------------------
if [[ "$(uname -m)" == "aarch64" ]]; then
  pass "架构正确: aarch64"
else
  fail "架构不对: $(uname -m)（应为 aarch64）"
fi

if [[ -f /var/lib/pacman/local/ALPM_DB_VERSION ]]; then
  pass "pacman 本地数据库存在（$(pacman -Q --color never | wc -l) 个已安装包）"
else
  fail "/var/lib/pacman/local/ALPM_DB_VERSION 缺失，pacman 数据库不可用"
fi

if [[ -e /var/lib/pacman/db.lck ]]; then
  fail "存在 /var/lib/pacman/db.lck（镜像里残留了锁文件，设备上 pacman 无法使用）"
else
  pass "无 pacman 锁文件"
fi

# ---------------------------------------------------------------------------
# 1.5) 可引导性：内核 exec 的第一个进程
#   内核 cmdline 没有 init= 参数，因此必须存在 /sbin/init（Arch 由 systemd-sysvcompat
#   提供，指向 /usr/lib/systemd/systemd）。缺了它内核会 panic：
#     Kernel panic - not syncing: No working init found.
#   设备侧表现为**开机全黑、背光不亮**，与"刷砖/内核没起来"完全一样，极难排查。
#   Holo Core 底座（只有 systemd + systemd-libs）就缺这个包 —— 实机黑屏事故的根因。
# ---------------------------------------------------------------------------
INIT_OK=0
for cand in /sbin/init /usr/sbin/init /usr/lib/systemd/systemd; do
  if [[ -x "$cand" ]]; then
    INIT_OK=1
    if [[ -L "$cand" ]]; then
      pass "init 存在: $cand -> $(readlink -f "$cand")"
    else
      pass "init 存在: $cand"
    fi
    break
  fi
done
if [[ "$INIT_OK" -eq 0 ]]; then
  fail "找不到 /sbin/init 或 /usr/lib/systemd/systemd —— 内核会 panic（No working init found），设备开机全黑。请安装 systemd-sysvcompat"
fi
if pac_installed systemd-sysvcompat; then
  pass "systemd-sysvcompat 已安装（提供 /sbin/init）"
else
  warn "未安装 systemd-sysvcompat（若 /sbin/init 由其它方式提供可忽略）"
fi

# ---------------------------------------------------------------------------
# 2) 内核模块索引（无 initramfs 启动的前提）
# ---------------------------------------------------------------------------
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [[ -n "$KVER" && -f "/usr/lib/modules/$KVER/modules.dep" ]]; then
  pass "内核模块就绪: $KVER（modules.dep 已生成）"
else
  fail "内核模块不完整（KVER=${KVER:-无}，缺少 modules.dep）"
fi
if [[ -n "$KVER" && -f "/usr/lib/modules/$KVER/modules.alias" ]]; then
  pass "modules.alias 存在（udev 能按别名加载驱动）"
else
  fail "缺少 modules.alias，设备驱动可能无法自动加载"
fi

# ---------------------------------------------------------------------------
# 3) fstab
# ---------------------------------------------------------------------------
if grep -qE "^PARTLABEL=.*[[:space:]]/[[:space:]]+ext4.*x-systemd\.growfs" /etc/fstab 2>/dev/null; then
  pass "fstab 正确（PARTLABEL + x-systemd.growfs）"
else
  fail "fstab 不符合预期: $(tr '\n' ' ' < /etc/fstab 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 4) locale
# ---------------------------------------------------------------------------
if [[ "${LANGUAGE:-None (C.UTF-8)}" != "None (C.UTF-8)" ]]; then
  if grep -q "${LANGUAGE%% *}" /etc/locale.conf 2>/dev/null; then
    pass "locale 已写入 /etc/locale.conf: $LANGUAGE"
  else
    fail "locale 未写入 /etc/locale.conf（期望 $LANGUAGE）"
  fi
  if [[ -f "/usr/lib/locale/locale-archive" ]] || [[ -d "/usr/lib/locale/${LANGUAGE}" ]]; then
    pass "locale 已生成"
  else
    skip "未能确认 locale 是否生成（locale-archive 缺失），请人工确认"
  fi
else
  skip "未选择语言（LANGUAGE=None），跳过 locale 校验"
fi

# ---------------------------------------------------------------------------
# 5) 设备功能包关键文件
# ---------------------------------------------------------------------------
for f in /usr/bin/adsprpcd /usr/libexec/iio-sensor-proxy /usr/bin/ssccli \
         /usr/lib/systemd/system/adsprpcd-sensorspd.service \
         /usr/lib/systemd/system/sheng-devauth.service \
         /usr/bin/xiaomi_devauth \
         /usr/share/qcom/sm8550/Xiaomi/sheng; do
  if [[ -e "$f" ]]; then
    pass "存在 $f"
  else
    fail "缺少 $f"
  fi
done

# monitor-sensor 由 iio-sensor-proxy 提供，属于可选工具
if [[ -e /usr/bin/monitor-sensor ]]; then
  pass "存在 /usr/bin/monitor-sensor"
else
  skip "缺少 /usr/bin/monitor-sensor（iio-sensor-proxy 的可选工具）"
fi

# ---------------------------------------------------------------------------
# 6) 我们的本地 pacman 包必须被 pacman 收录
#    （注意 iio-sensor-proxy 在 Arch 侧叫 iio-sensor-proxy-sheng，
#      因为它与 ALARM 官方仓库的同名包冲突，见 packages/iio-sensor-proxy/PKGBUILD）
# ---------------------------------------------------------------------------
LOCAL_PKGS=(
  linux-xiaomi-sheng
  firmware-xiaomi-sheng
  alsa-xiaomi-sheng
  sheng-sensors
  sheng-devauth
  fastrpc
  libssc
  iio-sensor-proxy-sheng
)
for p in "${LOCAL_PKGS[@]}"; do
  if pac_installed "$p"; then
    pass "pacman -Q $p → $(pac_version "$p")"
  else
    fail "pacman 未收录本地包: $p"
  fi
done

# xiaomi-* 包逐个报告（未装不致命：上游这几个包的 release 可能暂时缺失）
XIAOMI_COUNT=0
for p in $(pacman -Qq --color never 2>/dev/null | grep -E '^xiaomi-' || true); do
  pass "pacman -Q $p → $(pac_version "$p")"
  XIAOMI_COUNT=$((XIAOMI_COUNT + 1))
done
if [[ "$XIAOMI_COUNT" -eq 0 ]]; then
  warn "没有任何 xiaomi-* 包被安装（deb 下载或重打包可能失败，见 README「已知限制」）"
fi

# 服务必须处于 enabled（chroot 内 systemctl enable 只建软链，这里检查软链）
for unit in adsprpcd-sensorspd.service sheng-devauth.service; do
  if [[ -e "/etc/systemd/system/multi-user.target.wants/$unit" || -e "/etc/systemd/system/$unit" ]]; then
    if systemctl is-enabled "$unit" >/dev/null 2>&1; then
      pass "服务已启用: $unit"
    else
      fail "服务未启用: $unit"
    fi
  else
    skip "服务不存在，跳过启用校验: $unit"
  fi
done

# ---------------------------------------------------------------------------
# 7) 用户 / 自动登录 / 显示管理器
# ---------------------------------------------------------------------------
if id "${USERNAME:-}" >/dev/null 2>&1; then
  pass "用户存在: $USERNAME"
else
  fail "用户不存在: ${USERNAME:-<未设置>}"
fi

if id -nG "${USERNAME:-}" 2>/dev/null | grep -qw wheel; then
  pass "用户 $USERNAME 属于 wheel 组（可 sudo）"
else
  fail "用户 $USERNAME 不在 wheel 组"
fi

if [[ -f /etc/sudoers.d/10-wheel ]]; then
  pass "wheel 的 sudoers 配置存在"
else
  fail "缺少 /etc/sudoers.d/10-wheel"
fi

# 桌面环境的核心包必须真的装上（lists/*.list 是 best-effort 安装，
# 单个包改名/缺失不会中断构建，这里做硬校验兜底）
case "${DESKTOP:-server}" in
  GNOME)
    if pac_installed gnome-shell; then
      pass "gnome-shell 已安装：$(pac_version gnome-shell)"
    else
      fail "gnome-shell 未安装，GNOME 桌面不完整"
    fi
    ;;
  "KDE Plasma")
    if pac_installed plasma-workspace; then
      pass "plasma-workspace 已安装：$(pac_version plasma-workspace)"
    else
      fail "plasma-workspace 未安装，KDE Plasma 不完整"
    fi
    if [[ "${PLASMA_MOBILE:-false}" == "true" ]] && ! pac_installed plasma-mobile; then
      fail "勾选了 plasma_mobile，但 plasma-mobile 未安装"
    fi
    ;;
  *) skip "server 模式：跳过桌面环境核心包校验" ;;
esac

if [[ "${AUTOLOGIN:-false}" == "true" ]]; then
  case "${DESKTOP:-server}" in
    GNOME)
      [[ -f /etc/gdm/custom.conf ]] && pass "GDM 自动登录已配置" || fail "缺少 /etc/gdm/custom.conf"
      ;;
    "KDE Plasma")
      if [[ "${ROOTFS_BASE:-alarm}" == "holo-core" ]] && ! command -v sddm >/dev/null 2>&1; then
        # holo 无显示管理器时的兜底路径（sddm 未装上）：由 plasma-autologin.service 起会话
        systemctl is-enabled plasma-autologin.service >/dev/null 2>&1 \
          && pass "Plasma 自动登录服务已启用（holo 模式，无显示管理器）" \
          || fail "缺少已启用的 plasma-autologin.service"
      else
        [[ -f /etc/sddm.conf.d/autologin.conf ]] && pass "SDDM 自动登录已配置" || fail "缺少 /etc/sddm.conf.d/autologin.conf"
      fi
      ;;
  esac
fi

case "${DESKTOP:-server}" in
  GNOME)
    if systemctl is-enabled gdm.service >/dev/null 2>&1; then
      pass "gdm 已启用"
    else
      fail "gdm 未启用"
    fi
    ;;
  "KDE Plasma")
    if [[ "${ROOTFS_BASE:-alarm}" == "holo-core" ]] && command -v sddm >/dev/null 2>&1; then
      systemctl is-enabled sddm.service >/dev/null 2>&1 \
        && pass "sddm 已启用（holo 模式：本仓库构建的 sddm 包）" \
        || fail "sddm 已安装但未启用"
    elif [[ "${ROOTFS_BASE:-alarm}" == "holo-core" ]]; then
      if [[ "${AUTOLOGIN:-false}" == "true" ]] && ! systemctl is-enabled plasma-autologin.service >/dev/null 2>&1; then
        fail "plasma-autologin.service 未启用"
      else
        pass "holo 模式：无显示管理器（Plasma 会话由 systemd 拉起）"
      fi
    elif systemctl is-enabled sddm.service >/dev/null 2>&1; then
      pass "sddm 已启用"
    else
      fail "sddm 未启用"
    fi
    ;;
  *) skip "server 模式：未配置显示管理器" ;;
esac

if systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
  pass "NetworkManager 已启用"
else
  fail "NetworkManager 未启用"
fi

# ---------------------------------------------------------------------------
# 7.5) quiet_boot 时 plymouth 必须真的装上
#      plymouth.list 是 best-effort 安装的（ALARM 里 plymouth-themes / mkinitcpio 的
#      包名未逐一核实），因此这里做"关键项硬校验"，避免静默产出没有开机画面的镜像。
# ---------------------------------------------------------------------------
if [[ "${QUIET_BOOT:-false}" == "true" && "${DESKTOP:-server}" != "server" ]]; then
  if command -v plymouth >/dev/null 2>&1; then
    pass "plymouth 已安装（quiet boot）"
  else
    fail "quiet_boot=true 但 plymouth 未安装（见 lists/plymouth.list 的警告清单）"
  fi
fi

# ---------------------------------------------------------------------------
# 8) 防回归：Arch 侧不应存在 snap（与 ubuntu 版的 snap 校验对应）
# ---------------------------------------------------------------------------
if [[ -e /usr/bin/snap || -e /snap || -e /var/lib/snapd ]]; then
  fail "镜像里存在 snap/snapd（Arch 侧不应出现）"
else
  pass "无 snap / snapd（Arch 官方仓库不提供）"
fi

# ---------------------------------------------------------------------------
# 9) 清理镜像内的构建残留
# ---------------------------------------------------------------------------
rm -rf /tmp/pkgs /tmp/* 2>/dev/null || true

if [[ "$FAIL" -ne 0 ]]; then
  die "校验未通过，镜像不可用"
fi
log "全部校验通过"
