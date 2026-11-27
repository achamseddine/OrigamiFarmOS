"""The least-cost solver (app/feeding/lp.py; ADR-010) on problems with known answers."""
from __future__ import annotations

import pytest

from app.feeding import lp


def test_a_textbook_minimum():
    # min -x - y  s.t. x + 2y ≤ 4, 3x + y ≤ 6 → x = 1.6, y = 1.2
    r = lp.solve([-1, -1], A_ub=[[1, 2], [3, 1]], b_ub=[4, 6])
    assert r.status == "optimal"
    assert r.x == pytest.approx([1.6, 1.2], abs=1e-9) and r.objective == pytest.approx(-2.8)


def test_equalities_bounds_and_a_ge_row():
    # The cheapest 100 kg of three grains with at least 12 % protein: barley 11 %, soy 44 %, corn 8 %.
    price = [0.36, 0.70, 0.30]
    protein = [11, 44, 8]
    r = lp.solve(price, A_ub=[[-p for p in protein]], b_ub=[-12 * 100], A_eq=[[1, 1, 1]], b_eq=[100], bounds=[(0, None), (0, None), (0, 80)])
    assert r.status == "optimal"
    assert sum(r.x) == pytest.approx(100)
    assert sum(p * x for p, x in zip(protein, r.x)) >= 1200 - 1e-6
    assert r.x[2] <= 80 + 1e-9
    # Corn to its 80 kg cap; barley and soybean share the rest so the protein is exactly 12 %
    # (11b + 44s = 560, b + s = 20). Below the best whole-kg mix (USD 34.84), as a continuous optimum must be.
    assert r.x == pytest.approx([320 / 33, 340 / 33, 80], abs=1e-6)
    assert r.objective == pytest.approx(0.36 * 320 / 33 + 0.70 * 340 / 33 + 0.30 * 80) and r.objective < 34.84


def test_lower_bounds_are_kept():
    r = lp.solve([1, 1], A_eq=[[1, 1]], b_eq=[10], bounds=[(3, None), (2, None)])
    assert r.status == "optimal" and r.x[0] >= 3 - 1e-9 and r.x[1] >= 2 - 1e-9 and r.objective == pytest.approx(10)


def test_infeasible_and_unbounded_are_said():
    assert lp.solve([1, 1], A_ub=[[1, 1]], b_ub=[5], A_eq=[[1, 1]], b_eq=[10]).status == "infeasible"
    assert lp.solve([1], bounds=[(5, 3)]).status == "infeasible"
    assert lp.solve([-1, 0], A_ub=[[0, 1]], b_ub=[1]).status == "unbounded"


def test_a_degenerate_problem_does_not_cycle():
    # Beale's cycling example (cycles under the classic largest-coefficient rule, not under Bland's).
    c = [-0.75, 150, -0.02, 6]
    A = [[0.25, -60, -0.04, 9], [0.5, -90, -0.02, 3], [0, 0, 1, 0]]
    r = lp.solve(c, A_ub=A, b_ub=[0, 0, 1])
    assert r.status == "optimal" and r.objective == pytest.approx(-0.05)


def test_redundant_equalities():
    r = lp.solve([1, 2], A_eq=[[1, 1], [2, 2]], b_eq=[4, 8])
    assert r.status == "optimal" and r.x == pytest.approx([4, 0])
