#!/usr/bin/env bash
# =============================================================
# pwrt-cache.sh —— 整体构建缓存（OpenWRT-CI 风格）
#
#   思路与 VIKINGYFY/OpenWRT-CI 一致：
#     缓存整个 staging_dir（含 host 工具、交叉编译器、hostpkg 的 Go、
#     target-*/host 的 Rust），靠「指纹」决定是否复用，恢复后 touch
#     全部 stamp 让 make 认定已装；dl 与 .ccache 长期累计。
#
#   与之前「挑 go / rust 产物打包」那套的区别：
#     - 不再猜产物落在 staging_dir/host 还是 hostpkg 还是 target-*/host
#       （整目录收，位置问题从根上消失）；
#     - 不再单独处理 build_dir 的 .built —— 整目录的 stamp 全在里面，
#       且 build_dir 本身不打包（太大）；
#     - 不再按机型判断「要不要编 golang」，预热流程一律编全。
#
# 子命令：
#   fingerprint <openwrt_dir>   算指纹与 key
#   pack        <openwrt_dir>   打包 staging_dir → $STAGING_CACHE_DIR/<KEY>.tzst
#   unpack      <openwrt_dir>   解压 + touch 全部 stamp
#   status      <openwrt_dir>   打印版本与目录体积
# =============================================================

set -u

OW="${2:-$PWD}"
cd "$OW" || exit 1

out() { # 同时写 GITHUB_OUTPUT（CI 里）和 stdout
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"
}

# ---------------------------------------------------------------
# staging_dir 里要收的部分
#
#   收：host（tools 装的 host 工具，含 gcc）
#       hostpkg（HostBuild 且不依赖 target 的包 —— golang 在这里）
#       toolchain-*（交叉编译器）
#       target-*/host（HostBuild 且绑定 target 的包 —— rust 在这里）
#
#   不收：target-*/ 下的其它子目录（packages / root-* / stamp），
#         那是固件编译的产物，每次都要重来，收了只增加体积。
#   tools/ 与 build_dir/ 也不收（build_dir 动辄 10GB+）。
# ---------------------------------------------------------------
staging_parts() {
  local d
  for d in staging_dir/host staging_dir/hostpkg staging_dir/toolchain* \
           staging_dir/target-*/host; do
    [ -e "$d" ] && printf '%s\n' "$d"
  done
}

