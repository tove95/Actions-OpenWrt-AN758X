#!/usr/bin/env bash
# ================================================================
# add_sonic_fullcone.sh
#   Apply SONiC fullcone NAT patches to the OpenWrt source tree,
#   for GitHub Actions cloud builds.
#
#   与上游 mufeng05/openwrt-sonic-fullcone 的 add_sonic_fullcone.sh
#   行为一致：运行时 git clone 上游仓库获取补丁，再复制到源码树。
#   在此基础上增加一段「移除源码树自带 fullcone」逻辑：
#     ponwrt / immortalwrt 自带 kmod-nft-fullcone（独立 nft_fullcone.ko）
#     及配套的 nftables / firewall4 / firewall3 补丁，与 sonic 的内核
#     补丁（改 nf_nat_core / nft_masq）互斥，必须先整套拆除。
#
#   用法（OpenWrt 源码根目录，feeds install -a 之后、编译之前）:
#     cd /workdir/openwrt && bash /path/to/add_sonic_fullcone.sh
#
#   可覆盖的环境变量:
#     SONIC_FULLCONE_REPO   上游补丁仓库（默认 mufeng05/openwrt-sonic-fullcone）
#     SONIC_FULLCONE_REF    上游分支/标签（默认 master）
#     REMOVE_BUILTIN_FULLCONE  是否移除自带 fullcone（默认 1）
# ================================================================

set -e

# --- Check required tools ---
for tool in git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: '$tool' is required but not found in PATH."
        exit 1
    fi
done

# --- Check environment ---
if ! [ -d "./package" ] || ! [ -d "./target" ]; then
    echo "Error: please run this script from the root of an OpenWrt source tree."
    exit 1
fi

# --- Clone repo to temp dir ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REPO="${SONIC_FULLCONE_REPO:-https://github.com/mufeng05/openwrt-sonic-fullcone}"
REF="${SONIC_FULLCONE_REF:-master}"
SRC="$TMPDIR/sonic-fullcone"

echo "Cloning $REPO (branch: $REF) ..."
clone_ok=0
for attempt in 1 2 3; do
    if git clone --depth=1 --single-branch -b "$REF" "$REPO" "$SRC" 2>&1; then
        clone_ok=1
        break
    fi
    echo "::warning::git clone 第 $attempt 次失败，5 秒后重试"
    rm -rf "$SRC"
    sleep 5
done
if [ "$clone_ok" != "1" ]; then
    echo "Error: failed to clone $REPO after 3 attempts."
    echo "Check your network connection (GitHub 偶发 443 超时) and retry."
    exit 1
fi

# --- Verify patch source ---
if [ ! -d "$SRC/kernel" ] || [ ! -d "$SRC/patches" ]; then
    echo "Error: cloned repo does not contain the expected kernel/ and patches/ directories."
    exit 1
fi

