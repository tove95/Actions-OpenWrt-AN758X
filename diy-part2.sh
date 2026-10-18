#!/bin/bash
# ================================================================
# diy-part2.sh —— 默认值定制（在 .config 加载之后运行）
# 运行目录: ponwrt 源码根目录
#
#   1) 默认时区改成中国（Asia/Shanghai, CST-8）
#   2) 5G WiFi：国家码 CN、信道 auto、频宽 160MHz
#   3) 概览页「CPU 使用率（%）」行：显示 USR/SYS + 每个核心的明细
#   4) 固件版本后追加「作者 + 构建时间」
#
# ================================================================

set -euo pipefail

echo "=========================================="
echo "默认值定制：时区 + 5G WiFi (diy-part2.sh)"
echo "=========================================="

# =============================================================
# 可配置：5G 无线参数
# 如需改动，直接改这里即可（编译期常量，会写进 uci-defaults 脚本）
# =============================================================
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"       # 国家代码（CN = 中国）
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-auto}"     # 信道（auto = 自动选择）
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"      # 160MHz（WiFi6）；回落 HE80
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"   # 硬件不支持 160MHz 时的回落值

readonly FW_AUTHOR="qwe"
FW_BUILD_TIME="${FW_BUILD_TIME:-}"
FW_DESC_SUFFIX="${FW_DESC_SUFFIX:-}" 

echo "配置：5G country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE fallback=$WIFI_5G_FALLBACK"
echo "配置：FW_AUTHOR=$FW_AUTHOR (固定)"

# ---------------------------------------------------------
# 1. 修改 config_generate 的默认值（首次开机生成的 /etc/config/system）
# ---------------------------------------------------------
CFG="package/base-files/files/bin/config_generate"

if [ -f "$CFG" ]; then
  # 兼容 @system[-1]（旧）与 @system[0]（OpenWrt 21+）
  sed -i "s/option timezone.*/option timezone 'CST-8'/" "$CFG"
  sed -i "s/option zonename.*/option zonename 'Asia\/Shanghai'/" "$CFG"
  echo "✅ config_generate 默认时区 -> CST-8 / Asia/Shanghai"
else
  echo "::warning::未找到 $CFG，跳过默认值修改"
fi

# ---------------------------------------------------------
# 2. uci-defaults：即使保留了旧配置也强制刷成中国时区
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
uci -q batch <<'UCI'
set system.@system[0].zonename='Asia/Shanghai'
set system.@system[0].timezone='CST-8'
commit system
UCI
exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ uci-defaults 时区脚本已写入"

# ---------------------------------------------------------
# 3. 补上亚洲时区数据库包（LuCI 显示与时区切换需要）
# ---------------------------------------------------------
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  echo "CONFIG_PACKAGE_zoneinfo-asia=y    # 亚洲时区数据库（中国时区需要）" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"
fi

# ---------------------------------------------------------
# 4. 5G WiFi：国家码 CN / 信道 auto / 频宽 160MHz
#
#    分两层落地：
#      a) 编译期：改无线 detect 脚本的默认值（best effort，找不到就跳过）
#      b) 运行期：uci-defaults 首启强制刷（主要手段，与保留配置升级都生效）
#
#    说明：不同版本 detect 脚本路径不同（有的叫 mac80211.sh / mac80211.uc），
#    且 uci-defaults 执行时 /etc/config/wireless 可能尚未生成，
#    故 uci-defaults 里自带「未生成就先生成」的逻辑。
# ---------------------------------------------------------

# ---- 4a. 编译期：改 detect 脚本默认值（best effort） ----
DETECT_SCRIPT=""
for cand in \
  "package/kernel/mac80211/files/lib/wifi/mac80211.sh" \
  "package/kernel/mac80211/files/lib/wifi/mac80211.uc" \
  "package/network/services/hostapd/files/lib/wifi/mac80211.sh"; do
  [ -f "$cand" ] && { DETECT_SCRIPT="$cand"; break; }
done

if [ -n "$DETECT_SCRIPT" ]; then
  # 5G（11a / band 5g）的默认信道改成 auto
  sed -i "s/option channel '36'/option channel 'auto'/g" "$DETECT_SCRIPT"
  sed -i "s/option channel='36'/option channel='auto'/g" "$DETECT_SCRIPT"
  echo "✅ detect 脚本默认信道 -> auto ($DETECT_SCRIPT)"
