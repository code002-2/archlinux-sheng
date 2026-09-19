#!/usr/bin/env bash
# 20-alarm-chroot.sh —— 在宿主上准备一个「可复用的原生 ALARM aarch64 chroot」
#
# 为什么需要它：Arch 侧全部设备包都由 makepkg 构建，而 makepkg 要求：
#   * 在 Arch 环境里运行（pacman + base-devel + fakeroot，宿主是 Ubuntu runner）
#   * 不能以 root 运行（PKGBUILD 的构建脚本有权被执行，makepkg 会拒绝 root）
# 因此这里在宿主上直接解包 ALARM tarball 到 /mnt/alarm，做成一个原生的
# aarch64 Arch 环境 —— runner 是 ubuntu-24.04-arm（原生 arm64），所以
# chroot 进 aarch64 的 Arch 是原生的，**不需要 qemu-user-static / binfmt_misc**。
#
# 增量复用（重要）：
#   * /mnt/alarm 已经就绪（含 /usr/bin/pacman 与 builder 用户）时，只做
#     `pacman -Syu` 与依赖包补齐，不重新解包、不重新 init 密钥环
#   * 也可以用 tarball 快照在 job 之间复用（GitHub Actions 每一个 job 都是全新
#     虚拟机，因此缓存必须以文件形式落地）：
#         # 恢复阶段
#         sudo env ALARM_CHROOT_TAR=/mnt/alarm-chroot.tar.zst bash scripts/host/20-alarm-chroot.sh
#         # 保存阶段（cache key 命中失败时自动上传）
#         sudo env ALARM_CHROOT_PACK=/mnt/alarm-chroot.tar.zst bash scripts/host/20-alarm-chroot.sh
#     对应 workflow 中的 actions/cache 建议 key（见 README / _packages.yml）：
#         alarm-chroot-v1-<hashFiles('scripts/host/20-alarm-chroot.sh','scripts/common/distro-env.sh')>
#     注意：ALARM_TARBALL_URL 是滚动地址，**不要**把它的内容 hash 进 key，
#     否则缓存永远命中不了；用固定的 v1 前缀 + 脚本 hash 即可。
#
# 环境变量：
#   ALARM_CHROOT         chroot 目录（默认 /mnt/alarm）
#   ALARM_MIRROR         包镜像（默认 http://mirror.archlinuxarm.org）
#   ALARM_TARBALL_URL    tarball 地址
#   ALARM_TARBALL_PATH   复用已下载的 tarball
#   ALARM_CHROOT_TAR     若该 tarball 存在，则用它恢复 chroot（优先于网络下载）
#   ALARM_CHROOT_PACK    若设置，则构建完成后把 chroot 打包到该路径（供缓存）
#   ALARM_EXTRA_PKGS     额外的官方仓库包（空格分隔，默认空）
#   ALARM_AUR_SOURCE_PKGS  <包名>|<git URL> 列表，用于 ALARM 官方仓库没有的包
#                          （例如 AUR 包；默认空。protobuf-c/libssc 等 ALARM extra 里已有）
#
# 用法: sudo scripts/host/20-alarm-chroot.sh
#       sudo env ALARM_CHROOT_PACK=/mnt/alarm-chroot.tar.zst bash scripts/host/20-alarm-chroot.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
# shellcheck source=alarm-lib.sh
source "$HERE/alarm-lib.sh"
# shellcheck source=holo-lib.sh
source "$HERE/holo-lib.sh"
require_root

# 构建 chroot 目录由底包决定（ROOTFS_BASE=alarm → /mnt/alarm；holo-core → /mnt/holo）
ALARM_CHROOT="${ALARM_CHROOT:-$BUILD_CHROOT}"
ALARM_CHROOT_TAR="${ALARM_CHROOT_TAR:-}"
ALARM_CHROOT_PACK="${ALARM_CHROOT_PACK:-}"
ALARM_EXTRA_PKGS="${ALARM_EXTRA_PKGS:-}"
ALARM_AUR_SOURCE_PKGS="${ALARM_AUR_SOURCE_PKGS:-}"
BUILDER_USER="${BUILDER_USER:-builder}"