# =========================================================
# 移除源码树自带的 fullcone（与 sonic 互斥）
#
#   ponwrt / immortalwrt 自带的满锥实现：
#     - fullconenat-nft   独立内核模块 nft_fullcone.ko（kmod-nft-fullcone）
#     - fullconenat       xt_FULLCONENAT（kmod-ipt-fullconenat）
#     - nftables / firewall4 / firewall3 配套补丁
#   与 sonic（改 nf_nat_core / nft_masq）是两套互斥实现：
#     · nftables 补丁同名，会被下面 cp -f 覆盖；
#     · firewall4/firewall3 补丁改同一批文件，hunk 重叠 → 第二个必失败。
#   故先整套拆除，让 sonic 成为唯一 fullcone 实现。
# =========================================================
REMOVE_BUILTIN_FULLCONE="${REMOVE_BUILTIN_FULLCONE:-1}"
if [ "$REMOVE_BUILTIN_FULLCONE" = "1" ]; then
    echo "=== 移除自带 fullcone（避免与 sonic 冲突）==="
    removed=0
    for d in \
        "./package/network/utils/fullconenat-nft" \
        "./package/network/utils/fullconenat"; do
        if [ -d "$d" ]; then
            rm -rf "$d"
            echo "[remove]    源码包已删除: $d"
            removed=$((removed + 1))
        fi
    done
    for f in \
        "./package/network/utils/nftables/patches/002-nftables-add-fullcone-expression-support.patch" \
        "./package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch" \
        "./package/network/config/firewall/patches/fullconenat.patch"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            echo "[remove]    补丁已删除: $f"
            removed=$((removed + 1))
        fi
    done
    echo "[remove]    共移除 $removed 项自带 fullcone"

    # 剥离 firewall4 / firewall(fw3) Makefile 里对已删包的内核依赖。
    # 仅仅删包、改 .config 还不够：DEPENDS 是硬依赖，apk 安装阶段会报
    #   kmod-nft-fullcone (no such package):
    #     required by: firewall4-2025.03.17~b6e51575-r4[kmod-nft-fullcone]
    # sonic 的 fullcone 编进现有 kmod-nft-nat（nft_masq），无需独立包。
    fw4_mk="./package/network/config/firewall4/Makefile"
    if [ -f "$fw4_mk" ] && grep -q 'kmod-nft-fullcone' "$fw4_mk"; then
        sed -i 's/ +kmod-nft-fullcone//g' "$fw4_mk"
        echo "[remove]    firewall4 依赖已剥离: +kmod-nft-fullcone"
    fi
    fw3_mk="./package/network/config/firewall/Makefile"
    if [ -f "$fw3_mk" ] && grep -q 'iptables-mod-fullconenat' "$fw3_mk"; then
        sed -i 's/ +iptables-mod-fullconenat//g' "$fw3_mk"
        echo "[remove]    firewall(fw3) 依赖已剥离: +iptables-mod-fullconenat"
    fi

    # 兜底：若还有其它组件依赖已删的 fullcone 包，打印告警便于排查
    for mf in $(grep -rl --include=Makefile 'kmod-nft-fullcone\|iptables-mod-fullconenat' package/ 2>/dev/null); do
        case "$mf" in
            ./package/network/config/firewall4/Makefile|./package/network/config/firewall/Makefile) continue ;;
        esac
        echo "[remove]    ::warning::仍有组件依赖已删的 fullcone 包: $mf"
    done

    # 强制重建包索引：diy-part1.sh 已生成过含 kmod-nft-fullcone 的
    # tmp/.packageinfo，清掉 stamp 让后续 make defconfig 重新扫描，
    # 避免残留的自带 fullcone 包符号被二次 defconfig 带回。
    if [ "$removed" -gt 0 ]; then
        rm -f tmp/.packageinfo tmp/.targetinfo tmp/.config-package.in tmp/.config-target.in
        rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
    fi
fi

# --- Detect kernel versions ---
kernel_versions=""
for f in ./include/kernel-[0-9]*; do
    [ -f "$f" ] && kernel_versions="$kernel_versions $(basename "$f" | sed 's/kernel-//')"
done
if [ -z "$kernel_versions" ]; then
    for f in ./target/linux/generic/kernel-[0-9]*; do
        [ -f "$f" ] && kernel_versions="$kernel_versions $(basename "$f" | sed 's/kernel-//')"
    done
fi
kernel_versions="$(echo "$kernel_versions" | xargs)"

if [ -z "$kernel_versions" ]; then
    echo "Error: cannot detect kernel version."
    exit 1
fi
echo "Detected kernel versions: $kernel_versions"

applied=0
skipped=0

# --- Kernel patches ---
#   984: nf_nat_core fullcone (SONiC core, 3-tuple hash)
#   985: xt_MASQUERADE FULLCONE target (iptables, PRE+POST hooks)
#   986: nft_masq fullcone expression (nftables, PRE+POST hooks)
for kv in $kernel_versions; do
    hack_dir="./target/linux/generic/hack-$kv"
    if [ -d "$hack_dir" ]; then
        cp -f "$SRC/kernel/984-add-sonic-fullcone-support.patch"  "$hack_dir/"
        cp -f "$SRC/kernel/985-add-sonic-fullcone-to-ipt.patch"   "$hack_dir/"
        cp -f "$SRC/kernel/986-add-sonic-fullcone-to-nft.patch"   "$hack_dir/"
        echo "[kernel]   hack-$kv: applied (984+985+986)"
        applied=$((applied + 3))
    else
        echo "[kernel]   hack-$kv: directory not found, skipped"
        skipped=$((skipped + 3))
    fi
done

# --- iptables: FULLCONE target userspace support ---
if [ -d "./package/network/utils/iptables" ]; then
    ipt_dir="./package/network/utils/iptables/patches"
    mkdir -p "$ipt_dir"
    cp -f "$SRC/patches/iptables/901-sonic-fullcone.patch" "$ipt_dir/"
    echo "[iptables] applied"
    applied=$((applied + 1))
else
    echo "[iptables] not found, skipped"
    skipped=$((skipped + 1))
fi

