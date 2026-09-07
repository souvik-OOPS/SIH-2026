"""Fetch public, pinned llama.cpp sources and the official Qwen GGUF.
Run from any directory: python mobile/tool/prepare_local_llm.py
The model stays outside the APK; import/copy it once before offline use.
"""
import hashlib
import io
import json
import pathlib
import urllib.request
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
vendor = root / 'vendor'
vendor.mkdir(exist_ok=True)
revision_file = pathlib.Path(__file__).with_name('llama_revision.txt')
headers = {'User-Agent': 'SwasthyaShield-build'}
def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120)

if revision_file.exists():
    revision = revision_file.read_text().strip()
else:
    revision = json.load(get('https://api.github.com/repos/ggml-org/llama.cpp/commits/master'))['sha']
    revision_file.write_text(revision + '\n')
destination = (vendor / 'llama.cpp').resolve()
if not (destination / 'CMakeLists.txt').exists():
    print('Fetching llama.cpp', revision, flush=True)
    archive = zipfile.ZipFile(io.BytesIO(get(f'https://codeload.github.com/ggml-org/llama.cpp/zip/{revision}').read()))
    for member in archive.infolist():
        relative = pathlib.PurePosixPath(member.filename).parts[1:]
        if not relative or member.is_dir():
            continue
        target = destination.joinpath(*relative).resolve()
        if not target.is_relative_to(destination):
            raise ValueError('Unsafe archive path')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.read(member))

model = vendor / 'Qwen3-0.6B-Q8_0.gguf'
model_revision = '23749fe'
if not model.exists():
    print('Fetching official Qwen3-0.6B Q8_0 (~639 MB)', flush=True)
    temporary = model.with_suffix('.download')
    with get(f'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/{model_revision}/Qwen3-0.6B-Q8_0.gguf') as response, temporary.open('wb') as out:
        while block := response.read(1024 * 1024):
            out.write(block)
    if temporary.open('rb').read(4) != b'GGUF':
        raise ValueError('Downloaded file is not GGUF')
    temporary.replace(model)
digest = hashlib.file_digest(model.open('rb'), 'sha256').hexdigest()
expected = '9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031'
if digest != expected:
    raise ValueError('Model SHA-256 mismatch; remove the incomplete model and prepare again')
(vendor / 'model-manifest.json').write_text(json.dumps({'model': model.name, 'revision': model_revision, 'sha256': digest, 'bytes': model.stat().st_size}, indent=2))
print('Ready:', model, digest, flush=True)