mkdir -p "$ALARM_CHROOT"

# ---------------------------------------------------------------------------
# 1) 准备 chroot 根目录：优先用缓存 tarball，其次解包 ALARM tarball
# ---------------------------------------------------------------------------
if [[ -x "$ALARM_CHROOT/usr/bin/pacman" ]]; then
  log "复用已就绪的 chroot: $ALARM_CHROOT"
else
  if [[ -n "$ALARM_CHROOT_TAR" && -s "$ALARM_CHROOT_TAR" ]]; then
    log "从缓存快照恢复 chroot: $ALARM_CHROOT_TAR ($(du -h "$ALARM_CHROOT_TAR" | cut -f1))"
    if ! tar -xpf "$ALARM_CHROOT_TAR" -C "$ALARM_CHROOT" 2>/dev/null; then
      warn "快照解包失败，改为从 ALARM tarball 重建"
      rm -rf "${ALARM_CHROOT:?}/"* "${ALARM_CHROOT:?}/".[!.]* 2>/dev/null || true
    fi
  fi
fi

if [[ ! -x "$ALARM_CHROOT/usr/bin/pacman" ]]; then
  _ALARM_TMP="$(mktemp -d)"
  trap 'rm -rf "$_ALARM_TMP"' EXIT
  if [[ "$ROOTFS_BASE" == "holo-core" ]]; then
    log "底包 = Holo Core（$HOLO_SNAPSHOT）：下载 system.rootfs.zst 作为构建 chroot"
    HOLO_ROOTFS_PATH="${HOLO_ROOTFS_PATH:-$_ALARM_TMP/system.rootfs.zst}"
    holo_fetch_rootfs "$HOLO_ROOTFS_PATH"
    holo_extract_rootfs "$HOLO_ROOTFS_PATH" "$ALARM_CHROOT"
    holo_ensure_base_dirs "$ALARM_CHROOT"
  else
    ALARM_TARBALL_PATH="${ALARM_TARBALL_PATH:-$_ALARM_TMP/ArchLinuxARM-aarch64-latest.tar.gz}"
    alarm_fetch_tarball "$ALARM_TARBALL_PATH"
    log "解包 ALARM 到 $ALARM_CHROOT"
    alarm_extract_tarball "$ALARM_TARBALL_PATH" "$ALARM_CHROOT"
  fi
  [[ -x "$ALARM_CHROOT/usr/bin/pacman" ]] || die "解包后仍找不到 pacman，底包可能损坏"
  FRESH_CHROOT=1
else
  FRESH_CHROOT=0
fi

# ---------------------------------------------------------------------------
# 1.5) 挂载虚拟文件系统（幂等：已挂载则跳过）
#   必须在 pacman-key --init / pacman -Syu 之前挂上：
#   gpg 的签名校验要读 /dev/urandom，而 ALARM tarball 自带的 /dev 未必完整，
#   缺失时会表现为 pacman-key 卡住或 "cannot open /dev/urandom"。
#   makepkg / fakeroot 还需要 /proc 与可写的 /dev/null。
#   函数定义已抽到 alarm-lib.sh（21-build-pkg.sh 也要用），这里传 chroot 根目录。
# ---------------------------------------------------------------------------
alarm_mount_virtfs "$ALARM_CHROOT"

# ---------------------------------------------------------------------------
# 2) 镜像源 / DNS / 架构
# ---------------------------------------------------------------------------
if [[ "$ROOTFS_BASE" == "holo-core" ]]; then
  # Holo Core：core + extra 两个仓库，SigLevel = Optional（包未强制签名）
  holo_write_repo_config "$ALARM_CHROOT"
else
  log "写入 pacman 镜像源: $ALARM_MIRROR/\$arch/\$repo"
  install -d "$ALARM_CHROOT/etc/pacman.d"
  cat > "$ALARM_CHROOT/etc/pacman.d/mirrorlist" <<EOF
