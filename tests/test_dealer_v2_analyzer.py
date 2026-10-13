"""python -m unittest tests.test_dealer_v2_analyzer  (or: python tests/test_dealer_v2_analyzer.py)"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dealer_v2_analyzer as A


def dump(live, ledger, mode, money, generation="1"):
    lines = ["RLIDENTITY LIVE %s %s %s pen" % k for k in live]
    lines += ["RLIDENTITY LEDGER %s %s %s %s" % (k + (s,)) for k, s in ledger]
    lines.append("RLIDENTITY DUMP live=%d ledger=%d mode=%s generation=%s money=%.2f" % (len(live), len(ledger), mode, generation, money))
    return "\n".join(lines)


K1, K2 = ("41", "310001", "2"), ("41", "310002", "2")


class AnalyzerTest(unittest.TestCase):
    def good(self):
        a = dump([K1], [(K1, "CONSUMED")], "ON", 1000)
        b = dump([K1, K2], [(K1, "CONSUMED"), (K2, "CONSUMED")], "ON", 790)
        return a + "\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\n" + b

    def test_clean_session_passes(self):
        r = A.analyze(self.good())
        for name in ("LIVE-UNIQUE", "LIVE-IN-LEDGER", "MONEY-DELTA", "ORDER-ONCE", "NO-STUCK-KEYS"):
            self.assertEqual(r[name][0], "PASS", (name, r[name]))

    def test_empty_log_is_incomplete_never_pass(self):
        r = A.analyze("nothing here")
        self.assertTrue(all(v[0] == "INCOMPLETE" for v in r.values()), r)

    def test_duplicate_live_key_fails(self):
        r = A.analyze(dump([K1, K1], [(K1, "CONSUMED")], "ON", 1000))
        self.assertEqual(r["LIVE-UNIQUE"][0], "FAIL")

    def test_live_key_missing_from_ledger_fails(self):
        r = A.analyze(dump([K1, K2], [(K1, "CONSUMED")], "ON", 1000))
        self.assertEqual(r["LIVE-IN-LEDGER"][0], "FAIL")

    def test_shadow_dump_cannot_prove_ledger(self):
        r = A.analyze(dump([K1], [], "SHADOW", 1000))
        self.assertEqual(r["LIVE-IN-LEDGER"][0], "INCOMPLETE")

    def test_double_debit_fails(self):
        a = dump([K1], [(K1, "CONSUMED")], "ON", 1000)
        b = dump([K1], [(K1, "CONSUMED")], "ON", 580)
        r = A.analyze(a + "\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\n" + b)
        self.assertEqual(r["MONEY-DELTA"][0], "FAIL")

    def test_missing_debit_fails_and_income_can_be_allowed(self):
        a = dump([K1], [(K1, "CONSUMED")], "ON", 1000)
        b = dump([K1], [(K1, "CONSUMED")], "ON", 1000)
        text = a + "\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\n" + b
        self.assertEqual(A.analyze(text)["MONEY-DELTA"][0], "FAIL")
        c = dump([K1], [(K1, "CONSUMED")], "ON", 1500)
        text = a + "\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\n" + c
        self.assertEqual(A.analyze(text)["MONEY-DELTA"][0], "FAIL")
        self.assertEqual(A.analyze(text, allow_income=True)["MONEY-DELTA"][0], "PASS")

    def test_retried_order_line_counts_once(self):
        a = dump([K1], [(K1, "CONSUMED")], "ON", 1000)
        b = dump([K1], [(K1, "CONSUMED")], "ON", 790)
        text = a + "\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\n" + b
        r = A.analyze(text)
        self.assertEqual(r["MONEY-DELTA"][0], "PASS")
        self.assertEqual(r["ORDER-ONCE"][0], "PASS")

    def test_order_amount_change_fails(self):
        text = "RLDEALERV2 ORDER c-1 COMMITTED amount=210.00\nRLDEALERV2 ORDER c-1 COMMITTED amount=100.00"
        self.assertEqual(A.analyze(text)["ORDER-ONCE"][0], "FAIL")

    def test_stuck_reserved_key_fails_when_it_survives_two_dumps(self):
        a = dump([K1], [(K1, "CONSUMED"), (K2, "RESERVED")], "ON", 1000)
        b = dump([K1], [(K1, "CONSUMED"), (K2, "RESERVED")], "ON", 1000)
        self.assertEqual(A.analyze(a + "\n" + b)["NO-STUCK-KEYS"][0], "FAIL")

    def test_announced_counts_must_match_the_lines(self):
        text = "RLIDENTITY LIVE 41 310001 2 pen\nRLIDENTITY DUMP live=2 ledger=0 mode=ON generation=1 money=5.00"
        self.assertEqual(A.analyze(text)["LIVE-UNIQUE"][0], "INCOMPLETE")



class ReviewRegressions(unittest.TestCase):
    def test_old_order_reprinted_later_is_not_charged_twice(self):
        a = dump([K1], [(K1, "CONSUMED")], "ON", 1000)
        b = dump([K1], [(K1, "CONSUMED")], "ON", 790)
        c = dump([K1], [(K1, "CONSUMED")], "ON", 790)
        text = a + "\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\n" + b + "\nRLDEALERV2 ORDER c-1 COMMITTED amount=210.00\n" + c
        self.assertEqual(A.analyze(text)["MONEY-DELTA"][0], "PASS")

    def test_placeholder_identity_is_not_a_ledger_failure(self):
        ph = ("1", "1", "2")
        r = A.analyze(dump([K1, ph], [(K1, "CONSUMED")], "ON", 5))
        self.assertEqual(r["LIVE-IN-LEDGER"][0], "PASS")


if __name__ == "__main__":
    unittest.main()
