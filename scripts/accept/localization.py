#!/usr/bin/env python3
"""Render the shipped bilingual UI without visible windows, Safari, or the user's settings."""
import argparse
import base64
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'perf/acceptance/l10n'
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import sim_lane


def source_digest():
    paths = sorted([*ROOT.glob('App/*.swift'), *ROOT.glob('App/*.xcstrings'),
                    *ROOT.glob('Extension/*.xcstrings'), *ROOT.glob('Extension/Resources/**/*'),
                    ROOT / 'project.yml', ROOT / 'Tests/snapshot.swift', ROOT / 'Tests/shim.js',
                    ROOT / 'Tests/localization.js'])
    digest = hashlib.sha256()
    for path in paths:
        if path.is_file() and 'images' not in path.parts:
            digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes())
    return digest.hexdigest()


def run(argv, **kwargs):
    subprocess.run([str(a) for a in argv], cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=ROOT / 'build/Tempo.app')
    args = parser.parse_args()
    app = args.app.resolve()
    binary = app / 'Contents/MacOS/Tempo'
    resources = app / 'Contents/PlugIns/TempoExtension.appex/Contents/Resources'
    OUT.mkdir(parents=True, exist_ok=True)
    tool = ROOT / 'build/tests/snapshot'
    try:
        with sim_lane.BuildSlot('Tempo bilingual offscreen snapshot compiler', wait=0):
            tool.parent.mkdir(parents=True, exist_ok=True)
            run(['swiftc', '-O', '-o', tool, ROOT / 'Tests/snapshot.swift'])
        with tempfile.TemporaryDirectory(prefix='tempo-l10n-') as work:
            work = Path(work)
            store = work / 'LocalStorage.db'
            with sqlite3.connect(store) as db:
                db.execute('PRAGMA user_version=2')
                db.execute('CREATE TABLE extension_storage (key TEXT PRIMARY KEY, value TEXT)')
                db.execute('INSERT INTO extension_storage VALUES (?, ?)', ('speed', '1.75'))
            for language in ('en', 'zh-Hans'):
                output = OUT / language
                output.mkdir(exist_ok=True)
                env = dict(os.environ, TEMPO_L10N_OUT=str(output), TEMPO_L10N_LANGUAGE=language, TEMPO_STORE=str(store),
                           TEMPO_RESOURCES=str(resources), TEMPO_BASICS_SUITE='test.tempo.l10n.' + language,
                           APP_LIFECYCLE_SUPPORT_DIR=str(work / language), TEMPO_REEXEC='1')
                run([binary, '--l10n-self-test', '-AppleLanguages', f'({language})'], env=env)
                for name, flags in [('popup', []), ('popup-settings', ['--open-settings']),
                                    ('popup-settings-dark', ['--open-settings', '--dark'])]:
                    run([tool, resources, ROOT / 'Tests', output / (name + '.png'), '--language', language,
                         '--verify-localization', *flags])
        # Flat copies for the cross-product l10n review: en-<screen>.png and zh-<screen>.png.
        for old in OUT.glob('*-*.png'):
            if old.parent == OUT and old.name.split('-', 1)[0] in ('en', 'zh'):
                old.unlink()
        for language, prefix in (('en', 'en'), ('zh-Hans', 'zh')):
            for png in sorted((OUT / language).glob('*.png')):
                shutil.copyfile(png, OUT / f'{prefix}-{png.name}')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        receipt = {'source_sha256': source_digest(), 'app': str(app),
                   'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                   'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                   'screenshots': sorted(str(p.relative_to(ROOT)) for p in OUT.glob('*/*.png')),
                   'languages': ['en', 'zh-Hans'], 'shared_layer_included': ['AppLifecycleUI', 'AppShortcuts', 'AppConfiguration status']}
        (OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        cards = []
        for p in sorted(OUT.glob('*/*.png')):
            data = base64.b64encode(p.read_bytes()).decode()
            cards.append(f'<figure><figcaption>{html.escape(p.parent.name + " / " + p.stem)}</figcaption><img src="data:image/png;base64,{data}" alt="{html.escape(p.stem)}"></figure>')
        page = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Tempo · 双语界面验收</title><style>body{margin:0;padding:28px;font:16px system-ui;background:#f7f8fa;color:#202632}h1{font-size:28px}p{max-width:1000px;line-height:1.6}.grid{display:flex;flex-wrap:wrap;gap:24px;align-items:flex-start}figure{margin:0;padding:18px;background:white;border:1px solid #dce1e8;border-radius:12px;max-width:100%;box-sizing:border-box}figcaption{margin-bottom:12px;font-weight:600}img{display:block;max-width:100%;width:auto;max-height:1100px;object-fit:contain;object-position:top left}</style><h1>Tempo · 英文与简体中文界面</h1><p>真实 SwiftUI/AppKit 与 WebKit 离屏渲染，未显示窗口、未进入 Dock。截图包含启用、未启用、读取中、恢复提示、未公证快装提示，产品设置及其错误提示，共享“设置…”窗口（浅色/深色），以及 Safari 面板和深色面板。图片保留原始分辨率，可另存放大核对。共享层已双语，英文截图同样核对无中文残留。</p><div class="grid">' + ''.join(cards) + '</div></html>'
        (OUT / 'index.html').write_text(page)
        print(json.dumps(receipt, ensure_ascii=False))
        return 0
    except sim_lane.Busy as error:
        print(str(error), file=sys.stderr)
        return 75
    except subprocess.CalledProcessError as error:
        return error.returncode


if __name__ == '__main__':
    raise SystemExit(main())
