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
let results = cases.map { item -> Any in
    if item["operation"] as? String == "clean" {
        guard let range = PasteBaseline.cleanPasteRange(before: item["before"] as! String,
            after: item["after"] as! String, pasted: item["pasted"] as! String) else { return NSNull() }
        return [range.location, range.length]
    }
    if item["operation"] as? String == "evidence" {
        return PasteBaseline.hasPastedTextEvidence(in: item["text"] as! String, pastedText: item["pasted"] as! String)
    }
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

    def check_clean(self, *, before, after, pasted, expected):
        case = dict(operation="clean", before=before, after=after, pasted=pasted)
        result = subprocess.run([self.binary], input=json.dumps([case]),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), [expected], case)

    def test_clean_paste_is_located_from_text_without_a_caret(self):
        self.check_clean(before="abc", after="abchello", pasted="hello", expected=[3, 0])
        self.check_clean(before="ab\ncd", after="ab\nXYcd", pasted="XY", expected=[3, 0])
        self.check_clean(before="", after="hello", pasted="hello", expected=[0, 0])
        # UTF-16 offsets: the globe emoji occupies two units.
        self.check_clean(before="你好🌍", after="你好🌍世界", pasted="世界", expected=[4, 0])

    def test_clean_paste_covers_selection_replacement(self):
        self.check_clean(before="one two three", after="one 2 three", pasted="2", expected=[4, 3])
        self.check_clean(before="say hello", after="say hello", pasted="hello", expected=[4, 5])

    def test_clean_paste_tolerates_dropped_final_separator_and_repeats(self):
        self.check_clean(before="abc", after="abchello", pasted="hello\n", expected=[3, 0])
        self.check_clean(before="aa", after="aaa", pasted="a", expected=[2, 0])

    def test_clean_paste_rejects_any_other_change(self):
        self.check_clean(before="abc", after="abXchello", pasted="hello", expected=None)
        self.check_clean(before="abc", after="abcHello", pasted="hello", expected=None)
        self.check_clean(before="abc", after="abc", pasted="hello", expected=None)
        self.check_clean(before="abc", after="ab", pasted="hello", expected=None)

    def check_evidence(self, *, text, pasted, expected):
        case = dict(operation="evidence", text=text, pasted=pasted)
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

    def test_existing_pasted_line_terminator_cannot_be_deleted_or_changed(self):
        for newline in ("\n", "\r\n"):
            for start in (None, 0):
                with self.subTest(newline=newline, start=start):
                    values = dict(before="", start=start, after="hello" + newline, pasted="hello" + newline)
                    self.check(**values, current="hello", expected=False)
                    other = "\r\n" if newline == "\n" else "\n"
                    self.check(**values, current="hello" + other, expected=False)

    def test_multiline_paste_preserves_each_original_line_terminator(self):
        values = dict(before="head\n> ", start=7, after="head\n> first\nsecond\r\n", pasted="first\nsecond\r\n")
        self.check(**values, current="head\n> first\nsecond", expected=False)
        self.check(**values, current="head\n> first\r\nsecond\r\n", expected=False)
        self.check(**values, current="new head\n> first\nsecond\r\nnew output", expected=True)

    def test_settlement_detects_deleted_or_changed_pasted_line_terminator(self):
        for newline in ("\n", "\r\n"):
            for start in (None, 0):
                with self.subTest(newline=newline, start=start):
                    self.check_settlement(before="", start=start, after="hello", pasted="hello" + newline, expected=True)
                    other = "\r\n" if newline == "\n" else "\n"
                    self.check_settlement(before="", start=start, after="hello" + other, pasted="hello" + newline, expected=True)
        for start in (None, 0):
            values = dict(before="", start=start, pasted="first\nsecond\r\n")
            self.check_settlement(**values, after="first\nsecond", expected=True)
            self.check_settlement(**values, after="first\r\nsecond\r\n", expected=True)
            self.check_settlement(**values, after="first\nsecond\r\n", expected=False)
        self.check_settlement(before="draft ", after="draft hello", pasted="hello\n", expected=True)

    def test_paste_evidence_rejects_history_refresh_without_actual_transcription(self):
        self.check_evidence(text="new history\n> ", pasted="hello", expected=False)
        self.check_evidence(text="new history\n> hello", pasted="hello", expected=True)
        # Evidence is a minimum content condition, rather than a history-count heuristic.
        self.check_evidence(text="hello\n> ", pasted="hello", expected=True)

    def test_paste_evidence_accepts_multiline_and_crlf_lf_equivalence(self):
        self.check_evidence(text="prefix\r\n你好🌍\r\nsecond\r\nsuffix", pasted="你好🌍\nsecond\n", expected=True)
        self.check_evidence(text="你好🌍\nsecond", pasted="你好🌍\r\nsecond\r\n", expected=True)
        self.check_evidence(text="hello", pasted="hello\n", expected=True)
        self.check_evidence(text="hello", pasted="hello\r\n", expected=True)

    def test_paste_evidence_does_not_discard_substantive_characters_or_extra_newlines(self):
        for text, pasted in (("hell", "hello"), ("hello", "hello!"), ("hello", " hello "),
                             ("hello", "\nhello"), ("hello", "hello\n\n"),
                             ('say “hello”', 'say "hello"'), ("你好", "你好🌍")):
            with self.subTest(text=text, pasted=pasted):
                self.check_evidence(text=text, pasted=pasted, expected=False)
        self.check_evidence(text="hello\n", pasted="hello\n\n", expected=True)
        self.check_evidence(text="prefix hello! suffix", pasted="hello!", expected=True)

    def test_paste_evidence_rejects_empty_or_only_whitespace_values(self):
        for text in ("", "\n", "\r\n\n", " \t\n"):
            with self.subTest(text=text):
                self.check_evidence(text=text, pasted="hello", expected=False)
        for pasted in ("", "\n", "\r\n\n", " \t\n"):
            with self.subTest(pasted=pasted):
                self.check_evidence(text="hello\n", pasted=pasted, expected=False)


if __name__ == "__main__":
    unittest.main()
