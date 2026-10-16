#!/usr/bin/env bash
# ================================================================
# apply-sonic-fullcone.sh
#   Apply SONiC fullcone NAT patches to the OpenWrt source tree.
#
#   本脚本是 openwrt-sonic-fullcone 的「离线内嵌」版：
#   上游 add_sonic_fullcone.sh 会在运行时 git clone 仓库，
#   这里改为直接读取本仓库内嵌的 sonic-fullcone/ 补丁集，
#   避免 CI 期间再次联网克隆第三方仓库。
#
#   补丁作用点：
#     target/linux/generic/hack-<kv>/   内核 fullcone（984/985/986）
#     package/network/utils/iptables/   FULLCONE target（901）
#     package/libs/libnftnl/            fullcone 表达式序列化（001）
#     package/network/utils/nftables/   fullcone CLI 关键字（002）
#     package/network/config/firewall4/ nftables/fw4 per-zone（001）
#     package/network/config/firewall/  iptables/fw3 per-zone（001）
#     feeds/luci/applications/luci-app-firewall/  LuCI 选项（001）
#
# 运行目录: OpenWrt 源码根目录（feeds install -a 之后、编译之前）
#
# 用法:
#   cd /path/to/openwrt && \
#     SONIC_FULLCONE_SRC=/path/to/sonic-fullcone \
#     /path/to/apply-sonic-fullcone.sh
# ================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 补丁源目录：优先环境变量，其次仓库内嵌的 sonic-fullcone/
SRC="${SONIC_FULLCONE_SRC:-$SCRIPT_DIR/../sonic-fullcone}"

# --- 校验补丁源 ---
if [ ! -d "$SRC/kernel" ] || [ ! -d "$SRC/patches" ]; then
    echo "Error: sonic-fullcone patches not found at: $SRC"
    echo "       override with SONIC_FULLCONE_SRC=/path/to/sonic-fullcone"
    exit 1
fi

# --- 校验运行目录是 OpenWrt 源码树 ---
if ! [ -d "./package" ] || ! [ -d "./target" ]; then
    echo "Error: please run this script from the root of an OpenWrt source tree."
    exit 1
fi

# --- 检测内核版本 ---
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