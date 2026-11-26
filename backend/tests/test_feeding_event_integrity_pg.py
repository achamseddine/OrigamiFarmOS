"""Feeding event integrity (v0.8.7, audit I-7 / I-12) on PostgreSQL 16.

The tests of tests/test_feeding_event_integrity.py against the demo farm
seeded in PostgreSQL, through the API: the consumption check before any
stock moves, the feeding-round window over `timestamptz`, the confirmed
extra feeding and its audit, idempotent replays. Each test works in a
schema of its own (the fixtures of test_feeding_plan_policy_pg).
"""
from __future__ import annotations

import os

import pytest

from tests import test_feeding_event_integrity as integrity
# The fixture the parent classes use (their marks are inherited), resolved here.
from tests.test_feeding_event_integrity import herd_on_ration  # noqa: F401
from tests.test_feeding_plan_policy_pg import client, db_session  # noqa: F401 - PostgreSQL fixtures

pytestmark = pytest.mark.skipif(not os.environ.get("FARMOS_TEST_POSTGRES_URL"), reason="needs FARMOS_TEST_POSTGRES_URL (PostgreSQL 16)")


class TestConsumedNeverExceedsOfferedOnPostgres(integrity.TestConsumedNeverExceedsOffered):
    pass


class TestOneRoundIsNotCountedTwiceOnPostgres(integrity.TestOneRoundIsNotCountedTwice):
    pass


class TestWhoConfirmsAndReplaysOnPostgres(integrity.TestWhoConfirmsAndReplays):
    pass
