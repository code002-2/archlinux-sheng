#!/usr/bin/env bash
# 40-system-config.sh —— 系统级配置：主机名 / locale / 用户 / 密码 / 显示管理器 /
# 自动登录 / 网络 / fstab / 清理
#
# 对应 ubuntu-sheng 的 40-system-config.sh，语义一一对应，Arch 侧的差异：
#   * locale：写 /etc/locale.conf（Arch 没有 /etc/default/locale），
#     放开 /etc/locale.gen 后 locale-gen
#   * 用户：useradd -m -s /bin/bash -G wheel，并写 /etc/sudoers.d/10-wheel
#     （Ubuntu 用 sudo 组，Arch 的惯例是 wheel）
#   * GDM：Arch 的包是 gdm（不是 gdm3），自动登录写 /etc/gdm/custom.conf
#   * SDDM：同样写 /etc/sddm.conf.d/autologin.conf（Arch 的 sddm 会读该目录）
#   * 清理：pacman -Scc + 删 /var/cache/pacman/pkg/*
#
# 环境变量：
#   /root/build.env 提供 HOSTNAME / USERNAME / LANGUAGE / AUTOLOGIN / DESKTOP /
#                    PLASMA_MOBILE / PARTITION_LABEL / QUIET_BOOT
#   ROOTFS_PASSWORD 由 workflow 通过 env 传入（不落盘；为空则回退到上游的 password）
#
# 在 chroot 内执行:
#   chroot "$MOUNT" env ROOTFS_PASSWORD=... /root/sheng-build/in-chroot/40-system-config.sh
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

: "${HOSTNAME:?需要 HOSTNAME}"
: "${USERNAME:?需要 USERNAME}"
DESKTOP="${DESKTOP:-server}"
AUTOLOGIN="${AUTOLOGIN:-false}"
PLASMA_MOBILE="${PLASMA_MOBILE:-false}"
LANGUAGE="${LANGUAGE:-None (C.UTF-8)}"
PARTITION_LABEL="${PARTITION_LABEL:-linux}"

# ---------------------------------------------------------------------------
# 1) 主机名
# ---------------------------------------------------------------------------
log "设置主机名: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*$HOSTNAME" /etc/hosts 2>/dev/null; then
  echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# 2) locale（与 ubuntu 版一致：生成所选 locale + en_US.UTF-8）
#    Arch：locale 由 glibc 提供，/etc/locale.gen 决定生成哪些，然后 locale-gen
# ---------------------------------------------------------------------------
if [[ "$LANGUAGE" == "None (C.UTF-8)" ]]; then
  log "locale: 保持 C.UTF-8（跳过 locale-gen）"
else
  log "生成 locale: $LANGUAGE"
  [[ -f /etc/locale.gen ]] || die "缺少 /etc/locale.gen（glibc 是否已安装？）"
  sed -i 's/^# *\(en_US\.UTF-8\)/\1/' /etc/locale.gen
  esc="$(printf '%s' "$LANGUAGE" | sed 's/\./\\./g')"
  sed -i "s/^# *\(${esc}\)/\1/" /etc/locale.gen
  if ! grep -qE "^${esc}[[:space:]]" /etc/locale.gen; then
    warn "/etc/locale.gen 里没有可直接放开的 $LANGUAGE 条目，尝试整行追加"
    printf '%s UTF-8\n' "$LANGUAGE" >> /etc/locale.gen
  fi
  locale-gen
  # 生成结果校验：locale -a 的命名与 locale.gen 的写法不完全一致（zh_CN.UTF-8 → zh_CN.utf8），
  # 因此只做归一化后的比对并告警，不硬失败
  _want="$(printf '%s' "$LANGUAGE" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"
  if locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$_want"; then
    log "locale 已生成: $_want"
  else
    warn "locale -a 里没有找到 $_want（可能是命名差异），请人工确认 locale 是否生效"
  fi
  # Arch（systemd）约定：/etc/locale.conf
  printf 'LANG=%s\n' "$LANGUAGE" > /etc/locale.conf
fi

# ---------------------------------------------------------------------------
# 3) 用户与密码（上游语义：用户与 root 同密码）
# ---------------------------------------------------------------------------
if ! id "$USERNAME" >/dev/null 2>&1; then
  log "创建用户: $USERNAME（加入 wheel 组）"
  useradd -m -s /bin/bash -G wheel "$USERNAME"
fi

# wheel 组可 sudo（Arch 惯例；Ubuntu 那边是 sudo 组）
install -d -m 755 /etc/sudoers.d
cat > /etc/sudoers.d/10-wheel <<'EOF'
# archlinux-sheng：wheel 组可提权
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/10-wheel

# 密码由 workflow 写入 /root/build.pw（600），读完即删，避免出现在命令行参数里
if [[ -z "${ROOTFS_PASSWORD:-}" && -f /root/build.pw ]]; then
  ROOTFS_PASSWORD="$(cat /root/build.pw)"
