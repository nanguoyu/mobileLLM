#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bounded operation helpers executed INSIDE the OpenSandbox container, never on the Mac."""
import asyncio
import ast
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import selectors
import signal
import subprocess
import sys
import time
import uuid
import zipfile
from types import SimpleNamespace
import urllib.request
import urllib.error
from urllib.parse import urlsplit

ROOT = Path('/workspace/project')
MAX_TEXT = 131072
MAX_FILE = 8 * 1024 * 1024


class BoundedCapture:
    def __init__(self, limit=16384):
        self.limit = limit
        self.parts = []
        self.size = 0
        self.truncated = False

    def write(self, text):
        data = str(text).encode('utf-8', errors='replace')
        kept = data[:self.limit - self.size]
        if kept:
            self.parts.append(kept)
            self.size += len(kept)
        self.truncated |= len(data) > len(kept)
        return len(text)

    def flush(self):
        pass

    def value(self):
        return b''.join(self.parts).decode('utf-8', errors='replace')
IGNORED = {'node_modules', '.git', '.mobilellm', '.venv', '__pycache__', '.next', 'dist', 'build'}


def source_files():
    total = 0
    count = 0
    for directory, folders, files in os.walk(ROOT, followlinks=False):
        folders[:] = sorted(p for p in folders if p not in IGNORED)
        for name in folders + sorted(files):
            path = Path(directory, name)
            if path.is_symlink():
                raise ValueError('Source snapshots require ordinary files: ' + str(path.relative_to(ROOT)))
        for name in sorted(files):
            path = str(Path(directory, name).relative_to(ROOT))
            data = read_file(path)
            total += len(data); count += 1
            if total > MAX_FILE or count > 1000:
                raise ValueError('Source snapshot exceeds 8 MiB or 1000 files; keep runtime data outside the project')
            yield path, data


def source_digest():
    manifest = [{'path': path, 'sha256': hashlib.sha256(data).hexdigest()} for path, data in source_files()]
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def components(path):
    value = PurePosixPath(path)
    if value.is_absolute() or '..' in value.parts or '\x00' in path or len(path) > 512:
        raise ValueError('Use a relative path inside the workspace')
    return [p for p in value.parts if p != '.']


def parent_fd(path, create=False):
    parts = components(path)
    if not parts:
        raise ValueError('A file path is required')
    fd = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            if create:
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise


def read_file(path):
    fd, leaf = parent_fd(path)
    try:
        file = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        with os.fdopen(file, 'rb') as stream:
            if os.fstat(stream.fileno()).st_size > MAX_FILE:
                raise ValueError('File exceeds the readable size limit')
            return stream.read(MAX_FILE + 1)
    finally:
        os.close(fd)


