import contextlib
import io
import json
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch
from subprocess import CompletedProcess

SCRIPT = Path(__file__).resolve().parents[2] / 'script/website_deploy_needed.py'


class DeploymentChangesTests(unittest.TestCase):
    def check(self, responses, diff_status=0):
        output = io.StringIO()
        with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'example/site', 'GITHUB_SHA': 'new'}), \
             patch('subprocess.check_output', side_effect=[json.dumps(r) for r in responses]), \
             patch('subprocess.run', return_value=CompletedProcess([], diff_status)) as diff, \
             contextlib.redirect_stdout(output):
            runpy.run_path(str(SCRIPT))
        return output.getvalue().strip(), diff

    def test_first_deployment_publishes(self):
        output, diff = self.check([[]])
        self.assertEqual(output, 'changed=true')
        diff.assert_not_called()

    def test_app_only_changes_skip_deployment(self):
        output, diff = self.check([[{'id': 1, 'sha': 'old'}], [{'state': 'success'}]])
        self.assertEqual(output, 'changed=false')
        self.assertEqual(diff.call_args.args[0][3:5], ['old', 'new'])

    def test_failed_and_running_deployments_do_not_hide_website_changes(self):
        output, diff = self.check([
            [{'id': 3, 'sha': 'running'}, {'id': 2, 'sha': 'failed'}, {'id': 1, 'sha': 'old'}],
            [{'state': 'in_progress'}], [{'state': 'failure'}], [{'state': 'success'}],
        ], 1)
        self.assertEqual(output, 'changed=true')
        self.assertEqual(diff.call_args.args[0][3:5], ['old', 'new'])

    def test_unknown_baseline_never_silently_skips(self):
        with self.assertRaises(SystemExit):
            self.check([[{'id': 1, 'sha': 'missing'}], [{'state': 'success'}]], 128)


if __name__ == '__main__':
    unittest.main()