else
  echo "::warning::未找到无线 detect 脚本，跳过编译期默认值修改（由 uci-defaults 兜底）"
fi

# ---- 4b. 运行期：uci-defaults 首启强制刷 ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/96-wifi-5g-cn <<UCEOF
#!/bin/sh
# 5G WiFi 默认值：国家码 CN、信道 auto、频宽 160MHz
# 由 diy-part2.sh 生成（编译期常量注入）

COUNTRY='$WIFI_5G_COUNTRY'
CHANNEL='$WIFI_5G_CHANNEL'
HTMODE='$WIFI_5G_HTMODE'
FALLBACK='$WIFI_5G_FALLBACK'

log() { logger -t wifi-5g "\$@"; }

# uci-defaults 可能在 wifi config 之前执行 —— 没生成就先生成
if [ ! -f /etc/config/wireless ]; then
	command -v wifi >/dev/null 2>&1 && wifi config >/dev/null 2>&1
fi
[ -f /etc/config/wireless ] || { log "未找到 /etc/config/wireless，跳过"; exit 0; }

# 检测该 phy 是否支持 160MHz（兼容 "160 MHz" 与 "80+80 MHz" 两种表述）
support_160() {
	local phy="\$1"
	[ -z "\$phy" ] && return 1
	command -v iw >/dev/null 2>&1 || return 1
	iw phy "\$phy" info 2>/dev/null | grep -qE '160 MHz|80\+80 MHz' || return 1
	return 0
}

changed=0
for dev in \$(uci -q show wireless | sed -n 's/^wireless\.\([A-Za-z0-9_-]*\)=wifi-device\$/\1/p'); do
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"

	# 只处理 5G：新版用 band='5g'，旧版用 hwmode='11a'
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1
	[ "\$is5g" = "0" ] && continue

	# 频宽：确认不支持 160MHz 才回落
	# 取不到 phy 名时不检测（保持 HTMODE）—— 避免无 phy 选项的 radio 被误判回落
	ht="\$HTMODE"
	phy="\$(uci -q get wireless.\$dev.phy 2>/dev/null)"
	if [ -n "\$phy" ] && ! support_160 "\$phy"; then
		ht="\$FALLBACK"
		log "\$dev：未检测到 160MHz 能力，回落为 \$ht"
	fi

	uci -q set wireless.\$dev.country="\$COUNTRY"
	uci -q set wireless.\$dev.country_ie='1'
	uci -q set wireless.\$dev.channel="\$CHANNEL"
	uci -q set wireless.\$dev.htmode="\$ht"

	log "\$dev：country=\$COUNTRY channel=\$CHANNEL htmode=\$ht"
	changed=1
done

if [ "\$changed" = "1" ]; then
	uci -q commit wireless
	# 重载而非重启：避免首启期间无线中断后不可恢复
	command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1 || true
	log "已提交 wireless 配置"
else
	log "未找到 5G radio，未做任何修改"
fi

exit 0
UCEOF
chmod +x files/etc/uci-defaults/96-wifi-5g-cn
echo "✅ uci-defaults 5G WiFi 脚本已写入（country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE）"

# ---- 4c. 确保 hostapd 支持 160MHz / 11ax ----
# wpad-openssl = 完整版 hostapd，支持 HE160；
# 若用的是 wpad-basic / hostapd-basic（精简版），160MHz 可能不生效。
if [ -f .config ]; then
  if grep -qE "^CONFIG_PACKAGE_(wpad-basic|hostapd-basic)=y" .config; then
    echo "::warning::检测到精简版 wpad/hostapd-basic，160MHz 可能不支持"
  fi
  # 无线工具：uci-defaults 里的能力检测需要 iw
  if ! grep -q "^CONFIG_PACKAGE_iw=y" .config; then
    sed -i '/^CONFIG_PACKAGE_iw=/d; /^# CONFIG_PACKAGE_iw is not set/d' .config
    echo "CONFIG_PACKAGE_iw=y                       # 无线命令行工具（160MHz 能力检测需要）" >> .config
    echo "✅ iw 已加入 .config"
  fi
fi

