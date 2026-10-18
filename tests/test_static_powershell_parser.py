"""Native host ownership and fail-closed controls for static parser correction."""
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
import copy
from pathlib import Path
import shutil
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from standard_static_powershell import ParserCoverageError, native_proof, check_command_views, validate_proof


class StaticPowerShellParserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pwsh = shutil.which("pwsh")
        if not cls.pwsh:
            raise RuntimeError("Native PowerShell is required; do not skip parser validation")

    # Scenario: normal URI data and interpolated members coexist with executable commands.
    # Purpose: require actual native command ownership instead of tokenizing hashtable data as shell.
    def test_UnitT10_uri_data_is_not_a_shell_command(self):
        text = '$request=@{Uri="https://example.test/$($entry.Id)"}\nWrite-Output $request\n'
        proof = native_proof(text, "powershell", self.pwsh)
        seen = []
        result = check_command_views(text, "powershell", proof, lambda s, **kw: seen.append(s) or False)
        self.assertFalse(result)
        self.assertTrue(any("Write-Output" in s for s in seen))
        self.assertFalse(any("https://" in s for s in seen))

    # Scenario: an ordinary method call and line continuation contain valid host quotes.
    # Purpose: retain the argument text while removing only native syntactic ownership.
    def test_UnitT20_continuation_preserves_command_arguments(self):
        text = "Write-Output (Join-Path $root 'file.txt') " + chr(96) + "\n  -Verbose\n"
        proof = native_proof(text, "powershell", self.pwsh)
        seen = []
        self.assertFalse(check_command_views(text, "powershell", proof, lambda s, **kw: seen.append(s) or False))
        self.assertTrue(any("-Verbose" in s for s in seen))
        self.assertTrue(any("file.txt" in s for s in seen))

    # Scenario: script text has an unclosed quote or unsupported malformed source.
    # Purpose: native parser failure must not become a completion claim.
    def test_UnitT30_malformed_source_fails_closed(self):
        text = 'Write-Output "unterminated'
        proof = native_proof(text, "powershell", self.pwsh)
        with self.assertRaises(ParserCoverageError):
            check_command_views(text, "powershell", proof, lambda *a, **k: False)

    # Scenario: a shell or dynamic expression receiver can interpret runtime-generated text.
    # Purpose: do not turn host ownership into a dynamic execution bypass.
    def test_UnitT40_shell_execution_remains_partial(self):
        for text in ['bash -c $payload', 'cmd /c $payload', 'pwsh -Command $payload',
                     'Invoke-Expression $payload', '& $shell -c $payload', 'python3.12 -c $payload', 'Add-Type -TypeDefinition $payload',
                     '[scriptblock]::Create($payload).Invoke()',
                     "[scriptblock]::Create($payload).'Invoke'()", '$object.$method($payload)']:
            with self.subTest(text=text):
                proof = native_proof(text, "powershell", self.pwsh)
                self.assertTrue(check_command_views(text, "powershell", proof, lambda *a, **k: False))

    # Scenario: native process objects use separate typed arguments instead of a command string.
    # Purpose: distinguish harmless allocation from direct or mutable shell execution APIs.
    def test_UnitT45_native_argv_allocation_and_shell_string_controls(self):
        source = '$p=[Diagnostics.ProcessStartInfo]::new();$p.UseShellExecute=$false;$p.ArgumentList.Add("cat-file")'
        source = '$g=Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1;' + source + ';$p.FileName=$g.Source'
        proof = native_proof(source, "powershell", self.pwsh)
        self.assertFalse(check_command_views(source, "powershell", proof, lambda *a, **k: False))
        source += ';$process=[Diagnostics.Process]::new();$process.StartInfo=$p;$process.Start()'
        proof = native_proof(source, "powershell", self.pwsh)
        self.assertFalse(check_command_views(source, "powershell", proof, lambda *a, **k: False))
        for source in ["[Diagnostics.Process]::Start('bash','-c payload')",
                       '$p=[Diagnostics.ProcessStartInfo]::new();$p.Arguments=$payload',
                       '$p=[Diagnostics.ProcessStartInfo]::new();$p.UseShellExecute=$true',
                       '$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName="bash"',
                       '$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName=$unresolved',
                       "$p=[Diagnostics.ProcessStartInfo]::new();$p.'Arguments'=$payload",
                       "$p=[Diagnostics.ProcessStartInfo]::new();$p.'FileName'='C:\\Windows\\System32\\cmd.exe'",
                       '$g=Get-Command bash -CommandType Application -ErrorAction Stop;$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName=$g.Source',
                       '$g=Get-Command git -CommandType Application -ErrorAction Stop;$g=$other;$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName=$g.Source',
                       'param($p);$p.Arguments=$payload;$p.Start()',
                       'param($p);$p.Start()',
                       '$p=New-Object Diagnostics.Process;$p.StartInfo.Arguments=$payload;$p.Start()',
                       '$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName=$g.Source;$g=Get-Command git -CommandType Application -ErrorAction Stop',
                       'param($g);if($condition){$g=Get-Command git -CommandType Application -ErrorAction Stop};$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName=$g.Source',
                       'param($p);if($condition){$p=[Diagnostics.Process]::new()};$p.Start()',
                       'param($info);$p=[Diagnostics.Process]::new();$p.StartInfo=$info;$p.Start()',
                       '$p=[Diagnostics.Process]::new();function f {$p.Start()};f']:
            with self.subTest(source=source):
                proof = native_proof(source, "powershell", self.pwsh)
                self.assertTrue(check_command_views(source, "powershell", proof, lambda *a, **k: False))
    # Scenario: dangerous native command operands are present in an actual command.
    # Purpose: preserve the official parser's blocking result and exact source content.
    def test_UnitT50_destructive_command_is_still_checked(self):
        text = '& $command -rf /'
        proof = native_proof(text, "powershell", self.pwsh)
        seen = []
        self.assertTrue(check_command_views(text, "powershell", proof, lambda s, **kw: seen.append(s) or ("-rf /" in s)))
        self.assertTrue(any("-rf /" in s for s in seen))

    # Scenario: PowerShell fences coexist with a real shell block in Markdown.
    # Purpose: check recognized host code independently and retain all unowned Markdown.
    def test_UnitT60_markdown_keeps_unowned_shell(self):
        text = '\x60\x60\x60powershell\nWrite-Output $x\n\x60\x60\x60\n\x60\x60\x60sh\nbash -c $payload\n\x60\x60\x60\n'
        proof = native_proof(text, "markdown", self.pwsh)
        seen = []
        self.assertTrue(check_command_views(text, "markdown", proof, lambda s, **kw: seen.append(s) or ('bash -c' in s)))
        self.assertTrue(any("bash -c" in s for s in seen))

    # Scenario: a proof belongs to different source or omits/duplicates native coverage.
    # Purpose: reject changed content and malformed ownership rather than trusting a claimed status.
    def test_UnitT70_source_and_shape_drift_are_rejected(self):
        text = "Write-Output $x\n"
        proof = native_proof(text, "powershell", self.pwsh)
        with self.assertRaises(ParserCoverageError):
            validate_proof(text + "# changed", "powershell", proof)
        for change in ("missing-unit", "duplicate-unit", "outside-command", "missing-command", "unknown-field"):
            bad = copy.deepcopy(proof)
            if change == "missing-unit": bad["units"] = []
            if change == "duplicate-unit": bad["units"] *= 2
            if change == "outside-command": bad["units"][0]["commands"][0]["end"] = 2**31
            if change == "missing-command": bad["units"][0]["commands"] = []
            if change == "unknown-field": bad["verified"] = True
            with self.subTest(change=change), self.assertRaises(ParserCoverageError):
                validate_proof(text, "powershell", bad)

    # Scenario: a non-BMP character precedes an executable command.
    # Purpose: translate UTF-16 parser offsets without splitting a surrogate pair.
    def test_UnitT80_unicode_offsets_preserve_command(self):
        text = "# \U0001f680\nWrite-Output 'value'\n"
        proof = native_proof(text, "powershell", self.pwsh)
        seen = []
        self.assertFalse(check_command_views(text, "powershell", proof, lambda s, **kw: seen.append(s) or False))
        self.assertIn("Write-Output 'value'", seen)

    # Scenario: a source exceeds the fixed resource budget.
    # Purpose: fail before starting a parser process.
    def test_UnitT90_oversized_source_is_rejected(self):
        with self.assertRaises(ParserCoverageError):
            native_proof("#" * (1024 * 1024 + 1), "powershell", self.pwsh)



    # Scenario: the official generic classifier sees a frozen .psm1 module as text.
    # Purpose: use the actual candidate extension without admitting arbitrary language claims.
    def test_UnitT95_psm1_ownership_requires_an_unambiguous_frozen_inventory(self):
        import hashlib
        import tempfile
        from types import SimpleNamespace
        from unittest.mock import patch
        import standard_static_powershell as implementation
        text = "$data='value'\nWrite-Output $data\n"
        digest = hashlib.sha256(text.encode()).hexdigest()
        runtime_hash = hashlib.sha256(Path(self.pwsh).read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as scratch:
            module_path = Path(scratch) / "synthetic.py"
            module_path.write_text("# synthetic identity boundary\n", encoding="utf-8")
            module_hash = hashlib.sha256(module_path.read_bytes()).hexdigest()
            def original(source, check_runtime, **kwargs):
                return source.startswith("$data")
            def helper(*a, **k):
                return False
            analyzer = lambda *a: ["original finding"]
            for paths, expected in [(["scripts/example.psm1"], False),
                                    (["scripts/example.txt"], True),
                                    (["scripts/example.psm1", "payload.txt"], True)]:
                module = SimpleNamespace(__file__=str(module_path), analyze=analyzer,
                                         has_bounded_parse_exhaustion=original,
                                         _has_shell_command_word_exhaustion=helper)
                with self.subTest(paths=paths), patch.object(implementation, "OFFICIAL_MODULE_SHA256", module_hash):
                    # Only the identity boundary is synthetic; the native parser is real.
                    records = implementation.install_bridge(self.pwsh, runtime_hash, module, "2.13.0", {digest: paths})
                    self.assertEqual(expected, module.has_bounded_parse_exhaustion(text, lambda: None, file_type="text"))
                    self.assertIs(module.analyze, analyzer)
                    self.assertEqual(0 if expected else 1, len(records))
                    if records:
                        self.assertEqual(0, records[0]["nativeParserProcess"]["exitCode"])

    # Scenario: a caller claims a different runtime, scanner version or official module.
    # Purpose: reject drift before installing the in-memory hook or launching a parser.
    def test_UnitT96_unreviewed_runtime_version_and_module_are_rejected(self):
        import hashlib
        import tempfile
        from types import SimpleNamespace
        from standard_static_powershell import install_bridge
        with tempfile.TemporaryDirectory() as scratch:
            file = Path(scratch) / "caller.py"
            file.write_text("# caller-authored\n", encoding="utf-8")
            module = SimpleNamespace(__file__=str(file))
            runtime_hash = hashlib.sha256(Path(self.pwsh).read_bytes()).hexdigest()
            for runtime_digest, version in [("0"*64, "2.13.0"), (runtime_hash, "999.0.0"), (runtime_hash, "2.12.0"), (runtime_hash, "2.13.0")]:
                with self.subTest(version=version), self.assertRaises(ParserCoverageError):
                    install_bridge(self.pwsh, runtime_digest, module, version, {})

if __name__ == "__main__":
    unittest.main()
