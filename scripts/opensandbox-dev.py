#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Create/stop a task-owned OpenSandbox dev environment without global package/config changes."""
import argparse
import datetime
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.request
import uuid

REPO = Path(__file__).resolve().parents[1]
EXECD = 'sandbox-registry.cn-zhangjiakou.cr.aliyuncs.com/opensandbox/execd@sha256:cda2bc35409bbf57561599b316cafb899598f7dce671332e7ceda14eb1cfeded'
EGRESS = 'sandbox-registry.cn-zhangjiakou.cr.aliyuncs.com/opensandbox/egress@sha256:bce2cc2e4dc3a3594678b91ac29efb0669fccebfdfc137727018d3b087fbb13a'
BASE = 'mcr.microsoft.com/playwright/python:v1.64.1-noble@sha256:330d401ae23c905896a0c26c66c36fc971b621519e7b11b435a8328d7bf6e031'
OWNER = 'mobileLLM OpenSandbox integration'


class Environment:
    def __init__(self, root):
        self.root = Path(root).resolve()
        temporary_roots = [Path('/private/tmp'), Path(tempfile.gettempdir()).resolve()]
        if not self.root.name.startswith('mobilellm-opensandbox-') or not any(self.root.is_relative_to(path) for path in temporary_roots):
            raise RuntimeError('Choose a dedicated mobilellm-opensandbox-* directory')
        self.path = self.root / 'state.json'
        if self.path.exists():
            self.state = json.loads(self.path.read_text())
            if self.state.get('owner') != OWNER or Path(self.state['taskRoot']).resolve() != self.root:
                raise RuntimeError('This directory is not owned by this setup')
        else:
            if self.root.exists() and any(self.root.iterdir()):
                raise RuntimeError('Refusing to adopt a nonempty unowned directory')
            self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
            self.state = {'owner': OWNER, 'taskRoot': str(self.root), 'createdUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                          'ownerLabel': 'mobilellm-' + uuid.uuid4().hex, 'images': [], 'containers': [], 'volumes': []}
        if 'ownerLabel' not in self.state:
            previous = self.root/'gateway.json'
            self.state['ownerLabel'] = json.loads(previous.read_text())['owner'] if previous.exists() else 'mobilellm-' + uuid.uuid4().hex
        (self.root / 'logs').mkdir(exist_ok=True)
        (self.root / 'docker').mkdir(exist_ok=True)
        plugins = Path('/Applications/OrbStack.app/Contents/MacOS/xbin')
        (self.root / 'docker' / 'config.json').write_text(json.dumps({'auths': {}, 'cliPluginsExtraDirs': [str(plugins)] if plugins.is_dir() else []}))
        self.env = os.environ.copy()
        self.env.update(DOCKER_CONFIG=str(self.root / 'docker'), UV_CACHE_DIR=str(self.root / 'cache' / 'uv'),
                        PYTHONPYCACHEPREFIX=str(self.root / 'cache' / 'python'))
        endpoint = self.state.get('dockerHost')
        if not endpoint:
            endpoint = subprocess.check_output(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'], text=True).strip()
        if not endpoint.startswith('unix://'):
            raise RuntimeError('The dev setup requires a local Docker socket; it never selects a remote Docker host')
        self.env['DOCKER_HOST'] = endpoint; self.state['dockerHost'] = endpoint
        self.save()

    def save(self):
        temporary = self.path.with_suffix('.new')
        temporary.write_text(json.dumps(self.state, indent=2) + '\n')
        temporary.chmod(0o600); temporary.replace(self.path)

    def run(self, command, *, log=None, timeout=300):
        if log:
            with (self.root / 'logs' / log).open('w') as output:
                subprocess.run(command, env=self.env, cwd=REPO, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=timeout)
            return ''
        return subprocess.check_output(command, env=self.env, cwd=REPO, text=True, timeout=timeout).strip()

    def docker_ready(self):
        try:
            self.run(['docker','version','--format','{{.Server.Version}}'], timeout=10)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            if not shutil.which('orbctl'):
                raise RuntimeError('Start an existing local Docker runtime before continuing')
            was_running = subprocess.check_output(['orbctl','status'], text=True).strip() != 'Stopped'
            self.state.setdefault('orbstackWasRunning', was_running)
            self.save()
            self.run(['orbctl','start'], timeout=60)
            self.run(['docker','version','--format','{{.Server.Version}}'], timeout=30)
        if 'baseline' not in self.state:
            self.state['baseline'] = {key: self.run(command).splitlines() for key, command in {
                'containers':['docker','ps','-aq'], 'images':['docker','image','ls','-q','--no-trunc'],
                'volumes':['docker','volume','ls','-q'], 'networks':['docker','network','ls','-q']}.items()}
            try:
                self.state['buildCacheBefore'] = self.run(['docker','buildx','du','--format','{{.ID}}']).splitlines()
            except subprocess.CalledProcessError:
                self.state['buildCacheBefore'] = None
            self.save()

    def record_image(self, reference):
        value = json.loads(self.run(['docker','image','inspect',reference]))[0]
        if not any(x['id'] == value['Id'] for x in self.state['images']):
            self.state['images'].append({'reference': reference, 'id': value['Id'], 'digests': value.get('RepoDigests', []), 'size': value['Size']})
            self.save()
        return value['Id']

    def record_build_cache(self):
        # Docker identifies the dependency graph of each build layer. Select our guest-helper
        # vertices and only ancestors created after this environment was started. Other builds
        # may share an ancestor, so never sweep its unrelated descendants.
        rows = [json.loads(line) for line in self.run(['docker','buildx','du','--format','{{json .}}']).splitlines() if line.strip()]
        started = datetime.datetime.fromisoformat(self.state['createdUTC'])
        def recent(row):
            stamp = datetime.datetime.fromisoformat(row['CreatedAt'][:19]).replace(tzinfo=datetime.timezone.utc)
            return stamp >= started
        records = {row['ID']:row for row in rows if recent(row)}
        owned = {key for key,row in records.items() if '/opt/mobilellm/guest.py' in row.get('Description','')}
        for _ in range(len(records)):
            before = set(owned)
            for key in list(owned):
                owned.update(parent for parent in records.get(key,{}).get('Parents',[]) or [] if parent in records)
            if owned == before:break
        self.state['ownedBuildCache'] = sorted(set(self.state.get('ownedBuildCache',[])) | owned)
        self.save()

    def setup(self, rebuild=False):
        self.docker_ready()
        python = self.root / 'venv' / 'bin' / 'python'
        if not python.exists():
            self.run(['uv','venv','--python',shutil.which('python3'),str(self.root/'venv')], log='venv.log')
            self.run(['uv','pip','install','--python',str(python),'-r','Tools/OpenSandboxGateway/requirements.txt'], log='install.log')
        for index, image in enumerate([BASE, EXECD, EGRESS]):
            try:
                self.record_image(image)
            except subprocess.CalledProcessError:
                self.run(['docker','pull',image], log=f'pull-{index}.log', timeout=300)
                self.record_image(image)
        tag = self.state.setdefault('runtimeImageReference', 'mobilellm-opensandbox-test:' + self.state['ownerLabel'])
        if rebuild or not self.state.get('runtimeImageID'):
            self.run(['docker','buildx','build','--load','--progress','plain','--label','org.mobilellm.owner='+self.state['ownerLabel'],
                      '-t',tag,'Tools/OpenSandboxGateway'], log='image-build.log', timeout=600)
            self.state['runtimeImageID'] = self.record_image(tag)
            self.record_build_cache()
            self.save()
        print('Prepared pinned SDK and tool image; all environment files are under ' + str(self.root))

    def call(self, method, path, body=None):
        config = json.loads((self.root/'gateway.json').read_text())
        request = urllib.request.Request('http://127.0.0.1:18281' + path,
            data=json.dumps(body).encode() if body is not None else None, method=method,
            headers={'Authorization':'Bearer '+config['apiKey'], 'X-MobileLLM-Server-ID':config['serverID'], 'Content-Type':'application/json'})
        return json.load(urllib.request.urlopen(request, timeout=20))

    def stop_processes(self):
        for key in ['gatewayPID','serverPID']:
            pid = self.state.get(key)
            if not pid:
                continue
            try:
                command = subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip()
            except subprocess.CalledProcessError:
                continue
            if str(self.root) not in command:
                raise RuntimeError('Refusing to signal a reused process ID')
            os.kill(pid, signal.SIGTERM)
            for _ in range(50):
                try:
                    os.kill(pid,0)
                except ProcessLookupError:
                    break
                time.sleep(.1)
            self.state[key] = None
        self.save()

    def owned_containers(self):
        candidates = self.run(['docker','ps','-aq']).splitlines()
        before = set(self.state.get('baseline',{}).get('containers',[]))
        owned = []
        sandbox_ids = set(self.state.get('sandboxIDs',[]))
        for short in candidates:
            if short in before:
                continue
            record = json.loads(self.run(['docker','inspect',short]))[0]
            labels = record.get('Config',{}).get('Labels',{}) or {}
            if self.state['ownerLabel'] in labels.values() or any(value in sandbox_ids for value in labels.values()):
                owned.append(record)
        return owned

    def stop_workspaces(self):
        try:
            rows = self.call('GET','/v1/workspaces')['workspaces']
            self.state['sandboxIDs'] = sorted(set(self.state.get('sandboxIDs',[])) | {x['sandbox'] for x in rows if x.get('sandbox')})
            self.save()
        except Exception:
            rows = []
        owned = self.owned_containers()
        mounts = {m['Name'] for c in owned for m in c.get('Mounts',[]) if m.get('Type') == 'volume' and m.get('Name')}
        self.state['volumes'] = sorted(set(self.state.get('volumes',[])) | mounts); self.save()
        for row in rows:
            if row.get('sandbox') and row['state'] != 'destroyed':
                try:
                    self.call('DELETE','/v1/workspaces/'+row['id'])
                except Exception:
                    pass  # The exact owned Docker resources below are the local fallback.
        for container in self.owned_containers():
            self.run(['docker','rm','-f',container['Id']])

    def start(self, rebuild=False):
        self.state.pop('cleanup', None)
        self.save()
        self.setup(rebuild)
        if self.state.get('serverPID') or self.state.get('gatewayPID'):
            self.stop_workspaces(); self.stop_processes()
        previous = self.root/'gateway-state'
        if previous.exists():
            archive = self.root/'retained-runs'; archive.mkdir(exist_ok=True)
            previous.rename(archive/('gateway-state-'+uuid.uuid4().hex[:8]))
        server_id = str(uuid.uuid4()); server_key = secrets.token_urlsafe(32); key = secrets.token_urlsafe(32)
        toml = f'''[server]\nhost="127.0.0.1"\nport=18280\napi_key="{server_key}"\nmax_sandbox_timeout_seconds=3600\n[proxy]\nresolve_internal=false\n[log]\nlevel="WARNING"\nfile_enabled=false\n[runtime]\ntype="docker"\nexecd_image="{EXECD}"\n[docker]\nnetwork_mode="bridge"\npublish_host="127.0.0.1"\nhost_ip="127.0.0.1"\npids_limit=256\nno_new_privileges=true\nport_range_min=42100\nport_range_max=42300\n[storage]\nallowed_host_paths=["{self.root}/no-host-mounts"]\n[store]\ntype="sqlite"\npath="{self.root}/server.sqlite"\n[egress]\nimage="{EGRESS}"\nmode="dns+nft"\n[otel]\nenabled=false\n'''
        config = {'serverID':server_id,'apiKey':key,'lifecycleKey':server_key,'lifecycleDomain':'127.0.0.1:18280',
            'port':18281,'stateDirectory':str(self.root/'gateway-state'),'image':self.state['runtimeImageID'],
            'owner':self.state['ownerLabel'],'allowedHosts':['registry.npmjs.org','pypi.org','files.pythonhosted.org']}
        for name, content in [('server.toml',toml),('gateway.json',json.dumps(config)),
                              ('client.json',json.dumps({'endpoint':'http://127.0.0.1:18281','apiKey':key,'serverID':server_id}))]:
            path=self.root/name; path.write_text(content); path.chmod(0o600)
        for field, command in [('serverPID',[str(self.root/'venv/bin/opensandbox-server'),'--config',str(self.root/'server.toml')]),
            ('gatewayPID',[str(self.root/'venv/bin/python'),str(REPO/'Tools/OpenSandboxGateway/gateway.py'),'--config',str(self.root/'gateway.json')])]:
            process=subprocess.Popen(command,env=self.env,stdin=subprocess.DEVNULL,stdout=(self.root/'logs'/f'{field}.log').open('w'),
                                     stderr=subprocess.STDOUT,start_new_session=True)
            self.state[field]=process.pid
        self.state['serverID']=server_id; self.save()
        for _ in range(100):
            try:
                self.call('GET','/v1/capabilities')
                print('Execution endpoint: http://127.0.0.1:18281')
                print('Private client configuration: '+str(self.root/'client.json'))
                return
            except Exception:
                time.sleep(.1)
        raise RuntimeError('Services did not become ready; inspect this environment\'s logs')

    def down(self, remove_directory=False):
        if self.state.get('cleanup',{}).get('retained') == []:
            if remove_directory:shutil.rmtree(self.root)
            print('This environment has already been cleaned.')
            return
        self.docker_ready(); self.stop_workspaces(); self.stop_processes()
        before = self.state.get('baseline',{})
        errors=[]
        for volume in self.state.get('volumes',[]):
            if volume not in before.get('volumes',[]):
                try:self.run(['docker','volume','rm',volume])
                except subprocess.CalledProcessError:errors.append('Volume retained: '+volume)
        seen=set()
        for image in reversed(self.state.get('images',[])):
            if image['id'] in seen or image['id'] in before.get('images',[]):continue
            seen.add(image['id'])
            try:current=json.loads(self.run(['docker','image','inspect',image['id']]))[0]
            except subprocess.CalledProcessError:continue
            references = set(current.get('RepoTags') or []) | set(current.get('RepoDigests') or [])
            known = {image['reference'], *(image.get('digests') or [])}
            for reference in references & known:
                try:self.run(['docker','image','rm',reference])
                except subprocess.CalledProcessError:pass
            try:current=json.loads(self.run(['docker','image','inspect',image['id']]))[0]
            except subprocess.CalledProcessError:continue
            if (set(current.get('RepoTags') or []) | set(current.get('RepoDigests') or [])) - known:
                errors.append('Image now has another reference and was retained: '+image['id']);continue
            try:self.run(['docker','image','rm',image['id']])
            except subprocess.CalledProcessError:errors.append('Image retained: '+image['id'])
        for identifier in self.state.get('ownedBuildCache',[]):
            if not identifier.isalnum() or not 10 <= len(identifier) <= 40:
                raise RuntimeError('Invalid owned build-cache identity')
            try:self.run(['docker','buildx','prune','--force','--filter','id='+identifier], log='cache-cleanup-'+identifier+'.log')
            except subprocess.CalledProcessError:errors.append('Build cache retained: '+identifier)
        current=set(self.run(['docker','ps','-q']).splitlines())
        if self.state.get('orbstackWasRunning') is False and current.issubset(set(before.get('containers',[]))):
            self.run(['orbctl','stop'],timeout=60)
        self.state['cleanup']={'atUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'retained':errors}
        self.save()
        print(json.dumps(self.state['cleanup'],indent=2))
        if remove_directory and not errors:
            shutil.rmtree(self.root)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['up','status','down'])
    parser.add_argument('--root',default='/private/tmp/mobilellm-opensandbox-dev')
    parser.add_argument('--rebuild',action='store_true')
    parser.add_argument('--remove-directory',action='store_true')
    args=parser.parse_args()
    if args.command != 'up' and not (Path(args.root)/'state.json').exists():
        parser.exit(0 if args.command == 'down' else 1, 'No owned environment exists at this path.\n')
    environment=Environment(args.root)
    if args.command=='up':environment.start(args.rebuild)
    elif args.command=='down':environment.down(args.remove_directory)
    else:print(json.dumps(environment.call('GET','/v1/workspaces'),indent=2))