# ---------------------------------------------------------
# 5. 概览页「CPU 使用率（%）」行：显示 USR/SYS + 每核明细
#
#    ImmortalWrt 的 luci 把这一行的值写成
#      luci.getCPUUsage → popen("top -n1 | awk '/^CPU/ {printf(\"%d%\", 100 - $8)}'")
#    只有一个总占用率。这里把它改指到 files/sbin/cpuusage（rootfs 覆盖，
#    已由 workflow 第 6 步拷进源码树的 files/），前端 10_system.js 与 ACL
#    都不用动。
#
#    脚本负责判断、打补丁与自检，找不到目标只 warning 不中断编译 ——
#    这是纯显示层的东西，不该让它把一次几小时的构建搞挂。
# ---------------------------------------------------------
PATCH_CPUUSAGE="$(dirname "$0")/scripts/patch-luci-cpuusage.sh"
if [ -f "$PATCH_CPUUSAGE" ]; then
  PONWRT_DIR=. bash "$PATCH_CPUUSAGE" || true
else
  echo "::warning::未找到 $PATCH_CPUUSAGE，跳过概览页 CPU 使用率行定制"
fi

[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"

VER_CODE="$(sed -n 's/^CONFIG_VERSION_CODE="\(.*\)"$/\1/p' .config 2>/dev/null || true)"
if [ -n "$VER_CODE" ]; then
  DESC_BODY='%D %V %C'
else
  DESC_BODY='%D %V'
fi
[ -z "$FW_DESC_SUFFIX" ] && FW_DESC_SUFFIX="· ${FW_AUTHOR} · ${FW_BUILD_TIME}"

RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"

# 用 perl + 环境变量传替换文本：作者名/后缀里带 / | # & 都不会搞坏语法
# （直接 sed "s|...|${FW_DESC_SUFFIX}|" 遇到这些字符会炸）
FW_DESC_LINE="DISTRIB_DESCRIPTION='${DESC_BODY} ${FW_DESC_SUFFIX}'"
OSREL_LINE="OPENWRT_RELEASE=\"${DESC_BODY} ${FW_DESC_SUFFIX}\""
export FW_DESC_LINE OSREL_LINE

if [ -f "$RELEASE_TPL" ]; then
  # 只替换 DISTRIB_DESCRIPTION 行，不动 DISTRIB_ID / DISTRIB_RELEASE 等其它行
  perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$RELEASE_TPL"
  echo "✅ 固件版本模板 -> $FW_DESC_LINE"
else
  echo "::warning::未找到 $RELEASE_TPL，固件版本不会带构建信息"
fi

# os-release 同步（部分工具/LuCI 版本读它；%B 只是 SOURCE_DATE_EPOCH 时间戳，不好看）
if [ -f "$OSREL_TPL" ]; then
  perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$OSREL_TPL"
  echo "✅ os-release 同步 -> $OSREL_LINE"
fi

# ---------------------------------------------------------
# 6. SONiC fullcone：剥离源码基座里自带的 fullcone 包符号
#
#    ponwrt 源码基座 configs/an7581.config、an7583.config 里有
#    CONFIG_PACKAGE_kmod-nft-fullcone=y，编出的是独立的 nft_fullcone.ko，
#    与 sonic 的内核补丁（改 nf_nat_core / nft_masq）互斥。
#    补丁层面已由 scripts/add_sonic_fullcone.sh 拆掉自带源码包，
#    这里再从已加载的 .config 里剥离对应符号，避免 defconfig 反复告警。
#    APPLY_SONIC_FULLCONE != true 时不动 .config。
# ---------------------------------------------------------
if [ "${APPLY_SONIC_FULLCONE:-true}" = "true" ] && [ -f .config ]; then
  for sym in kmod-nft-fullcone kmod-ipt-fullconenat iptables-mod-fullconenat; do
    sed -i "/^CONFIG_PACKAGE_${sym}=/d; /^# CONFIG_PACKAGE_${sym} is not set/d" .config
    echo "# CONFIG_PACKAGE_${sym} is not set  # 由 SONiC fullcone 取代" >> .config
    echo "✅ 已剥离自带 fullcone 包符号: ${sym}"
  done
fi

# ---------------------------------------------------------
# 7. 内核「软件」AES-GCM 加速（AN7581/AN7583 无硬件 AES，只能走软件）
#
#    背景（源码 pbs05/ponwrt，内核 6.18，airoha an7581/an7583 = aarch64 A53）：
#      · generic/config-6.18 里 AES/GCM/GHASH/CTR 的「通用软件实现」已是
#        built-in：
#          CONFIG_CRYPTO_AES=y  CONFIG_CRYPTO_GCM=y
#          CONFIG_CRYPTO_GHASH=y  CONFIG_CRYPTO_CTR=y
#        即 AES-128-GCM / AES-256-GCM 算法本身已能用，但 gcm(aes) 只能退回
#        aes-generic(查表实现) + ghash-generic，慢且非恒定时间。
#      · AN7581/AN7583 的 CPU 不带 ARMv8 Crypto Extensions（无 AES/PMULL
#        指令），所以内核里 CRYPTO_AES_ARM64_CE* / CRYPTO_GHASH_ARM64_CE
#        这些「硬件指令实现」在本平台无效（驱动会因 CPU 无该特性而不注册）。
#      · SoC 里另有 EIP93 硬件加密引擎（kmod-crypto-hw-eip93），但它只做
#        DES/3DES/AES 的 ECB/CBC/CTR 与 IPsec authenc(hmac,aes/cbc)，
#        **不支持 GCM**，对 AES-GCM 没有任何帮助。
#
#    => 无硬件 AES 时唯一可用的「软件加速」是 ARM64 的 bit-sliced NEON AES：
#         CONFIG_CRYPTO_AES_ARM64         aes-neonbs，bit-sliced，priority 300
#                                         （高于 aes-generic 的 100，会被优先选）
#         CONFIG_CRYPTO_AES_ARM64_NEON_BLK  ECB/CBC/CTR/XTS（NEON 模式）
#         CONFIG_CRYPTO_AES_ARM64_BS        ECB/CBC/CTR/XCTR/XTS（bit-sliced）
#       启用后 ctr(aes) 换成 aes-neonbs，gcm(aes) 自动采用它；GHASH 没有
#       非 CE 的 arm64 实现，仍用 ghash-generic。
#
#    关键：**不要**打开 CONFIG_CRYPTO_AES_ARM64_CE* / CRYPTO_GHASH_ARM64_CE，
#    那些是 ARMv8 Crypto Extensions 硬件指令实现，本 CPU 没有对应指令。
#
#    这些符号在 OpenWrt 没有对应 kmod 包（crypto.mk 里的 ghash-arm-ce 只给
#    32 位 ARM），只能走内核配置：用 CONFIG_KERNEL_* 前缀写进 .config，
#    defconfig 时映射为内核 CONFIG_*。workflow 步骤 8 在本脚本之后、
#    步骤 9 defconfig 之前，所以这里的追加会被正确展开并覆盖 generic 的
#    "is not set"。
# ---------------------------------------------------------
ADD_KERNEL_AES_GCM="${ADD_KERNEL_AES_GCM:-true}"
if [ "$ADD_KERNEL_AES_GCM" = "true" ] && [ -f .config ]; then
  # 打开：通用 AES-GCM + ARM64 bit-sliced NEON 软件加速
  for sym in \
    CRYPTO_SIMD \
    CRYPTO_AES \
    CRYPTO_AES_ARM64 \
    CRYPTO_AES_ARM64_NEON_BLK \
    CRYPTO_AES_ARM64_BS \
    CRYPTO_GCM \
    CRYPTO_GHASH \
    CRYPTO_CTR \
    CRYPTO_AEAD ; do
    sed -i "/^CONFIG_KERNEL_${sym}=/d; /^# CONFIG_KERNEL_${sym} is not set/d" .config
    echo "CONFIG_KERNEL_${sym}=y" >> .config
  done

  # 显式关闭需要 ARMV8 Crypto Extensions 的硬件实现（本 CPU 不支持，开了也无效）
  for sym in \
    CRYPTO_AES_ARM64_CE \
    CRYPTO_AES_ARM64_CE_BLK \
    CRYPTO_AES_ARM64_CE_CCM \
    CRYPTO_GHASH_ARM64_CE ; do
    sed -i "/^CONFIG_KERNEL_${sym}=/d; /^# CONFIG_KERNEL_${sym} is not set/d" .config
    echo "# CONFIG_KERNEL_${sym} is not set" >> .config
  done

  echo "✅ 内核软件 AES-GCM 加速已加入 .config（bit-sliced NEON AES + generic GCM/GHASH）"
else
  echo "内核软件 AES-GCM 加速：未开启（ADD_KERNEL_AES_GCM=$ADD_KERNEL_AES_GCM）"
fi

echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"
