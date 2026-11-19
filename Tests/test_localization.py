"""Runtime English UI guard. Regenerate with scripts/accept/localization.py after UI changes."""
import importlib.util
import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'perf/acceptance/l10n'


@pytest.mark.parametrize('view', ['native', 'popup', 'popup-settings', 'popup-settings-dark'])
def test_english_primary_views_have_no_remaining_chinese(view):
    if not (OUT / 'receipt.json').is_file():
        pytest.skip('Bilingual runtime rendering pending: run scripts/accept/localization.py after the build slot is available')
    spec = importlib.util.spec_from_file_location('tempo_l10n', ROOT / 'scripts/accept/localization.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    receipt = json.loads((OUT / 'receipt.json').read_text())
    assert receipt['source_sha256'] == module.source_digest(), 'Render current UI before testing localization'
    result = json.loads((OUT / 'en' / f'{view}.json').read_text())
    assert result['language'] == 'en', 'An English launch must actually load English resources'
    assert result['ok'] and not result['remaining'], result
    if view == 'native':
        assert result['never_visible_or_key'] and result['activation_prohibited']
        assert not result['catalog_remaining']
    else:
        assert not result['clipping'] and not result['missing']
        assert result['invalidImportShowsError']


def test_primary_view_has_no_unlocalized_chinese_fallback():
    # Covers a newly added SwiftUI literal omitted from the Catalog; CLI text is outside ContentView.
    view = (ROOT / 'App/TempoApp.swift').read_text().split('struct ContentView: View {', 1)[1]
    view = re.sub(r'//[^\n]*', '', view).replace('倍速', '')
    assert not re.search(r'[\u3400-\u9fff]', view)
    catalogs = [ROOT / 'App/Localizable.xcstrings', ROOT / 'App/InfoPlist.xcstrings', ROOT / 'Extension/InfoPlist.xcstrings']
    for path in catalogs:
        catalog = json.loads(path.read_text())
        assert catalog['sourceLanguage'] == 'en'
        for key, entry in catalog['strings'].items():
            for language in ('en', 'zh-Hans'):
                value = entry['localizations'][language]['stringUnit']['value']
                assert value.strip(), (path, key, language)
                if language == 'en':
                    assert not re.search(r'[\u3400-\u9fff]', value.replace('倍速', '')), (path, key, value)


@pytest.mark.parametrize('view', ['native', 'popup', 'popup-settings'])
def test_simplified_chinese_still_resolves_to_chinese(view):
    if not (OUT / 'receipt.json').is_file():
        pytest.skip('Bilingual runtime rendering pending: run scripts/accept/localization.py after the build slot is available')
    result = json.loads((OUT / 'zh-Hans' / f'{view}.json').read_text())
    assert result['language'] == 'zh-Hans', 'A Chinese launch must actually load Simplified Chinese resources'
    assert result['ok'], result
    if view == 'native':
        assert result['chinese_resolves']
        assert re.search(r'[㐀-鿿]', ''.join(result['resolved_catalog']))
    else:
        assert re.search(r'[㐀-鿿]', ''.join(s for state in result['states'] for s in state['strings']))


def test_flat_screenshot_sets_exist():
    if not (OUT / 'receipt.json').is_file():
        pytest.skip('Bilingual runtime rendering pending')
    en = sorted(p.name[3:] for p in OUT.glob('en-*.png'))
    zh = sorted(p.name[3:] for p in OUT.glob('zh-*.png'))
    assert en and en == zh
    for screen in ('main-enabled.png', 'product-settings.png', 'product-settings-error.png',
                   'lifecycle-settings-light.png', 'main-recovery.png'):
        assert screen in en
