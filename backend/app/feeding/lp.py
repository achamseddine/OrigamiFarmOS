"""A small linear-programming solver for least-cost feed formulation
(master prompt Package 12; architecture/ADR-010-LEAST-COST-SOLVER.md).

    minimise  c · x
    subject to  A_ub x ≤ b_ub,  A_eq x = b_eq,  lo ≤ x ≤ hi

A dense two-phase simplex with Bland's rule (no cycling). A farm's formula
has a dozen ingredients and as many nutrient bounds: a few hundred pivots
at most, exact enough on floats with a small tolerance, and no foundational
dependency (numerical libraries) for it. Phase one finds a feasible point or
proves there is none; phase two minimises the cost from it.
"""
from __future__ import annotations

from dataclasses import dataclass, field

EPS = 1e-9
FEASIBILITY_EPS = 1e-7
MAX_PIVOTS = 5000


@dataclass
class Result:
    # optimal | infeasible | unbounded
    status: str
    x: list[float] = field(default_factory=list)
    objective: float | None = None


def _pivot(t: list[list[float]], obj: list[float], basis: list[int], r: int, j: int) -> None:
    row = t[r]
    p = row[j]
    for k in range(len(row)):
        row[k] /= p
    for i, other in enumerate(t):
        if i != r and abs(other[j]) > EPS:
            f = other[j]
            for k in range(len(other)):
                other[k] -= f * row[k]
    if abs(obj[j]) > EPS:
        f = obj[j]
        for k in range(len(obj)):
            obj[k] -= f * row[k]
    basis[r] = j


def _simplex(t: list[list[float]], obj: list[float], basis: list[int], allowed: int) -> str:
    """Minimises over the reduced costs in obj (columns < allowed may enter)."""
    for _ in range(MAX_PIVOTS):
        entering = next((j for j in range(allowed) if obj[j] < -EPS), None)  # Bland: the lowest index
        if entering is None:
            return "optimal"
        best, leaving = None, None
        for i, row in enumerate(t):
            a = row[entering]
            if a > EPS:
                ratio = row[-1] / a
                if best is None or ratio < best - EPS or (abs(ratio - best) <= EPS and basis[i] < basis[leaving]):
                    best, leaving = ratio, i
        if leaving is None:
            return "unbounded"
        _pivot(t, obj, basis, leaving, entering)
    raise RuntimeError("The solver did not converge.")


def solve(c: list[float], A_ub: list[list[float]] | None = None, b_ub: list[float] | None = None, A_eq: list[list[float]] | None = None,
          b_eq: list[float] | None = None, bounds: list[tuple[float | None, float | None]] | None = None) -> Result:
    n = len(c)
    bounds = bounds or [(0.0, None)] * n
    lo = [b[0] if b[0] is not None else 0.0 for b in bounds]
    hi = [b[1] for b in bounds]
    if any(h is not None and h < l - FEASIBILITY_EPS for l, h in zip(lo, hi)):
        return Result("infeasible")

    def shifted(a: list[float], b: float) -> float:
        return b - sum(ai * li for ai, li in zip(a, lo))

    rows: list[tuple[list[float], str, float]] = []
    for a, b in zip(A_ub or [], b_ub or []):
        rows.append((list(a), "<=", shifted(a, b)))
    for j, h in enumerate(hi):
        if h is not None:
            e = [0.0] * n
            e[j] = 1.0
            rows.append((e, "<=", h - lo[j]))
    for a, b in zip(A_eq or [], b_eq or []):
        rows.append((list(a), "=", shifted(a, b)))

    n_slack = sum(1 for _, s, _ in rows if s == "<=")
    needs_art = [s == "=" or rhs < 0 for _, s, rhs in rows]
    n_art = sum(needs_art)
    width = n + n_slack + n_art
    t: list[list[float]] = []
    basis: list[int] = []
    slack_col, art_col = n, n + n_slack
    for (a, sense, rhs), art in zip(rows, needs_art):
        row = a + [0.0] * (n_slack + n_art) + [rhs]
        if sense == "<=":
            row[slack_col] = 1.0
            slack_here = slack_col
            slack_col += 1
        else:
            slack_here = None
        if rhs < 0:
            row = [-v for v in row]
        if art:
            row[art_col] = 1.0
            basis.append(art_col)
            art_col += 1
        else:
            basis.append(slack_here)
        t.append(row)

    # Phase one: minimise the artificials.
    obj = [0.0] * (width + 1)
    for j in range(n + n_slack, width):
        obj[j] = 1.0
    for i, b in enumerate(basis):
        if b >= n + n_slack:
            obj = [o - v for o, v in zip(obj, t[i])]
    if n_art:
        _simplex(t, obj, basis, width)
        if -obj[-1] > FEASIBILITY_EPS * max(1.0, max((abs(r[-1]) for r in t), default=1.0)):
            return Result("infeasible")
        # Artificials still in the basis (at zero) are pivoted out, or their row is redundant.
        i = 0
        while i < len(t):
            if basis[i] >= n + n_slack:
                j = next((j for j in range(n + n_slack) if abs(t[i][j]) > EPS), None)
                if j is None:
                    del t[i]
                    del basis[i]
                    continue
                _pivot(t, obj, basis, i, j)
            i += 1
        for row in t:
            del row[n + n_slack:width]
        width = n + n_slack

    # Phase two: the real cost.
    obj = [float(v) for v in c] + [0.0] * n_slack + [0.0]
    for i, b in enumerate(basis):
        if abs(obj[b]) > EPS:
            f = obj[b]
            obj = [o - f * v for o, v in zip(obj, t[i])]
    status = _simplex(t, obj, basis, width)
    if status != "optimal":
        return Result(status)
    y = [0.0] * width
    for i, b in enumerate(basis):
        y[b] = t[i][-1]
    x = [lo[j] + max(0.0, y[j]) for j in range(n)]
    return Result("optimal", x, sum(cj * xj for cj, xj in zip(c, x)))
