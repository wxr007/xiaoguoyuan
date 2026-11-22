#!/usr/bin/env python3
"""把 NAS 上的「剧名 - S01E01.mp4」批量改成「S01E01.mp4」。

用法：
  python scripts/rename_episodes.py "D:/XiaoGuoYuan"           # 只预览，不改动
  python scripts/rename_episodes.py "D:/XiaoGuoYuan" --apply   # 实际执行

安全策略：
  - 只匹配「前缀 - SxxEyy.扩展名」这种文件名，其他文件一律不动
  - 目标文件已存在时跳过，绝不覆盖
  - 默认只预览，必须显式加 --apply 才改名
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

VIDEO_EXT = "mp4|mkv|m4v|ts|webm|mov"
EPISODE_PATTERN = re.compile(
    rf"^(?P<prefix>.+?)\s*-\s*(?P<episode>S\d{{2}}E\d{{2}})\.(?P<ext>{VIDEO_EXT})$",
    re.IGNORECASE,
)


def collect(root: Path) -> tuple[list[tuple[Path, Path]], list[tuple[Path, str]]]:
    plans: list[tuple[Path, Path]] = []
    conflicts: list[tuple[Path, str]] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        match = EPISODE_PATTERN.match(path.name)
        if not match:
            continue
        episode = match.group("episode").upper()
        ext = match.group("ext").lower()
        target = path.with_name(f"{episode}.{ext}")
        if target.exists():
            conflicts.append((path, f"目标已存在：{target.name}"))
            continue
        if path.name == target.name:
            continue
        plans.append((path, target))
    return plans, conflicts


def main() -> int:
    parser = argparse.ArgumentParser(description="批量去掉 NAS 分集文件名中的剧名前缀")
    parser.add_argument("root", nargs="?", default=".", help="要处理的根目录，默认当前目录")
    parser.add_argument("--apply", action="store_true", help="实际执行改名（默认只预览）")
    args = parser.parse_args()

    root = Path(args.root).expanduser()
    if not root.is_dir():
        print(f"目录不存在：{root}")
        return 1

    plans, conflicts = collect(root)
    if not plans and not conflicts:
        print("没有找到需要改名的文件。")
        return 0

    print(f"目录：{root}")
    print(f"待改名：{len(plans)} 个文件")
    for source, target in plans:
        print(f"  {source.relative_to(root)}  ->  {target.name}")

    if conflicts:
        print(f"\n跳过 {len(conflicts)} 个（目标已存在）：")
        for source, reason in conflicts:
            print(f"  {source.relative_to(root)}：{reason}")

    if not args.apply:
        print("\n这是预览。确认无误后加 --apply 执行：")
        print(f'  python "{Path(__file__).name}" "{root}" --apply')
        return 0

    renamed = 0
    failed = 0
    for source, target in plans:
        try:
            source.rename(target)
            renamed += 1
        except OSError as error:
            failed += 1
            print(f"  失败：{source} -> {target}（{error}）")

    print(f"\n完成：成功 {renamed} 个，失败 {failed} 个，跳过 {len(conflicts)} 个。")
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
