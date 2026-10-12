"""Tests of pack tools and fixtures only. These are not Jackage product tests."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE / "tools"))
import delivery
from oracle import canonical_bytes, parse_canonical_input, portable_path, digest


class CanonicalOracleTests(unittest.TestCase):
    def test_object_order(self):
        self.assertEqual(canonical_bytes({"z":1,"a":2}), b'{"a":2,"z":1}')

    def test_array_order(self):
        self.assertNotEqual(digest("action",[1,2]),digest("action",[2,1]))

    def test_domain_prefix_contains_nul(self):
        expected = hashlib.sha256(b'jckg:action:v1\0{"a":1}').hexdigest()
        self.assertEqual(digest("action",{"a":1}),"sha256:"+expected)
        self.assertNotEqual(digest("action",{}),digest("tree",{}))

    def test_unicode_is_not_normalized(self):
        self.assertNotEqual(canonical_bytes("é"),canonical_bytes("e\u0301"))

    def test_surrogate_rejected(self):
        with self.assertRaises(UnicodeError):
            canonical_bytes("\ud800")

    def test_float_rejected(self):
        for n in [1.0, float("nan"),float("inf"),-0.0]:
            with self.subTest(value=n), self.assertRaises(ValueError):
                canonical_bytes(n)

    def test_integer_bounds(self):
        self.assertEqual(canonical_bytes(9007199254740991),b'9007199254740991')
        for n in [-9007199254740992,9007199254740992]:
            with self.subTest(value=n), self.assertRaises(ValueError):
                canonical_bytes(n)

    def test_bool_not_integer(self):
        self.assertEqual(canonical_bytes([True,False]),b'[true,false]')

    def test_nonstring_object_key_rejected(self):
        with self.assertRaises(ValueError):
            canonical_bytes({1:"x"})

    def test_invalid_json_fixtures(self):
        for v in delivery.load(SOURCE/"fixtures/invalid-canonical-json.json")["vectors"]:
            with self.subTest(reason=v["reason"]),self.assertRaises((ValueError,UnicodeError)):
                parse_canonical_input(v["text"])

    def test_golden_vectors(self):
        for v in delivery.load(SOURCE/"fixtures/canonical-vectors.json")["vectors"]:
            with self.subTest(vector=v["id"]):
                self.assertEqual(canonical_bytes(v["value"]).hex(),v["canonicalUtf8Hex"])
                for d in ["action","tree","plan"]:
                    self.assertEqual(digest(d,v["value"]),v[d+"Digest"])

    def test_blob_vectors(self):
        for v in delivery.load(SOURCE/"fixtures/blob-vectors.json")["vectors"]:
            b=bytes.fromhex(v["bytesHex"])
            self.assertEqual(len(b),v["size"])
            self.assertEqual("sha256:"+hashlib.sha256(b).hexdigest(),v["digest"])

    def test_path_vectors(self):
        for v in delivery.load(SOURCE/"fixtures/portable-path-vectors.json")["vectors"]:
            with self.subTest(path=v["path"]):
                self.assertEqual(portable_path(v["path"]),v["valid"])

    def test_unknown_domain_rejected(self):
        with self.assertRaises(ValueError):
            digest("unknown",{})


class PackTests(unittest.TestCase):
    def test_validate_catalog(self):
        r=delivery.validate_kit(SOURCE)
        self.assertEqual(r["cases"],188)
        self.assertEqual(r["milestones"],18)
        self.assertFalse(r["productTestsExecuted"])

    def test_manifest_excludes_existing_product_paths(self):
        # After extraction, those product files are expected to exist in the repo.
        # Inspect the pack manifest, not the surrounding checkout's contents.
        entries = [line.split("  ", 1)[1] for line in
                   (SOURCE / "MANIFEST.sha256").read_text(encoding="utf-8").splitlines()]
        for name in ['build.zig','build.zig.zon','.zigversion','src','scripts','tools','.omp','AGENTS.md','.gitignore']:
            self.assertFalse(any(p == name or p.startswith(name + "/") for p in entries), name)

    def test_native_roles_are_not_relabelable(self):
        self.assertFalse(delivery.role_is_native("host","linux-x86_64"))
        self.assertTrue(delivery.role_is_native("host","windows-aarch64"))
        self.assertFalse(delivery.role_is_native("windows-aarch64","windows-x86_64"))
        self.assertTrue(delivery.role_is_native("portable","linux-x86_64"))

    def test_evidence_path_escape_rejected(self):
        for name in ['../escape','/tmp/escape','C:/escape','a/../../escape',r'a\..\escape','a//b']:
            with self.subTest(path=name),self.assertRaises(ValueError):
                delivery.inside(SOURCE,name)

    def test_timestamp_timezone_required(self):
        with self.assertRaises(ValueError):
            delivery.timestamp('2026-10-11T12:00:00')


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='jackage-kit-test-')
        self.root=Path(self.temp.name)
        self.kit=self.root/'kit'
        shutil.copytree(SOURCE,self.kit,ignore=shutil.ignore_patterns('__pycache__','*.pyc','state'))
        self.cwd=self.root/'project'
        self.cwd.mkdir()
        self.probe=self.cwd/'probe.py'
        self.command=[sys.executable,str(self.probe)]
        self.case=delivery.catalog(self.kit)[0]['CAN-001']

    def tearDown(self):
        self.temp.cleanup()

    def run_stage(self,stage,code,marker='ASSERTION',**kwargs):
        self.probe.write_text("print("+repr(marker)+", flush=True)\nraise SystemExit("+str(code)+")\n")
        return delivery.record_run(self.kit,'CAN-001',stage,'canonical-order',marker,
                                   self.command,self.cwd,**kwargs)

    def bundle(self,fault=False):
        records=[]
        if fault:
            records.append(self.run_stage('characterize',0))
        records.append(self.run_stage('fault' if fault else 'red',1))
        records.append(self.run_stage('green',0))
        records.append(self.run_stage('regression',0))
        return records

    def test_initial_status_is_incomplete(self):
        r=delivery.status(self.kit)
        self.assertEqual(r['completedCases'],0)
        self.assertEqual([m['id'] for m in r['milestones'] if m['ready']],['M00'])

    def test_red_requires_failure(self):
        r=self.run_stage('red',0)
        self.assertFalse(r['acceptedObservation'])

    def test_green_requires_success(self):
        r=self.run_stage('green',1)
        self.assertFalse(r['acceptedObservation'])

    def test_marker_required_in_real_output(self):
        self.probe.write_text("print('not a test marker')\n")
        r=delivery.record_run(self.kit,'CAN-001','green','t','TEST_RAN',self.command,self.cwd)
        self.assertFalse(r['acceptedObservation'])

    def test_real_bundle_needs_review(self):
        self.bundle()
        ok,why=delivery.case_complete(self.kit,self.case)
        self.assertFalse(ok)
        self.assertIn('review',why)

    def test_reviewed_bundle_completes_local_structure(self):
        self.bundle()
        delivery.review_case(self.kit,'CAN-001','kit-test-reviewer','Synthetic tool test only.')
        self.assertTrue(delivery.case_complete(self.kit,self.case)[0])

    def test_characterization_route(self):
        self.bundle(fault=True)
        delivery.review_case(self.kit,'CAN-001','kit-test-reviewer','Characterization tool test only.')
        self.assertTrue(delivery.case_complete(self.kit,self.case)[0])

    def test_fault_without_characterization_rejected(self):
        self.run_stage('fault',1)
        self.run_stage('green',0)
        self.run_stage('regression',0)
        with self.assertRaises(ValueError):
            delivery.review_case(self.kit,'CAN-001','reviewer','note')

    def test_review_without_regression_rejected(self):
        self.run_stage('red',1)
        self.run_stage('green',0)
        with self.assertRaises(ValueError):
            delivery.review_case(self.kit,'CAN-001','reviewer','note')

    def test_tampered_log_rejected(self):
        records=self.bundle()
        delivery.review_case(self.kit,'CAN-001','reviewer','note')
        delivery.inside(self.kit,records[1]['logPath']).write_text('modified ASSERTION')
        self.assertFalse(delivery.case_complete(self.kit,self.case)[0])

    def test_changed_case_invalidates_evidence(self):
        self.bundle()
        delivery.review_case(self.kit,'CAN-001','reviewer','note')
        changed=dict(self.case,title='Changed required behavior')
        self.assertFalse(delivery.case_complete(self.kit,changed)[0])

    def test_new_failure_invalidates_old_review(self):
        self.bundle()
        delivery.review_case(self.kit,'CAN-001','reviewer','note')
        self.run_stage('green',1)
        self.assertFalse(delivery.case_complete(self.kit,self.case)[0])

    def test_red_green_command_mismatch_rejected(self):
        self.run_stage('red',1)
        self.command=[sys.executable,'-u',str(self.probe)]
        self.run_stage('green',0)
        self.run_stage('regression',0)
        with self.assertRaises(ValueError):
            delivery.review_case(self.kit,'CAN-001','reviewer','note')

    def test_missing_executable_is_infrastructure(self):
        r=delivery.record_run(self.kit,'CAN-001','red','t','ASSERTION',
                              ['jackage-kit-nonexistent-command-97a45'],self.cwd)
        self.assertFalse(r['acceptedObservation'])
        self.assertIsNotNone(r['infrastructureFailure'])

    def test_timeout_is_not_red(self):
        self.probe.write_text("import time\nprint('ASSERTION',flush=True)\ntime.sleep(3)\n")
        r=delivery.record_run(self.kit,'CAN-001','red','t','ASSERTION',self.command,self.cwd,timeout=0.1)
        self.assertFalse(r['acceptedObservation'])
        self.assertEqual(r['infrastructureFailure'],'timeout')

    def test_log_budget_is_not_green(self):
        self.probe.write_text("print('ASSERTION'+'x'*10000)\n")
        r=delivery.record_run(self.kit,'CAN-001','green','t','ASSERTION',self.command,self.cwd,max_log_bytes=256)
        self.assertFalse(r['acceptedObservation'])
        self.assertEqual(r['infrastructureFailure'],'log-limit')

    def test_wrong_platform_rejected(self):
        target='PLAT-002' if delivery.native_target()!='windows-aarch64' else 'PLAT-003'
        with self.assertRaises(ValueError):
            delivery.record_run(self.kit,target,'green','t','ASSERTION',self.command,self.cwd)

    def test_record_mutation_invalidates_review(self):
        records=self.bundle()
        delivery.review_case(self.kit,'CAN-001','reviewer','note')
        p=self.kit/'state/evidence'/(records[0]['id']+'.json')
        r=delivery.load(p)
        r['note']='Altered record after review.'
        p.write_text(json.dumps(r))
        self.assertFalse(delivery.case_complete(self.kit,self.case)[0])

    def test_duplicate_case_catalog_rejected(self):
        p=self.kit/'acceptance/cases.json'
        v=delivery.load(p)
        v['cases'].append(v['cases'][0])
        p.write_text(json.dumps(v))
        with self.assertRaises(ValueError):
            delivery.validate_kit(self.kit)

    def test_milestone_cycle_rejected(self):
        p=self.kit/'acceptance/milestones.json'
        v=delivery.load(p)
        v['milestones'][0]['dependsOn']=['M17']
        p.write_text(json.dumps(v))
        with self.assertRaises(ValueError):
            delivery.validate_kit(self.kit)

    def test_unknown_case_cannot_record(self):
        with self.assertRaises(ValueError):
            delivery.record_run(self.kit,'UNKNOWN','green','t','ASSERTION',self.command,self.cwd)

    def test_review_needs_name_and_note(self):
        self.bundle()
        with self.assertRaises(ValueError):
            delivery.review_case(self.kit,'CAN-001','','note')
        with self.assertRaises(ValueError):
            delivery.review_case(self.kit,'CAN-001','reviewer','')


if __name__=='__main__':
    unittest.main()
