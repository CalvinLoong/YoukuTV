#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 GitHub Git Data API 推送一次提交（绕过 git 协议层，规避 HTTP2 framing 错误）。

流程：
  1. 取远端 main 的 tree
  2. 用本地工作区内容构造新 blob
  3. 建新 tree（base_tree = 远端 tree）
  4. 建 commit（parent = 远端 commit）
  5. 更新 ref

用法：python3 tools/推送GitHub.py <提交信息>
"""
import base64
import json
import os
import subprocess
import sys
import urllib.request

REPO = "CalvinLoong/YoukuTV"
BRANCH = "main"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GH = os.path.join(ROOT, "tools", "gh", "gh_2.62.0_macOS_arm64", "bin", "gh")


def api(method, path, data=None, raw=False):
    """调用 gh api，返回解析后的 JSON。"""
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
    if raw:
        return out
    return json.loads(out.decode("utf-8")) if out.strip() else None


def git(*args):
    return subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True
    ).stdout.strip()


def remote_tree_files(tree_sha):
    """列出远端 tree 里的所有文件（递归），返回 {path: blob_sha}。"""
    files = {}
    stack = [(tree_sha, "")]
    while stack:
        sha, prefix = stack.pop()
        tree = api("GET", f"repos/{REPO}/git/trees/{sha}?recursive=1")
        for entry in tree.get("tree", []):
            path = f"{prefix}{entry['path']}"
            if entry["type"] == "blob":
                files[path] = entry["sha"]
            elif entry["type"] == "tree":
                stack.append((entry["sha"], path + "/"))
    return files


def collect_changes(base_tree_sha):
    """比对远端 tree 与本地工作区，返回需要推送的变更。

    比对基准是**远端实际内容**，而不是本地 git 历史 ——
    因为本地可能缺少远端某些提交的对象（用 API 推送过的场景）。
    """
    remote = remote_tree_files(base_tree_sha)

    # 本地应纳入版本控制的文件：git ls-files（已跟踪） + 未跟踪的新文件
    local = {}
    tracked = git("ls-files").splitlines()
    untracked = git("ls-files", "--others", "--exclude-standard").splitlines()
    for path in tracked + untracked:
        if not path:
            continue
        full = os.path.join(ROOT, path)
        if os.path.isfile(full):
            with open(full, "rb") as f:
                local[path] = f.read()

    changes = {}

    # 1) 本地有内容且与远端不同的 → 需要新增/更新
    for path, content in local.items():
        if path.startswith("输出/") or path.startswith("apk/") or path.startswith("h5js/"):
            continue
        remote_sha = remote.get(path)
        if remote_sha is None:
            changes[path] = content          # 新增
            continue
        # 比对内容：用 blob API 取回远端内容做字节比较
        blob = api("GET", f"repos/{REPO}/git/blobs/{remote_sha}")
        remote_content = base64.b64decode(blob["content"]) if blob.get("encoding") == "base64" else b""
        if remote_content != content:
            changes[path] = content          # 修改

    # 2) 远端有、本地已删除的 → 删除
    for path in remote:
        if path not in local:
            changes[path] = None

    return changes


def main():
    message = sys.argv[1] if len(sys.argv) > 1 else "Update from WorkBuddy"

    print("→ 读取远端状态")
    base_commit = api("GET", f"repos/{REPO}/commits/{BRANCH}")
    base_sha = base_commit["sha"]
    base_tree = base_commit["commit"]["tree"]["sha"]
    print(f"  远端 HEAD = {base_sha[:12]}")

    changes = collect_changes(base_tree)
    print(f"→ 待推送文件 {len(changes)} 个")

    # 1) 建 blob
    tree_entries = []
    for path, content in changes.items():
        if content is None:
            # 删除：mode 设为 None 表示删除该路径
            tree_entries.append({
                "path": path,
                "mode": "100644",
                "type": "blob",
                "sha": None,
            })
            continue
        b64 = base64.b64encode(content).decode()
        blob = api(
            "POST",
            f"repos/{REPO}/git/blobs",
            {"content": b64, "encoding": "base64"},
        )
        tree_entries.append({
            "path": path,
            "mode": "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        print(f"  blob {path}")

    # 2) 建 tree
    new_tree = api(
        "POST",
        f"repos/{REPO}/git/trees",
        {"base_tree": base_tree, "tree": tree_entries},
    )
    print(f"→ 新 tree = {new_tree['sha'][:12]}")

    # 3) 建 commit
    new_commit = api(
        "POST",
        f"repos/{REPO}/git/commits",
        {
            "message": message,
            "tree": new_tree["sha"],
            "parents": [base_sha],
        },
    )
    print(f"→ 新 commit = {new_commit['sha'][:12]}")

    # 4) 更新 ref
    api(
        "PATCH",
        f"repos/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": new_commit["sha"], "force": False},
    )
    print(f"✓ 推送完成: {new_commit['sha'][:12]}")

    # 让本地 git 与远端对齐，便于后续 git 操作
    subprocess.run(
        ["git", "update-ref", f"refs/heads/{BRANCH}", new_commit["sha"]],
        cwd=ROOT,
        capture_output=True,
    )


if __name__ == "__main__":
    main()
