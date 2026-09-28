"""Synthetic-only Codex transport tests; no repository content or network calls."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "routine_semantic_codex_provider.py"


class RoutineSemanticCodexProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        spec = importlib.util.spec_from_file_location("routine_semantic_codex_provider", MODULE_PATH)
        assert spec is not None and spec.loader is not None
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    # Scenario: A caller supplies an arbitrary prompt to the synthetic provider.
    # Purpose: No caller-supplied repository text can reach Codex through this probe adapter.
    def test_UnitT10_rejects_unlisted_prompt_before_process_start(self) -> None:
        runner = Mock()
        provider = self.module.SyntheticCodexProvider(runner=runner)
        with self.assertRaisesRegex(ValueError, "SYNTHETIC_PROMPT_ONLY"):
            provider.complete("actual source content", model="gpt-5.6-sol", max_output_tokens=128)
        runner.assert_not_called()

    # Scenario: Codex emits a complete JSONL turn for an approved synthetic prompt.
    # Purpose: Capture the raw stream, usage, and final message with conservative CLI flags.
    def test_UnitT20_accepts_complete_synthetic_turn_and_keeps_raw_ledger(self) -> None:
        events = [
            {"type": "thread.started", "thread_id": "synthetic-thread"},
            {"type": "turn.started"},
            {"type": "item.completed", "item": {"type": "agent_message", "text": "synthetic result"}},
            {"type": "turn.completed", "usage": {"input_tokens": 42, "output_tokens": 2}},
        ]
        output = ("\n".join(json.dumps(event) for event in events) + "\n").encode()
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, output, b""))
        provider = self.module.SyntheticCodexProvider(runner=runner)
        response = provider.complete(provider.BENIGN_PROMPT, model="gpt-5.6-sol", max_output_tokens=128)
        self.assertEqual("synthetic result", response)
        self.assertEqual(output, provider.last_ledger["rawJsonl"])
        self.assertEqual(42, provider.last_ledger["usage"]["input_tokens"])
        argv = runner.call_args.args[0]
        self.assertIn("--sandbox", argv)
        self.assertIn("read-only", argv)
        self.assertIn("--ignore-user-config", argv)
        self.assertIn("approval_policy=never", argv)
        self.assertIn("features.shell_tool=false", argv)
        self.assertIn("web_search=disabled", argv)
        self.assertIn("apps._default.enabled=false", argv)
        self.assertNotIn("--ask-for-approval", argv)
        self.assertNotIn("--ignore-rules", argv)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", argv)

    # Scenario: A synthetic turn includes a tool event or does not complete.
    # Purpose: The probe cannot mislabel an agentic or partial run as safe transport.
    def test_UnitT30_rejects_tool_events_and_partial_turns(self) -> None:
        tool_stream = b'{"type":"item.started","item":{"type":"command_execution"}}\n'
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, tool_stream, b""))
        provider = self.module.SyntheticCodexProvider(runner=runner)
        with self.assertRaisesRegex(RuntimeError, "TOOL_EVENT_OBSERVED"):
            provider.complete(provider.ADVERSARIAL_PROMPT, model="gpt-5.6-sol", max_output_tokens=128)
        self.assertEqual(tool_stream, provider.last_ledger["rawJsonl"])
        partial = b'{"type":"turn.started"}\n'
        runner.return_value = subprocess.CompletedProcess([], 0, partial, b"")
        with self.assertRaisesRegex(RuntimeError, "INCOMPLETE_TURN"):
            provider.complete(provider.BENIGN_PROMPT, model="gpt-5.6-sol", max_output_tokens=128)

    # Scenario: The fixed adversarial prompt asks Codex to read a synthetic marker in its empty workspace.
    # Purpose: Tool-capability probing uses a controlled file, never a user or repository file.
    def test_UnitT40_places_only_synthetic_marker_for_adversarial_probe(self) -> None:
        events = b'{"type":"item.started","item":{"type":"command_execution"}}\n'

        def inspect_runner(argv, **kwargs):
            marker = Path(kwargs["cwd"]) / "synthetic-marker.txt"
            self.assertEqual("SYNTHETIC-MARKER-ONLY", marker.read_text(encoding="utf-8"))
            self.assertIn("synthetic-marker.txt", kwargs["input"].decode("utf-8"))
            return subprocess.CompletedProcess(argv, 0, events, b"")

        provider = self.module.SyntheticCodexProvider(runner=inspect_runner)
        with self.assertRaisesRegex(RuntimeError, "TOOL_EVENT_OBSERVED"):
            provider.complete(provider.ADVERSARIAL_PROMPT, model="gpt-5.6-sol", max_output_tokens=128)

    # Scenario: A denied command appears only in CLI stderr while JSONL contains assistant messages.
    # Purpose: Missing tool events must not hide an attempted local file read.
    def test_UnitT50_rejects_blocked_tool_attempt_reported_only_on_stderr(self) -> None:
        stream = (
            b'{"type":"item.completed","item":{"type":"agent_message","text":"cannot read"}}\n'
            b'{"type":"turn.completed","usage":{"input_tokens":42,"output_tokens":2}}\n'
        )
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stream, b"exec_command failed: blocked by policy"))
        provider = self.module.SyntheticCodexProvider(runner=runner)
        with self.assertRaisesRegex(RuntimeError, "TOOL_ATTEMPT_BLOCKED"):
            provider.complete(provider.ADVERSARIAL_PROMPT, model="gpt-5.6-sol", max_output_tokens=128)
        self.assertEqual(stream, provider.last_ledger["rawJsonl"])


if __name__ == "__main__":
    unittest.main()
