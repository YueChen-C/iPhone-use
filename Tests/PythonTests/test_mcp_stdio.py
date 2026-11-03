"""Exercise the actual MCP launcher and Swift-to-HTTP bridge without phone input."""
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "scripts" / "mcp.sh"
CHECKER = ROOT / "scripts" / "check-mcp.py"
IMAGE = b"mock JPEG payload"
CONFIG = os.environ.get("IPHONE_USE_TEST_CONFIG", "debug")


class MockApp(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.events.append(("GET", self.path))
        if self.path == "/devices":
            self.server.devices_requested.set()
            self.send(200, json.dumps({"devices": self.server.devices}).encode())
        elif self.path == "/config":
            self.send(200, json.dumps({"language": self.server.language}).encode())
        elif self.path.startswith("/screenshot?"):
            if self.server.before_screenshot:
                self.server.before_screenshot(self.path)
            self.send(200, IMAGE, {
                "Content-Type": "image/jpeg", "X-Device": parse_qs(urlsplit(self.path).query)["device"][0],
                "X-Image-Width": "500", "X-Image-Height": "1000",
            })
        else:
            self.send(404, b'{"error":"not found"}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.server.events.append(("POST", self.path, body))
        if self.server.before_post:
            self.server.before_post(body)
        if self.path == "/ocr":
            self.send(200, json.dumps({"device": body["device"], "width": 600, "height": 1200,
                                       "items": [{"text": "设置", "x": 120, "y": 400}]}).encode())
            return
        if self.server.fail_actions:
            self.send(503, b'{"error":"pointer is not ready"}')
        else:
            self.send(200, b'{"ok":true,"device":"phone-1"}')

    def send(self, status, body, headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {"Content-Type": "application/json"}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


@unittest.skipUnless((ROOT / ".build" / CONFIG / "iphone-use").is_file(), "Build the executable first")
class MCPStdioTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), MockApp)
        self.server.events = []
        self.server.fail_actions = False
        self.server.language = "en"
        self.server.devices = [{"id": "phone-1", "name": "First", "bluetooth": True}]
        self.server.devices_requested = threading.Event()
        self.server.before_post = None
        self.server.before_screenshot = None
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.state = tempfile.TemporaryDirectory()
        self.env = dict(os.environ, CONFIG=CONFIG, IPHONE_USE_PORT=str(self.server.server_port),
                        IPHONE_USE_STATE_DIR=self.state.name)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.state.cleanup()

    def exchange(self, calls):
        messages = [
            {"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "integration-test", "version": "1.0.0"},
            }},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ]
        for number, (name, arguments) in enumerate(calls, 1):
            messages.append({"jsonrpc": "2.0", "id": number, "method": "tools/call", "params": {
                "name": name, "arguments": arguments,
            }})
        process = subprocess.run(
            [str(LAUNCHER)], input="".join(json.dumps(message) + "\n" for message in messages),
            env=self.env, cwd="/", capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], ["init"] + list(range(1, len(calls) + 1)))
        return [reply["result"] for reply in replies[1:]]

    def test_protocol_checker_can_launch_from_an_unrelated_directory(self):
        with tempfile.TemporaryDirectory(prefix="iphone use ") as directory:
            process = subprocess.run(
                ["python3", "-B", str(CHECKER)], env=self.env, cwd=directory,
                capture_output=True, text=True, timeout=15,
            )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("14 tools", process.stdout)
        # The checker's initialize fetches /config; tools/list reuses the value.
        self.assertEqual(self.server.events, [("GET", "/config")])

    def test_device_list_and_tap_preserve_routing_scaling_and_confirmation_image(self):
        listed, tapped = self.exchange([
            ("list_devices", {}), ("tap", {"x": 120.5, "y": 400, "device": "phone-1"}),
        ])
        self.assertEqual(json.loads(listed["content"][0]["text"])["devices"][0]["id"], "phone-1")
        self.assertNotIn("isError", tapped)
        self.assertEqual(tapped["content"][0], {
            "type": "image", "data": base64.b64encode(IMAGE).decode(), "mimeType": "image/jpeg",
        })
        self.assertIn("500x1000 px", tapped["content"][1]["text"])
        self.assertEqual(self.server.events, [
            ("GET", "/config"),
            ("GET", "/devices"),
            ("GET", "/devices"),
            ("POST", "/tap", {"x": 120.5, "y": 400, "device": "phone-1", "maxEdge": 1000}),
            ("GET", "/screenshot?maxEdge=1000&device=phone-1"),
        ])

    def test_ocr_screen_returns_only_text_and_preserves_dimensions_and_device(self):
        result = self.exchange([("ocr_screen", {"device": "First", "maxEdge": 800})])[0]
        self.assertNotIn("isError", result)
        self.assertEqual(len(result["content"]), 1)
        self.assertEqual(result["content"][0]["type"], "text")
        self.assertEqual(json.loads(result["content"][0]["text"]), {
            "device": "phone-1", "width": 600, "height": 1200,
            "items": [{"text": "设置", "x": 120, "y": 400}],
        })
        self.assertEqual(self.server.events, [
            ("GET", "/config"), ("GET", "/devices"),
            ("POST", "/ocr", {"device": "phone-1", "maxEdge": 800}),
        ])

    def test_text_only_screenshot_and_tap_text_have_no_base64_image(self):
        screenshot, tapped = self.exchange([
            ("screenshot", {"device": "First", "include_image": False}),
            ("tap_text", {"text": "设置", "exact": True, "index": 1, "hold": 0.2,
                          "maxEdge": 800, "device": "phone-1", "include_image": False}),
        ])
        for result in (screenshot, tapped):
            self.assertNotIn("isError", result)
            self.assertEqual([block["type"] for block in result["content"]], ["text"])
            self.assertNotIn("data", result["content"][0])
            self.assertIn("500x1000 px", result["content"][0]["text"])
        self.assertEqual([event for event in self.server.events if event[0] == "POST"], [
            ("POST", "/tap_text", {"device": "phone-1", "text": "设置", "exact": True,
                                   "index": 1, "hold": 0.2, "maxEdge": 800}),
        ])
        self.assertEqual(sum(event[1].startswith("/screenshot?") for event in self.server.events), 2)

    def test_invalid_ocr_arguments_never_query_devices_or_send_input(self):
        calls = [("tap_text", {}), ("tap_text", {"text": " "}),
                 ("tap_text", {"text": "x", "index": -1}),
                 ("ocr_screen", {"maxEdge": 0}),
                 ("screenshot", {"include_image": "false"})]
        for name, arguments in calls:
            self.assertTrue(self.exchange([(name, arguments)])[0]["isError"])
        self.assertEqual(self.server.events, [("GET", "/config")] * len(calls))

    def test_failed_action_and_unknown_tool_return_errors_without_a_screenshot(self):
        self.server.fail_actions = True
        failed, unknown = self.exchange([
            ("tap", {"x": 1, "y": 2, "device": "phone-1"}), ("missing_tool", {}),
        ])
        self.assertTrue(failed["isError"])
        self.assertEqual(failed["content"][0]["text"], "pointer is not ready")
        self.assertTrue(unknown["isError"])
        self.assertEqual(unknown["content"][0]["text"], "unknown tool missing_tool")
        self.assertEqual(len(self.server.events), 3)
        self.assertEqual(self.server.events[2][:2], ("POST", "/tap"))

    def test_normalized_tools_forward_screen_fractions_and_capture_at_1000(self):
        results = self.exchange([
            ("move_pointer", {"x": 250, "y": 750, "normalized": True}),
            ("tap", {"x": 0, "y": 1000, "normalized": True}),
            ("long_press", {"x": 500, "y": 500, "seconds": 2, "normalized": True}),
            ("swipe", {"points": [{"x": 0, "y": 1000}, {"x": 500, "y": 0}],
                       "duration": 0.4, "normalized": True}),
        ])
        self.assertTrue(all("isError" not in result for result in results))
        common = {"fraction": True, "maxEdge": 1000, "device": "phone-1"}
        self.assertEqual([event for event in self.server.events if event[0] == "POST"], [
            ("POST", "/move", dict(common, x=0.25, y=0.75)),
            ("POST", "/tap", dict(common, x=0, y=1)),
            ("POST", "/tap", dict(common, x=0.5, y=0.5, hold=2)),
            ("POST", "/swipe", dict(common, points=[{"x": 0, "y": 1}, {"x": 0.5, "y": 0}], duration=0.4)),
        ])
        self.assertEqual([event for event in self.server.events if event[1].startswith("/screenshot")],
                         [("GET", "/screenshot?maxEdge=1000&device=phone-1")] * 4)

    def test_pointer_inspection_does_not_click_and_click_does_not_reposition(self):
        results = self.exchange([
            ("move_pointer", {"x": 100, "y": 200, "device": "First"}),
            ("adjust_pointer", {"dx": -2, "dy": 3, "device": "phone-1"}),
            ("click_pointer", {"device": "phone-1"}),
        ])
        for result in results:
            self.assertNotIn("isError", result)
            self.assertEqual(result["content"][0]["type"], "image")
        self.assertEqual([event for event in self.server.events if event[0] == "POST"], [
            ("POST", "/move", {"x": 100, "y": 200, "maxEdge": 1000, "device": "phone-1"}),
            ("POST", "/nudge", {"dx": -2, "dy": 3, "click": False, "device": "phone-1"}),
            ("POST", "/nudge", {"dx": 0, "dy": 0, "click": True, "device": "phone-1"}),
        ])

    def test_invalid_pointer_parameters_do_not_query_devices_or_send_input(self):
        calls = [("move_pointer", {"x": x, "y": 1}) for x in (True, "1", -1)]
        calls += [("adjust_pointer", {"dx": x, "dy": 0}) for x in (True, "1", 0.5, -33, 33)]
        calls += [("adjust_pointer", {"dx": 0}), ("move_pointer", {"x": 1})]
        for name, arguments in calls:
            with self.subTest(name=name, arguments=arguments):
                self.assertTrue(self.exchange([(name, arguments)])[0]["isError"])
        # Every exchange still fetches /config at initialize; nothing else may run.
        self.assertEqual(self.server.events, [("GET", "/config")] * len(calls))

    def test_keyboard_sequence_preserves_order_and_captures_only_the_final_screen(self):
        result = self.exchange([("keyboard_sequence", {"device": "First", "steps": [
            {"key": "l", "modifiers": ["cmd"]}, {"text": "https://www.baidu.com"}, {"key": "enter"},
        ]})])[0]
        self.assertNotIn("isError", result)
        self.assertEqual(result["content"][0]["type"], "image")
        self.assertEqual(self.server.events, [
            ("GET", "/config"),
            ("GET", "/devices"),
            ("POST", "/key", {"key": "l", "modifiers": ["cmd"], "device": "phone-1"}),
            ("POST", "/type", {"text": "https://www.baidu.com", "device": "phone-1"}),
            ("POST", "/key", {"key": "enter", "modifiers": [], "device": "phone-1"}),
            ("GET", "/screenshot?maxEdge=1000&device=phone-1"),
        ])

    def test_device_id_routes_screenshot_and_actions_with_original_precedence(self):
        self.server.devices.append({"id": "phone-2", "name": "Second"})
        results = self.exchange([
            ("screenshot", {"device_id": "Second"}),
            ("type_text", {"text": "nihao", "device_id": "Second", "clear_before": True,
                           "commit_ime": True, "press_enter": True}),
            ("home", {"device": "First", "device_id": "Second"}),
        ])
        self.assertTrue(all("isError" not in result for result in results))
        posts = [event for event in self.server.events if event[0] == "POST"]
        self.assertEqual(posts, [
            ("POST", "/type", {"text": "nihao", "device": "phone-2", "clear_before": True,
                               "commit_ime": True, "press_enter": True}),
            ("POST", "/home", {"device": "phone-1"}),
        ])
        self.assertIn(("GET", "/screenshot?maxEdge=1000&device=phone-2"), self.server.events)

    def test_ocr_and_tap_text_aliases_default_to_1000(self):
        self.server.devices.append({"id": "phone-2", "name": "Second"})
        results = self.exchange([
            ("ocr_screen", {"device_id": "Second", "include_image": False}),
            ("tap_text", {"text": "Confirm", "device_id": "Second", "include_image": False}),
        ])
        self.assertTrue(all("isError" not in result for result in results))
        self.assertTrue(all(block["type"] == "text" for result in results for block in result["content"]))
        self.assertEqual([event for event in self.server.events if event[0] == "POST"], [
            ("POST", "/ocr", {"device": "phone-2", "maxEdge": 1000}),
            ("POST", "/tap_text", {"device": "phone-2", "text": "Confirm", "maxEdge": 1000}),
        ])
        self.assertIn(("GET", "/screenshot?maxEdge=1000&device=phone-2"), self.server.events)

    def test_actions_typed_steps_and_delays_preserve_atomic_order(self):
        result = self.exchange([("keyboard_sequence", {"device_id": "First", "actions": [
            {"type": "text", "text": "nihao", "clear_before": True,
             "commit_ime": True, "press_enter": True},
            {"delay": 0}, {"wait": 0}, {"type": "delay", "seconds": 0.01},
            {"type": "wait", "seconds": 0}, {"type": "key", "key": "tab"},
        ]})])[0]
        self.assertNotIn("isError", result)
        self.assertEqual([event for event in self.server.events if event[0] == "POST"], [
            ("POST", "/key", {"key": "a", "modifiers": ["command"], "device": "phone-1"}),
            ("POST", "/key", {"key": "backspace", "modifiers": [], "device": "phone-1"}),
            ("POST", "/type", {"text": "nihao", "device": "phone-1"}),
            ("POST", "/key", {"key": "space", "modifiers": [], "device": "phone-1"}),
            ("POST", "/key", {"key": "enter", "modifiers": [], "device": "phone-1"}),
            ("POST", "/key", {"key": "tab", "modifiers": [], "device": "phone-1"}),
        ])
        self.assertEqual(sum(event[1].startswith("/screenshot") for event in self.server.events), 1)

    def test_new_invalid_forms_fail_before_device_lookup(self):
        invalid = [
            {"actions": [{"delay": True}]}, {"actions": [{"wait": 5.1}]},
            {"actions": [{"type": "delay", "seconds": -1}]},
            {"actions": [{"type": "key", "text": "x"}]},
            {"actions": [{"text": "x", "commit_ime": 1}]},
            {"steps": [{"text": "x"}], "actions": [{"text": "y"}]},
        ]
        for arguments in invalid:
            self.assertTrue(self.exchange([("keyboard_sequence", arguments)])[0]["isError"])
        self.assertTrue(self.exchange([("type_text", {"text": "a", "press_enter": 1})])[0]["isError"])
        self.assertEqual(self.server.events, [("GET", "/config")] * (len(invalid) + 1))

    def test_sequence_can_omit_confirmation_image(self):
        result = self.exchange([("keyboard_sequence", {
            "actions": [{"wait": 0}], "include_image": False,
        })])[0]
        self.assertNotIn("isError", result)
        self.assertEqual(self.server.events, [("GET", "/config"), ("GET", "/devices")])

    def test_invalid_later_keyboard_step_prevents_all_input_and_device_queries(self):
        bad_steps = [
            {"text": "今天"}, {"text": "x" * 257}, {"text": ""},
            {"text": "x", "key": "enter"}, {"key": "enter", "unexpected": True},
            {"key": "unknown-name"}, {"key": ""}, {"key": "🌟"},
            {"key": "enter", "modifiers": ["unknown"]}, {"key": "enter", "modifiers": "cmd"},
            {"text": 123},
        ]
        for bad in bad_steps:
            with self.subTest(step=bad):
                result = self.exchange([("keyboard_sequence", {"steps": [
                    {"key": "l", "modifiers": ["cmd"]}, bad,
                ]})])[0]
                self.assertTrue(result["isError"])
                self.assertIn("step 2", result["content"][0]["text"])
        for steps in ([], [{"key": "enter"}] * 17, "not-an-array", [{"text": "x" * 200}] * 2):
            with self.subTest(steps=steps):
                self.assertTrue(self.exchange([("keyboard_sequence", {"steps": steps})])[0]["isError"])
        # Validation fails before any device query; only initialize's /config ran.
        self.assertEqual(self.server.events, [("GET", "/config")] * (len(bad_steps) + 4))

    def test_keyboard_sequence_stops_at_failed_step_without_replaying(self):
        def fail_second_step(body):
            if "text" in body:
                self.server.fail_actions = True

        self.server.before_post = fail_second_step
        result = self.exchange([("keyboard_sequence", {"steps": [
            {"key": "l", "modifiers": ["cmd"]}, {"text": "example.com"}, {"key": "enter"},
        ]})])[0]
        self.assertTrue(result["isError"])
        self.assertIn("stopped at step 2/3", result["content"][0]["text"])
        self.assertIn("fresh screenshot", result["content"][0]["text"])
        self.assertEqual([event[:2] for event in self.server.events], [
            ("GET", "/config"), ("GET", "/devices"), ("POST", "/key"), ("POST", "/type"),
        ])

    def test_same_phone_cannot_interleave_a_keyboard_sequence(self):
        first_step = threading.Event()
        release_step = threading.Event()
        other_input = threading.Event()

        def post(body):
            if body.get("key") == "l":
                first_step.set()
                release_step.wait(5)
            elif body.get("key") == "escape":
                other_input.set()

        self.server.before_post = post
        with ThreadPoolExecutor(max_workers=2) as pool:
            sequence = pool.submit(self.exchange, [("keyboard_sequence", {"device": "First", "steps": [
                {"key": "l", "modifiers": ["cmd"]}, {"text": "example.com"}, {"key": "enter"},
            ]})])
            try:
                self.assertTrue(first_step.wait(5))
                self.server.devices_requested.clear()
                other = pool.submit(self.exchange, [("press_key", {"device": "phone-1", "key": "escape"})])
                self.assertTrue(self.server.devices_requested.wait(5))
                self.assertFalse(other_input.wait(0.3))
            finally:
                release_step.set()
            self.assertNotIn("isError", sequence.result(timeout=8)[0])
            self.assertNotIn("isError", other.result(timeout=8)[0])
        changes = [event for event in self.server.events if event[0] == "POST" or event[1].startswith("/screenshot")]
        self.assertEqual([event[:2] for event in changes], [
            ("POST", "/key"), ("POST", "/type"), ("POST", "/key"),
            ("GET", "/screenshot?maxEdge=1000&device=phone-1"),
            ("POST", "/key"), ("GET", "/screenshot?maxEdge=1000&device=phone-1"),
        ])

    def test_same_phone_aliases_queue_action_and_confirmation_across_processes(self):
        screenshot_started = threading.Event()
        release_screenshot = threading.Event()
        second_post = threading.Event()

        def screenshot(path):
            if not screenshot_started.is_set():
                screenshot_started.set()
                release_screenshot.wait(5)

        self.server.before_screenshot = screenshot
        self.server.before_post = lambda body: second_post.set() if body["x"] == 2 else None
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.exchange, [("tap", {"x": 1, "y": 1, "device": "First"})])
            try:
                self.assertTrue(screenshot_started.wait(5))
                # The shared service lock also prevents recovery from stopping
                # the GUI while this action's confirmation is still in flight.
                lock_path = Path(self.state.name) / f"service-{self.server.server_port}.lock"
                with lock_path.open("a") as lock:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.server.devices_requested.clear()
                second = pool.submit(self.exchange, [("tap", {"x": 2, "y": 1, "device": "phone-1"})])
                self.assertTrue(self.server.devices_requested.wait(5))
                self.assertFalse(second_post.wait(0.3))
            finally:
                release_screenshot.set()
            self.assertNotIn("isError", first.result(timeout=8)[0])
            self.assertNotIn("isError", second.result(timeout=8)[0])
        changes = [event for event in self.server.events if event[0] == "POST" or event[1].startswith("/screenshot")]
        self.assertEqual([event[0] for event in changes], ["POST", "GET", "POST", "GET"])
        self.assertEqual(changes[0][2]["device"], "phone-1")

    def test_different_phones_can_act_concurrently(self):
        self.server.devices.append({"id": "phone-2", "name": "Second"})
        barrier = threading.Barrier(2)
        self.server.before_post = lambda body: barrier.wait(timeout=5)
        with ThreadPoolExecutor(max_workers=2) as pool:
            calls = [pool.submit(self.exchange, [("tap", {"x": 1, "y": 1, "device": phone})])
                     for phone in ("phone-1", "phone-2")]
            for result in calls:
                self.assertNotIn("isError", result.result(timeout=10)[0])

    def test_ambiguous_phone_name_does_not_send_input(self):
        self.server.devices.append({"id": "phone-2", "name": "First"})
        result = self.exchange([("tap", {"x": 1, "y": 1, "device": "First"})])[0]
        self.assertTrue(result["isError"])
        self.assertIn("found 2", result["content"][0]["text"])
        self.assertEqual(self.server.events, [("GET", "/config"), ("GET", "/devices")])

    def test_live_checker_only_lists_devices(self):
        process = subprocess.run(
            ["python3", "-B", str(CHECKER), "--live"], env=self.env, cwd="/",
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("App reachable: 1 iPhone(s)", process.stdout)
        self.assertEqual(self.server.events, [("GET", "/config"), ("GET", "/devices")])

    def test_tools_and_errors_follow_the_app_language(self):
        self.server.language = "zh"
        process = subprocess.run(
            [str(LAUNCHER)], input="".join(json.dumps(message) + "\n" for message in [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "language-test", "version": "1.0.0"},
                }},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                    "name": "move_pointer", "arguments": {"x": -1, "y": 1},
                }},
            ]),
            env=self.env, cwd="/", capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertIn("控制真实 iPhone", replies[0]["result"]["instructions"])
        tools = replies[1]["result"]["tools"]
        # Tool and parameter names are the client contract and stay English.
        self.assertEqual(len(tools), 14)
        home = next(tool for tool in tools if tool["name"] == "home")
        self.assertEqual(home["description"], "回到主屏幕。")
        error = replies[2]["result"]["content"][0]["text"]
        self.assertIn("截图坐标", error)
        self.assertEqual(self.server.events, [("GET", "/config")])


if __name__ == "__main__":
    unittest.main()
