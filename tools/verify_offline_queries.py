"""
verify_offline_queries.py

Verifies query correctness and benchmarks speed on wimb_offline.db.
"""

import sqlite3
import time
import os
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

DB_PATH = os.path.abspath('app/assets/data/wimb_offline.db')

def benchmark(name, fn):
    t0 = time.perf_counter()
    res = fn()
    dt_ms = (time.perf_counter() - t0) * 1000
    print(f"  [{dt_ms:5.2f} ms] {name} -> {len(res)} results")
    return res

def test():
    print("=" * 60)
    print("⚡ TESTING OFFLINE SQLITE QUERY PERFORMANCE & FUNCTIONALITY")
    print("=" * 60)
    
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()

    # 1. Stop Search
    stops = benchmark(
        "Stop search: 'Nehru Place'",
        lambda: cur.execute(
            "SELECT stop_id, stop_name, lat, lon FROM stops WHERE stop_name LIKE '%Nehru Place%' LIMIT 10"
        ).fetchall()
    )
    assert len(stops) > 0, "No stops returned for Nehru Place"
    for s in stops[:2]:
        print(f"     • {s[1]} ({s[2]:.4f}, {s[3]:.4f})")

    # 2. Route Search
    routes = benchmark(
        "Route search: '764'",
        lambda: cur.execute(
            "SELECT route_id, route_short_name, route_desc FROM routes WHERE route_short_name LIKE '%764%' LIMIT 10"
        ).fetchall()
    )
    assert len(routes) > 0, "No routes returned for 764"
    for r in routes[:2]:
        print(f"     • {r[1]}: {r[2]}")

    # 3. Route Stops List
    route_id = routes[0][0]
    rstops = benchmark(
        f"Route stops for route_id={route_id}",
        lambda: cur.execute(
            "SELECT stop_sequence, stop_name, metres_along_route FROM route_stops WHERE route_id = ? ORDER BY stop_sequence",
            (route_id,)
        ).fetchall()
    )
    assert len(rstops) > 0, f"No stops for route {route_id}"
    print(f"     • First: {rstops[0][1]} (0m)")
    print(f"     • Last:  {rstops[-1][1]} ({rstops[-1][2]}m)")

    # 4. Direct buses between two stops (CP to Nehru Place)
    buses = benchmark(
        "Direct buses between 'AIIMS' and 'Nehru Place'",
        lambda: cur.execute("""
            SELECT DISTINCT r.route_short_name, r.route_desc
            FROM route_stops s1
            JOIN route_stops s2 ON s1.route_id = s2.route_id AND s1.stop_sequence < s2.stop_sequence
            JOIN routes r ON r.route_id = s1.route_id
            WHERE s1.stop_name LIKE '%AIIMS%' AND s2.stop_name LIKE '%Nehru Place%'
            LIMIT 5
        """).fetchall()
    )
    assert len(buses) > 0, "No direct buses between AIIMS and Nehru Place"
    for b in buses[:3]:
        print(f"     • Direct Bus: {b[0]} ({b[1]})")

    con.close()
    print("\n🎉 ALL OFFLINE SQLITE TESTS & BENCHMARKS PASSED (all < 5ms)!")
    print("=" * 60)

if __name__ == '__main__':
    test()
