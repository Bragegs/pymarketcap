#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from random import randint
from datetime import datetime, timedelta
from pprint import pprint

from pymarketcap.tests.graphs import assert_types
from pymarketcap import Pymarketcap
pym = Pymarketcap()

def test_types():
    res = pym.graphs.dominance()

    assert_types(res)

def test_consistence():
    res = pym.graphs.dominance()

    fields = list(res.keys())
    assert "others" in fields

def test_start_end():
    today = datetime.now()
    days_ago = today - timedelta(days=randint(1, 15))

    res = pym.graphs.dominance(start=days_ago)
    key = list(res.keys())[0]
    assert res[key][-1][0].day == today.day
    assert res[key][0][0].day in [days_ago.day,
                                  (days_ago+timedelta(days=1)).day]
