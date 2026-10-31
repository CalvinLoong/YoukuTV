#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按文件列表定向推送（GitHub Git Data API）。

为什么不用 tools/推送GitHub.py 的全量比对版：
    全量版要对远端每个 blob 逐个 GET 取回内容做字节比对，
    本机到 GitHub 的链路慢，几十个文件就会超时。
    定向版只处理明确给出的文件，秒级完成。

用法：
    python3 tools/定向推送.py "<提交信息>" <文件1> [文件2 ...]

注意：
    · 文件路径相对仓库根目录
    · 只推送「修改/新增」，不做删除
    · 提交后本地 git 会 update-ref 对齐远端 HEAD
"""
import base64
import json
import os
import subprocess
import sys

REPO = "CalvinLoong/YoukuTV"
BRANCH = "main"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GH = os.path.join(ROOT, "tools", "gh", "gh_2.62.0_macOS_arm64", "bin", "gh")


def api(method, path, data=None):
    cmd = [GH, "api", "-X", method, path]
    if data is not None:
        cmd += ["--input", "-"]
    proc = subprocess.run(
        cmd,
        input=(json.dumps(data).encode() if data is not None else None),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"gh api {method} {path} 失败:\n{proc.stderr.decode('utf-8', 'replace')}"
        )
    out = proc.stdout
    return json.loads(out.decode("utf-8")) if out.strip() else None


def main():
    if len(sys.argv) < 3:
        print('用法: python3 tools/定向推送.py "<提交信息>" <文件1> [文件2 ...]', file=sys.stderr)
        return 1

    message = sys.argv[1]
    paths = sys.argv[2:]

    print("→ 读取远端状态")
    base_commit = api("GET", f"repos/{REPO}/commits/{BRANCH}")
    base_sha = base_commit["sha"]
    base_tree = base_commit["commit"]["tree"]["sha"]
    print(f"  远端 HEAD = {base_sha[:12]}")

    entries = []
    for path in paths:
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            print(f"::error::本地文件不存在：{path}", file=sys.stderr)
            return 1
        with open(full, "rb") as f:
            content = f.read()
        b64 = base64.b64encode(content).decode()
        blob = api("POST", f"repos/{REPO}/git/blobs", {"content": b64, "encoding": "base64"})
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print(f"  blob {path}  ({len(content)} bytes)")

    new_tree = api("POST", f"repos/{REPO}/git/trees", {"base_tree": base_tree, "tree": entries})
    print(f"→ 新 tree = {new_tree['sha'][:12]}")

    new_commit = api(
        "POST",
        f"repos/{REPO}/git/commits",
        {"message": message, "tree": new_tree["sha"], "parents": [base_sha]},
    )
    print(f"→ 新 commit = {new_commit['sha'][:12]}")

    api("PATCH", f"repos/{REPO}/git/refs/heads/{BRANCH}", {"sha": new_commit["sha"], "force": False})
    print(f"✓ 推送完成: {new_commit['sha'][:12]}")

    subprocess.run(
        ["git", "update-ref", f"refs/heads/{BRANCH}", new_commit["sha"]],
        cwd=ROOT,
        capture_output=True,
    )


if __name__ == "__main__":
    sys.exit(main() or 0)