fi
if [[ -z "${ROOTFS_PASSWORD:-}" ]]; then
  warn "ROOTFS_PASSWORD 未设置，使用上游同样的默认密码: password"
  ROOTFS_PASSWORD="password"
fi
printf '%s:%s\n' "$USERNAME" "$ROOTFS_PASSWORD" | chpasswd
printf 'root:%s\n' "$ROOTFS_PASSWORD" | chpasswd
rm -f /root/build.pw
log "已设置 $USERNAME 与 root 的密码"

# ---------------------------------------------------------------------------
# 4) 网络
# ---------------------------------------------------------------------------
log "启用 NetworkManager"
systemctl enable NetworkManager.service || warn "启用 NetworkManager 失败"

# ---------------------------------------------------------------------------
# 5) 显示管理器 + 自动登录
# ---------------------------------------------------------------------------
case "$DESKTOP" in
  GNOME)
    if [[ "$ROOTFS_BASE" == "holo-core" ]]; then
      die "holo-core 源里没有 GNOME/gdm（请在 workflow 里改选 KDE Plasma 或 server）"
    fi
    if [[ "$AUTOLOGIN" == "true" ]]; then
      log "配置 GDM 自动登录: $USERNAME"
      install -d /etc/gdm
      cat > /etc/gdm/custom.conf <<EOF
# archlinux-sheng：自动登录配置
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$USERNAME
EOF
    fi
    systemctl enable gdm.service || warn "启用 gdm 失败"
    systemctl set-default graphical.target
    ;;
  "KDE Plasma")
    # holo 模式下如果本仓库构建的 sddm 装上了（_packages.yml 的 build-sddm 作业），
    # 就走和 ALARM 完全一样的 SDDM 路径；否则退回 systemd 直起 Plasma 会话的兜底方案。
    if [[ "$ROOTFS_BASE" == "holo-core" ]] && ! command -v sddm >/dev/null 2>&1; then
      # holo 源里没有 sddm：用 systemd 服务在 tty1 上直接拉起 Plasma Wayland 会话。
      # autologin=true 时开机即进桌面；false 时保持 tty 登录，登录后手动
      # `startplasma-wayland`（或在该用户 ~/.bash_profile 里自行 exec）。
      systemctl set-default graphical.target
      if [[ "$AUTOLOGIN" == "true" ]]; then
        log "配置 Plasma 自动登录（holo 模式：无显示管理器，直接起 startplasma-wayland）"
        cat > /etc/systemd/system/plasma-autologin.service <<EOF
[Unit]
Description=Plasma Wayland session for $USERNAME (archlinux-sheng, autologin without display manager)
After=systemd-user-sessions.service systemd-logind.service
Conflicts=getty@tty1.service
After=getty@tty1.service

[Service]
Type=simple
User=$USERNAME
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
WorkingDirectory=/home/$USERNAME
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_SESSION_DESKTOP=KDE
Environment=XDG_CURRENT_DESKTOP=KDE
ExecStart=/usr/bin/dbus-run-session /usr/bin/startplasma-wayland
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF
        systemctl enable plasma-autologin.service || die "启用 plasma-autologin.service 失败"
      else
        log "holo 模式：autologin=false，保持 tty 登录（登录后执行 startplasma-wayland）"
      fi
    else
      if [[ "$AUTOLOGIN" == "true" ]]; then
        if [[ "$PLASMA_MOBILE" == "true" ]]; then SDDM_SESSION="plasmamobile"; else SDDM_SESSION="plasma"; fi
        log "配置 SDDM 自动登录: $USERNAME (session=$SDDM_SESSION)"
        install -d /etc/sddm.conf.d
        cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=$SDDM_SESSION
EOF
      fi
      systemctl enable sddm.service || warn "启用 sddm 失败"
      systemctl set-default graphical.target
    fi
    ;;
  server)
    log "server 模式：不配置显示管理器"
    systemctl set-default multi-user.target
    ;;
esac

# ---------------------------------------------------------------------------
# 6) fstab（PARTLABEL 定位根分区；x-systemd.growfs 首启自动扩容）
# ---------------------------------------------------------------------------
log "写入 fstab: PARTLABEL=$PARTITION_LABEL"
cat > /etc/fstab <<EOF
# <file system>            <mount point>  <type>  <options>                          <dump> <pass>
PARTLABEL=$PARTITION_LABEL /              ext4    defaults,x-systemd.growfs         0      1
EOF

# ---------------------------------------------------------------------------
# 7) 清理
#    注意：pacman 缓存（含 sync 数据库/var/lib/pacman/sync）**不在这里清**，
#    因为 90-verify.sh 紧随其后运行。真正的清理由 workflow 的最后一步
#    「[chroot] Clean pacman cache」负责（跑在 verify 通过之后）。
# ---------------------------------------------------------------------------
log "清理临时文件"
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
rm -f /var/log/pacman.log.old 2>/dev/null || true
# /tmp/pkgs 保留到 90-verify.sh 通过之后再删（见 90-verify.sh 末尾），
# 这样设备包校验阶段仍能列出包清单。

log "系统配置完成"
