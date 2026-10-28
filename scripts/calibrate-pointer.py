#!/usr/bin/env python3
"""Measure relative HID acceleration using Safari mouse events. Python stdlib only.

Run with iphone-use already running. --auto opens Safari and checks whether the
current mapping can be reused before measuring a new curve. Without --auto,
open the printed URL on the paired iPhone. Keep the phone and Mac mouse still.
Measurement sends movement, never clicks.
Keep the same iOS tracking-speed settings after calibration. Verified profiles
are loaded without restarting Bluetooth. Positioning remains approximate.
"""
import argparse
import contextlib
import fcntl
import json
import math
import os
import secrets
import socket
import threading
import time
import urllib.request
import urllib.error
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CALIBRATION_PAGE = b'''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>body{margin:0;background:#162233;color:white;font:20px system-ui;overflow:hidden;touch-action:none}p{padding:30px}</style>
<p>Pointer calibration. Keep the phone and Mac mouse still until the terminal finishes.</p>
<script>
const send=v=>fetch(location.pathname,{method:'POST',body:JSON.stringify(v)}).catch(()=>{});
send({type:'loaded',screenWidth:screen.width,screenHeight:screen.height,dpr:devicePixelRatio});
let latest=null;document.addEventListener('mousemove',e=>latest={type:'move',x:e.clientX,y:e.clientY,time:Date.now()});
setInterval(()=>{if(latest){send(latest);latest=null}},50);
</script>'''


class PhoneAPI:
    """The existing local API contract used by the calibration tool."""

    def __init__(self, base_url):
        self.base_url = base_url

    def select_device(self, device_id):
        devices = json.load(urllib.request.urlopen(self.base_url + '/devices', timeout=5))['devices']
        selected = [device for device in devices if device_id is None or device['id'] == device_id]
        if len(selected) != 1 or not selected[0].get('bluetooth'):
            raise RuntimeError('Select exactly one paired phone with --device.')
        return selected[0]

    def nudge(self, device_id, x, y):
        body = json.dumps({'device': device_id, 'dx': x, 'dy': y}).encode()
        urllib.request.urlopen(urllib.request.Request(self.base_url + '/nudge', body), timeout=15).read()

    def post(self, route, device_id, **arguments):
        body = json.dumps(dict(device=device_id, **arguments)).encode()
        urllib.request.urlopen(urllib.request.Request(self.base_url + route, body), timeout=15).read()

    def open_safari(self, device_id, url):
        # Global search works independently of the foreground app. Page load is
        # confirmed by the token-specific callback, not by assuming Enter worked.
        self.post('/key', device_id, key='space', modifiers=['cmd'])
        time.sleep(0.5)
        self.post('/key', device_id, key='a', modifiers=['cmd'])
        self.post('/type', device_id, text='Safari')
        time.sleep(0.7)
        self.post('/key', device_id, key='enter')
        time.sleep(0.7)
        # A composing IME consumes the first Enter. If Safari already opened,
        # focus its address bar before the second Enter instead of submitting
        # whatever form had focus in the previously displayed page.
        self.post('/key', device_id, key='l', modifiers=['cmd'])
        self.post('/key', device_id, key='enter')
        time.sleep(1)
        self.post('/key', device_id, key='l', modifiers=['cmd'])
        time.sleep(0.3)
        self.post('/key', device_id, key='a', modifiers=['cmd'])
        self.post('/type', device_id, text=url)
        self.post('/key', device_id, key='enter')


class PointerMeasurements:
    """Shares Safari observations between HTTP threads and the measurement loop."""

    def __init__(self):
        self.lock = threading.Lock()
        self.state = {}
        self.loaded = threading.Event()

    def record(self, value):
        with self.lock:
            if value.get('type') == 'loaded':
                self.state['page'] = value
                self.loaded.set()
            elif value.get('type') == 'move' and value.get('time', 0) > self.state.get('move', {}).get('time', 0):
                self.state['move'] = value

    def wait_for_page(self, timeout=180):
        if not self.loaded.wait(timeout):
            raise RuntimeError('Timed out waiting for the test page.')
        return self.state['page']

    def position(self, dpr):
        # Let HID notifications and page observations arrive; events can arrive
        # out of order, so the server retains the largest page event timestamp.
        time.sleep(0.6)
        with self.lock:
            value = self.state.get('move')
            if not value:
                raise RuntimeError('Safari did not report pointer movement; calibration cannot continue.')
            return (value['x'] * dpr, value['y'] * dpr)


class CalibrationRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != self.server.token:
            self.send_error(404)
            return
        body = CALIBRATION_PAGE
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != self.server.token:
            self.send_error(404)
            return
        try:
            value = json.loads(self.rfile.read(min(4096, int(self.headers.get('Content-Length', 0)))))
            self.server.measurements.record(value)
            self.send_response(204)
            self.end_headers()
        except (ValueError, TypeError):
            self.send_error(400)

    def log_message(self, *_):
        pass


class CalibrationHTTPServer(ThreadingHTTPServer):
    def __init__(self, address, token, measurements):
        self.token = token
        self.measurements = measurements
        super().__init__(address, CalibrationRequestHandler)


class PointerCalibration:
    """Measures the existing single-axis curve, then checks its diagonal model.

    Movement and observation are injected so the full sequence can be checked
    without sending HID input or waiting for a physical phone.
    """

    def __init__(self, device, host, nudge, position):
        self.device = device
        self.host = host
        self.width = device['width']
        self.height = device['height']
        self.nudge = nudge
        self.position = position

    def measure(self):
        self._enter_calibration_area()
        distances = self._measure_horizontal_curve()
        self._verify_vertical_curve(distances)
        profile = dict(host=self.host, screenID=self.device['id'], screenWidth=self.width, screenHeight=self.height,
                       reportInterval=0.03, distances=distances)
        if self._verify_diagonal_curve(distances):
            profile['vectorModel'] = 'radialQuantized'
            print('Diagonal movement verified; combined X/Y tracking enabled.', flush=True)
        else:
            print('Diagonal movement differs; keeping calibrated single-axis tracking.', flush=True)
        return profile

    def _enter_calibration_area(self):
        self.nudge(-1500, -1500)
        # Enter the page from the top-left without clicking browser controls.
        for _ in range(3):
            self.nudge(0, 32)
        self._enter_horizontal_area()

    def _enter_horizontal_area(self):
        # Tracking gain varies even between phones with the same iOS version
        # and resolution. Reserve most of the width for the measurement burst
        # instead of assuming that three reports of 32 counts fit every phone.
        for count in (32, 16, 8, 4, 2, 1):
            self.nudge(-1500, 0)
            for _ in range(32):
                self.nudge(count, 0)
                x, _ = self.position()
                if x >= self.width / 4:
                    break
                if x > 20:
                    return
        raise RuntimeError('Cannot find a repeatable sampling area inside the screen; calibration was not saved.')

    def _measure_horizontal_curve(self):
        distances = [0.0]
        for count in range(1, 33):
            for reports in (3, 2, 1):
                before = self.position()
                for _ in range(reports):
                    self.nudge(count, 0)
                after = self.position()
                for _ in range(reports):
                    self.nudge(-count, 0)
                returned = self.position()
                if after[0] < self.width - 10:
                    break
                # A clipped sample is unusable, including its reverse burst.
                # Re-establish the origin before retrying a shorter burst.
                self._enter_horizontal_area()
            distance = ((after[0] - before[0]) + (after[0] - returned[0])) / (2 * reports)
            if (abs(returned[0] - before[0]) > 3 or after[0] >= self.width - 10
                    or not math.isfinite(distance) or distance <= distances[-1]):
                raise RuntimeError('Nonrepeatable movement or screen edge reached; calibration was not saved.')
            distances.append(distance)
            print(f'{count:2}: {distance:.3f} pixels/report', flush=True)
        return distances

    def _verify_vertical_curve(self, distances):
        before = self.position()
        for _ in range(3):
            self.nudge(0, 16)
        after = self.position()
        for _ in range(3):
            self.nudge(0, -16)
        returned = self.position()
        if abs(after[1] - before[1] - distances[16] * 3) > 3 or abs(returned[1] - before[1]) > 3:
            raise RuntimeError('Vertical movement does not match the measured curve; calibration was not saved.')

    def _verify_diagonal_curve(self, distances):
        # A single-axis curve does not establish how the host accelerates a
        # diagonal report. Enable combined X/Y tracking only after measuring it.
        # Check both integral and fractional magnitudes: this host model selects
        # its gain using the integer part of the combined HID vector length.
        radial_verified = True
        for dx, dy in [(12, 16), (16, 12), (7, 7), (16, 16)]:
            before = self.position()
            for _ in range(4):
                self.nudge(dx, dy)
            after = self.position()
            for _ in range(4):
                self.nudge(-dx, -dy)
            returned = self.position()
            magnitude = int(math.hypot(dx, dy))
            predicted = [distances[magnitude] * component / magnitude for component in (dx, dy)]
            for axis in range(2):
                observed = ((after[axis] - before[axis]) + (after[axis] - returned[axis])) / 8
                if abs(observed - predicted[axis]) > 0.6 or abs(returned[axis] - before[axis]) > 3:
                    radial_verified = False
        return radial_verified