# archlinux-sheng：由 scripts/host/20-alarm-chroot.sh 生成（构建用 chroot，非最终镜像）
Server = ${ALARM_MIRROR}/\$arch/\$repo
EOF
fi

# DNS：chroot 里没有任何 resolver 在跑，必须给它一个可用的 /etc/resolv.conf。
# 两个已知坑（首次实跑时就是这里失败：chroot 内报 "Could not resolve host"）：
#   1) ALARM rootfs 里的 /etc/resolv.conf 可能是指向 /run/systemd/resolve/... 的
#      **悬空软链**（该目录在解包后的 chroot 里不存在），此时 `cp -f` 会跟随软链写失败
#      → chroot 内根本没有 resolv.conf。必须先 rm -f 破掉软链。
#   2) 宿主的 resolv.conf 可能只含 systemd-resolved 的 stub（127.0.0.53），
#      在 chroot 内未必可用 —— 检测到 stub 就改用公共 DNS 兜底。
rm -f "$ALARM_CHROOT/etc/resolv.conf"
if [[ -r /etc/resolv.conf ]] && ! grep -qE '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.53' /etc/resolv.conf; then
  install -m644 /etc/resolv.conf "$ALARM_CHROOT/etc/resolv.conf"
  log "已写入 chroot DNS（沿用宿主 resolv.conf）"
else
  warn "宿主 resolv.conf 缺失或只含 127.0.0.53 stub，改用公共 DNS"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ALARM_CHROOT/etc/resolv.conf"
fi
log "chroot resolv.conf: $(tr '\n' ' ' < "$ALARM_CHROOT/etc/resolv.conf")"

grep -qE '^[[:space:]]*Architecture[[:space:]]*=[[:space:]]*aarch64' "$ALARM_CHROOT/etc/pacman.conf" || {
  warn "补写 pacman.conf 的 Architecture = aarch64"
  sed -i '1i Architecture = aarch64' "$ALARM_CHROOT/etc/pacman.conf"
}

# ---------------------------------------------------------------------------
# 2.5) 让 pacman 能在 chroot 里工作（详见 alarm-lib.sh 里 alarm_tune_pacman_for_chroot）
#   实测失败链：could not determine cachedir mount point → 空间检查误判
#   → "not enough free disk space" → 事务中止。
#   三处修法：修正 /etc/mtab 软链、关闭下载沙箱、构建 chroot 关闭 CheckSpace。
#   ALARM 的 pacman 不支持 --disable-sandbox 开关，只能改配置文件。
# ---------------------------------------------------------------------------
alarm_tune_pacman_for_chroot "$ALARM_CHROOT" --no-checkspace

# ---------------------------------------------------------------------------
# 3) 密钥环（只有全新 chroot 且底包为 ALARM 时才需要）
#    Holo Core 的仓库是 SigLevel = Optional（包未强制签名），不需要 populate
# ---------------------------------------------------------------------------
if [[ "$FRESH_CHROOT" -eq 1 && "$ROOTFS_BASE" != "holo-core" ]]; then
  log "初始化 pacman 密钥环"
  alarm_chroot_run "$ALARM_CHROOT" pacman-key --init || die "pacman-key --init 失败"
  alarm_chroot_run "$ALARM_CHROOT" pacman-key --populate archlinuxarm || die "pacman-key --populate archlinuxarm 失败"
fi

# ---------------------------------------------------------------------------
# 4) 全量更新 + 安装 base-devel（makepkg / fakeroot / gcc / make 全在这里）
#    --needed 避免重复安装；pacman -Syu 让滚动发行版保持最新（与镜像内一致）
# ---------------------------------------------------------------------------
log "pacman -Syu（滚动更新）"
alarm_chroot_run "$ALARM_CHROOT" pacman -Syu --noconfirm --needed || die "chroot 内 pacman -Syu 失败"

