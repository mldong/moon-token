import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from check_doc_tables import main, table_errors


class DocTableTests(unittest.TestCase):
    def test_contiguous_rows(self):
        self.assertEqual(table_errors("| # | Decision |\n|---|---|\n| 7.1 | First |\n| 7.2 | Second |\n"), [])

    def test_alignment_delimiters(self):
        self.assertEqual(table_errors("| # | Decision |\n|:--|--:|\n| 1 | First |\n"), [])

    def test_blank_line_break(self):
        errors = table_errors("| # | Decision |\n|---|---|\n| 7.1 | First |\n\n| 7.2 | Second |\n")
        self.assertEqual([line for line, _ in errors], [5])

    def test_blockquote_break(self):
        errors = table_errors("| # | Decision |\n|---|---|\n| 7.14 | Last |\n\n> Explanation\n| 7.10 | Earlier |\n| 7.11 | Next |\n")
        self.assertEqual([line for line, _ in errors], [6, 7])

    def test_heading_break(self):
        errors = table_errors("| # | Decision |\n|---|---|\n| 1 | First |\n## Next\n| 2 | Second |\n")
        self.assertEqual([line for line, _ in errors], [5])

    def test_new_table_resets_identifiers(self):
        table = "| # | Decision |\n|---|---|\n| 1 | First |\n"
        self.assertEqual(table_errors(table + "\n> Explanation\n\n" + table), [])

    def test_duplicate_identifier(self):
        errors = table_errors("| # | Decision |\n|---|---|\n| 8.14 | First |\n| 8.14 | Second |\n")
        self.assertEqual(errors, [(4, "duplicate row identifier: 8.14")])

    def test_non_numeric_first_cells_can_repeat(self):
        self.assertEqual(table_errors("| State | Value |\n|---|---|\n| Active | One |\n| Active | Two |\n"), [])

    def test_code_fences_ignore_table_shaped_text(self):
        for fence in ("```", "~~~", "````"):
            with self.subTest(fence=fence):
                self.assertEqual(table_errors(fence + "text\n| not a table |\n" + fence + "\n"), [])

    def test_shorter_fence_does_not_close_block(self):
        self.assertEqual(table_errors("````markdown\n```\n| still code |\n````\n"), [])

    def test_cli_rejects_bad_file_and_reports_location(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.md"
            path.write_text("| orphan |\n", encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                result = main([str(path)])
            self.assertEqual(result, 1)
            self.assertIn(str(path) + ":1:", output.getvalue())
            self.assertIn("DOC TABLE CHECK FAIL", output.getvalue())

    def test_cli_checks_each_file(self):
        with tempfile.TemporaryDirectory() as directory:
            good, bad = Path(directory) / "good.md", Path(directory) / "bad.md"
            good.write_text("# Text\n", encoding="utf-8")
            bad.write_text("| orphan |\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main([str(good)]), 0)
                self.assertEqual(main([str(good), str(bad)]), 1)
                self.assertEqual(main([]), 2)


if __name__ == "__main__":
    unittest.main()
