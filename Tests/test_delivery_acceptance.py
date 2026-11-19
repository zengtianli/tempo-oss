"""Delivery contract regressions; never launch the owner's App or Safari."""
import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cli = load('tempo_cli_acceptance', 'scripts/accept/cli_entry.py')
basics = load('tempo_basics_acceptance', 'scripts/accept/product_basics.py')
WRAPPER = '#!/bin/sh\nexec /Applications/Tempo.app/Contents/MacOS/Tempo "$@"\n'


@pytest.mark.parametrize('body,accepted', [
    (WRAPPER, True),
    (WRAPPER + 'touch /tmp/unwanted\n', False),
    (WRAPPER.replace('"$@"', '--update'), False),
    (WRAPPER.replace('/Applications/Tempo.app', '/tmp/Tempo.app'), False),
])
def test_only_installers_exact_wrapper(tmp_path, body, accepted):
    link = tmp_path / 'tempo'
    link.write_text(body)
    link.chmod(0o755)
    if accepted:
        assert cli.entry_target(link, Path('/Applications/Tempo.app/Contents/MacOS/Tempo')) == 'exec-wrapper'
    else:
        with pytest.raises(ValueError):
            cli.entry_target(link, Path('/Applications/Tempo.app/Contents/MacOS/Tempo'))


def test_symlink_must_reach_bundle_executable(tmp_path):
    target = tmp_path / 'app-executable'
    target.write_text('fixture')
    target.chmod(0o755)
    link = tmp_path / 'tempo'
    link.symlink_to(target)
    assert cli.entry_target(link, target) == 'symlink'
    with pytest.raises(ValueError):
        cli.entry_target(link, tmp_path / 'other')


def test_selected_receipt_has_priority(monkeypatch):
    monkeypatch.delenv('TEMPO_BASICS_RECEIPT', raising=False)
    monkeypatch.setenv('SOP_BUILD_RECEIPT', '/channel/original.json')
    assert basics.default_receipt(basics.INSTALLED_APP) == Path('/channel/original.json')
    monkeypatch.setenv('TEMPO_BASICS_RECEIPT', '/explicit/original.json')
    assert basics.default_receipt(basics.INSTALLED_APP) == Path('/explicit/original.json')


def test_installed_receipt_and_no_candidate_fallback(tmp_path, monkeypatch):
    monkeypatch.delenv('TEMPO_BASICS_RECEIPT', raising=False)
    monkeypatch.delenv('SOP_BUILD_RECEIPT', raising=False)
    import plistlib
    monkeypatch.setattr(basics, 'ROOT', tmp_path)
    installed = tmp_path / 'Applications/Tempo.app'
    (installed / 'Contents').mkdir(parents=True)
    (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.4', 'CFBundleVersion': '7'}))
    monkeypatch.setattr(basics, 'INSTALLED_APP', installed.resolve())
    (tmp_path / 'release').mkdir()
    release = tmp_path / 'release/private.json'
    release.write_text('{"version":"0.1.4","build":"7","installed_receipt":"build/accept/original.json"}')
    assert basics.default_receipt(basics.INSTALLED_APP) == tmp_path / 'build/accept/original.json'
    assert basics.default_receipt(tmp_path / 'Tempo.app') == tmp_path / 'perf/build-receipt.json'
    # A newer install (another channel) does not borrow the retired channel's receipt.
    (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.5', 'CFBundleVersion': '9'}))
    assert basics.default_receipt(basics.INSTALLED_APP) == tmp_path / 'perf/build-receipt.json'
    (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.4', 'CFBundleVersion': '7'}))
    release.write_text('{"version":"0.1.4","build":"7","installed_receipt":"../other.json"}')
    with pytest.raises(ValueError):
        basics.default_receipt(basics.INSTALLED_APP)


def test_chapter_rejects_stale_production_binding(tmp_path, monkeypatch):
    import hashlib
    import json
    import plistlib
    app = tmp_path / 'Tempo.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/MacOS/Tempo').write_bytes(b'fixture')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'cyou.tianli.tempo',
        'CFBundleShortVersionString': '0.1.4', 'CFBundleVersion': '7'}))
    (app / 'icon').write_bytes(b'icon')
    receipt = tmp_path / 'receipt.json'
    receipt.write_text(json.dumps({'artifact': {
        'bundle_id': 'cyou.tianli.tempo', 'version': '0.1.4', 'build': '7',
        'executable': 'Contents/MacOS/Tempo', 'sha256': hashlib.sha256(b'fixture').hexdigest(),
        'icon': {'path': 'icon', 'sha256': hashlib.sha256(b'icon').hexdigest()}}}))
    monkeypatch.setattr(basics, 'INSTALLED_APP', app)
    monkeypatch.setenv('SOP_BUILD_CURRENT', '0')
    monkeypatch.setenv('SOP_CODE_BINDING_SHA256', 'a' * 64)
    with pytest.raises(ValueError, match='SOP_BUILD_CURRENT=0'):
        basics.verify_product(app, receipt)
