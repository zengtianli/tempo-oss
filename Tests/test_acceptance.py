"""Acceptance contracts: worktree output, installed provenance, and retryable environment failures."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def product(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location('tempo_basics_acceptance', ROOT / 'scripts/accept/product_basics.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    repo = tmp_path / 'worktree'
    app = tmp_path / 'installed/Tempo.app'
    binary = app / 'Contents/MacOS/Tempo'
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b'original installed executable')
    info = {'CFBundleIdentifier': 'cyou.tianli.tempo', 'CFBundleShortVersionString': '0.1.4', 'CFBundleVersion': '6'}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    resource = repo / 'Extension/Resources/shared.js'
    resource.parent.mkdir(parents=True)
    resource.write_text('original production rules')
    embedded = app / 'Contents/PlugIns/TempoExtension.appex/Contents/Resources/shared.js'
    embedded.parent.mkdir(parents=True)
    shutil.copyfile(resource, embedded)
    receipt = tmp_path / 'receipt.json'
    receipt.write_text(json.dumps({'artifact': {'bundle_id': 'cyou.tianli.tempo', 'version': '0.1.4', 'build': '6',
                                              'executable': 'Contents/MacOS/Tempo', 'sha256': module.sha(binary)},
                                   'source': {'sha256': 'original-source'}}))
    monkeypatch.setattr(module, 'ROOT', repo)
    monkeypatch.setattr(module, 'INSTALLED_APP', app)
    monkeypatch.setenv('SOP_CODE_BINDING_SHA256', 'a' * 64)
    monkeypatch.setenv('SOP_BUILD_CURRENT', '1')
    commands = []

    def run(argv, **kwargs):
        commands.append(argv)
        return subprocess.CompletedProcess(argv, 0, json.dumps({'ok': True, 'detail': 'original Chapter verifier'}), '')

    monkeypatch.setattr(module.subprocess, 'run', run)
    return module, app, receipt, commands


def test_current_binding_still_checks_signature_and_packaged_bytes(product):
    module, app, receipt, commands = product
    binding, _, _ = module.verify_product(app, receipt)
    assert binding['code_binding_sha256'] == 'a' * 64 and binding['candidate'] is False
    assert commands == [['codesign', '--verify', '--deep', '--strict', str(app)]]
    (app / 'Contents/PlugIns/TempoExtension.appex/Contents/Resources/shared.js').write_text('changed')
    with pytest.raises(ValueError, match='Packaged resource mismatch'):
        module.verify_product(app, receipt)


@pytest.mark.parametrize('change', ['version', 'binary', 'signature'])
def test_current_binding_cannot_hide_changed_installed_artifact(product, monkeypatch, change):
    module, app, receipt, _ = product
    if change == 'version':
        info = app / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleVersion'] = '2'
        info.write_bytes(plistlib.dumps(data))
    elif change == 'binary':
        (app / 'Contents/MacOS/Tempo').write_bytes(b'another distribution')
    else:
        def reject(*args, **kwargs):
            raise subprocess.CalledProcessError(1, args[0], stderr=b'invalid signature')
        monkeypatch.setattr(module.subprocess, 'run', reject)
    with pytest.raises((ValueError, subprocess.CalledProcessError)):
        module.verify_product(app, receipt)


@pytest.mark.parametrize('current,digest', [('0', 'a' * 64), ('1', None), (None, 'a' * 64), ('1', 'invalid')])
def test_incomplete_or_stale_chapter_binding_is_rejected(product, monkeypatch, current, digest):
    module, app, receipt, commands = product
    for key, value in [('SOP_BUILD_CURRENT', current), ('SOP_CODE_BINDING_SHA256', digest)]:
        if value is None:
            monkeypatch.delenv(key, raising=False)
        else:
            monkeypatch.setenv(key, value)
    with pytest.raises(ValueError, match='SOP_BUILD_CURRENT='):
        module.verify_product(app, receipt)
    assert not commands


def test_standalone_delegates_production_file_set_to_original_verifier(product, monkeypatch):
    module, app, receipt, commands = product
    monkeypatch.delenv('SOP_CODE_BINDING_SHA256')
    monkeypatch.delenv('SOP_BUILD_CURRENT')
    binding, _, _ = module.verify_product(app, receipt)
    assert binding['source_verification'] == 'original Chapter verifier'
    assert 'code_only=True' in commands[0][2]
    assert commands[0][-3:] == [str(module.ROOT), str(app), str(receipt)]


def test_standalone_does_not_override_original_production_mismatch(product, monkeypatch):
    module, app, receipt, _ = product
    monkeypatch.delenv('SOP_CODE_BINDING_SHA256')
    monkeypatch.delenv('SOP_BUILD_CURRENT')
    monkeypatch.setattr(module.subprocess, 'run', lambda argv, **kwargs:
                        subprocess.CompletedProcess(argv, 0, json.dumps({'ok': False, 'detail': 'production input added'}), ''))
    with pytest.raises(ValueError, match='production input added'):
        module.verify_product(app, receipt)


@pytest.mark.parametrize('changed', [False, True])
def test_ui_only_exit_includes_final_owner_preservation_check(product, monkeypatch, tmp_path, changed):
    module, app, receipt, _ = product
    monkeypatch.setenv('SOP_OUT_DIR', str(tmp_path / 'ui-output'))
    monkeypatch.setattr(sys, 'argv', ['product_basics.py', '--app', str(app), '--receipt', str(receipt), '--ui-only'])
    observations = iter([{'owner': 'original'}, {'owner': 'changed' if changed else 'original'}])
    monkeypatch.setattr(module, 'owner', lambda: next(observations))

    def run(argv, **kwargs):
        if '--ui-self-test' in argv:
            output = Path(kwargs['env']['SOP_OUT_DIR'])
            output.mkdir()
            output.joinpath('ui-self-test.json').write_text(json.dumps({'checks': {
                f + '.' + c: True for f in ('settings', 'shortcuts') for c in module.REQUIRED[f]}}))
        return subprocess.CompletedProcess(argv, 0, json.dumps({'ok': True, 'settings': {'speed': 1.75}}), '')

    monkeypatch.setattr(module.subprocess, 'run', run)
    assert module.main() == (1 if changed else 0)
    detail = json.loads((tmp_path / 'ui-output/native_ui.detail.json').read_text())
    assert detail['checks']['settings.production_bytes_unchanged'] is (not changed)


@pytest.mark.parametrize('ui_only', [False, True])
@pytest.mark.parametrize('timeout', [False, True])
def test_external_worktree_output_survives_failure_and_preserves_status(product, monkeypatch, tmp_path, ui_only, timeout):
    module, app, receipt, _ = product
    out = tmp_path / 'main-repo/perf/acceptance'
    monkeypatch.setenv('SOP_OUT_DIR', str(out))
    monkeypatch.setattr(sys, 'argv', ['product_basics.py', '--app', str(app), '--receipt', str(receipt)] + (['--ui-only'] if ui_only else []))
    monkeypatch.setattr(module, 'owner', lambda: {})

    def reject(*args):
        if timeout:
            raise subprocess.TimeoutExpired('offscreen-WebKit', 50)
        raise AssertionError()  # Formerly produced an empty error that hid the root failure.

    monkeypatch.setattr(module, 'verify_product', reject)
    assert module.main() == (75 if timeout else 1)
    detail = json.loads((out / ('native_ui.detail.json' if ui_only else 'product_basics.detail.json')).read_text())
    evidence = Path(detail['evidence'] if ui_only else detail['features']['settings']['evidence'])
    assert evidence.is_absolute() and evidence.is_file()
    raw = json.loads(evidence.read_text())
    assert raw['error'] and raw['deferred'] is timeout
    assert all(row['result'] != 'passed' for row in detail.get('features', {}).values())
    assert detail['deferred'] is timeout


def test_functionality_preserves_test_environment_exit_75(tmp_path):
    scripts = tmp_path / 'scripts/accept'
    scripts.mkdir(parents=True)
    shutil.copyfile(ROOT / 'scripts/accept/functionality.sh', scripts / 'functionality.sh')
    (scripts / 'product_basics.py').write_text('raise SystemExit(0)\n')
    tests = tmp_path / 'Tests'
    tests.mkdir()
    (tests / 'run.sh').write_text('echo "WebKit temporarily unavailable"\nexit 75\n')
    done = subprocess.run(['/bin/bash', str(scripts / 'functionality.sh')], capture_output=True, text=True, env=os.environ)
    assert done.returncode == 75 and 'DEFERRED' in done.stdout