# --- libnftnl: fullcone expression serialization ---
if [ -d "./package/libs/libnftnl" ]; then
    nftnl_dir="./package/libs/libnftnl/patches"
    mkdir -p "$nftnl_dir"
    cp -f "$SRC/patches/libnftnl/001-libnftnl-add-fullcone-expression-support.patch" "$nftnl_dir/"

    # The patch touches src/Makefile.am, making it newer than the pre-generated
    # src/Makefile.in shipped in the tarball. make then tries to regenerate
    # Makefile.in with the exact automake version that produced it (automake-1.17
    # for libnftnl 1.3.1), which does not exist in the build environment --
    # OpenWrt's own host tools provide automake 1.18.x only. PKG_FIXUP:=autoreconf
    # regenerates the build system with whatever autotools OpenWrt ships.
    nftnl_mk="./package/libs/libnftnl/Makefile"
    if [ -f "$nftnl_mk" ] && ! grep -q '^PKG_FIXUP:=.*autoreconf' "$nftnl_mk"; then
        awk '!ins && /^include \$\(INCLUDE_DIR\)\/package\.mk/ { print "PKG_FIXUP:=autoreconf"; print ""; ins=1 } { print }' \
            "$nftnl_mk" > "$nftnl_mk.tmp" && mv "$nftnl_mk.tmp" "$nftnl_mk"
        echo "[libnftnl] PKG_FIXUP:=autoreconf added to package Makefile"
    fi

    echo "[libnftnl] applied"
    applied=$((applied + 1))
else
    echo "[libnftnl] not found, skipped"
    skipped=$((skipped + 1))
fi

# --- nftables: fullcone CLI keyword ---
if [ -d "./package/network/utils/nftables" ]; then
    nft_dir="./package/network/utils/nftables/patches"
    mkdir -p "$nft_dir"
    cp -f "$SRC/patches/nftables/002-nftables-add-fullcone-expression-support.patch" "$nft_dir/"
    echo "[nftables] applied"
    applied=$((applied + 1))
else
    echo "[nftables] not found, skipped"
    skipped=$((skipped + 1))
fi

# --- firewall4 (nftables/fw4): per-zone, per-proto fullcone ---
if [ -d "./package/network/config/firewall4" ]; then
    fw4_dir="./package/network/config/firewall4/patches"
    mkdir -p "$fw4_dir"
    cp -f "$SRC/firewall/firewall4/001-sonic-fullcone.patch" "$fw4_dir/"
    echo "[fw4]      applied"
    applied=$((applied + 1))
else
    echo "[fw4]      not found, skipped"
    skipped=$((skipped + 1))
fi

# --- firewall3 (iptables/fw3): per-zone, per-proto fullcone ---
if [ -d "./package/network/config/firewall" ]; then
    fw3_dir="./package/network/config/firewall/patches"
    mkdir -p "$fw3_dir"
    cp -f "$SRC/firewall/firewall3/001-sonic-fullcone.patch" "$fw3_dir/"
    echo "[fw3]      applied"
    applied=$((applied + 1))
else
    echo "[fw3]      not found, skipped"
    skipped=$((skipped + 1))
fi

# --- LuCI: web interface fullcone options ---
if [ -d "./feeds/luci/applications/luci-app-firewall" ]; then
    luci_fw_dir="./feeds/luci/applications/luci-app-firewall/patches"
    mkdir -p "$luci_fw_dir"
    cp -f "$SRC/patches/luci-app-firewall/"*.patch "$luci_fw_dir/"
    echo "[luci]     patch applied"

    # Append zh_Hans translations directly to po file (po/ is not in build_dir, patches won't work)
    zh_po="./feeds/luci/applications/luci-app-firewall/po/zh_Hans/firewall.po"
    if [ -f "$zh_po" ] && ! grep -q "Fullcone NAT" "$zh_po"; then
        cat "$SRC/translations/zh_Hans.po" >> "$zh_po"
        echo "[luci]     zh_Hans translation appended"
    fi
    applied=$((applied + 1))
else
    echo "[luci]     not found — run './scripts/feeds update -a && ./scripts/feeds install -a' first"
    skipped=$((skipped + 1))
fi

echo ""
echo "=== Done: $applied applied, $skipped skipped ==="
if [ "$skipped" -gt 0 ]; then
    echo "Warning: some patches were skipped. Run './scripts/feeds update -a && ./scripts/feeds install -a' and re-run this script if LuCI was skipped."
fi
echo ""
echo "After flashing, enable fullcone via LuCI (Network > Firewall) or UCI:"
echo ""
echo "  uci set firewall.@defaults[0].fullcone='1'"
echo "  uci set firewall.@zone[1].fullcone='1'"
echo "  uci commit firewall && /etc/init.d/firewall restart"