def verify_mapping(api, device, position, tolerance=5):
    """Check observed deltas; browser chrome offsets cancel between positions.

    The same check works for native absolute input and saved relative curves.
    Never infer compatibility from the phone model or iOS version alone.
    """
    targets = [(0.3, 0.4), (0.6, 0.6), (0.4, 0.5)]
    observations = []
    try:
        # Raw movement invalidates the shared relative estimate. The first
        # coordinate move then establishes a fresh origin using the saved curve.
        api.nudge(device['id'], 1, 0)
        for x, y in targets:
            api.post('/move', device['id'], x=x, y=y, fraction=True)
            observations.append(position())
    except urllib.error.HTTPError as error:
        if error.code == 503:
            return False
        raise
    except RuntimeError:
        return False
    errors = []
    for index in range(1, len(targets)):
        for axis, size in enumerate((device['width'], device['height'])):
            expected = (targets[index][axis] - targets[index - 1][axis]) * size
            observed = observations[index][axis] - observations[index - 1][axis]
            errors.append(abs(observed - expected) if math.isfinite(observed) else float('inf'))
    print(f'Mapping verification: maximum delta error {max(errors):.2f}px (limit {tolerance}px).', flush=True)
    return max(errors) <= tolerance


def baseline_profile(path, device, host):
    """A baseline is a candidate gain, never evidence of device identity."""
    source = json.loads(path.read_text())
    reference = source.get('reference', source)
    if (reference.get('screenWidth'), reference.get('screenHeight')) != (device['width'], device['height']):
        return None  # Never scale a physical-pixel curve by resolution ratios.
    distances = source.get('distances', [])
    interval = source.get('reportInterval', 0)
    if not (2 <= len(distances) <= 128 and distances[0] == 0 and
            all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in distances) and
            all(a < b for a, b in zip(distances, distances[1:])) and distances[1] >= .05 and
            isinstance(interval, (int, float)) and .01 <= interval <= .1 and
            math.ceil(device['width'] / distances[-1]) + math.ceil(device['height'] / distances[-1]) <= 512):
        raise RuntimeError(f'Invalid pointer baseline: {path}')
    profile = dict(host=host, screenID=device['id'], screenWidth=device['width'], screenHeight=device['height'],
                   reportInterval=interval, distances=distances)
    if source.get('vectorModel') is not None:
        if source['vectorModel'] != 'radialQuantized':
            raise RuntimeError(f'Unknown vector model in {path}')
        profile['vectorModel'] = source['vectorModel']
    return profile


def apply_verified_profile(api, device, directory, host, profile, position):
    """Try on the actual phone; roll back both files and live input on failure."""
    root = directory / 'pointer-calibration'
    paths = [root / (host.upper() + '.json'), root / 'by-screen' / (device['id'].encode().hex() + '.json')]
    backups = {path: path.read_bytes() if path.exists() else None for path in paths}
    committed = False
    try:
        save_profile(directory, host, profile)
        api.post('/calibration/reload', device['id'])
        committed = verify_mapping(api, device, position)
        return committed
    finally:
        if not committed:
            for path, data in backups.items():
                if data is None:
                    path.unlink(missing_ok=True)
                else:
                    temporary = path.with_suffix('.rollback.tmp')
                    temporary.write_bytes(data)
                    temporary.replace(path)
            api.post('/calibration/reload', device['id'])