def write_files(files):
    if not 1 <= len(files) <= 8 or len({f['path'] for f in files}) != len(files):
        raise ValueError('Supply one to eight distinct files')
    if sum(len(f['content'].encode()) for f in files) > MAX_TEXT:
        raise ValueError('File batch exceeds 128 KiB')
    # Compare before changing any file. The gateway serializes writes for this workspace.
    for item in files:
        components(item['path'])
        try:
            previous = read_file(item['path'])
        except FileNotFoundError:
            previous = None
        if previous is not None and previous != item['content'].encode():
            if hashlib.sha256(previous).hexdigest() != item.get('expectedSHA256'):
                raise ValueError('File changed; read its current SHA256 before replacing ' + item['path'])
        elif previous is None and item.get('expectedSHA256'):
            raise ValueError('Expected existing file is missing: ' + item['path'])
    result = []
    for item in files:
        data = item['content'].encode()
        directory, leaf = parent_fd(item['path'], create=True)
        temporary = '.mobilellm-write-' + uuid.uuid4().hex
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=directory)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.rename(temporary, leaf, src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
            os.close(directory)
        result.append({'path': item['path'], 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
    return {'files': result}


def run_command(command, timeout):
    if not isinstance(command, str) or not command.strip() or len(command.encode()) > MAX_TEXT:
        raise ValueError('Invalid or oversized command')
    process = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', command], cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
    selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
    output = {'stdout': bytearray(), 'stderr': bytearray()}
    truncated = False
    expired = False
    cancelled = False
    def stop_children(signum, frame):
        nonlocal cancelled
        cancelled = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    previous_signals = {sig: signal.signal(sig, stop_children) for sig in (signal.SIGTERM, signal.SIGINT)}
    deadline = time.monotonic() + timeout
    while selector.get_map():
        if time.monotonic() > deadline:
            expired = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            deadline = float('inf')
        for key, _ in selector.select(0.1):
            data = os.read(key.fileobj.fileno(), 4096)
            if not data:
                selector.unregister(key.fileobj)
                key.fileobj.close()
                continue
            remaining = 32768 - len(output[key.data])
            output[key.data].extend(data[:remaining])
            truncated |= len(data) > remaining
    code = process.wait()
    for sig, handler in previous_signals.items():
        signal.signal(sig, handler)
    return {'exitCode': code, 'stdout': output['stdout'].decode('utf-8', errors='replace'),
            'stderr': output['stderr'].decode('utf-8', errors='replace'), 'truncated': truncated, 'timedOut': expired, 'cancelled': cancelled}


async def inspect_browser(script, operation_id, port):
    from playwright.async_api import async_playwright, expect
    if len(script.encode()) > 32768:
        raise ValueError('Browser script exceeds 32 KiB')
    forbidden = {'eval','exec','compile','open','input','globals','locals','vars','getattr','setattr','delattr','__import__','exit','quit','breakpoint'}
    for node in ast.walk(ast.parse(script)):
        if isinstance(node, (ast.Import, ast.ImportFrom, ast.ClassDef)) or (
            isinstance(node, ast.Name) and (node.id.startswith('_') or node.id in forbidden)) or (
            isinstance(node, ast.Attribute) and node.attr.startswith('_')):
            raise ValueError('Use the provided Playwright objects; imports, introspection and OS operations belong in sandbox_run')
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=True, args=['--no-sandbox'])
        context = await browser.new_context(viewport={'width': 1280, 'height': 900})
        page = await context.new_page()
        browser_errors = []
        def record_error(message):
            if len(browser_errors) < 20:
                browser_errors.append(str(message)[:1000])
        page.on('pageerror', record_error)
        page.on('console', lambda message: record_error(message.text) if message.type == 'error' else None)
        page.set_default_timeout(10000)
        base_url = 'http://127.0.0.1:' + str(port)
        before = source_digest()
        response = await page.goto(base_url)
        if response is None or response.status >= 400:
            raise ValueError('The application page did not load successfully')
        # The supplied script is authorized code running only in the guest, like shell execution.
        namespace = {'page': page, 'context': context, 'browser': browser, 'base_url': base_url, 'expect': expect,
                     'asyncio': SimpleNamespace(sleep=asyncio.sleep,gather=asyncio.gather),
                     'json': SimpleNamespace(dumps=json.dumps,loads=json.loads)}
        exec('async def user_check():\n' + '\n'.join('    ' + line for line in script.splitlines()), namespace)
        stdout, stderr = BoundedCapture(), BoundedCapture()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = await namespace['user_check']()
        location = urlsplit(page.url)
        if location.hostname not in {'localhost', '127.0.0.1'} or location.port != port:
            raise ValueError('Browser checks must finish on the selected workspace application')
        if source_digest() != before:
            raise ValueError('Project files changed during browser checks; store runtime data in MOBILELLM_DATA_DIR and retest')
        folder = ROOT / '.mobilellm' / 'screenshots'
        folder.mkdir(parents=True, exist_ok=True)
        screenshot = folder / (operation_id + '.jpg')
        await page.screenshot(path=str(screenshot), type='jpeg', quality=70, full_page=False)
        data = screenshot.read_bytes()
        if len(data) > 512 * 1024:
            await page.screenshot(path=str(screenshot), type='jpeg', quality=35, full_page=False)
            data = screenshot.read_bytes()
        if len(data) > 512 * 1024:
            raise ValueError('Browser screenshot exceeds 512 KiB')
        response = {'scriptCompleted': True, 'url': page.url, 'port': port, 'title': await page.title(),
                    'result': result, 'stdout': stdout.value(), 'stderr': stderr.value(),
                    'outputTruncated': stdout.truncated or stderr.truncated,
                    'pageText': (await page.locator('body').inner_text())[:12000], 'browserErrors': browser_errors,
                    'controls': await page.locator('input,select,textarea,button').evaluate_all("""nodes => nodes.slice(0,40).map(n => ({
                        tag:n.tagName.toLowerCase(),type:n.type || '',name:(n.name || '').slice(0,128),
                        id:(n.id || '').slice(0,128),label:(n.getAttribute('aria-label') || n.labels?.[0]?.innerText || n.innerText || '').slice(0,256)
                    }))"""),
                    'screenshot': str(screenshot.relative_to(ROOT)),
                    'screenshotBase64': base64.b64encode(data).decode(), 'screenshotSHA256': hashlib.sha256(data).hexdigest()}
        await browser.close()
        return response


def execute(payload):
    action = payload['action']
    if action == 'write':
        return write_files(payload['files'])
    if action == 'read':
        data = read_file(payload['path'])
        offset = payload.get('offset', 0)
        if not isinstance(offset, int) or not 0 <= offset <= len(data):
            raise ValueError('Invalid byte offset')
        data.decode('utf-8')
        data[:offset].decode('utf-8')  # Reject offsets inside a scalar instead of corrupting original text.
        chunk = data[offset:offset + 32768]
        text = chunk.decode('utf-8', errors='ignore')
        return {'path': payload['path'], 'sha256': hashlib.sha256(data).hexdigest(), 'content': text,
                'offset': offset, 'nextOffset': offset + len(text.encode()), 'bytes': len(data),
                'truncated': offset + len(text.encode()) < len(data)}
    if action == 'list':
        parts = components(payload.get('path', '.'))
        directory = ROOT.joinpath(*parts)
        if not directory.resolve().is_relative_to(ROOT) or directory.is_symlink():
            raise ValueError('Directory escapes workspace')
        entries = sorted(directory.iterdir(), key=lambda p: p.name)
        return {'entries': [{'name': p.name, 'directory': p.is_dir(), 'symlink': p.is_symlink(),
                             'bytes': p.lstat().st_size} for p in entries[:200]], 'truncated': len(entries) > 200}
    if action == 'download':
        data = read_file(payload['path'])
        if len(data) > 512 * 1024:
            raise ValueError('Binary artifact exceeds 512 KiB')
        return {'dataBase64': base64.b64encode(data).decode(), 'bytes': len(data),
                'sha256': hashlib.sha256(data).hexdigest()}
    if action == 'exec':
        return run_command(payload['command'], min(120, max(1, payload.get('timeoutSeconds', 60))))
    if action == 'browser':
        return asyncio.run(inspect_browser(payload['script'], payload['operationID'], payload['port']))
    if action == 'probe':
        port = payload['port']
        if not isinstance(port, int) or not 1024 <= port <= 32767:
            raise ValueError('Application ports must be between 1024 and 32767')
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen('http://127.0.0.1:' + str(port), timeout=1) as response:
                    return {'port': port, 'httpStatus': response.status, 'ready': True}
            except urllib.error.HTTPError as error:
                if error.code < 500:
                    return {'port': port, 'httpStatus': error.code, 'ready': True}
            except OSError:
                pass
            time.sleep(0.2)
        raise ValueError('The started process did not serve HTTP on its declared port')
    if action == 'digest':
        return {}
    if action == 'export':
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            count = 0
            for path, data in source_files():
                archive.writestr(path, data)
                count += 1
        if count == 0:
            raise ValueError('There are no project source files to export')
        data = buffer.getvalue()
        if len(data) > 512 * 1024:
            raise ValueError('Compressed source export exceeds 512 KiB')
        return {'mimeType': 'application/zip', 'sha256': hashlib.sha256(data).hexdigest(),
                'dataBase64': base64.b64encode(data).decode(), 'bytes': len(data)}
    raise ValueError('Unknown operation')


if __name__ == '__main__':
    payload = json.loads(base64.b64decode(sys.argv[1], validate=True))
    code = 1
    try:
        result = execute(payload)
        result['sourceDigest'] = source_digest()
        encoded = json.dumps(result, ensure_ascii=False)
        if len(encoded.encode()) > 850000:
            raise ValueError('Operation result exceeds its output limit')
        code = 0 if result.get('exitCode', 0) == 0 else 1
    except BaseException as error:
        result = {'error': str(error)[:4000] or type(error).__name__}
        try: result['sourceDigest'] = source_digest()
        except Exception: pass
        encoded = json.dumps(result, ensure_ascii=False)
    if payload.get('operationID'):
        identity = str(uuid.UUID(payload['operationID']))
        directory, leaf = parent_fd('.mobilellm/operations/' + identity + '.json', create=True)
        try:
            fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            with os.fdopen(fd, 'w') as output: output.write(encoded)
        finally: os.close(directory)
        print(json.dumps({'resultPath': '.mobilellm/operations/' + identity + '.json', 'exitCode': code}), flush=True)
    else:
        print(encoded, flush=True)
    sys.exit(code)
