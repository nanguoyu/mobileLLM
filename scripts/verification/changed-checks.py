#!/usr/bin/env python3
"""Select existing checks from changed paths; no model, simulator, or network calls."""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = {p.parent.name: p for p in (ROOT / 'Packages').glob('*/Package.swift')}
PORTABLE = {'AgentContracts', 'AgentSandboxAPI', 'AgentHarnessVerification'}
ENGINES = {'LLMEngineMLX', 'LLMEngineLlama'}

def select(paths, all_checks=False):
    changed = set()
    for path in paths:
        parts = Path(path).parts
        if len(parts) > 2 and parts[0] == 'Packages' and parts[1] in PACKAGES:
            if path.endswith(('.swift', '.resolved', '.h', '.c', '.cpp', '.metal')):
                changed.add(parts[1])
    affected = set(changed)
    while True:
        previous = set(affected)
        for name, manifest in PACKAGES.items():
            deps = set(re.findall(r'\.package\(path:\s*"\.\./([^"/]+)"', manifest.read_text()))
            if deps & affected:
                affected.add(name)
        if previous == affected:
            break
    verifier = all_checks or bool(affected) or any(
        p == 'spec.md' or p.startswith(('Verification/', 'Tools/AgentHarnessVerification/', 'scripts/verification/'))
        or (p.startswith('App/') and p.endswith('.swift')) for p in paths)
    if verifier:
        affected.add('AgentHarnessVerification')
    if all_checks:
        affected.update(PACKAGES)
    app = all_checks or bool(affected - {'AgentSandboxAPI', 'AgentHarnessVerification'}) or any(
        p == 'project.yml' or p.startswith(('App/', 'AppUnitTests/', 'UITests/', 'DeviceUITests/')) for p in paths)
    return {
        'packages': sorted(affected - ENGINES),
        'engineBuilds': sorted(affected & ENGINES),
        'static': verifier,
        'portable': bool(affected & PORTABLE),
        'apple': app,
        'documents': bool(paths) or all_checks,
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-ref', default='origin/main')
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--paths', nargs='*', help='Classify explicit paths without reading git differences')
    parser.add_argument('--github-output', action='store_true')
    args = parser.parse_args()
    if args.paths is not None:
        paths = args.paths
    elif args.all:
        paths = []
    else:
        base = subprocess.check_output(['git', 'merge-base', args.base_ref, 'HEAD'], cwd=ROOT, text=True).strip()
        tracked = subprocess.check_output(['git', 'diff', '--name-only', '-z', base, '--'], cwd=ROOT)
        untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=ROOT)
        paths = [p.decode('utf-8') for p in (tracked + untracked).split(b'\0') if p]
    result = select(paths, args.all)
    if args.github_output:
        for key in ('portable', 'apple', 'documents', 'static'):
            print(f'{key}={str(result[key]).lower()}')
    else:
        print(json.dumps(result, indent=2))

if __name__ == '__main__':
    main()
