#!/usr/bin/env python3
"""Tempo's installed entry is exactly the install.sh real-path exec wrapper.

Only that known two-line transport or a direct link to the bundle executable is
accepted. Product logic must remain inside the signed App; no shell is evaluated
to discover a target. The original Chapter helpers run bounded --help probes.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

sys.path.insert(0, str(Path.home() / 'Apps/chapter/engine/acceptors'))
from _common import env, finish
from cli_entry import host_apps, run_help, tilde


def installed_app():
    """The installed copy this entry must reach: Chapter's installed target when it names one
    (SOP_INSTALLED_APP with SOP_ACCEPTANCE_TARGET scope=installed), else /Applications/Tempo.app.
    A current-source candidate is never an install entry, so a candidate scope keeps the default."""
    try:
        scope = json.loads(os.environ.get('SOP_ACCEPTANCE_TARGET') or '{}').get('scope')
    except ValueError:
        scope = None
    chosen = os.environ.get('SOP_INSTALLED_APP') if scope == 'installed' else None
    return Path(chosen or '/Applications/Tempo.app')


def entry_target(link, target):
    if not link.is_file() or not os.access(link, os.X_OK):
        raise ValueError('tempo 入口缺失或不可执行')
    if link.is_symlink():
        if link.resolve() != target.resolve():
            raise ValueError('tempo 软链未指向 App 主程序')
        return 'symlink'
    expected = f'#!/bin/sh\nexec {target} "$@"\n'
    if link.read_bytes() != expected.encode():
        raise ValueError('tempo 不是安装器生成的两行 exec 入口')
    return 'exec-wrapper'


def main():
    ctx = env()
    detail = {}
    try:
        installed = installed_app()
        apps = host_apps('cyou.tianli.tempo')
        if len(apps) != 1 or apps[0].resolve() != installed.resolve():
            raise ValueError(f'须唯一安装 {installed}')
        app = apps[0]
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        target = app / 'Contents/MacOS/Tempo'
        if info.get('CFBundleExecutable') != 'Tempo' or not target.is_file() or not os.access(target, os.X_OK):
            raise ValueError('App 主程序声明或可执行文件无效')
        link = Path.home() / '.local/bin/tempo'
        detail.update(transport=entry_target(link, target), link=tilde(link), target=tilde(target))
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                       check=True, capture_output=True, timeout=30)
        for path in (link, target):
            code, output, timed_out = run_help(path)
            if timed_out:
                raise subprocess.TimeoutExpired([str(path), '--help'], 5)
            if code != 0:
                raise ValueError(f'{tilde(path)} --help 退出 {code}: {output[-300:]}')
        finish(ctx, True, 'tempo 两行入口直达已签名 App 主程序，两侧 --help 均退出 0', **detail)
    except subprocess.TimeoutExpired as exc:
        finish(ctx, False, f'命令行入口验收暂缓：{exc}', code=75, **detail)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        finish(ctx, False, f'命令行入口失败：{exc}', **detail)


if __name__ == '__main__':
    main()
