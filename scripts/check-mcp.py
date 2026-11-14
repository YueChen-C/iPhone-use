#!/usr/bin/env python3
"""Check the real stdio MCP process without an SDK or phone input side effects."""
import argparse
import json
import subprocess
import sys
from pathlib import Path


def check(command, live=False):
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "iphone-use-check", "version": "1.0.0"},
        }},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "ping"},
    ]
    if live:
        messages.append({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
            "name": "list_devices", "arguments": {},
        }})
    process = subprocess.run(
        command, input="".join(json.dumps(message) + "\n" for message in messages),
        capture_output=True, text=True, timeout=70 if live else 15,
    )
    if process.returncode:
        raise ValueError(process.stderr.strip() or "MCP process exited with code %s" % process.returncode)
    try:
        replies = [json.loads(line) for line in process.stdout.splitlines()]
    except ValueError as error:
        raise ValueError("MCP stdout contains non-JSON output: %s" % error) from error
    expected_ids = [1, 2, 3, 4] if live else [1, 2, 3]
    if [reply.get("id") for reply in replies] != expected_ids:
        raise ValueError("Missing or unexpected replies (notifications must not produce replies)")
    for reply in replies:
        if reply.get("jsonrpc") != "2.0" or "error" in reply or "result" not in reply:
            raise ValueError("Invalid MCP response: %s" % reply)
    initialized = replies[0]["result"]
    if initialized.get("protocolVersion") != "2025-06-18":
        raise ValueError("MCP protocol negotiation failed")
    if "tools" not in initialized.get("capabilities", {}):
        raise ValueError("Server did not advertise tools")
    tools = replies[1]["result"].get("tools", [])
    required = {"list_devices", "set_input_backend", "screenshot", "move_pointer", "adjust_pointer", "click_pointer",
                "tap", "long_press", "swipe", "type_text", "press_key", "keyboard_sequence", "home"}
    if not required.issubset({tool.get("name") for tool in tools}):
        raise ValueError("Server is missing iPhone Use tools")
    for tool in tools:
        if tool.get("inputSchema", {}).get("type") != "object":
            raise ValueError("Invalid input schema for %s" % tool.get("name"))
    if replies[2]["result"] != {}:
        raise ValueError("Unexpected ping response")
    print("MCP OK: initialize, notifications, %d tools, ping; stdout is clean JSON-RPC." % len(tools))
    if live:
        result = replies[3]["result"]
        if result.get("isError"):
            raise ValueError("App connection failed: %s" % result.get("content"))
        devices = json.loads(result["content"][0]["text"])["devices"]
        print("App reachable: %d iPhone(s). No phone input was sent." % len(devices))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Also list devices through the running app")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Optional server command after --")
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        command = [str(Path(__file__).resolve().with_name("mcp.sh"))]
    try:
        check(command, args.live)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
        print("MCP check failed: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
