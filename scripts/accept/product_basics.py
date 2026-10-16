#!/usr/bin/env python3
"""Real Tempo executable + offscreen native settings + isolated Safari SQLite/lifecycle transports."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
FEATURES = ('settings', 'shortcuts', 'icloud', 'updates')
REQUIRED = {
    'settings': ('interaction', 'persisted_readback', 'error_preserves_data'),
    'shortcuts': ('action_path', 'disable_restore', 'conflict_or_reserved_keys'),
    'icloud': ('push_pull', 'unavailable_local_fallback', 'conflict_or_corrupt_recovery', 'disable_preserves_data'),
    'updates': ('check_result', 'failure_recovery', 'options_or_store_entry', 'data_preservation'),
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def owner():
    paths = [Path('/Applications/Tempo.app/Contents/MacOS/Tempo'), Path.home() / 'Library/Preferences/cyou.tianli.tempo.plist']
    paths += list((Path.home() / 'Library/Containers/com.apple.Safari/Data/Library/WebKit/WebExtensions').glob('*/cyou.tianli.tempo.extension*/LocalStorage.db*'))
    return {str(p): sha(p) if p.is_file() else None for p in paths}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path(os.environ.get('TEMPO_BASICS_APP', '/Applications/Tempo.app')))
    parser.add_argument('--receipt', type=Path, default=Path(os.environ.get('TEMPO_BASICS_RECEIPT', ROOT / 'perf/build-receipt.json')))
    parser.add_argument('--ui-only', action='store_true')
    args = parser.parse_args()
    spec = json.loads(os.environ.get('SOP_PRODUCT_BASICS_SPEC', '{"digest":"standalone"}'))
    out = Path(os.environ.get('SOP_OUT_DIR', ROOT / 'build/accept/product-basics')).resolve()
    run = out / ('product-basics-' + uuid.uuid4().hex)
    run.mkdir(parents=True)
    checks = {f + '.' + c: False for f in FEATURES for c in REQUIRED[f]}
    cases, binding, error = [], {}, None
    identity = 'test.tianli.tempo.basics.' + uuid.uuid4().hex
    before = owner()
    write(run / 'owner-before.json', before)
    env = dict(os.environ)
    try:
        receipt = json.loads(args.receipt.read_text())
        artifact = receipt['artifact']
        info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        binary = args.app / artifact['executable']
        assert info['CFBundleIdentifier'] == artifact['bundle_id'] == 'cyou.tianli.tempo'
        assert info['CFBundleShortVersionString'] == artifact['version'] and str(info['CFBundleVersion']) == str(artifact['build'])
        assert sha(binary) == artifact['sha256'], 'Executable differs from build receipt'
        assert all((ROOT / p).is_file() and sha(ROOT / p) == h for p, h in receipt['source']['files'].items()), 'Source differs from build receipt'
        resources = args.app / 'Contents/PlugIns/TempoExtension.appex/Contents/Resources'
        for source in (ROOT / 'Extension/Resources').glob('*'):
            if source.is_file():
                assert (resources / source.name).is_file() and sha(resources / source.name) == sha(source), 'Packaged resource mismatch: ' + source.name
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True, capture_output=True)
        binding = {'app': str(args.app), 'candidate': args.app.resolve() != Path('/Applications/Tempo.app'),
                   'receipt': str(args.receipt), 'receipt_sha256': sha(args.receipt), 'executable_sha256': sha(binary),
                   'source_sha256': receipt['source']['sha256'], 'version': artifact['version'], 'build': artifact['build']}
        shutil.copyfile(args.receipt, run / 'build-receipt.json')
        binding['immutable_receipt'] = str((run / 'build-receipt.json').relative_to(ROOT))
        app = run / 'fixture/Tempo.app'
        app.parent.mkdir()
        shutil.copytree(args.app, app, symlinks=True)
        info.update(CFBundleIdentifier=identity, LSUIElement=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
        binding['fixture_executable_sha256'] = sha(app / artifact['executable'])
        store = run / 'safari/LocalStorage.db'
        store.parent.mkdir()
        with sqlite3.connect(store) as db:
            db.execute('CREATE TABLE extension_storage (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)')
            db.execute('PRAGMA user_version=2')
            db.execute('INSERT INTO extension_storage VALUES (?,?)', ('remote', 'false'))
        env.update(TEMPO_REEXEC='1', TEMPO_STORE=str(store), TEMPO_REMOTE_DIR=str(run / 'remote'), TEMPO_REMOTE_TAG=identity,
                   TEMPO_BASICS_SUITE=identity, APP_LIFECYCLE_SUPPORT_DIR=str(run / 'support'),
                   APP_LIFECYCLE_CLOUD_DIR=str(run / 'cloud'), APP_LIFECYCLE_NO_RELAUNCH='1', SOP_OUT_DIR=str(run / 'ui'))
        cli = app / artifact['executable']

        def call(label, words, predicate=lambda b: b.get('ok') is True, code=0, override=None):
            done = subprocess.run([str(cli), *words, '--json'], env=override or env, capture_output=True, text=True, timeout=40)
            body = json.loads(done.stdout)
            passed = done.returncode == code and bool(predicate(body))
            cases.append({'case': label, 'argv': words, 'exit': done.returncode, 'response': body, 'passed': passed, 'stderr': done.stderr})
            assert passed, f'{label}: exit={done.returncode}, body={body}'
            return body

        # The self-test calls real NSButton targets and the shared settings window construction without ordering it in.
        ui_done = subprocess.run([str(cli), '--ui-self-test'], env=env, capture_output=True, text=True, timeout=50)
        (run / 'ui.log').write_text(ui_done.stdout + ui_done.stderr)
        ui = json.loads((run / 'ui/ui-self-test.json').read_text())['checks']
        checks.update({k: ui.get(k) is True for k in ('settings.interaction', 'settings.error_preserves_data',
                        'shortcuts.action_path', 'shortcuts.disable_restore', 'shortcuts.conflict_or_reserved_keys')})
        checks['settings.offscreen_native_window'] = ui_done.returncode == 0 and all(ui.values())
        assert ui_done.returncode == 0, 'Offscreen self-test failed; see ui.log'
        call('fresh_process_readback', ['show'], lambda b: b['settings']['speed'] == 1.75)
        checks['settings.persisted_readback'] = True
        if args.ui_only:
            return 0

        call('icloud_enable_and_push', ['config', 'sync', 'on', '--yes'])
        cloud = run / 'cloud/cyou.tianli.tempo.json'
        remote = json.loads(cloud.read_text())
        assert remote['values']['file.0.speed'] == 1.75
        remote['values']['file.0.speed'] = 2.25
        write(cloud, remote)

        def sync(label, code=0, override=None):
            call(label + '.off', ['config', 'sync', 'off', '--yes'])
            return call(label, ['config', 'sync', 'on', '--yes'], lambda b: b.get('ok') is (code == 0), code, override)

        sync('icloud_pull')
        call('cloud_change_reaches_safari', ['show'], lambda b: b['settings']['speed'] == 2.25 and b['settings']['remote'] is False)
        checks['icloud.push_pull'] = True
        local = store.read_bytes()
        good_cloud = cloud.read_bytes()
        cloud.write_text('{broken')
        sync('corrupt_cloud_refused', code=1)
        assert store.read_bytes() == local, 'Corrupt cloud changed Safari store'
        cloud.write_bytes(good_cloud)
        sync('recover_after_corrupt_cloud')
        call('recovered_readback', ['show'], lambda b: b['settings']['speed'] == 2.25)
        checks['icloud.conflict_or_corrupt_recovery'] = True
        unavailable = run / 'unavailable-cloud'
        unavailable.write_text('not a directory')
        sync('unavailable_cloud', code=1, override=dict(env, APP_LIFECYCLE_CLOUD_DIR=str(unavailable)))
        call('offline_local_usable', ['show'], lambda b: b['settings']['speed'] == 2.25)
        assert store.read_bytes() == local
        checks['icloud.unavailable_local_fallback'] = True
        call('disable_sync', ['config', 'sync', 'off', '--yes'])
        assert store.read_bytes() == local and cloud.read_bytes() == good_cloud
        checks['icloud.disable_preserves_data'] = True
        # Real update checker: missing -> corrupt -> valid local release, no installer action.
        feed = run / ('cloud/TianliApps/Updates/' + identity + '/isolated/release.json')
        feed.parent.mkdir(parents=True)
        call('missing_feed', ['update', 'check'], lambda b: b.get('ok') is False, code=1)
        feed.write_text('{broken')
        call('corrupt_feed', ['update', 'check'], lambda b: b.get('ok') is False, code=1)
        asset = feed.parent / 'fixture.zip'
        asset.write_bytes(b'check-only; never downloaded or installed')
        write(feed, {'version': artifact['version'], 'build': str(int(artifact['build']) + 1), 'bundle_id': identity,
                     'channel': 'isolated', 'filename': asset.name, 'sha256': sha(asset), 'size_bytes': asset.stat().st_size})
        call('valid_release', ['update', 'check'], lambda b: b['state'] == 'update_available' and b['latest']['build'] == str(int(artifact['build']) + 1))
        checks['updates.check_result'] = ui['updates.actual_check_action'] is True
        checks['updates.failure_recovery'] = True
        call('default_update_options', ['update', 'options'], lambda b: not b['options']['automaticCheck'])
        call('save_update_options', ['update', 'options', '--interval', '6', '--auto-check', 'on', '--yes'])
        call('fresh_update_options', ['update', 'options'], lambda b: b['options']['intervalHours'] == 6 and b['options']['automaticCheck'])
        call('invalid_interval', ['update', 'options', '--interval', '0', '--yes'], lambda b: b.get('ok') is False, code=2)
        checks['updates.options_or_store_entry'] = True
        call('public_release_actual_check', ['--update-source-self-test'],
             lambda b: b.get('bundle_id') == 'cyou.tianli.tempo' and bool(b.get('version')) and bool(b.get('build'))
             and b.get('download_url', '').startswith('https://github.com/zengtianli/tempo-oss/releases/') and len(b.get('sha256', '')) == 64)
        assert store.read_bytes() == local
        assert not list((run / 'support').rglob('update-downloads/*'))
        checks['updates.data_preservation'] = True
    except Exception as exc:
        error = str(exc)
    finally:
        subprocess.run(['defaults', 'delete', identity], capture_output=True)
        after = owner()
        write(run / 'owner-after.json', after)
        checks['updates.production_bytes_unchanged'] = before == after
        if args.ui_only:
            checks = {k: v for k, v in checks.items() if k.startswith(('settings.', 'shortcuts.'))}
            checks['settings.production_bytes_unchanged'] = before == after
        scope = ('Current source candidate' if binding.get('candidate') else 'Installed product') + '; re-identified copy, real offscreen AppKit controls, Safari-shaped isolated SQLite, shared iCloud directory transport and release checker; Apple cross-device transport not tested; no installation, actual keyboard dispatch, account changes, or release publication.'
        raw = {'schema_version': 1, 'app_id': 'tempo', 'spec_digest': spec['digest'], 'checked_at': time.time(),
               'checks': checks, 'binding': binding, 'cases': cases, 'scope': scope, 'error': error,
               'upstream': {str(p.relative_to(ROOT)): sha(p) for p in (run / 'ui').glob('*') if p.is_file()}}
        raw_path = run / 'raw.json'
        write(raw_path, raw)
        features = {f: {'result': 'passed' if all(v for k, v in checks.items() if k.startswith(f + '.')) else 'failed',
                        'method': 'ui_automation' if f == 'settings' else 'real_product', 'evidence': str(raw_path.relative_to(ROOT)),
                        'evidence_sha256': sha(raw_path), 'checks': [k for k in checks if k.startswith(f + '.')]} for f in FEATURES}
        detail = {'schema_version': 1, 'app_id': 'tempo', 'spec_digest': spec['digest'], 'features': features,
                  'summary': ('Tempo 原生离屏交互' if args.ui_only else 'Tempo 基础功能') + ('通过' if all(checks.values()) else '失败') + '；绑定当前产品原件',
                  'scope': scope, 'error': error}
        if args.ui_only:
            detail.pop('features')
            detail.update(checks=checks, evidence=str(raw_path.relative_to(ROOT)), evidence_sha256=sha(raw_path))
        write(out / ('native_ui.detail.json' if args.ui_only else 'product_basics.detail.json'), detail)
        print(json.dumps(detail, ensure_ascii=False))
    return 0 if all(checks.values()) and error is None else 1

if __name__ == '__main__':
    raise SystemExit(main())
