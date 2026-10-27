#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bounded operation helpers executed INSIDE the OpenSandbox container, never on the Mac."""
import asyncio
import base64
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

ROOT = Path('/workspace')
MAX_TEXT = 131072
MAX_FILE = 8 * 1024 * 1024


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
    process = subprocess.Popen(['/bin/bash', '-lc', command], cwd=ROOT, stdout=subprocess.PIPE,
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


async def inspect_browser(script, operation_id):
    from playwright.async_api import async_playwright
    if len(script.encode()) > 32768:
        raise ValueError('Browser script exceeds 32 KiB')
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=True, args=['--no-sandbox'])
        context = await browser.new_context(viewport={'width': 1280, 'height': 900})
        page = await context.new_page()
        page.set_default_timeout(10000)
        # The supplied script is authorized code running only in the guest, like shell execution.
        namespace = {'page': page, 'context': context, 'browser': browser, 'asyncio': asyncio, 'json': json}
        exec('async def user_check():\n' + '\n'.join('    ' + line for line in script.splitlines()), namespace)
        result = await namespace['user_check']()
        folder = ROOT / '.mobilellm' / 'screenshots'
        folder.mkdir(parents=True, exist_ok=True)
        screenshot = folder / (operation_id + '.jpg')
        await page.screenshot(path=str(screenshot), type='jpeg', quality=70, full_page=False)
        response = {'scriptCompleted': True, 'url': page.url, 'title': await page.title(),
                    'result': result, 'screenshot': str(screenshot.relative_to(ROOT))}
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
        return asyncio.run(inspect_browser(payload['script'], payload['operationID']))
    if action == 'export':
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            total = 0
            for directory, folders, files in os.walk(ROOT, followlinks=False):
                folders[:] = sorted(p for p in folders if p not in {'node_modules', '.git', '.mobilellm', '.venv', '__pycache__'}
                                    and not Path(directory, p).is_symlink())
                for name in sorted(files):
                    path = Path(directory, name)
                    if path.is_symlink():
                        continue
                    data = read_file(str(path.relative_to(ROOT)))
                    total += len(data)
                    if total > 8 * 1024 * 1024:
                        raise ValueError('Source export exceeds 8 MiB')
                    archive.writestr(str(path.relative_to(ROOT)), data)
        data = buffer.getvalue()
        if len(data) > 512 * 1024:
            raise ValueError('Compressed source export exceeds 512 KiB')
        return {'mimeType': 'application/zip', 'sha256': hashlib.sha256(data).hexdigest(),
                'dataBase64': base64.b64encode(data).decode(), 'bytes': len(data)}
    raise ValueError('Unknown operation')


if __name__ == '__main__':
    try:
        result = execute(json.loads(base64.b64decode(sys.argv[1], validate=True)))
        print(json.dumps(result, ensure_ascii=False), flush=True)
        sys.exit(0 if result.get('exitCode', 0) == 0 else 1)
    except Exception as error:
        print(json.dumps({'error': str(error)[:4000]}), flush=True)
        sys.exit(1)
