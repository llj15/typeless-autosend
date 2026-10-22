"""Compile and exercise the production paste-region algorithm without macOS APIs."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class PasteBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="autosend-paste-baseline-")
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        (root / "main.swift").write_text(r'''
import Foundation

let data = FileHandle.standardInput.readDataToEndOfFile()
let cases = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
let results = cases.map { item -> Bool in
    if item["operation"] as? String == "settlement" {
        return PasteBaseline.settlementWasEdited(
            beforeText: item["before"] as! String,
            insertionStart: item["start"] as? Int,
            insertionLength: item["length"] as? Int ?? 0,
            afterText: item["after"] as! String,
            pastedText: item["pasted"] as! String)
    }
    let baseline = PasteBaseline(
        beforeText: item["before"] as? String,
        insertionStart: item["start"] as? Int,
        insertionLength: item["length"] as? Int ?? 0,
        afterText: item["after"] as! String,
        pastedText: item["pasted"] as! String)
    return baseline.matches(item["current"] as! String)
}
print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
''')
        cls.binary = root / "paste-baseline"
        result = subprocess.run(
            ["swiftc", str(ROOT / "PasteBaseline.swift"), str(root / "main.swift"),
             "-o", str(cls.binary)], capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def check(self, *, before=None, start=None, length=0, after, pasted, current, expected):
        case = dict(before=before, start=start, length=length, after=after,
                    pasted=pasted, current=current)
        result = subprocess.run([self.binary], input=json.dumps([case]),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), [expected], case)

    def check_settlement(self, *, before, start=None, length=0, after, pasted, expected):
        case = dict(operation="settlement", before=before, start=start, length=length,
                    after=after, pasted=pasted)
        result = subprocess.run([self.binary], input=json.dumps([case]),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), [expected], case)

    def test_cursor_selects_full_line_and_allows_other_rows_to_refresh(self):
        values = dict(before="status\nprompt: \nfooter", start=15,
                      after="status\nprompt: hello\nfooter", pasted="hello")
        self.check(**values, current="new status\nprompt: hello\nnew footer", expected=True)
        self.check(**values, current="status\nprompt: HELLO\nfooter", expected=False)
        self.check(**values, current="status\nchanged: hello\nfooter", expected=False)

    def test_utf16_offset_and_selected_text_replacement(self):
        values = dict(before="😀\nask: old\nend", start=8, length=3,
                      after="😀\nask: 你好🌍\nend", pasted="你好🌍")
        self.check(**values, current="🧭\nask: 你好🌍\nnew end", expected=True)
        self.check(**values, current="😀\nask: 你好🌎\nend", expected=False)

    def test_multiple_pasted_lines_are_protected(self):
        values = dict(before="head\n> \nfoot", start=7,
                      after="head\n> first\nsecond\nfoot", pasted="first\nsecond")
        self.check(**values, current="new head\n> first\nsecond\nnew foot", expected=True)
        self.check(**values, current="head\n> first\nextra\nsecond\nfoot", expected=False)
        self.check(**values, current="head\n> first\nSECOND\nfoot", expected=False)

    def test_newline_at_end_does_not_protect_following_line(self):
        values = dict(before="head\nfoot", start=5,
                      after="head\nhello\nfoot", pasted="hello\n")
        self.check(**values, current="head\nhello\nchanged foot", expected=True)
        self.check(**values, current="head\nHELLO\nfoot", expected=False)

    def test_crlf_line_boundaries(self):
        values = dict(before="head\r\n> \r\nfoot", start=8,
                      after="head\r\n> hello\r\nfoot", pasted="hello")
        self.check(**values, current="changed\r\n> hello\r\nother", expected=True)
        self.check(**values, current="head\r\n> HELLO\r\nfoot", expected=False)

    def test_missing_cursor_finds_new_occurrence_among_history(self):
        values = dict(before="ok\nhistory\n> ", after="ok\nhistory\n> ok", pasted="ok")
        self.check(**values, current="ok\nnew history\n> ok", expected=True)
        self.check(**values, current="ok\nhistory\n> edited", expected=False)

    def test_alignment_tolerates_refresh_between_snapshots(self):
        values = dict(before="status 1\nok\n> ", after="status 2\nok\n> ok", pasted="ok")
        self.check(**values, current="status 3\nok\n> ok", expected=True)
        self.check(**values, current="status 2\nok\n> edited", expected=False)

    def test_duplicate_pasted_lines_do_not_mask_target_edit(self):
        values = dict(before="ok\nanchor\n", start=10,
                      after="ok\nanchor\nok", pasted="ok")
        self.check(**values, current="ok\nanchor\nedited", expected=False)
        self.check(**values, current="edited history\nanchor\nok", expected=True)
        self.check(**values, current="new header\nok\nanchor\nok", expected=True)

    def test_ambiguous_identical_rows_cancel_instead_of_using_history(self):
        self.check(before="ok\n", after="ok\nok\n", pasted="ok\n",
                   current="changed outside\nok\n", expected=False)
        self.check(before="ok\n", start=3, after="ok\nok\n", pasted="ok\n",
                   current="ok\n", expected=False)

    def test_unlocatable_or_empty_paste_uses_whole_input(self):
        for extra in ({}, {"before": "history ok\nold"}, {"start": -1},
                      {"start": 999}, {"before": "old", "start": 1, "length": -1}):
            self.check(**extra, after="history ok\nnew", pasted="missing",
                       current="changed ok\nnew", expected=False)
            self.check(**extra, after="history ok\nnew", pasted="missing",
                       current="history ok\nnew", expected=True)
        self.check(before="old", after="head\nbody", pasted="",
                   current="new head\nbody", expected=False)

    def test_missing_before_with_valid_cursor_still_locates(self):
        self.check(start=5, after="head\nhello\nfoot", pasted="hello",
                   current="new head\nhello\nnew foot", expected=True)

    def test_unavailable_cursor_replacement_falls_back_safely(self):
        self.check(before="head\nold\nfoot", after="head\nhello\nfoot", pasted="hello",
                   current="changed head\nhello\nfoot", expected=False)

    def test_cursor_identity_survives_external_refresh_shifting_utf16_offset(self):
        values = dict(before="status\n> ", start=9,
                      after="status XXok\n> ok", pasted="ok")
        self.check(**values, current="status XXok\n> changed", expected=False)
        self.check(**values, current="changed status\n> ok", expected=True)

    def test_unknown_selection_replacement_cannot_choose_external_refresh(self):
        values = dict(before="old\n> old", after="oldok\n> ok", pasted="ok")
        self.check(**values, current="oldok\n> edited", expected=False)
        self.check(**values, current="changed\n> ok", expected=False)

    def test_unique_target_survives_deleted_header_and_added_footer(self):
        self.check(before="status\n> \n", start=9,
                   after="status\n> ok\n", pasted="ok",
                   current="> ok\nnew status\n", expected=True)

    def test_new_output_after_unterminated_target_line_is_outside_region(self):
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline):
                before = "status" + newline + "> "
                self.check(before=before, start=len(before), after=before + "ok", pasted="ok",
                           current=before + "ok" + newline + "new output", expected=True)

    def test_settlement_rejects_extra_edit_before_locking_baseline(self):
        values = dict(before="draft ", start=6, pasted="hello")
        self.check_settlement(**values, after="draft hello!", expected=True)
        self.check_settlement(**values, after="draft hello", expected=False)

    def test_settlement_can_prove_extra_edit_without_cursor(self):
        self.check_settlement(before="draft ", after="draft hello!", pasted="hello", expected=True)
        self.check_settlement(before="draft ", after="draft hello", pasted="hello", expected=False)
        self.check_settlement(before="status\n> ", after="new status\n> hello!", pasted="hello", expected=True)

    def test_settlement_ignores_external_refresh_and_new_output(self):
        values = dict(before="status\n> ", start=9, pasted="hello")
        self.check_settlement(**values, after="new status\n> hello", expected=False)
        self.check_settlement(**values, after="status\n> hello\noutput", expected=False)

    def test_settlement_unlocatable_and_ambiguous_snapshots_do_not_guess(self):
        self.check_settlement(before="draft ", start=6, after="unrelated screen", pasted="hello", expected=False)
        self.check_settlement(before="draft ", after="unrelated screen", pasted="hello", expected=False)
        self.check_settlement(before="draft \ndraft ", after="draft hello!\ndraft hello!",
                              pasted="hello", expected=False)
        self.check_settlement(before="old\n> old", after="oldok\n> ok", pasted="ok", expected=False)

    def test_settlement_detects_rewritten_or_deleted_paste_with_stable_context(self):
        values = dict(before="draft ", start=6, pasted="hello")
        self.check_settlement(**values, after="draft hallo", expected=True)
        self.check_settlement(**values, after="draft ", expected=True)
        self.check_settlement(before=" tail", start=0, after="hallo tail", pasted="hello", expected=True)

    def test_settlement_handles_utf16_selection_and_multiline_edits(self):
        values = dict(before="😀\nask: old\nfooter", start=8, length=3, pasted="你好\nworld")
        self.check_settlement(**values, after="😀\nask: 你好\nworld!\nfooter", expected=True)
        self.check_settlement(**values, after="new header\nask: 你好\nworld\nnew footer", expected=False)
        self.check_settlement(**values, after="😀\nask: \nfooter", expected=True)


if __name__ == "__main__":
    unittest.main()
