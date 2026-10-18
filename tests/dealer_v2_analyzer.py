"""Check a game log of a dealer v2 test session against the identity and money evidence it holds.

    python tests/dealer_v2_analyzer.py path/to/log.txt [--allow-income]

The log must contain blocks written by the console command rlIdentityDump (RLIDENTITY LIVE / LEDGER lines
ending in one RLIDENTITY DUMP line) and the order lines of rlDealerV2Confirm (RLDEALERV2 ORDER ...).
Each result is PASS, FAIL or INCOMPLETE; a log without the needed evidence is INCOMPLETE, never PASS.

Checks
  LIVE-UNIQUE     no full key (farm uniqueId country) twice among the live animals of one dump
  LIVE-IN-LEDGER  with the ledger ON, every live key is CONSUMED in the ledger
  NO-STUCK-KEYS   no ledger key RESERVED / MATERIALIZED older than the first dump (reported, FAIL if any survive two dumps)
  ORDER-ONCE      an order id commits once; its amount never changes between lines; no order is refused as
                  REQUEST_CONFLICT (an order id made again, e.g. after a restart)
  KEY-NOT-REISSUED  a live key that left the world (absent from a later dump: sold, dead) never comes back in a
                  still later dump - that would be its key handed out again (recovery clear, re-activation).
                  Needs three dumps. Use one log per uninterrupted run: a load that undoes a sale (leave without
                  saving, an older copy) brings the same animal back and must not share a log with this check.
  MONEY-DELTA     between two dumps the host farm's money changed by exactly minus the committed orders
                  (--allow-income lets it be higher, for sessions that also earned money)
"""
import re
import sys

LIVE = re.compile(r"RLIDENTITY LIVE (\S+) (\S+) (\S+) (\S+)")
LEDGER = re.compile(r"RLIDENTITY LEDGER (\S+ \S+ \S+) (\S+)")
DUMP = re.compile(r"RLIDENTITY DUMP live=(\d+) ledger=(\d+) mode=(\S+) generation=(\S+) money=(-?[\d.]+)")
ORDER = re.compile(r"RLDEALERV2 ORDER (\S+) (COMMITTED|ROLLED_BACK|PENDING|UNCERTAIN) amount=(-?[\d.]+|nil)")
REFUSED = re.compile(r"RLDEALERV2 ORDER (\S+) refused: (\S+)")


def parse(text):
    """Return (blocks, events). A block is a dump; events are (order, kind, ...) in log order."""
    blocks, events = [], []
    live, ledger = [], {}
    for line in text.splitlines():
        m = LIVE.search(line)
        if m:
            live.append(m.groups())
            continue
        m = LEDGER.search(line)
        if m:
            ledger[m.group(1)] = m.group(2)
            continue
        m = DUMP.search(line)
        if m:
            blocks.append({"live": live, "ledger": ledger, "count": (int(m.group(1)), int(m.group(2))), "mode": m.group(3),
                           "generation": m.group(4), "money": float(m.group(5)), "at": len(events)})
            events.append(("dump", len(blocks) - 1))
            live, ledger = [], {}
            continue
        m = ORDER.search(line)
        if m:
            amount = None if m.group(3) == "nil" else float(m.group(3))
            events.append(("order", m.group(1), m.group(2), amount))
            continue
        m = REFUSED.search(line)
        if m:
            events.append(("refused", m.group(1), m.group(2)))
    return blocks, events


