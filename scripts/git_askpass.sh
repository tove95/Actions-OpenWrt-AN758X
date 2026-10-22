#!/usr/bin/env bash
#
# git-askpass —— 把 GitHub App 安装令牌喂给 git 的凭证助手
#
# 用法（build-ponwrt.yml 里已配好）：
#   install -m 700 scripts/git_askpass.sh "$RUNNER_TEMP/git-askpass"
#   echo "GIT_ASKPASS=$RUNNER_TEMP/git-askpass" >> "$GITHUB_ENV"
#   echo "GIT_TERMINAL_PROMPT=0"                >> "$GITHUB_ENV"
#
# 令牌来源（二选一，优先文件）：
#   GH_TOKEN_FILE  600 权限的令牌文件路径（推荐：令牌不进任何进程的 env）
#   GH_REPO_TOKEN  直接放令牌（create-github-app-token 的输出会被自动 add-mask）
#
# 为什么用 askpass 而不是 url.*.insteadOf：
#   insteadOf 会把 user:token@ 写进 ~/.gitconfig 落盘，且和 checkout 注入的
#   http.https://github.com/.extraheader 抢优先级（后者写本地 .git/config，
#   本地优先级更高，会直接盖掉令牌导致 404）。askpass 只在 git 真正被要求
#   认证时才调用，不写任何配置、不改 clone URL，diy-part1.sh 可以保持裸 URL。
#
# 只有「需要认证」的远端才会触发本脚本；公开仓库 clone 不会调用它。

set -euo pipefail

token_file="${GH_TOKEN_FILE:-}"
token="${GH_REPO_TOKEN:-}"

case "$1" in
    *Username*)
        # GitHub 用令牌认证时用户名固定为 x-access-token（App 安装令牌同 PAT）
        printf '%s\n' 'x-access-token'
        ;;

    *Password*)
        # -s 而不是 -r：空文件会让 git 拿着空密码去认证，报错比没令牌还难懂
        if [ -n "$token_file" ] && [ -s "$token_file" ] && [ -r "$token_file" ]; then
            printf '%s\n' "$(cat "$token_file")"
        elif [ -n "$token" ]; then
            printf '%s\n' "$token"
        else
            echo "git-askpass: 没有可用令牌（GH_TOKEN_FILE 与 GH_REPO_TOKEN 均为空）" >&2
            exit 1
        fi
        ;;

    *)
        # 认不出的提示一律拒绝，避免把令牌交给非预期的远端
        exit 1
        ;;
esac