# ---------------------------------------------------------------
# 指纹：决定「能不能整体复用」
#
#   ★ 口径必须【生产端与消费端完全一致】，否则永远命中不了。
#     warm-cache 用 configs/<soc>.config，主流程用 configs/<机型>.config，
#     两者内容不同 —— 所以整机 .config 绝不能进指纹。
#
#   只算会影响 host 工具链 / 交叉编译器 / host 侧 Go·Rust 的部分：
#     include/ + tools/ + toolchain/ 的构建脚本
#     feeds 里 golang / rust 的包定义
#     feeds.conf 与各 feed 提交
#     CI 仓的 diy-part*.sh（会改变源码树）
#     runner 架构（避免不同 OS 误复用）
# ---------------------------------------------------------------
fingerprint() {
  local tmp; tmp=$(mktemp)

  # ⚠ 口径只覆盖「会影响 host 工具链 / 交叉编译器 / host 侧 Go·Rust」的东西。
  #   刻意【不】含整机 .config 与上游 HEAD —— 见下方说明。

  # 1) 构建系统本身
  #    include/ 变动会改变编译行为；tools/ toolchain/ 决定工具链版本。
  #   这两项与「上游新增了什么软件包」无关，所以上游提交不会让缓存失效。
  for d in include tools toolchain; do
    find "$d" -type f \( -name 'Makefile' -o -name '*.mk' -o -name '*.sh' \) \
      -exec md5sum {} + 2>/dev/null | sort -k2 >> "$tmp"
  done

  # 2) host 侧语言栈的包定义 —— 决定 golang / rustc 的版本与构建方式
  for d in feeds/packages/lang/golang feeds/packages/lang/rust \
           package/feeds/packages/golang package/feeds/packages/rust; do
    [ -e "$d" ] || continue
    find -L "$d" -maxdepth 2 -type f \
      \( -name 'Makefile' -o -name '*.mk' \) -exec md5sum {} + 2>/dev/null | sort -k2 >> "$tmp"
  done

  # 3) feeds 配置与各 feed 的提交
  for f in feeds.conf feeds.conf.default; do
    [ -f "$f" ] && md5sum "$f" >> "$tmp"
  done
  if [ -d feeds ]; then
    for d in feeds/*/; do
      [ -d "$d" ] || continue
      printf '%s ' "${d%/}" >> "$tmp"
      git -C "$d" rev-parse HEAD 2>/dev/null >> "$tmp" || echo "-" >> "$tmp"
    done
  fi

  # 4) CI 侧会改变源码树的脚本
  #    ⚠ 刻意【不】算 configs/*.config：
  #      warm-cache 用 configs/<soc>.config，主流程用 configs/<机型>.config，
  #      两者内容必然不同。算进去的话两边 key 永远对不上，
  #      主流程就永远命中不了 warm-cache 生成的缓存。
  #      而机型选择只影响 target 侧包，不影响 host 工具链，本就不该进指纹。
  local ci="${GITHUB_WORKSPACE:-}"
  if [ -n "$ci" ] && [ -d "$ci" ]; then
    for f in diy-part1.sh diy-part2.sh; do
      [ -f "$ci/$f" ] && md5sum "$ci/$f" >> "$tmp"
    done
    find "$ci/.github/workflows" -maxdepth 1 -type f -name '*.yml' \
      -exec md5sum {} + 2>/dev/null | sort -k2 >> "$tmp"
  fi

  # 5) runner 架构
  printf 'arch=%s os=%s\n' "$(uname -m)" "${RUNNER_OS:-local}" >> "$tmp"

  local fp; fp=$(md5sum "$tmp" | cut -d' ' -f1)
  rm -f "$tmp"
  printf '%s' "$fp"
}

case "${1:-}" in

# ---------------------------------------------------------------
fingerprint)
  TARGET=$(grep '^CONFIG_TARGET_BOARD=' .config 2>/dev/null | cut -d'"' -f2)
  SUBTARGET=$(grep '^CONFIG_TARGET_SUBTARGET=' .config 2>/dev/null | cut -d'"' -f2)
  [ -n "$TARGET" ] || TARGET=unknown
  [ -n "$SUBTARGET" ] || SUBTARGET=unknown

  FP=$(fingerprint)
  # 整串过白名单：不管上游写出什么花样都不会变成 shell 语法
  FP=$(printf '%s' "$FP" | tr -c 'A-Za-z0-9._-' '_')
  TARGET=$(printf '%s' "$TARGET" | tr -c 'A-Za-z0-9._-' '_')
  SUBTARGET=$(printf '%s' "$SUBTARGET" | tr -c 'A-Za-z0-9._-' '_')

  out "TARGET=$TARGET"
  out "SUBTARGET=$SUBTARGET"
  out "FP=$FP"
  out "STAGING_KEY=ponwrt-staging-${TARGET}-${SUBTARGET}-${FP:0:16}"
  out "STAGING_PREFIX=ponwrt-staging-${TARGET}-${SUBTARGET}-"
  echo "========================================"
  echo "target   : $TARGET / $SUBTARGET"
  echo "指纹     : $FP"
  echo "staging  : ponwrt-staging-${TARGET}-${SUBTARGET}-${FP:0:16}"
  echo "========================================"
  ;;

# ---------------------------------------------------------------
pack)
  KEY="${STAGING_KEY:-}"
  [ -n "$KEY" ] || { echo "::error::缺 STAGING_KEY" >&2; exit 1; }

  LIST=$(mktemp)
  staging_parts >> "$LIST"
  # 源码树里的两个「已编译」标记，不收的话 make 会认为工具链没装
  for f in tools/stamp-compile toolchain/stamp-compile; do
    [ -e "$f" ] && echo "$f" >> "$LIST"
  done

  if [ ! -s "$LIST" ]; then
    echo "::warning::staging_dir 里没有可打包的内容"
    rm -f "$LIST"; exit 0
  fi

  echo "打包 $(wc -l < "$LIST") 个顶层条目："
  sed 's/^/  /' "$LIST"

  # ---------------------------------------------------------------
  # 完整性校验：缓存必须同时含 golang 与 rustc。
  #   静默少一个最难排查 —— 主流程会以为命中了，实际却在固件编译里现编一遍。
  #   注意是查磁盘而不是查 $LIST：$LIST 里是顶层目录，
  #   展开后才有 bin/rustc 这样的路径，grep 列表会漏报。
  # ---------------------------------------------------------------
  for want in go rustc; do
    if find staging_dir -path "*/bin/$want" -type f 2>/dev/null | grep -q .; then
      continue
    fi
    echo "::warning::staging_dir 里没有 $want —— 缓存不完整，下次该栈会重新编译"
  done

  # 体积预估：zstd 对这类内容约 3 倍压缩比
  RAW_MB=0
  if command -v du >/dev/null 2>&1; then
    RAW_MB=$(( $(du -sk $(cat "$LIST") 2>/dev/null | awk '{s+=$1} END{print s+0}') / 1024 ))
    EST=$(( RAW_MB / 3 ))
    echo "原始体积约 ${RAW_MB} MB → 预计压缩后 ${EST} MB（Release 上限 2048 MB）"
    [ "$EST" -gt 2048 ] && echo "::warning::预计 ${EST} MB 超过 Release 2GB 上限，上传会失败；仍会写 actions/cache"
  fi

  TARBALL="${STAGING_CACHE_DIR:-/workdir/staging-cache}/${KEY}.tzst"
  # ⚠ 目录必须自己建：tar 不会创建父目录，缺了就是「Cannot open」静默失败
  mkdir -p "$(dirname "$TARBALL")"
  rm -f "$TARBALL"
  if tar -I zstdmt -cf "$TARBALL" -T "$LIST" 2>/dev/null || tar -I zstd -cf "$TARBALL" -T "$LIST"; then
    ls -lh "$TARBALL"
    echo "packed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  else
    echo "::warning::打包失败，本次不写缓存"
    rm -f "$TARBALL"
    echo "packed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
  rm -f "$LIST"
  ;;

# ---------------------------------------------------------------
unpack)
  KEY="${STAGING_KEY:-}"
  [ -n "$KEY" ] || { echo "::error::缺 STAGING_KEY" >&2; exit 1; }
  TARBALL="${STAGING_CACHE_DIR:-/workdir/staging-cache}/${KEY}.tzst"
  if [ ! -f "$TARBALL" ]; then
    echo "unpacked=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::$TARBALL 不存在"
    exit 0
  fi

  tar -I unzstd -xf "$TARBALL" || tar -I zstd -xf "$TARBALL" || tar -xf "$TARBALL" || {
    echo "unpacked=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::解压失败，将走真实编译"
    exit 0
  }

  # -------------------------------------------------------------
  # ★ touch：OpenWrt 靠 mtime 做依赖判断。
  #   tar 还原的是旧 mtime，而源码树是刚 clone 的（mtime 是现在），
  #   不 touch 的话 make 认为「源码比产物新」从而全部重编 ——
  #   缓存等于白命中。这一步是整个方案生效的关键。
  # -------------------------------------------------------------
  find staging_dir -path '*/stamp/*' -type f -exec touch {} + 2>/dev/null || true
  find staging_dir/host/bin staging_dir/hostpkg/bin \
       staging_dir/target-*/host/bin staging_dir/toolchain*/bin \
       -type f -exec touch {} + 2>/dev/null || true
  touch tools/stamp-compile toolchain/stamp-compile 2>/dev/null || true
  # 目录本身也 touch，避免「目录比内容旧」触发不必要的重建
  find staging_dir -maxdepth 1 -type d -exec touch {} + 2>/dev/null || true

  echo "unpacked=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "✅ staging_dir 已从缓存恢复（stamp 已刷新）"
  ;;