@contextlib.contextmanager
def calibration_access(base_url, device_id):
    """Use the same local locks as MCP for the entire measurement sequence."""
    url = urllib.parse.urlsplit(base_url)
    if url.hostname not in ('127.0.0.1', 'localhost', '::1'):
        yield
        return
    state = Path(os.environ.get('IPHONE_USE_STATE_DIR', str(Path.home() / 'Library/Logs/iPhoneUse')))
    if not state.is_absolute():
        raise RuntimeError('IPHONE_USE_STATE_DIR must be an absolute path.')
    state.mkdir(parents=True, exist_ok=True)
    port = url.port or (443 if url.scheme == 'https' else 80)
    key = device_id.lower().encode().hex()
    with contextlib.ExitStack() as stack:
        for name, mode in [(f'service-{port}.lock', fcntl.LOCK_SH),
                           (f'device-{port}-{key}.lock', fcntl.LOCK_EX)]:
            lock = stack.enter_context((state / name).open('a'))
            deadline = time.monotonic() + 10
            while True:
                try:
                    fcntl.flock(lock, mode | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Device or service is busy; calibration did not start.')
                    time.sleep(0.05)
        yield


def save_profile(directory, host, profile):
    # Write only after all required measurements succeed. Replacement keeps the
    # previous profile available if writing the temporary file fails.
    destination = directory / 'pointer-calibration' / (host.upper() + '.json')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.tmp')
    temporary.write_text(json.dumps(profile, indent=2) + '\n')
    temporary.replace(destination)
    if profile.get('screenID'):
        # Keep the latest measured curve under the stable USB identity. Swift
        # prefers this over stale or ambiguous profiles from earlier pairings.
        template = destination.parent / 'by-screen' / (profile['screenID'].encode().hex() + '.json')
        template.parent.mkdir(parents=True, exist_ok=True)
        temporary = template.with_suffix('.tmp')
        temporary.write_text(json.dumps(profile, indent=2) + '\n')
        temporary.replace(template)
    print(f'Saved {destination}', flush=True)


def local_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect(('192.0.2.1', 80))  # choose an interface, send no packet
        return sock.getsockname()[0]


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='device ID from /devices (required for multiple phones)')
    parser.add_argument('--api', default='http://127.0.0.1:7390')
    parser.add_argument('--listen-port', type=int, default=7391)
    parser.add_argument('--address', help='Mac LAN address visible from the iPhone')
    parser.add_argument('--auto', action='store_true', help='Open Safari, verify the existing mapping, and measure only if needed')
    parser.add_argument('--force', action='store_true', help='Measure a new curve even if the existing mapping passes verification')
    parser.add_argument('--baseline', type=Path, help='Try this baseline/profile on the phone before measuring; requires --auto')
    args = parser.parse_args()
    if args.baseline and not args.auto:
        parser.error('--baseline requires --auto so the candidate can be verified on the phone')
    return args


def main():
    args = parse_arguments()
    api = PhoneAPI(args.api)
    device = api.select_device(args.device)
    directory = Path.home() / 'Library/Application Support/iPhoneUse'
    host = json.loads((directory / 'pairings.json').read_text())[device['id']]
    token = '/' + secrets.token_hex(16)
    measurements = PointerMeasurements()
    address = args.address
    if not address:
        address = local_address()
    server = CalibrationHTTPServer(('0.0.0.0', args.listen_port), token, measurements)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with calibration_access(args.api, device['id']):
            run_calibration(args, api, device, directory, host, measurements, address, token)
    finally:
        server.shutdown()
        server.server_close()


def run_calibration(args, api, device, directory, host, measurements, address, token):
    url = f'http://{address}:{args.listen_port}{token}'
    print(f'Open in iPhone Safari: {url}', flush=True)
    if args.auto:
        api.open_safari(device['id'], url)
    try:
        page = measurements.wait_for_page(timeout=30 if args.auto else 180)
    except RuntimeError:
        if args.auto:
            raise RuntimeError('Safari did not load the test page. Use an English hardware-keyboard input source '
                               f'or open {url} manually; no calibration was saved.') from None
        raise
    dpr = page['dpr']
    width, height = device['width'], device['height']
    if page['screenWidth'] * dpr != width or page['screenHeight'] * dpr != height:
        raise RuntimeError('Safari screen size differs from capture; use portrait and disable page zoom.')
    position = lambda: measurements.position(dpr)
    if args.auto and not args.force and verify_mapping(api, device, position):
        print('Existing coordinate mapping verified; reused without recalibration or restart.', flush=True)
        return
    if args.auto and not args.force:
        explicit = getattr(args, 'baseline', None)
        candidates = [explicit] if explicit else sorted((Path(__file__).resolve().parents[1] / 'data/pointer-calibration').glob('*.json'))
        for path in candidates:
            candidate = baseline_profile(path, device, host)
            if candidate is None:
                print(f'Skipped different-resolution baseline: {path.name}', flush=True)
                continue
            print(f'Trying baseline: {path.name}', flush=True)
            if apply_verified_profile(api, device, directory, host, candidate, position):
                print('Baseline verified on this phone, saved by device identity, and loaded without restart.', flush=True)
                return
            print('Baseline did not match this phone; previous configuration restored. Measuring its own curve.', flush=True)
    calibration = PointerCalibration(
        device, host, lambda x, y: api.nudge(device['id'], x, y), position)
    profile = calibration.measure()
    if not apply_verified_profile(api, device, directory, host, profile, position):
        raise RuntimeError('Measured profile failed live mapping verification; previous configuration restored.')
    print('Measured profile verified, saved, and loaded without restart. Keep tracking speed unchanged.', flush=True)


if __name__ == '__main__':
    main()