log "安装 base-devel 与构建工具"
# 必需集合：base-devel 已含 gcc/make/patch/fakeroot/pkgconf；libarchive 提供 bsdtar
# （deb 载荷解包与 PKGBUILD 的 pkgver() 都要用 bsdtar）
alarm_chroot_run "$ALARM_CHROOT" pacman -S --noconfirm --needed \
  base-devel git zstd xz libarchive || die "安装 base-devel 失败"

# 可选集合：个别包名可能在不同时间点不存在或被合并，装不上不影响主流程
# shellcheck disable=SC2086
alarm_chroot_run "$ALARM_CHROOT" pacman -S --noconfirm --needed \
  libarchive jq ccache $ALARM_EXTRA_PKGS || warn "可选构建工具安装失败（已忽略）"

# ---------------------------------------------------------------------------
# 4.5) 移除构建 chroot 自带的发行版内核
#   底包（ALARM tarball / Holo Core rootfs）都预装了 stock 内核，而我们在 21-build-pkg.sh
#   里会把构建产物 linux-xiaomi-sheng 装进同一个 chroot 供后续包使用，于是报：
#     :: linux-xiaomi-sheng-... and linux-6.17.8.arch1-1 are in conflict
#     [21-build-pkg.sh] 警告: 把 linux-xiaomi-sheng-... 装入构建 chroot 失败
#   （pacman --noconfirm 对"是否移除冲突包"默认回答 N）。
#   构建 chroot 不需要内核，-Rdd 直接删掉，顺带把缓存快照缩小约 500 MB。
# ---------------------------------------------------------------------------
for name in linux linux-aarch64; do
  if alarm_chroot_run "$ALARM_CHROOT" pacman -Q "$name" >/dev/null 2>&1; then
    log "移除构建 chroot 自带的发行版内核: $name（与 linux-xiaomi-sheng 冲突且构建不需要）"
    alarm_chroot_run "$ALARM_CHROOT" pacman -Rdd --noconfirm --color never "$name" \
      || warn "移除 $name 失败（继续，仅影响日志噪音）"
  fi
done

# ---------------------------------------------------------------------------
# 5) 允许以非 root 用户 builder 执行 makepkg
# ---------------------------------------------------------------------------
if ! alarm_chroot_run "$ALARM_CHROOT" id "$BUILDER_USER" >/dev/null 2>&1; then
  log "创建构建用户: $BUILDER_USER"
  alarm_chroot_run "$ALARM_CHROOT" useradd -m -s /bin/bash "$BUILDER_USER" || die "创建 $BUILDER_USER 失败"
fi
install -d -m 755 "$ALARM_CHROOT/etc/sudoers.d"
cat > "$ALARM_CHROOT/etc/sudoers.d/10-sheng-builder" <<EOF
# archlinux-sheng：makepkg 禁止 root，允许构建用户无密码使用 sudo 做安装步骤
${BUILDER_USER} ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 440 "$ALARM_CHROOT/etc/sudoers.d/10-sheng-builder"

# ---------------------------------------------------------------------------
# 6) 可选：ALARM 官方仓库没有的包（AUR 源码构建）
#    默认列表为空 —— 现有 10 个设备包的 makedepends 全部可由 ALARM 官方仓库满足
#    （libssc / iio-sensor-proxy / protobuf-c / libqmi / libmbim 都在 ALARM extra 里）。
#    语法：ALARM_AUR_SOURCE_PKGS='pkg-a|https://aur.archlinux.org/pkg-a.git pkg-b|...'
#
#    makepkg 需要 /proc、/dev（fakeroot 会用到），因此构建期间临时挂载虚拟文件系统，
#    结束后逆序卸载；这一步只影响构建 chroot，不会污染最终镜像。
# ---------------------------------------------------------------------------
# （alarm_mount_virtfs / alarm_umount_virtfs 已提前到第 1.5 步定义并挂载，见上）

