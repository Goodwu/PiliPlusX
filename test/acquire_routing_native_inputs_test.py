"""Synthetic A/B fixtures; no native producer or acceptance authorization."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import acquire_routing_native_inputs as acquire
import verify_routing_native_inputs_test as fixtures
import verify_routing_native_inputs as gate


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.NativeInputTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.temp.cleanup)
        self.root = self.fixture.root
        self.output = self.root / 'private/native'
        self.receipt = {}
        self.archives = {}
        for label in ('jar', 'evidence'):
            path = self.root / (label + '-artifact.zip')
            with zipfile.ZipFile(path, 'w') as archive:
                if label == 'jar':
                    archive.write(self.fixture.jar, self.fixture.jar.name)
                else:
                    archive.write(self.fixture.manifest_file, 'manifest.json')
                    for file in self.fixture.evidence.iterdir():
                        archive.write(file, 'evidence/' + file.name)
            self.archives[label] = path
        self.ledger = self.fixture.accepted
        for label, spec in self.ledger['entries'][0]['acquisition'].items():
            spec['zipSha256'] = gate.file_digest(self.archives[label])
        self.metadata_mutation = lambda value: None
        self.job_mutation = lambda value: None
        self.transport = self.Transport(self)

    class Transport:
        def __init__(self, test):
            self.test = test
            self.calls = []
        def metadata(self, endpoint, root, label):
            self.calls.append(endpoint)
            spec = self.test.ledger['entries'][0]['acquisition'][label.split('-')[0]]
            if '/artifacts/' in endpoint:
                value = {'id': spec['artifactId'], 'name': spec['name'], 'expired': False, 'digest': 'sha256:' + spec['zipSha256'], 'size_in_bytes': self.test.archives[label.split('-')[0]].stat().st_size, 'created_at': '2026-10-12T00:01:00Z', 'workflow_run': {'id': 1, 'head_sha': '1' * 40}}
                self.test.metadata_mutation(value)
                return value
            job = {'id': 4, 'run_id': 1, 'run_attempt': 1, 'head_sha': '1' * 40, 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-12T00:00:00Z', 'completed_at': '2026-10-12T00:02:00Z'}
            self.test.job_mutation(job)
            return {'total_count': 1, 'jobs': [job]}
        def request(self, endpoint, destination):
            self.calls.append(endpoint)
            label = 'jar' if '/artifacts/2/' in endpoint else 'evidence'
            shutil.copyfile(self.test.archives[label], destination)
            return destination

    def run_gate(self, **kwargs):
        with patch.dict(os.environ, RUNNER_TEMP=str(self.root)), patch.object(gate.subprocess, 'run', side_effect=self.fixture.tool):
            acquire.acquire(self.output, self.ledger, self.fixture.consumer, self.receipt, github=self.transport, **kwargs)

    def reject(self, reason):
        with self.assertRaisesRegex(gate.GateError, reason):
            self.run_gate()
        self.assertFalse(self.receipt['nativeVerified'])

    def test_synthetic_two_artifact_flow_runs_gate_after_exact_downloads(self):
        self.run_gate()
        self.assertTrue(self.receipt['nativeVerified'])
        self.assertFalse(self.receipt['deviceVerified'])
        self.assertEqual(self.receipt['nativeGate']['nativeVerified'], True)
        self.assertEqual([x for x in self.transport.calls if x.endswith('/zip')], ['repos/Goodwu/native-build/actions/artifacts/2/zip', 'repos/Goodwu/native-build/actions/artifacts/3/zip'])

    def test_empty_selector_fails_before_API_and_staging(self):
        self.ledger['selectedManifestSha256'] = None
        self.reject('missing-accepted-native-input')
        self.assertEqual(self.transport.calls, [])
        self.assertFalse(self.output.exists())

    def test_missing_selector_field_is_not_latest_fallback(self):
        self.ledger.pop('selectedManifestSha256')
        self.reject('expected exactly')

    def test_wrong_artifact_metadata_id_name_digest_expired(self):
        for field, bad in (('id', 99), ('name', 'other-attempt'), ('digest', 'sha256:' + '9' * 64), ('expired', True)):
            with self.subTest(field=field):
                self.metadata_mutation = lambda m: m.update({field: bad})
                self.reject('artifact ID/name/expiry|ZIP digest')
                shutil.rmtree(self.output)

    def test_artifact_run_and_head_must_match_reviewed_producer(self):
        self.metadata_mutation = lambda m: m['workflow_run'].update(head_sha='9' * 40)
        self.reject('run/HEAD')

    def test_no_invented_attempt_from_artifact_metadata(self):
        self.job_mutation = lambda j: j.update(run_attempt=2)
        self.reject('attempt/run/HEAD/success')

    def test_upload_job_must_be_successful_exact_identity(self):
        for field, bad in (('id', 5), ('conclusion', 'failure'), ('status', 'in_progress'), ('head_sha', '9' * 40), ('run_id', 9)):
            with self.subTest(field=field):
                self.job_mutation = lambda j: j.update({field: bad})
                self.reject('upload job|upload-job')
                shutil.rmtree(self.output)

    def test_upload_job_window_cannot_bind_later_attempt_archive(self):
        self.metadata_mutation = lambda m: m.update(created_at='2026-10-12T00:03:00Z')
        self.reject('time window')

    def test_downloaded_zip_bytes_are_bound(self):
        with self.archives['jar'].open('ab') as stream:
            stream.write(b'changed after review')
        self.reject('size/hash')

    def rewrite_evidence_zip(self, extra):
        with zipfile.ZipFile(self.archives['evidence'], 'a') as archive:
            archive.writestr(*extra)
        self.ledger['entries'][0]['acquisition']['evidence']['zipSha256'] = gate.file_digest(self.archives['evidence'])

    def test_B_cannot_override_source_or_acceptance_ledger(self):
        source = self.root / 'untouched-source'
        source.write_bytes(b'original')
        self.rewrite_evidence_zip(('docs/plans/routing-native-accepted-inputs.json', b'forged'))
        self.reject('file layout')
        self.assertEqual(source.read_bytes(), b'original')

    def test_traversal_and_symlink_are_rejected_before_escape(self):
        self.rewrite_evidence_zip(('../outside', b'evil'))
        self.reject('unsafe relative')
        self.assertFalse((self.output / 'outside').exists())

    def test_dirty_output_is_not_cleaned_or_overwritten(self):
        self.output.mkdir(parents=True)
        saved = self.output / 'preserved'
        saved.write_bytes(b'original')
        self.reject('fresh child')
        self.assertEqual(saved.read_bytes(), b'original')

    def test_private_staging_cannot_escape_RUNNER_TEMP(self):
        self.output = self.root.parent / 'unapproved-native-stage'
        self.reject('fresh child')

    def test_API_permission_failure_keeps_failure_not_candidate(self):
        with patch.object(self.transport, 'metadata', side_effect=gate.GateError('HTTP 403 unavailable actions permission')):
            self.reject('HTTP 403')
        self.assertNotIn('jar', self.receipt)

    def test_acquisition_schema_A_B_IDs_must_be_distinct(self):
        self.ledger['entries'][0]['acquisition']['evidence']['artifactId'] = 2
        self.reject('distinct artifacts')

    def test_corrupt_extra_B_attachment_CRC_is_rejected(self):
        path = self.archives['evidence']
        self.rewrite_evidence_zip(('extra.txt', b'synthetic-extra'))
        with zipfile.ZipFile(path) as archive:
            info = archive.getinfo('extra.txt')
        import struct
        raw = bytearray(path.read_bytes())
        name_len, extra_len = struct.unpack_from('<HH', raw, info.header_offset + 26)
        raw[info.header_offset + 30 + name_len + extra_len] ^= 1
        path.write_bytes(raw)
        self.ledger['entries'][0]['acquisition']['evidence']['zipSha256'] = gate.file_digest(path)
        self.reject('CRC')

    def make_staging(self):
        staging=self.root/'staging';staging.mkdir()
        apk=staging/'PiliPlusX_routing_android_arm64-v8a.apk'
        with zipfile.ZipFile(apk,'w') as archive:
            for name,data in self.fixture.data.items():archive.writestr(name,data)
        consumer=self.fixture.consumer
        values={
          'native-after.json':{'status':'passed','nativeVerified':True,'consumer':consumer,'native':{'manifestSha256':self.ledger['selectedManifestSha256']}},
          'variant.json':{'status':'finalized','flavor':'android','appCommit':consumer['appCommit'],'mediaKitCommit':consumer['mediaKitCommit']},
          'bootstrap.json':{'status':'fresh-source-only','finalVector':{'app':consumer['appCommit'],'media-kit':consumer['mediaKitCommit']}},
        }
        for name,value in values.items():(staging/name).write_text(json.dumps(value))
        (staging/'apk-signature.log').write_text('synthetic signature fixture')
        (staging/'source.txt').write_text(f"pending-parity=true\napp={consumer['appCommit']}\nmedia-kit={consumer['mediaKitCommit']}\ndeviceVerified=false\n")
        return staging

    def test_final_staging_rechecks_approved_native_bytes(self):
        staging=self.make_staging();self.run_gate(staging=staging,flavor='android')
        self.assertTrue(self.receipt['nativeGate']['nativeVerified'])
        self.assertIn('apk',self.receipt['nativeGate'])

    def test_staging_cannot_supply_other_consumer_or_unfinalized_state(self):
        staging=self.make_staging()
        for filename,field,bad in (('native-after.json','consumer',{'appCommit':'9'*40,'mediaKitCommit':'b'*40}),('variant.json','status','prepared'),('bootstrap.json','status','prepared-source-only')):
            with self.subTest(file=filename):
                file=staging/filename;original=file.read_text();value=json.loads(original);value[field]=bad;file.write_text(json.dumps(value))
                with self.assertRaisesRegex(gate.GateError,'staging'):
                    self.run_gate(staging=staging,flavor='android')
                file.write_text(original)
        self.assertEqual(self.transport.calls,[])

    def test_staging_cannot_substitute_one_library_even_with_pass_receipt(self):
        staging=self.make_staging()
        with zipfile.ZipFile(staging/'PiliPlusX_routing_android_arm64-v8a.apk','w') as archive:
            for name,data in self.fixture.data.items():archive.writestr(name,data+(b'changed' if name==gate.MEMBERS[0] else b''))
        with self.assertRaisesRegex(gate.GateError,'APK native member differs'):
            self.run_gate(staging=staging,flavor='android')
        self.assertFalse(self.receipt['nativeVerified'])

    def test_legacy_empty_ledger_is_compatible_only_as_rejection(self):
        self.ledger={'schemaVersion':1,'task':gate.TASK,'entries':[]}
        self.reject('missing-accepted-native-input')
        self.assertEqual(self.transport.calls,[])

    def test_legacy_nonempty_ledger_without_selector_cannot_authorize(self):
        self.ledger.pop('selectedManifestSha256')
        self.reject('expected exactly')

    def test_GitHub_download_stream_limit_is_enforced_before_full_write(self):
        tools=self.root/'bin';tools.mkdir();gh=tools/'gh'
        gh.write_text('#!/bin/sh\npython3 -c "import sys;sys.stdout.buffer.write(b\'x\'*65536)"\n');gh.chmod(0o755)
        receipt={'commands':[]};destination=self.root/'limited-download'
        with patch.dict(os.environ,PATH=str(tools)+os.pathsep+os.environ['PATH']),self.assertRaisesRegex(gate.GateError,'streaming limit'):
            acquire.GitHub(receipt).request('synthetic-test',destination,limit=1024)
        self.assertLessEqual(destination.stat().st_size,1024)
        self.assertIsInstance(receipt['commands'][0]['exitCode'],int)

    def test_real_empty_ledger_cli_failure_receipt(self):
        receipt = self.root / 'cli-receipt.json'
        result = subprocess.run([sys.executable, str(Path(acquire.__file__)), '--output', str(self.output), '--receipt', str(receipt), '--app-commit', 'a' * 40, '--media-kit-commit', 'b' * 40], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        observed = json.loads(receipt.read_text())
        self.assertIn('missing-accepted-native-input', observed['reason'])
        self.assertEqual(observed['commands'], [])
        self.assertFalse(observed['nativeVerified'])


if __name__ == '__main__':
    unittest.main()
