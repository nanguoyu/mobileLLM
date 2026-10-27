#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Ownership checks for the destructive development-environment cleanup."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('opensandbox_dev', Path(__file__).parents[1] / 'opensandbox-dev.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CleanupOwnershipTests(unittest.TestCase):
    def environment(self, history, cache):
        env = module.Environment.__new__(module.Environment)
        env.state = {}
        env.save = lambda: None
        env.commands = []
        def run(command, **kwargs):
            env.commands.append(command)
            if command[2:4] == ['history', 'ls']:
                return '\n'.join(json.dumps(row) for row in history)
            if command[2] == 'du':
                return '\n'.join(json.dumps(row) if command[-1] == '{{json .}}' else row['ID'] for row in cache)
            return ''
        env.run = run
        return env

    def test_tracks_final_leaves_and_context_but_preserves_preexisting_cache(self):
        history = [{'ref':'default/default/ownedbuild', 'created_at':'2026-10-27T01:00:00Z',
                    'completed_at':'2026-10-27T01:00:02Z'}]
        cache = [{'ID':value, 'CreatedAt':'2026-10-27 01:00:01 +0000 UTC'} for value in
                 ['guestlayer00', 'workdirleaf0', 'localcontext', 'preexisting0']]
        cache.append({'ID':'laterforeign', 'CreatedAt':'2026-10-27 01:00:03 +0000 UTC'})
        env = self.environment(history, cache)
        with tempfile.TemporaryDirectory(prefix='mobilellm-cache-test-') as folder:
            metadata = Path(folder) / 'metadata.json'
            metadata.write_text(json.dumps({'buildx.build.ref':history[0]['ref']}))
            env.record_build_cache({'preexisting0'}, metadata)
        self.assertEqual(env.state['ownedBuildCache'], ['guestlayer00','localcontext','workdirleaf0'])
        self.assertEqual(env.state['ownedBuildHistoryRefs'], ['default/default/ownedbuild'])

    def test_concurrent_build_is_never_adopted_by_time_alone(self):
        history = [{'ref':'default/default/ownedbuild', 'created_at':'2026-10-27T01:00:00Z',
                    'completed_at':'2026-10-27T01:00:02Z'},
                   {'ref':'default/default/foreign', 'created_at':'2026-10-27T00:59:59Z'}]
        env = self.environment(history, [{'ID':'foreigncache', 'CreatedAt':'2026-10-27 01:00:01 +0000 UTC'}])
        with tempfile.TemporaryDirectory(prefix='mobilellm-cache-test-') as folder:
            metadata = Path(folder) / 'metadata.json'
            metadata.write_text(json.dumps({'buildx.build.ref':history[0]['ref']}))
            env.record_build_cache(set(), metadata)
        self.assertNotIn('ownedBuildCache', env.state)
        self.assertTrue(env.state['cacheTrackingWarnings'])

    def test_prune_uses_one_exact_union_and_checks_actual_remaining_records(self):
        env = self.environment([{'ref':'default/default/ownedbuild'}, {'ref':'default/default/foreign'}],
                               [{'ID':'workdirleaf0'}, {'ID':'foreigncache'}])
        env.state = {'ownedBuildCache':['guestlayer00','workdirleaf0'],
                     'ownedBuildHistoryRefs':['default/default/ownedbuild']}
        errors = env.clean_build_cache()
        self.assertEqual(errors, ['Build cache retained: workdirleaf0'])
        self.assertIn(['docker','buildx','prune','--all','--force','--filter',
                       'id~=^(guestlayer00|workdirleaf0)$'], env.commands)
        self.assertIn(['docker','buildx','history','rm','ownedbuild'], env.commands)
        self.assertNotIn(['docker','buildx','history','rm','foreign'], env.commands)

    def test_invalid_identity_cannot_widen_the_prune_filter(self):
        env = self.environment([], [])
        env.state = {'ownedBuildCache':['.*']}
        with self.assertRaisesRegex(RuntimeError, 'Invalid owned'):
            env.clean_build_cache()
        self.assertFalse(any(command[2] == 'prune' for command in env.commands))


if __name__ == '__main__':
    unittest.main()
