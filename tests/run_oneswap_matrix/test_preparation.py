import csv
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.lib = self.base / 'lib/ruby'
        (self.lib / 'cli/one_helper').mkdir(parents=True)
        (self.base / 'share/gems').mkdir(parents=True)
        (self.lib / 'command_parser.rb').write_text('')
        (self.lib / 'cli/one_helper/oneswap_helper.rb').write_text('''
class OneSwapHelper
  def connection_options(*); {}; end
  def get_objects(*); [OpenStruct.new('name' => 'source-vm', :obj => $test_vm)]; end
end
''')
        (self.lib / 'rbvmomi.rb').write_text('''
require 'ostruct'
module RbVmomi
  module VIM
    def self.connect(*)
      raise 'mock VMware connection error' if ENV['SCENARIO'] == 'error'
      OpenStruct.new
    end
  end
end
class TestVM
  def runtime
    caller_command = ARGV.first
    state = caller_command == 'wait-powered-off' || caller_command == 'state' ? 'poweredOff' : 'poweredOn'
    OpenStruct.new(:powerState => state)
  end
  def guest; OpenStruct.new(:toolsStatus => 'toolsOk', :toolsRunningStatus => 'guestToolsRunning'); end
  def snapshot
    return nil unless ENV['SCENARIO'] == 'snapshots'
    child = OpenStruct.new(:name => 'child-snapshot', :childSnapshotList => [])
    root = OpenStruct.new(:name => 'user-snapshot', :childSnapshotList => [child])
    OpenStruct.new(:rootSnapshotList => [root])
  end
end
$test_vm = TestVM.new
File.open(ENV.fetch('HELPER_CALLS'), 'a') { |f| f.puts ARGV.first }
''')
        self.bins = self.base / 'bin'
        self.bins.mkdir()
        for name, body in {
            'oneswap': 'echo convert >> "$MIGRATION_CALLS"\nsleep 0.2\n',
            'onetemplate': 'exit 0\n',
            'oneimage': 'exit 0\n',
        }.items():
            path = self.bins / name
            path.write_text('#!/bin/sh\n' + body)
            path.chmod(0o755)
        self.configs = self.base / 'configs'
        self.configs.mkdir()
        (self.configs / 'test.yaml').write_text('''# TEST_VM=source-vm
# TEST_ENV=Lab
# TEST_METHOD=delta
# TEST_TRANSFER=http
# TEST_STORAGE=local
---
vcenter: example.invalid
vuser: test
vpass: test
''')
        self.env = dict(os.environ, ONE_LOCATION=str(self.base),
                        RUBYLIB=str(self.lib), PATH=str(self.bins) + ':' + os.environ['PATH'],
                        HELPER_CALLS=str(self.base / 'helper-calls'),
                        MIGRATION_CALLS=str(self.base / 'migration-calls'),
                        LOG_ROOT=str(self.base / 'results'))

    def run_matrix(self, scenario):
        result = subprocess.run(['bash', str(ROOT / 'run_oneswap_matrix.sh'), str(self.configs)],
                                cwd=ROOT, env=dict(self.env, SCENARIO=scenario),
                                text=True, capture_output=True, timeout=20)
        output = result.stdout + result.stderr
        self.assertNotIn('already initialized constant', output)
        self.calls = (self.base / 'helper-calls').read_text().splitlines()
        run = next((self.base / 'results').iterdir())
        with (run / 'timings.csv').open() as stream:
            self.rows = list(csv.DictReader(stream))
        self.summary = (run / 'summary.log').read_text()
        return result, output

    def test_no_snapshots_continues_and_validates(self):
        result, output = self.run_matrix('clean')
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(self.calls[:3], ['snapshots', 'power-on', 'wait-tools-ready'])
        self.assertIn('source-vm: no snapshots', output)
        self.assertIn('source-vm: poweredOn, toolsOk, guestToolsRunning', output)
        self.assertTrue((self.base / 'migration-calls').exists())
        self.assertIn('state', self.calls)
        self.assertEqual(self.calls.count('snapshots'), 2)
        self.assertEqual(self.rows[0]['status'], 'PASS')

    def test_existing_snapshots_aborts_before_power_on(self):
        result, output = self.run_matrix('snapshots')
        self.assertEqual(result.returncode, 2, output)
        self.assertEqual(self.calls, ['snapshots'])
        self.assertFalse((self.base / 'migration-calls').exists())
        for text in ['ERROR: source-vm has existing VMware snapshots:',
                     'user-snapshot', 'child-snapshot', 'Test aborted before migration.']:
            self.assertIn(text, output)
        self.assert_preparation_failed()

    def test_helper_errors_remain_visible(self):
        result, output = self.run_matrix('error')
        self.assertEqual(result.returncode, 2, output)
        self.assertIn('VM helper failed: RuntimeError: mock VMware connection error', output)
        self.assertEqual(self.calls, ['snapshots'])
        self.assertFalse((self.base / 'migration-calls').exists())
        self.assert_preparation_failed()

    def assert_preparation_failed(self):
        self.assertEqual(len(self.rows), 1)
        row = self.rows[0]
        self.assertNotIn(None, row)
        self.assertEqual(row['status'], 'PREPARATION_FAILED')
        self.assertEqual(row['vm'], 'source-vm')
        self.assertEqual(row['environment'], 'Lab')
        self.assertEqual(row['exit_code'], '2')
        self.assertEqual(row['duration_seconds'], '')
        self.assertEqual(row['start_time'], '')
        self.assertIn('PREPARATION_FAILED', self.summary)


if __name__ == '__main__':
    unittest.main()