alarm_build_aur_source_pkgs() {
  local entry name url
  [[ -n "$ALARM_AUR_SOURCE_PKGS" ]] || { log "ALARM_AUR_SOURCE_PKGS 为空：跳过源码构建的 AUR 包"; return 0; }
  alarm_mount_virtfs "$ALARM_CHROOT"
  for entry in $ALARM_AUR_SOURCE_PKGS; do
    name="${entry%%|*}"
    url="${entry#*|}"
    [[ -n "$name" && -n "$url" && "$name" != "$url" ]] || { warn "跳过非法条目: $entry"; continue; }
    log "源码构建 $name（$url）"
    rm -rf "$ALARM_CHROOT/build/aur"
    install -d "$ALARM_CHROOT/build/aur"
    alarm_chroot_run "$ALARM_CHROOT" git clone --depth 1 "$url" "/build/aur/$name" || { warn "clone 失败: $url"; continue; }
    alarm_chroot_run "$ALARM_CHROOT" chown -R "${BUILDER_USER}:${BUILDER_USER}" "/build/aur/$name" || true
    alarm_chroot_run "$ALARM_CHROOT" su - "$BUILDER_USER" -c "cd /build/aur/$name && makepkg -f --noconfirm --skippgpcheck" \
      || { warn "makepkg 失败: $name"; continue; }
    alarm_chroot_run "$ALARM_CHROOT" bash -c "pacman -U --noconfirm /build/aur/$name/*.pkg.tar.*" \
      || { warn "安装失败: $name"; continue; }
  done
  alarm_umount_virtfs "$ALARM_CHROOT"
  log "AUR 源码包构建完成"
}
# 用 `|| warn` 而不是裸调用：这样 $@ 在函数体内保持 set -e（bash 的 set -e 抑制规则）
alarm_build_aur_source_pkgs || warn "可选 AUR 源码包构建失败（已忽略）：$ALARM_AUR_SOURCE_PKGS"

# ---------------------------------------------------------------------------
# 7) 记录一次自检信息，便于在 CI 日志里核对环境
# ---------------------------------------------------------------------------
log "chroot 自检"
alarm_chroot_run "$ALARM_CHROOT" bash -c 'uname -m; pacman --version | head -n1; makepkg --version | head -n1; id builder'

# ---------------------------------------------------------------------------
# 7.4) 清理 chroot 内的 pacman 包缓存（磁盘空间）
#      GitHub 标准 arm64 runner 只有 14 GB 磁盘，而 ALARM tarball 解包后 + base-devel
#      + pacman 缓存会很快吃掉数 GB；缓存进快照还会让缓存体积翻倍。
#      安全性：缓存被清后，下一个作业恢复快照时第 4 步的 `pacman -Syu` 会重建
#      sync 数据库，因此随后 21-build-pkg.sh 里的 `makepkg -s` 仍能解析依赖。
# ---------------------------------------------------------------------------
rm -rf "${ALARM_CHROOT:?}/var/cache/pacman/pkg/"* 2>/dev/null || true
alarm_chroot_run "$ALARM_CHROOT" bash -c 'command -v pacman >/dev/null && pacman -Scc --noconfirm --color never' \
  || warn "清理 pacman 缓存失败（不影响功能）"

# ---------------------------------------------------------------------------
# 7.5) 打包快照前必须卸载虚拟文件系统
#      否则 tar 会把 /proc、/sys 以及宿主的 /dev（bind mount）一起打进缓存快照，
#      恢复出来的 chroot 会带着宿主的设备节点，甚至体积暴涨。
# ---------------------------------------------------------------------------
alarm_umount_virtfs "$ALARM_CHROOT"
# ---------------------------------------------------------------------------
# 8) 可选：打包快照供缓存
# ---------------------------------------------------------------------------
if [[ -n "$ALARM_CHROOT_PACK" ]]; then
  alarm_pack_chroot "$ALARM_CHROOT" "$ALARM_CHROOT_PACK"
fi

log "ALARM 构建 chroot 就绪: $ALARM_CHROOT"
