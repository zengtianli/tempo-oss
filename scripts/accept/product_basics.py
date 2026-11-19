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
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
INSTALLED_APP = Path('/Applications/Tempo.app')
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

def evidence_path(path):
    """Chapter may put evidence in the main repo while executing in a worktree."""
    path = path.resolve()
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)

def default_receipt(app):
    """Use Chapter's selected channel, then the original direct-install receipt.

    Never mint a receipt or silently fall back from an invalid selected receipt.
    Explicit --receipt remains authoritative for isolated candidates.
    """
    selected = os.environ.get('TEMPO_BASICS_RECEIPT') or os.environ.get('SOP_BUILD_RECEIPT')
    if selected:
        return Path(selected).expanduser()
    if app.resolve() == INSTALLED_APP:
        # The retired private iCloud channel (last 0.1.4 (7)) named its install receipt; only that install still uses it.
        release = ROOT / 'release/private.json'
        if release.is_file():
            data = json.loads(release.read_text())
            recorded = data.get('installed_receipt')
            plist = app / 'Contents/Info.plist'
            info = plistlib.loads(plist.read_bytes()) if plist.is_file() else {}
            same = (str(data.get('version')), str(data.get('build'))) == (str(info.get('CFBundleShortVersionString')), str(info.get('CFBundleVersion')))
            if recorded and same:
                path = (ROOT / recorded).resolve()
                if not path.is_relative_to(ROOT / 'build/accept') or path.suffix != '.json':
                    raise ValueError('Direct-install receipt must be a JSON file inside build/accept')
                return path
    return ROOT / 'perf/build-receipt.json'

def verify_product(app, receipt_path):
    receipt_path = receipt_path or default_receipt(app)
    receipt = json.loads(receipt_path.read_text())
    artifact = receipt['artifact']
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    binary = app / artifact['executable']
    observed = (info['CFBundleIdentifier'], info['CFBundleShortVersionString'], str(info['CFBundleVersion']))
    expected = (artifact['bundle_id'], artifact['version'], str(artifact['build']))
    if observed != expected or observed[0] != 'cyou.tianli.tempo':
        raise ValueError(f'Installed artifact/receipt mismatch: observed {observed}, expected {expected}; '
                         'Store/TestFlight and direct-download builds are distinct products for acceptance')
    if sha(binary) != artifact['sha256']:
        raise ValueError('Executable differs from build receipt')
    icon = artifact.get('icon')
    if not icon or sha(app / icon['path']) != icon['sha256']:
        raise ValueError('Icon differs from build receipt')
    candidate = app.resolve() != INSTALLED_APP
    code_binding = os.environ.get('SOP_CODE_BINDING_SHA256')
    build_current = os.environ.get('SOP_BUILD_CURRENT')
    if not candidate and (code_binding is not None or build_current is not None):
        if (build_current != '1' or code_binding is None or len(code_binding) != 64
                or any(c not in '0123456789abcdef' for c in code_binding)):
            raise ValueError('SOP_BUILD_CURRENT=' + str(build_current) + '; Chapter cannot bind the installed product to current production inputs')
        source_verification = 'Chapter acceptance_code_environment'
    else:
        # Standalone/candidate calls use the same read-only production-input verifier.
        # It checks added/deleted production files and build inputs too; do not duplicate its file filters.
        script = '''import json, sys
from pathlib import Path
import yaml
sys.path.insert(0, str(Path.home() / 'Apps/chapter/engine'))
import app_sop
root = Path(sys.argv[1])
app = yaml.safe_load((root / 'project.yaml').read_text())
app.update(id='tempo', repo=root)
ok, detail = app_sop.verify_build_receipt(app, Path(sys.argv[2]), Path(sys.argv[3]), code_only=True)
print(json.dumps({'ok': ok, 'detail': detail}))
'''
        done = subprocess.run([str(Path.home() / 'Dev/.venv/bin/python'), '-c', script,
                               str(ROOT), str(app), str(receipt_path)], capture_output=True, text=True, timeout=40)
        if done.returncode:
            raise RuntimeError('Chapter source verifier failed: ' + done.stderr[-1000:])
        verified = json.loads(done.stdout)
        if not verified['ok']:
            raise ValueError(verified['detail'])
        source_verification = verified['detail']
    resources = app / 'Contents/PlugIns/TempoExtension.appex/Contents/Resources'
    for source in (ROOT / 'Extension/Resources').glob('*'):
        if source.is_file() and (not (resources / source.name).is_file() or sha(resources / source.name) != sha(source)):
            raise ValueError('Packaged resource mismatch: ' + source.name)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True, timeout=30)
    binding = {'app': str(app), 'candidate': candidate, 'receipt': str(receipt_path),
               'receipt_sha256': sha(receipt_path), 'executable_sha256': sha(binary),
               'source_sha256': receipt['source']['sha256'], 'code_binding_sha256': code_binding,
               'source_verification': source_verification, 'version': artifact['version'], 'build': artifact['build']}
    return binding, artifact, info

