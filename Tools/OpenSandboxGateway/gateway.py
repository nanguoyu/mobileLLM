#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Authenticated, durable mobileLLM adapter over OpenSandbox 1.1.1.

All generated code and workspace operations execute in OpenSandbox. This process only owns
operation identity, observation/recovery and the fixed deployment configuration.
"""
import argparse
import asyncio
import base64
from contextlib import asynccontextmanager
from datetime import timedelta
import hashlib
import hmac
import json
import os
from pathlib import Path
import sqlite3
import time
import uuid

from fastapi import FastAPI, Header, HTTPException, Request
from opensandbox import Sandbox
from opensandbox.config import ConnectionConfig
from opensandbox.exceptions import SandboxApiException
from opensandbox.models import NetworkPolicy, NetworkRule
from opensandbox.models.execd import RunCommandOpts
from opensandbox.transport.retry import RetryPolicy
import uvicorn

TERMINAL = {'completed', 'failed', 'cancelled', 'uncertain'}
ACTIONS = {'write', 'read', 'list', 'exec', 'start', 'process', 'stop', 'browser', 'download', 'export'}


def identity(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(400, 'Invalid operation or workspace identity')


def now_ms():
    return int(time.time() * 1000)


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
          CREATE TABLE IF NOT EXISTS workspaces(id TEXT PRIMARY KEY, sandbox TEXT, state TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, workspace TEXT NOT NULL,
            fingerprint TEXT NOT NULL, request TEXT NOT NULL, state TEXT NOT NULL, version INTEGER NOT NULL,
            accepted INTEGER NOT NULL, started INTEGER, finished INTEGER, command TEXT, output TEXT, error TEXT);
          CREATE TABLE IF NOT EXISTS processes(id TEXT PRIMARY KEY, workspace TEXT NOT NULL, command TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS cancellations(id TEXT PRIMARY KEY, operation TEXT NOT NULL,
            expected INTEGER NOT NULL, response TEXT NOT NULL);
        ''')

    def operation(self, operation):
        value = self.db.execute('SELECT * FROM operations WHERE id=?', (operation,)).fetchone()
        if value is None:
            raise HTTPException(404, 'Unknown operation')
        return dict(value)

    def accept(self, operation, body):
        encoded = json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
        fingerprint = hashlib.sha256(encoded.encode()).hexdigest()
        with self.db:
            old = self.db.execute('SELECT fingerprint FROM operations WHERE id=?', (operation,)).fetchone()
            if old:
                if old['fingerprint'] != fingerprint:
                    raise HTTPException(409, 'Operation identity was already bound to a different request')
                return False
            self.db.execute('INSERT INTO operations(id,workspace,fingerprint,request,state,version,accepted) VALUES(?,?,?,?,?,1,?)',
                            (operation, body['workspaceID'], fingerprint, encoded, 'accepted', now_ms()))
        return True

    def transition(self, operation, state, **fields):
        allowed = {'started', 'finished', 'command', 'output', 'error'}
        if not set(fields).issubset(allowed):
            raise ValueError('Invalid stored operation field')
        assignments = ','.join(['state=?', 'version=version+1'] + [key + '=?' for key in fields])
        self.db.execute('UPDATE operations SET ' + assignments + ' WHERE id=?', [state, *fields.values(), operation])

    def public(self, operation):
        row = self.operation(operation)
        return {'operationID': row['id'], 'workspaceID': row['workspace'], 'state': row['state'],
                'version': row['version'], 'acceptedAtMS': row['accepted'], 'startedAtMS': row['started'],
                'finishedAtMS': row['finished'], 'error': row['error'],
                'submitted': row['command'] is not None,
                'output': json.loads(row['output']) if row['output'] else None}


class Gateway:
    def __init__(self, config):
        self.config = config
        root = Path(config['stateDirectory'])
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.store = Store(root / 'gateway.sqlite')
        self.connection = ConnectionConfig(domain=config['lifecycleDomain'], api_key=config['lifecycleKey'],
            protocol='http', use_server_proxy=True, disable_metrics=True, retry_policy=RetryPolicy.disabled(),
            request_timeout=timedelta(seconds=30))
        self.clients = {}
        self.locks = {}
        self.tasks = {}
        self.closing = False

    def authenticate(self, authorization, server_id, discovery=False):
        if not authorization or not hmac.compare_digest(authorization, 'Bearer ' + self.config['apiKey']):
            raise HTTPException(401, 'Authentication required')
        if not discovery and server_id != self.config['serverID']:
            raise HTTPException(409, 'Execution environment identity changed; reconnect explicitly')

    async def sandbox(self, workspace):
        if workspace in self.clients:
            return self.clients[workspace]
        row = self.store.db.execute('SELECT * FROM workspaces WHERE id=?', (workspace,)).fetchone()
        if row and row['state'] == 'rejected':
            self.store.db.execute('DELETE FROM workspaces WHERE id=?', (workspace,))
            row = None
        if row and row['sandbox'] and row['state'] == 'running':
            client = await Sandbox.connect(row['sandbox'], connection_config=self.connection)
        elif row:
            raise RuntimeError('Workspace creation outcome is unavailable; it must not be recreated silently')
        else:
            active = self.store.db.execute("SELECT count(*) FROM workspaces WHERE state IN ('creating','running')").fetchone()[0]
            if active >= 2:
                raise RuntimeError('The two-workspace resource limit is reached; close a workspace before creating another')
            self.store.db.execute('INSERT INTO workspaces VALUES(?,NULL,?)', (workspace, 'creating'))
            try:
                client = await Sandbox.create(self.config['image'], connection_config=self.connection,
                    timeout=timedelta(seconds=3600), ready_timeout=timedelta(seconds=90),
                    entrypoint=['/bin/sleep', 'infinity'], resource={'cpu': '2', 'memory': '2Gi'},
                    metadata={'mobilellm.owner': self.config['owner'], 'mobilellm.workspace': workspace},
                    network_policy=NetworkPolicy(default_action='deny', egress=[
                        NetworkRule(action='allow', target=host) for host in self.config.get('allowedHosts', [])]))
            except SandboxApiException as error:
                if error.status_code in {400, 401, 403, 404, 422, 429}:
                    self.store.db.execute('UPDATE workspaces SET state=? WHERE id=?', ('rejected', workspace))
                raise
            self.store.db.execute('UPDATE workspaces SET sandbox=?,state=? WHERE id=?', (client.id, 'running', workspace))
        self.clients[workspace] = client
        return client

    def schedule(self, operation):
        if operation not in self.tasks:
            task = asyncio.create_task(self.execute(operation))
            self.tasks[operation] = task
            task.add_done_callback(lambda _: self.tasks.pop(operation, None))

    async def recover(self):
        for row in self.store.db.execute('SELECT id,state,command FROM operations WHERE state NOT IN (?,?,?,?)', tuple(TERMINAL)).fetchall():
            if row['state'] == 'starting' and not row['command']:
                self.store.transition(row['id'], 'uncertain', finished=now_ms(), error='The gateway restarted during command submission. Execution was not repeated.')
            else:
                self.schedule(row['id'])

    async def execute(self, operation):
        row = self.store.operation(operation)
        lock = self.locks.setdefault(row['workspace'], asyncio.Lock())
        # Serialize workspace mutations. Different goal workspaces execute independently.
        async with lock:
            row = self.store.operation(operation)
            if row['state'] in TERMINAL:
                return
            body = json.loads(row['request'])
            payload = body['payload']
            sandbox = None
            try:
                sandbox = await self.sandbox(row['workspace'])
                row = self.store.operation(operation)
                if row['state'] in TERMINAL:
                    return
                if payload['action'] in {'process', 'stop'}:
                    process = self.store.db.execute('SELECT * FROM processes WHERE id=? AND workspace=?',
                                                   (identity(payload['processID']), row['workspace'])).fetchone()
                    if process is None:
                        raise ValueError('Unknown process in this workspace')
                    if payload['action'] == 'stop':
                        await sandbox.commands.interrupt(process['command'])
                    status = await sandbox.commands.get_command_status(process['command'])
                    self.store.transition(operation, 'completed', started=now_ms(), finished=now_ms(),
                        output=json.dumps({'processID': process['id'], 'running': status.running,
                                           'exitCode': status.exit_code, 'error': status.error}))
                    return
                command = row['command']
                if not command:
                    self.store.transition(operation, 'starting', started=now_ms())
                    if payload['action'] == 'start':
                        text = payload['command']
                        if not isinstance(text, str) or not text.strip() or len(text.encode()) > 131072:
                            raise ValueError('Invalid command')
                        # The process keeps running independently of its observing client. Its
                        # stdout is file-size bounded and readable from the same workspace.
                        argv = ['/bin/bash', '-lc', 'mkdir -p .mobilellm/processes; ulimit -f 65536; exec /bin/bash -lc '
                                + __import__('shlex').quote(text) + ' > .mobilellm/processes/' + operation + '.log 2>&1']
                        timeout = 1800
                    else:
                        value = dict(payload, operationID=operation)
                        value['timeoutSeconds'] = min(120, body['timeoutSeconds'])
                        encoded = base64.b64encode(json.dumps(value, ensure_ascii=False).encode()).decode()
                        argv = ['python3', '/opt/mobilellm/guest.py', encoded]
                        timeout = min(120, body['timeoutSeconds']) + 5
                    execution = await sandbox.commands.run(argv, opts=RunCommandOpts(background=True,
                        working_directory='/workspace', uid=1000, gid=1000, timeout=timedelta(seconds=timeout)))
                    if not execution.id:
                        raise RuntimeError('OpenSandbox did not return a command identity')
                    command = execution.id
                    self.store.transition(operation, 'running', command=command)
                    if payload['action'] == 'start':
                        self.store.db.execute('INSERT OR IGNORE INTO processes VALUES(?,?,?)', (operation, row['workspace'], command))
                if payload['action'] == 'start':
                    status = await sandbox.commands.get_command_status(command)
                    if status.running is not True:
                        raise RuntimeError('The service process did not remain running')
                    self.store.transition(operation, 'completed', finished=now_ms(),
                        output=json.dumps({'processID': operation, 'running': True, 'logPath': '.mobilellm/processes/' + operation + '.log'}))
                    return
                while not self.closing:
                    status = await sandbox.commands.get_command_status(command)
                    if status.running is False:
                        logs = await sandbox.commands.get_background_command_logs(command)
                        if len(logs.content.encode()) > 900000:
                            raise RuntimeError('OpenSandbox result exceeds the response limit')
                        try:
                            output = json.loads(logs.content.strip())
                        except json.JSONDecodeError:
                            output = {'stderr': logs.content[:32768]}
                        cancelled = self.store.operation(operation)['state'] == 'cancelling'
                        good = status.exit_code == 0 and output.get('exitCode', 0) == 0 and 'error' not in output
                        final = 'cancelled' if cancelled else 'completed' if good else 'failed'
                        error = None if good else str(output.get('error') or output.get('stderr') or status.error or 'Command exited unsuccessfully')[:8000]
                        self.store.transition(operation, final, finished=now_ms(), output=json.dumps(output, ensure_ascii=False), error=error)
                        return
                    await asyncio.sleep(0.25)
            except asyncio.CancelledError:
                # Detaching or stopping this observer leaves the submitted command recoverable.
                raise
            except Exception as error:
                latest = self.store.operation(operation)
                if latest['state'] not in TERMINAL:
                    workspace = self.store.db.execute('SELECT state FROM workspaces WHERE id=?', (row['workspace'],)).fetchone()
                    uncertain = latest['state'] in {'starting', 'running', 'cancelling'} or (workspace is not None and workspace['state'] == 'creating')
                    self.store.transition(operation, 'uncertain' if uncertain else 'failed', finished=now_ms(), error=str(error)[:8000])

    async def cancel(self, operation, command_id, expected):
        old = self.store.db.execute('SELECT * FROM cancellations WHERE id=?', (command_id,)).fetchone()
        if old:
            if old['operation'] != operation or old['expected'] != expected:
                raise HTTPException(409, 'Cancellation identity mismatch')
            return json.loads(old['response'])
        row = self.store.operation(operation)
        if row['version'] != expected:
            raise HTTPException(409, 'Operation state changed; read its current version')
        if row['state'] not in TERMINAL:
            if row['state'] == 'accepted':
                self.store.transition(operation, 'cancelled', finished=now_ms(), error='Cancelled before submission')
            else:
                self.store.transition(operation, 'cancelling', error='Cancellation requested')
                if row['command']:
                    sandbox = await self.sandbox(row['workspace'])
                    await sandbox.commands.interrupt(row['command'])
        response = self.store.public(operation)
        self.store.db.execute('INSERT INTO cancellations VALUES(?,?,?,?)', (command_id, operation, expected, json.dumps(response)))
        return response

    async def destroy(self, workspace):
        row = self.store.db.execute('SELECT * FROM workspaces WHERE id=?', (workspace,)).fetchone()
        if row is None or row['state'] == 'destroyed':
            return
        if not row['sandbox']:
            raise HTTPException(409, 'Workspace creation requires reconciliation')
        sandbox = await self.sandbox(workspace)
        await sandbox.kill()
        for operation in self.store.db.execute('SELECT id,state FROM operations WHERE workspace=?', (workspace,)).fetchall():
            if operation['state'] not in TERMINAL:
                self.store.transition(operation['id'], 'cancelled', finished=now_ms(), error='The workspace was stopped by its owner')
                if task := self.tasks.get(operation['id']):
                    task.cancel()
        await sandbox.close()
        self.clients.pop(workspace, None)
        self.store.db.execute('UPDATE workspaces SET state=? WHERE id=?', ('destroyed', workspace))


def create_app(config):
    gateway = Gateway(config)

    @asynccontextmanager
    async def lifecycle(app):
        await gateway.recover()
        yield
        gateway.closing = True
        pending = list(gateway.tasks.values())
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        for client in gateway.clients.values():
            await client.close()
        gateway.store.db.close()

    app = FastAPI(lifespan=lifecycle, docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware('http')
    async def guard(request, call_next):
        try:
            gateway.authenticate(request.headers.get('authorization'), request.headers.get('x-mobilellm-server-id'),
                                 discovery=request.url.path == '/v1/capabilities' and request.method == 'GET')
            if int(request.headers.get('content-length', '0')) > 300000:
                raise HTTPException(413, 'Request exceeds limit')
        except HTTPException as error:
            from fastapi.responses import JSONResponse
            return JSONResponse({'error': error.detail}, status_code=error.status_code)
        return await call_next(request)

    @app.get('/v1/capabilities')
    async def capabilities():
        return {'protocolVersion': 1, 'serverID': config['serverID'], 'backend': 'OpenSandbox',
                'backendVersion': '1.1.1', 'image': config['image'], 'features': ['workspaceFiles', 'codeExecution', 'applicationInspection'],
                'maximumConcurrentWorkspaces': 2, 'allowedHosts': config.get('allowedHosts', [])}

    @app.post('/v1/operations/{operation}')
    async def start(operation: str, request: Request):
        operation = identity(operation)
        raw = await request.body()
        if len(raw) > 300000:
            raise HTTPException(413, 'Request exceeds limit')
        try:
            body = json.loads(raw)
            if set(body) != {'workspaceID', 'requestFingerprint', 'payload', 'timeoutSeconds'}:
                raise ValueError('Invalid request fields')
            body['workspaceID'] = identity(body['workspaceID'])
            if not isinstance(body['payload'], dict) or body['payload'].get('action') not in ACTIONS:
                raise ValueError('Invalid operation')
            if not isinstance(body['timeoutSeconds'], int) or not 1 <= body['timeoutSeconds'] <= 120:
                raise ValueError('Invalid timeout')
            if not isinstance(body['requestFingerprint'], str) or len(body['requestFingerprint']) != 64:
                raise ValueError('Invalid request binding')
        except (ValueError, TypeError, KeyError) as error:
            raise HTTPException(400, str(error))
        if gateway.store.accept(operation, body):
            gateway.schedule(operation)
        return gateway.store.public(operation)

    @app.get('/v1/operations/{operation}')
    async def status(operation: str):
        return gateway.store.public(identity(operation))

    @app.post('/v1/operations/{operation}/cancel')
    async def cancel(operation: str, request: Request):
        body = await request.json()
        return await gateway.cancel(identity(operation), identity(body['commandID']), body['expectedVersion'])

    @app.delete('/v1/workspaces/{workspace}')
    async def destroy(workspace: str):
        await gateway.destroy(identity(workspace))
        return {'deleted': True}

    @app.get('/v1/workspaces')
    async def workspaces():
        return {'workspaces': [dict(row) for row in gateway.store.db.execute('SELECT * FROM workspaces')]}

    return app


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    options = parser.parse_args()
    settings = json.loads(Path(options.config).read_text())
    uvicorn.run(create_app(settings), host='127.0.0.1', port=settings.get('port', 18281), access_log=False)
