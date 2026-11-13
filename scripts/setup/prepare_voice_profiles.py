"""Generate relocatable WSL inference profiles without importing/deserializing models."""
from __future__ import annotations
import argparse
import json
from pathlib import Path, PureWindowsPath

ROOT = Path(__file__).resolve().parents[2]


def wsl_path(value: str | Path) -> str:
    text = str(value)
    if text.startswith('/'):
        return text
    path = PureWindowsPath(text)
    if not path.drive or len(path.drive) != 2:
        raise ValueError('Expected an absolute local-drive path')
    return '/mnt/' + path.drive[0].lower() + path.as_posix()[2:]


def paths(root: Path) -> dict[str, Path]:
    values = {'engine': 'runtime/gpt-sovits', 'profiles': 'runtime/voice-profiles',
              'references': 'models/references', 'wsl_python': 'runtime/voice-venv/bin/python'}
    local = root / 'runtime/paths.local.json'
    if local.is_file():
        overrides = json.loads(local.read_text(encoding='utf-8-sig'))
        values.update({key: value for key, value in overrides.items() if key in values})
    return {key: (root / value).resolve() for key, value in values.items()}


def generate(root: Path, device: str = 'cuda') -> list[Path]:
    locations = paths(root)
    engine = locations['engine']
    voices = json.loads((root / 'voice/profiles/voices.json').read_text(encoding='utf-8'))['voices']
    # WSL venv Python is a Linux symlink; Windows cannot stat its target.
    # Validate the environment through WSL at launch instead of following it here.
    required = [engine / 'api_v2.py']
    for folder in ['chinese-roberta-wwm-ext-large', 'chinese-hubert-base', 'v2Pro']:
        required.append(engine / 'GPT_SoVITS/pretrained_models' / folder)
    for voice in voices:
        required.extend([engine / voice['gpt'], engine / voice['sovits'], locations['references'] / voice['reference']])
    required.append(locations['references'] / 'ciel.json')
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise FileNotFoundError('Missing voice dependencies:\n' + '\n'.join(missing))
    locations['profiles'].mkdir(parents=True, exist_ok=True)
    generated = []
    for voice in voices:
        fields = {'bert_base_path': wsl_path(engine / 'GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large'),
                  'cnhuhbert_base_path': wsl_path(engine / 'GPT_SoVITS/pretrained_models/chinese-hubert-base'),
                  'device': device, 'is_half': device == 'cuda', 'version': 'v2Pro',
                  't2s_weights_path': wsl_path(engine / voice['gpt']),
                  'vits_weights_path': wsl_path(engine / voice['sovits'])}
        target = locations['profiles'] / (voice['speaker'] + '.yaml')
        # JSON scalars are valid YAML; quoting protects spaces and Unicode.
        target.write_text('custom:\n' + ''.join('  ' + key + ': ' + json.dumps(value, ensure_ascii=False) + '\n' for key, value in fields.items()), encoding='utf-8')
        generated.append(target)
    return generated


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--device', choices=['cpu', 'cuda'], default='cuda')
    args = parser.parse_args()
    for output in generate(args.root.resolve(), args.device):
        print('Prepared ' + output.name)