def owner():
    paths = [Path('/Applications/Tempo.app/Contents/MacOS/Tempo'), Path.home() / 'Library/Preferences/cyou.tianli.tempo.plist']
    paths += list((Path.home() / 'Library/Containers/com.apple.Safari/Data/Library/WebKit/WebExtensions').glob('*/cyou.tianli.tempo.extension*/LocalStorage.db*'))
    return {str(p): sha(p) if p.is_file() else None for p in paths}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    # Chapter hands over the app under test (the current-source candidate, PRD-foundation R1);
    # standalone runs keep the installed product.
    parser.add_argument('--app', type=Path, default=Path(os.environ.get('SOP_INSTALLED_APP')
                                                         or os.environ.get('TEMPO_BASICS_APP', str(INSTALLED_APP))))
    parser.add_argument('--receipt', type=Path, help='Explicit candidate/channel receipt; otherwise use the recorded installed receipt')
    parser.add_argument('--ui-only', action='store_true')
    parser.add_argument('--binding-only', action='store_true', help='Verify installed bytes, signature and production inputs without launching any product')
    args = parser.parse_args()
    if args.binding_only:
        try:
            binding, _, _ = verify_product(args.app, args.receipt)
            print(json.dumps(binding, ensure_ascii=False))
            return 0
        except subprocess.TimeoutExpired as exc:
            print(f'Product binding deferred: {exc}', file=sys.stderr)
            return 75
        except Exception as exc:
            print(f'Product binding failed: {type(exc).__name__}: {exc}', file=sys.stderr)
            return 1
    spec = json.loads(os.environ.get('SOP_PRODUCT_BASICS_SPEC', '{"digest":"standalone"}'))
    out = Path(os.environ.get('SOP_OUT_DIR', ROOT / 'build/accept/product-basics')).resolve()
    run = out / ('product-basics-' + uuid.uuid4().hex)
    run.mkdir(parents=True)
    checks = {f + '.' + c: False for f in FEATURES for c in REQUIRED[f]}
    cases, binding, error, deferred = [], {}, None, False
    identity = 'test.tianli.tempo.basics.' + uuid.uuid4().hex
    before = owner()
    write(run / 'owner-before.json', before)
    env = dict(os.environ)
    try:
        binding, artifact, info = verify_product(args.app, args.receipt)
        shutil.copyfile(binding['receipt'], run / 'build-receipt.json')
        binding['immutable_receipt'] = evidence_path(run / 'build-receipt.json')
        app = run / 'fixture/Tempo.app'
        app.parent.mkdir()
        shutil.copytree(args.app, app, symlinks=True)
        info.update(CFBundleIdentifier=identity, LSUIElement=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True, timeout=30)
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
        if not args.ui_only:
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
            # The window app's first open (the offscreen self-test above) seeds a daily check for the HTTPS feed.
            call('default_update_options', ['update', 'options'],
                 lambda b: b['options']['automaticCheck'] and b['options']['intervalHours'] == 24)
            latest = run / 'feed/latest.json'
            write(latest, {'version': artifact['version'], 'build': str(int(artifact['build']) + 1), 'bundle_id': identity,
                           'download_url': 'Tempo-' + artifact['version'] + '.zip', 'sha256': 'a' * 64, 'size_bytes': 1})
            call('https_feed_record_parse', ['feed', str(latest)],
                 lambda b: b['feed'] == 'https://github.com/zengtianli/tempo-oss/releases/latest/download/release-manifest.json' and b['newer_than_this_app'] is True
                 and b['download_url'] == b['feed'].rsplit('/', 1)[0] + '/Tempo-' + artifact['version'] + '.zip')
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
    except subprocess.TimeoutExpired as exc:
        error, deferred = str(exc), True
    except Exception as exc:
        error = f'{type(exc).__name__}: {exc}'
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
               'deferred': deferred,
               'upstream': {evidence_path(p): sha(p) for p in (run / 'ui').glob('*') if p.is_file()}}
        raw_path = run / 'raw.json'
        write(raw_path, raw)
        features = {f: {'result': 'deferred' if deferred else 'passed' if error is None and all(v for k, v in checks.items() if k.startswith(f + '.')) else 'failed',
                        'method': 'ui_automation' if f == 'settings' else 'real_product', 'evidence': evidence_path(raw_path),
                        'evidence_sha256': sha(raw_path), 'checks': [k for k in checks if k.startswith(f + '.')]} for f in FEATURES}
        detail = {'schema_version': 1, 'app_id': 'tempo', 'spec_digest': spec['digest'], 'features': features,
                  'summary': ('Tempo 原生离屏交互' if args.ui_only else 'Tempo 基础功能') + ('暂缓' if deferred else '通过' if error is None and all(checks.values()) else '失败') + '；' + (error or '绑定当前产品原件'),
                  'scope': scope, 'error': error, 'deferred': deferred}
        if args.ui_only:
            detail.pop('features')
            detail.update(checks=checks, evidence=evidence_path(raw_path), evidence_sha256=sha(raw_path))
        write(out / ('native_ui.detail.json' if args.ui_only else 'product_basics.detail.json'), detail)
        print(json.dumps(detail, ensure_ascii=False))
    return 75 if deferred else 0 if all(checks.values()) and error is None else 1

if __name__ == '__main__':
    raise SystemExit(main())