# ---------------------------------------------------------------
status)
  {
    echo "=== staging_dir ==="
    for d in $(staging_parts); do
      printf '%-60s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
    echo ""
    echo "=== 版本 ==="
    for d in staging_dir/host staging_dir/hostpkg staging_dir/target-*/host; do
      [ -d "$d" ] || continue
      [ -x "$d/bin/go" ]    && echo "go      : $("$d/bin/go" version 2>&1 | head -1)"
      [ -e "$d/lib/go"/bin/go ] && echo "go(lib) : $("$d"/lib/go/bin/go version 2>&1 | head -1)"
      [ -x "$d/bin/rustc" ] && echo "rustc   : $("$d/bin/rustc" --version 2>&1 | head -1)"
      [ -x "$d/bin/gcc" ]   && echo "gcc     : $("$d/bin/gcc" --version 2>&1 | head -1)"
    done
    ls -d staging_dir/toolchain* 2>/dev/null | head -3
    echo ""
    echo "=== 标记 ==="
    for f in tools/stamp-compile toolchain/stamp-compile; do
      printf '%-28s %s\n' "$f" "$([ -e "$f" ] && echo 有 || echo 无)"
    done
  } | tee "${REPORT_DIR:-/tmp}/staging-cache.txt"
  ;;

*)
  echo "用法: $0 {fingerprint|pack|unpack|status} <openwrt_dir>" >&2
  exit 1
  ;;
esac