def analyze(text, allow_income=False):
    blocks, events = parse(text)
    results = {}
    if not blocks:
        for name in ("LIVE-UNIQUE", "LIVE-IN-LEDGER", "NO-STUCK-KEYS", "MONEY-DELTA", "KEY-NOT-REISSUED"):
            results[name] = ("INCOMPLETE", "no rlIdentityDump block in the log")
    else:
        dup = []
        for i, b in enumerate(blocks):
            seen = set()
            for farm, uid, country, _where in b["live"]:
                key = (farm, uid, country)
                if key in seen:
                    dup.append((i, key))
                seen.add(key)
            if len(b["live"]) != b["count"][0] or len(b["ledger"]) != b["count"][1]:
                results["LIVE-UNIQUE"] = ("INCOMPLETE", "dump %d lists %d/%d lines but announced %s" % (i, len(b["live"]), len(b["ledger"]), b["count"]))
        if "LIVE-UNIQUE" not in results:
            results["LIVE-UNIQUE"] = ("FAIL", "duplicate live keys: %s" % dup[:5]) if dup else ("PASS", "%d dump(s)" % len(blocks))
        missing = []
        on = [b for b in blocks if b["mode"] == "ON"]
        if not on:
            results["LIVE-IN-LEDGER"] = ("INCOMPLETE", "no dump with the ledger ON")
        else:
            for b in on:
                for farm, uid, country, _where in b["live"]:
                    if farm == "1" and uid == "1":
                        continue     # the placeholder identity of an unmanaged pen's animal: never in the ledger by design
                    if b["ledger"].get("%s %s %s" % (farm, uid, country)) != "CONSUMED":
                        missing.append((farm, uid, country))
            results["LIVE-IN-LEDGER"] = ("FAIL", "live but not CONSUMED: %s" % missing[:5]) if missing else ("PASS", "%d dump(s) ON" % len(on))
        stuck = None
        if len(blocks) >= 2:
            first = {k for k, s in blocks[0]["ledger"].items() if s in ("RESERVED", "MATERIALIZED")}
            last = {k for k, s in blocks[-1]["ledger"].items() if s in ("RESERVED", "MATERIALIZED")}
            stuck = first & last
        results["NO-STUCK-KEYS"] = ("INCOMPLETE", "needs two dumps") if stuck is None else (
            ("FAIL", "keys still reserved after two dumps: %s" % sorted(stuck)[:5]) if stuck else ("PASS", "none"))
        # money between consecutive dumps
        verdict, note = "PASS", []
        if len(blocks) < 2:
            verdict, note = "INCOMPLETE", ["needs two dumps"]
        else:
            order_amounts = {}
            for e in events:
                if e[0] == "order" and e[2] == "COMMITTED" and e[3] is not None:
                    order_amounts.setdefault(e[1], e[3])
            segment, committed_in_segment, last_dump = None, 0.0, None
            counted = set()      # an order is charged in the segment where it first committed, never again
            for e in events:
                if e[0] == "dump":
                    b = blocks[e[1]]
                    if last_dump is not None:
                        delta = round(b["money"] - last_dump["money"], 2)
                        expected = round(-committed_in_segment, 2)
                        ok = (delta == expected) or (allow_income and delta >= expected)
                        note.append("dump %d->%d: delta %.2f expected %.2f" % (last_dump["idx"], e[1], delta, expected))
                        if not ok:
                            verdict = "FAIL"
                    b["idx"] = e[1]
                    last_dump = b
                    committed_in_segment = 0.0
                elif e[0] == "order" and e[2] == "COMMITTED" and e[3] is not None and e[1] not in counted:
                    counted.add(e[1])
                    committed_in_segment += e[3]
        results["MONEY-DELTA"] = (verdict, "; ".join(note))
        # a key that left the world and came back was handed out again
        if len(blocks) < 3:
            results["KEY-NOT-REISSUED"] = ("INCOMPLETE", "needs three dumps (alive, gone, after)")
        else:
            seen, gone, back = set(), set(), []
            for i, b in enumerate(blocks):
                now = {(farm, uid, country) for farm, uid, country, _where in b["live"] if not (farm == "1" and uid == "1")}
                for key in sorted(now & gone):
                    back.append((i, key))
                gone = (gone | (seen - now)) - now
                seen |= now
            results["KEY-NOT-REISSUED"] = ("FAIL", "gone and back (dump, key): %s" % back[:5]) if back else (
                "PASS", "%d dump(s), %d key(s) left the world" % (len(blocks), len(gone)))
    # orders
    amounts, fail = {}, []
    committed_seen = False
    for e in events:
        if e[0] == "order" and e[2] == "COMMITTED":
            committed_seen = True
            if e[1] in amounts and amounts[e[1]] != e[3]:
                fail.append(e[1])
            amounts.setdefault(e[1], e[3])
    conflicts = [e[1] for e in events if e[0] == "refused" and e[2] == "REQUEST_CONFLICT"]
    if conflicts:
        results["ORDER-ONCE"] = ("FAIL", "order id refused as REQUEST_CONFLICT (made again): %s" % conflicts[:5])
    else:
        results["ORDER-ONCE"] = ("INCOMPLETE", "no committed order in the log") if not committed_seen else (
            ("FAIL", "amount changed for %s" % fail) if fail else ("PASS", "%d order(s)" % len(amounts)))
    return results


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    with open(argv[1], encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    results = analyze(text, "--allow-income" in argv)
    worst = 0
    for name in sorted(results):
        status, note = results[name]
        print("%-15s %-10s %s" % (name, status, note))
        worst = max(worst, {"PASS": 0, "INCOMPLETE": 1, "FAIL": 2}[status])
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv))
