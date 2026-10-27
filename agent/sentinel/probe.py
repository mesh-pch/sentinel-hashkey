"""Red-team demo: the agent key tries things it must NOT be able to do. All are simulated with eth_call (no gas)."""
from __future__ import annotations
from .chain import Chain


def probe(c: Chain) -> int:
    lim = c.limits()
    nav = c.nav_usd()
    px = c.oracle_prices()
    usdt, btc = c.tokens["USDT"], c.tokens["BTC"]

    def trade(amount_usd, min_out_factor=1.0, venue=None, tin=usdt, tout=btc):
        raw = c.to_units("USDT", amount_usd)
        fair = raw * 10 ** c.dec["BTC"] // (int(px["BTC"] * 1e18) * 10 ** c.dec["USDT"] // 10**18) if tin == usdt else raw
        return (venue or c.venue, tin, tout, raw, int(fair * min_out_factor), b"\x11" * 32)

    cases = [
        ("trade 90% of NAV in one go", trade(nav * 0.9, 0.995), "TradeTooLarge"),
        ("accept any price (minOut = 0)", trade(nav * 0.05, 0.0), "SlippageTooLoose"),
        ("route through an unlisted venue", trade(nav * 0.05, 0.995, venue="0x000000000000000000000000000000000000dEaD"), "VenueNotAllowed"),
    ]
    ok = True
    print(f"vault NAV ${nav:,.2f}; limits: max trade {lim.max_trade_bps/100:.0f}% NAV, max slippage {lim.max_slippage_bps/100:.1f}%\n")
    for name, t, want in cases:
        try:
            c.vault.functions.executeTrade(t).call({"from": c.account.address})
            print(f"  ✗ {name}: was NOT rejected!"); ok = False
        except Exception as e:
            got = c.decode_error(e)
            flag = "✓" if got.startswith(want) else "✗"
            ok &= got.startswith(want)
            print(f"  {flag} {name}: rejected by contract -> {got}")
    try:
        c.vault.functions.withdraw(usdt, 1, c.account.address).call({"from": c.account.address})
        print("  ✗ agent withdraw: was NOT rejected!"); ok = False
    except Exception as e:
        print(f"  ✓ agent tries withdraw(): rejected -> {c.decode_error(e)[:60] or 'OwnableUnauthorizedAccount'}")
    return 0 if ok else 1
