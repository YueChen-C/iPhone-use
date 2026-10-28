"""Calibration contract tests using simulated movement and no physical device."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts' / 'calibrate-pointer.py'
SPEC = importlib.util.spec_from_file_location('calibrate_pointer', SCRIPT)
calibration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(calibration)


class SimulatedPointer:
    def __init__(self, diagonal_scale=1, vertical_scale=1, return_drift=0, gain=1):
        self.x = 400
        self.y = 400
        self.diagonal_scale = diagonal_scale
        self.vertical_scale = vertical_scale
        self.return_drift = return_drift
        self.gain = gain
        self.edge_hits = 0
        self.events = []

    def nudge(self, dx, dy):
        self.events.append(('nudge', dx, dy))
        scale = self.gain * (self.diagonal_scale if dx and dy else 1)
        x = self.x + dx * scale
        self.edge_hits += int(x >= 749)
        self.x = max(0, min(749, x))
        self.y = max(0, min(1333, self.y + dy * scale * self.vertical_scale))
        if dx < 0 and not dy:
            self.x += self.return_drift

    def position(self):
        self.events.append(('position',))
        return self.x, self.y


class PointerCalibrationTests(unittest.TestCase):
    device = {'id': 'phone-1', 'width': 750, 'height': 1334}

    def measure(self, pointer):
        runner = calibration.PointerCalibration(self.device, 'aa:bb:cc', pointer.nudge, pointer.position)
        with contextlib.redirect_stdout(io.StringIO()):
            return runner.measure()

    def test_full_measurement_sequence_and_profile(self):
        pointer = SimulatedPointer()
        profile = self.measure(pointer)
        self.assertEqual(profile, {
            'host': 'aa:bb:cc', 'screenID': 'phone-1', 'screenWidth': 750, 'screenHeight': 1334,
            'reportInterval': 0.03, 'distances': [float(count) for count in range(33)],
            'vectorModel': 'radialQuantized',
        })
        self.assertEqual(pointer.edge_hits, 0)

    def test_diagonal_mismatch_retains_valid_single_axis_profile(self):
        pointer = SimulatedPointer(diagonal_scale=2)
        profile = self.measure(pointer)
        self.assertNotIn('vectorModel', profile)
        self.assertEqual(profile['distances'], [float(count) for count in range(33)])
        # Verification must run all four diagonal cases even after a mismatch.
        self.assertEqual(pointer.events[-5:], [('nudge', -16, -16)] * 4 + [('position',)])

    def test_horizontal_return_drift_rejects_measurement(self):
        with self.assertRaisesRegex(RuntimeError, 'Nonrepeatable movement or screen edge reached'):
            self.measure(SimulatedPointer(return_drift=2))

    def test_vertical_mismatch_rejects_measurement(self):
        with self.assertRaisesRegex(RuntimeError, 'Vertical movement does not match the measured curve'):
            self.measure(SimulatedPointer(vertical_scale=2))

    def test_high_tracking_gain_no_longer_requires_changing_phone_settings(self):
        profile = self.measure(SimulatedPointer(gain=4.5))
        self.assertEqual(profile['distances'], [count * 4.5 for count in range(33)])
        self.assertEqual(profile['vectorModel'], 'radialQuantized')

    def test_clipped_bursts_retry_from_a_fresh_origin_and_do_not_bias_curve(self):
        pointer = SimulatedPointer(gain=7)
        profile = self.measure(pointer)
        self.assertGreater(pointer.edge_hits, 0)
        self.assertEqual(profile['distances'], [count * 7.0 for count in range(33)])

    def test_low_gain_uses_more_entry_reports_without_changing_phone_settings(self):
        profile = self.measure(SimulatedPointer(gain=.1))
        for count, distance in enumerate(profile['distances']):
            self.assertAlmostEqual(distance, count * .1)

    def test_missing_entry_movement_stops_before_curve_measurement(self):
        pointer = SimulatedPointer()
        pointer.position = Mock(return_value=(20, 96))
        with self.assertRaisesRegex(RuntimeError, 'Cannot find a repeatable sampling area'):
            self.measure(pointer)


class PointerMeasurementsTests(unittest.TestCase):
    def test_latest_timestamp_wins_and_position_preserves_observation_delay(self):
        measurements = calibration.PointerMeasurements()
        page = {'type': 'loaded', 'dpr': 2}
        measurements.record(page)
        self.assertIs(measurements.wait_for_page(), page)
        measurements.record({'type': 'move', 'x': 10, 'y': 20, 'time': 100})
        measurements.record({'type': 'move', 'x': 99, 'y': 99, 'time': 99})
        measurements.record({'type': 'move', 'x': 50, 'y': 50, 'time': 100})
        with patch.object(calibration.time, 'sleep') as sleep:
            self.assertEqual(measurements.position(2), (20, 40))
        sleep.assert_called_once_with(0.6)

    def test_missing_movement_and_page_timeout_keep_existing_errors(self):
        measurements = calibration.PointerMeasurements()
        with patch.object(calibration.time, 'sleep'), self.assertRaisesRegex(
                RuntimeError, 'Safari did not report pointer movement; calibration cannot continue.'):
            measurements.position(2)
        measurements.loaded = Mock()
        measurements.loaded.wait.return_value = False
        with self.assertRaisesRegex(RuntimeError, 'Timed out waiting for the test page.'):
            measurements.wait_for_page()
        measurements.loaded.wait.assert_called_once_with(180)


class CalibrationIOTests(unittest.TestCase):
    def test_api_selection_and_nudge_keep_urls_payload_and_timeouts(self):
        api = calibration.PhoneAPI('http://127.0.0.1:7390')
        devices = {'devices': [
            {'id': 'other', 'bluetooth': True}, {'id': 'selected', 'bluetooth': True},
        ]}
        with patch.object(calibration.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(devices).encode())) as request:
            self.assertEqual(api.select_device('selected'), devices['devices'][1])
            request.assert_called_once_with('http://127.0.0.1:7390/devices', timeout=5)
        response = Mock()
        with patch.object(calibration.urllib.request, 'urlopen', return_value=response) as request:
            api.nudge('selected', 12, -16)
            sent = request.call_args.args[0]
            self.assertEqual(sent.full_url, 'http://127.0.0.1:7390/nudge')
            self.assertEqual(sent.data, b'{"device": "selected", "dx": 12, "dy": -16}')
            self.assertEqual(request.call_args.kwargs, {'timeout': 15})
            response.read.assert_called_once_with()

    def test_save_replaces_host_profile_with_existing_json_format(self):
        profile = {'host': 'aa:bb', 'distances': [0.0, 1.0], 'reportInterval': 0.03}
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            calibration.save_profile(Path(directory), 'aa:bb', profile)
            destination = Path(directory) / 'pointer-calibration' / 'AA:BB.json'
            self.assertEqual(destination.read_text(), json.dumps(profile, indent=2) + '\n')
            self.assertFalse(destination.with_suffix('.tmp').exists())

    def test_latest_template_is_stable_across_bluetooth_identity_changes(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            first = {'host': 'old-host', 'screenID': 'phone-a', 'distances': [0, 1, 3]}
            latest = {'host': 'new-host', 'screenID': 'phone-a', 'distances': [0, 2, 5]}
            calibration.save_profile(root, 'old-host', first)
            calibration.save_profile(root, 'new-host', latest)
            template = root / 'pointer-calibration/by-screen/70686f6e652d61.json'
            self.assertEqual(json.loads(template.read_text()), latest)
            self.assertEqual(json.loads((root / 'pointer-calibration/OLD-HOST.json').read_text()), first)
            self.assertFalse(template.with_suffix('.tmp').exists())


class AutomaticCalibrationTests(unittest.TestCase):
    device = {'id': 'phone-a', 'width': 750, 'height': 1334}

    def test_auto_navigation_replaces_the_entire_safari_address(self):
        api = calibration.PhoneAPI('http://127.0.0.1:7390')
        with patch.object(api, 'post') as post, patch.object(calibration.time, 'sleep'):
            api.open_safari('phone-a', 'http://192.0.2.1:7391/token')
        from unittest.mock import call
        self.assertEqual(post.call_args_list[-4:], [
            call('/key', 'phone-a', key='l', modifiers=['cmd']),
            call('/key', 'phone-a', key='a', modifiers=['cmd']),
            call('/type', 'phone-a', text='http://192.0.2.1:7391/token'),
            call('/key', 'phone-a', key='enter'),
        ])

    def test_mapping_verification_accepts_browser_offsets_and_rejects_wrong_gain(self):
        api = Mock()
        # Physical screen positions minus a fixed browser chrome offset.
        observed = [(225, 433.6), (450, 700.4), (300, 567)]
        self.assertTrue(calibration.verify_mapping(api, self.device, Mock(side_effect=observed)))
        api.nudge.assert_called_once_with('phone-a', 1, 0)
        self.assertEqual(api.post.call_count, 3)
        api.post.assert_any_call('/move', 'phone-a', x=0.6, y=0.6, fraction=True)
        for incorrect in [[(0, 0)] * 3, [(x * .8, y * .8) for x, y in observed],
                          [(225, 433.6), (float('nan'), 700.4), (300, 567)]]:
            self.assertFalse(calibration.verify_mapping(api, self.device, Mock(side_effect=incorrect)))

    def test_missing_mapping_can_measure_but_busy_pointer_is_not_interrupted(self):
        api = Mock()
        api.post.side_effect = calibration.urllib.error.HTTPError('http://local/move', 503, 'unavailable', {}, None)
        self.assertFalse(calibration.verify_mapping(api, self.device, Mock()))
        api.post.side_effect = calibration.urllib.error.HTTPError('http://local/move', 409, 'busy', {}, None)
        with self.assertRaises(calibration.urllib.error.HTTPError):
            calibration.verify_mapping(api, self.device, Mock())
        api.post.side_effect = None
        self.assertFalse(calibration.verify_mapping(api, self.device, Mock(side_effect=RuntimeError('no movement'))))

    def test_verified_auto_mapping_does_not_measure_or_replace_saved_profile(self):
        args = SimpleNamespace(auto=True, force=False, listen_port=7391)
        api, measurements = Mock(), Mock()
        measurements.wait_for_page.return_value = {'dpr': 2, 'screenWidth': 375, 'screenHeight': 667}
        with patch.object(calibration, 'verify_mapping', return_value=True), \
                patch.object(calibration, 'PointerCalibration') as measure, \
                patch.object(calibration, 'save_profile') as save, contextlib.redirect_stdout(io.StringIO()):
            calibration.run_calibration(args, api, self.device, Path('/unused'), 'host', measurements, '192.0.2.2', '/token')
        api.open_safari.assert_called_once_with('phone-a', 'http://192.0.2.2:7391/token')
        measure.assert_not_called()
        save.assert_not_called()

    def test_failed_verification_measures_before_saving_and_preserves_failures(self):
        args = SimpleNamespace(auto=True, force=False, listen_port=7391)
        api, measurements = Mock(), Mock()
        measurements.wait_for_page.return_value = {'dpr': 2, 'screenWidth': 375, 'screenHeight': 667}
        with patch.object(calibration, 'verify_mapping', return_value=False), \
                patch.object(calibration, 'PointerCalibration') as measure, \
                patch.object(calibration, 'baseline_profile', return_value=None), \
                patch.object(calibration, 'apply_verified_profile', return_value=True) as apply, contextlib.redirect_stdout(io.StringIO()):
            measure.return_value.measure.side_effect = RuntimeError('unreliable curve')
            with self.assertRaisesRegex(RuntimeError, 'unreliable curve'):
                calibration.run_calibration(args, api, self.device, Path('/unused'), 'host', measurements, '192.0.2.2', '/token')
            apply.assert_not_called()
            measure.return_value.measure.side_effect = None
            measure.return_value.measure.return_value = {'distances': [0, 1, 3]}
            calibration.run_calibration(args, api, self.device, Path('/unused'), 'host', measurements, '192.0.2.2', '/token')
            self.assertEqual(apply.call_args.args[1:5], (self.device, Path('/unused'), 'host', {'distances': [0, 1, 3]}))

    def test_baseline_rebinds_identity_but_never_scales_different_resolutions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'baseline.json'
            path.write_text(json.dumps({'reference': {'screenWidth': 750, 'screenHeight': 1334},
                                       'host': 'old-host', 'screenID': 'old-phone',
                                       'distances': [0, 1, 8], 'reportInterval': .03}))
            profile = calibration.baseline_profile(path, self.device, 'new-host')
            self.assertEqual(profile['host'], 'new-host')
            self.assertEqual(profile['screenID'], 'phone-a')
            self.assertEqual(profile['distances'], [0, 1, 8])
            self.assertIsNone(calibration.baseline_profile(path, dict(self.device, width=1080), 'new-host'))
            source = json.loads(path.read_text())
            source['distances'] = [0, 4, 2]
            path.write_text(json.dumps(source))
            with self.assertRaisesRegex(RuntimeError, 'Invalid pointer baseline'):
                calibration.baseline_profile(path, self.device, 'new-host')

    def test_failed_candidate_restores_both_files_and_live_input(self):
        api = Mock()
        profile = {'host': 'new', 'screenID': 'phone-a', 'distances': [0, 1, 3]}
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            calibration.save_profile(root, 'new', dict(profile, distances=[0, 2, 5]))
            paths = list((root / 'pointer-calibration').rglob('*.json'))
            before = {path: path.read_bytes() for path in paths}
            with patch.object(calibration, 'verify_mapping', return_value=False):
                self.assertFalse(calibration.apply_verified_profile(api, self.device, root, 'new', profile, Mock()))
            self.assertEqual({path: path.read_bytes() for path in paths}, before)
            self.assertEqual(api.post.call_count, 2)  # load candidate, then restore old input
            api.post.assert_called_with('/calibration/reload', 'phone-a')

    def test_failed_first_candidate_leaves_no_unverified_profile(self):
        api = Mock()
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()), \
                patch.object(calibration, 'verify_mapping', side_effect=RuntimeError('connection lost')):
            root = Path(directory)
            with self.assertRaisesRegex(RuntimeError, 'connection lost'):
                calibration.apply_verified_profile(api, self.device, root, 'new',
                    {'host': 'new', 'screenID': 'phone-a', 'distances': [0, 1, 3]}, Mock())
            self.assertEqual(list(root.rglob('*.json')), [])

    def test_successful_baseline_reuse_skips_measurement(self):
        api, measurements = Mock(), Mock()
        measurements.wait_for_page.return_value = {'dpr': 2, 'screenWidth': 375, 'screenHeight': 667}
        args = SimpleNamespace(auto=True, force=False, listen_port=7391, baseline=Path('/baseline.json'))
        with patch.object(calibration, 'verify_mapping', return_value=False), \
                patch.object(calibration, 'baseline_profile', return_value={'distances': [0, 1, 3]}), \
                patch.object(calibration, 'apply_verified_profile', return_value=True), \
                patch.object(calibration, 'PointerCalibration') as measure, contextlib.redirect_stdout(io.StringIO()):
            calibration.run_calibration(args, api, self.device, Path('/unused'), 'host', measurements, '192.0.2.2', '/token')
            measure.assert_not_called()

    def test_local_measurement_holds_the_same_service_and_device_locks_as_mcp(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(calibration.os.environ, IPHONE_USE_STATE_DIR=directory):
            with calibration.calibration_access('http://127.0.0.1:7390', 'PHONE-A'):
                path = Path(directory) / 'device-7390-70686f6e652d61.lock'
                with path.open('a') as competing:
                    with self.assertRaises(BlockingIOError):
                        calibration.fcntl.flock(competing, calibration.fcntl.LOCK_EX | calibration.fcntl.LOCK_NB)
                self.assertTrue((Path(directory) / 'service-7390.lock').exists())
            with path.open('a') as released:
                calibration.fcntl.flock(released, calibration.fcntl.LOCK_EX | calibration.fcntl.LOCK_NB)


if __name__ == '__main__':
    unittest.main()
