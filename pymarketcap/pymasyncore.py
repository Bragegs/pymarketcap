#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Standard Python modules
import re
import logging
from json import loads
from datetime import datetime
from collections import OrderedDict
from asyncio import (
    ensure_future,
    Queue,
    TimeoutError
)

# External Python dependencies
from aiohttp import ClientSession
from tqdm import tqdm

# Internal Cython modules
from pymarketcap import Pymarketcap

# Internal Python modules
from pymarketcap.consts import (
    DEFAULT_TIMEOUT,
    exceptional_coin_slugs,
    DEFAULT_FORMATTER
)
from pymarketcap import processer
_is_symbol = processer._is_symbol

# Logging initialization
logger_name = "/pymarketcap%s" % __file__.split("pymarketcap")[-1]
logger = logging.getLogger(logger_name)
handler = logging.StreamHandler()
handler.setFormatter(DEFAULT_FORMATTER)
logger.addHandler(handler)

class AsyncPymarketcapScraper(ClientSession):
    """Asynchronous scraper for coinmarketcap.com
    The next methods are the most powerful, because they
    involve several get requests:
        [self.every_currency]

    Args:
        queue_size (int): Number of maximum simultanenous
           get requests performing together in methods
           involving several requests.
        progress_bar(bool): Select ``True`` or ``False`` if you
            want to show a progress bar in methods involving
            processing of several requests (requires ``tqdm``
            module). As default, ``True``.
        consumers(int): Number of consumers resolving http
            requests in from an internal ``asyncio.Queue``.
            As default, 10.
        timeout (int/float, optional): Limit max time
            waiting for a response. As default, ``15``.
        logger (logging.logger): As default with
            ``logging.StreamHandler()``.
        debug (bool, optional): If ``True``, the logger
            level will be setted as ``logging.DEBUG``.
        **kwargs: arguments that corresponds to
            ``aiohttp.ClientSession``.

    """

    def __init__(self, queue_size=50, progress_bar=True,
                 consumers=50, timeout=DEFAULT_TIMEOUT,
                 logger=logger, debug=False,
                 **kwargs):
        super(AsyncPymarketcapScraper, self).__init__(**kwargs)
        self.timeout = timeout
        self.logger = logger
        self.sync = Pymarketcap()
        self.queue_size = queue_size
        self.connector_limit = self.connector.limit
        self._responses = []
        self.progress_bar = progress_bar
        self.consumers = consumers

        if debug:
            self.logger.setLevel(logging.DEBUG)

    # PROPERTIES

    @property
    def correspondences(self):
        try:
            return self._correspondences
        except AttributeError:
            self._correspondences = self.sync._cache_symbols_ids()[0]
            return self._correspondences

    @property
    def symbols(self):
        try:
            return self._symbols
        except AttributeError:
            self._symbols = sorted(list(self.sync.correspondences.keys()))
            return self._symbols

    @property
    def coins(self):
        try:
            return self._coins
        except AttributeError:
            self._coins = sorted(list(self.sync.correspondences.values()))
            return self._coins

    @property
    def exchange_names(self):
        """Get all exchange formatted names provided by coinmarketcap."""
        try:
            return self._exchange_names
        except AttributeError:
            self._exchange_names = self.sync.exchange_names
            return self._exchange_names

    @property
    def exchange_slugs(self):
        """Get all exchange raw names provided by coinmarketcap."""
        try:
            return self._exchange_slugs
        except AttributeError:
            self._exchange_slugs = self.sync.exchange_slugs
            return self._exchange_slugs

    # UTILS

    async def _cache_symbols(self):
        url = "https://files.coinmarketcap.com/generated/search/quick_search.json"
        res = await self._get(url)
        symbols = {}
        for currency in loads(res):
            symbols[currency["symbol"]] = currency["slug"].replace(" ", "")
        for original, correct in exceptional_coin_slugs.items():
            symbols[original] = correct
        return symbols

    async def _get(self, url):
        async with self.get(url, timeout=self.timeout) as response:
            return await response.text()

    async def _async_multiget(self, itr, build_url_callback, num_of_consumers=None, desc=""):
        queue, dlq, responses = Queue(maxsize=self.queue_size), Queue(), []
        num_of_consumers = num_of_consumers or min(self.connector_limit, self.try_get_itr_len(itr))
        consumers = [ensure_future(
            self._consumer(main_queue=queue, dlq=dlq, responses=responses)) for _ in
                     range(num_of_consumers or self.connector_limit)]
        dlq_consumers = [ensure_future(
            self._consumer(dlq, dlq, responses)) for _ in range(num_of_consumers)]
        produce = await self._producer(itr, build_url_callback, queue, desc=desc)
        await queue.join()
        await dlq.join()

        all_consumers = consumers
        all_consumers.extend(dlq_consumers)
        for consumer in all_consumers:
            consumer.cancel()
        return responses

    def try_get_itr_len(self, itr):
        try:
            return len(itr)
        except TypeError:
            return 1000000

    async def _producer(self, items, build_url_callback, queue, desc=""):
        for item in tqdm(items, desc=desc + " (Estimation)", 
                         disable=not self.progress_bar):
            await queue.put(await build_url_callback(item))

    async def _consumer(self, main_queue, dlq, responses):
        while True:
            try:
                url = await main_queue.get()
                responses.append(await self._get(url))
                # Notify the queue that the item has been processed
                main_queue.task_done()
            except (TimeoutError) as e:
                logger.debug("Problem with %s, Moving to DLQ" % url)
                await dlq.put(url)
                main_queue.task_done()

    # SCRAPER
    async def _base_currency_url(self, name):
        if _is_symbol(name):
            name = self.correspondences[name]
        return "https://coinmarketcap.com/currencies/%s/" % name

    async def currency(self, name, convert="USD"):
        res = await self._get(self._base_currency_url(name))
        convert = convert.lower()
        return processer.currency(res[20000:], convert)

    async def every_currency(self, currencies=None, convert="USD"):
        """Return data from every currency in coinmarketcap
        passing a list of symbols as first parameter. As
        default returns data for all symbols.

        Args:
            currencies (list, optional): Iterator with all the currencies
                that you want to retrieve. As default ``self.symbols``.
            convert (str): Convert prices in response between "USD"
               and BTC. As default ``"USD"``.

        Returns (list): Data for al symbols.
        """
        convert = convert.lower()
        res = await self._async_multiget(
            currencies if currencies else self.symbols,
            self._base_currency_url,
            self.consumers,
            desc="Retrieving every currency from coinmarketcap..."
        )
        for raw_res in res:
            yield processer.currency(raw_res[20000:], convert)

    async def _base_market_url(self, name):
        if _is_symbol(name):
            name = self.correspondences[name]
        return "https://coinmarketcap.com/currencies/%s/" % name

    async def markets(self, name, convert="USD"):
        res = await self._get(self._base_currency_url(name))
        convert = convert.lower()
        return processer.markets(res[20000:], convert)

    async def every_markets(self, currencies=None, convert="USD"):
        convert = convert.lower()
        res = await self._async(
            currencies if currencies else self.symbols,
            self._base_market_url,
            self.consumers,
            desc="Retrieving all markets for all currencies from coinmarketcap."
        )
        for raw_res in res:
            yield processer.markets(raw_res[20000:], convert)


    async def ranks(self):
        res = await self._get("https://coinmarketcap.com/gainers-losers/")
        return processer.ranks(res)

    async def historical(self, currency,
                         start=datetime(2008, 8, 18),
                         end=datetime.now(),
                         revert=False):
        if _is_symbol(currency):
            currency = self.correspondences[currency]

        url = "https://coinmarketcap.com/currencies/%s/historical-data/" % currency
        _start = "%d%02d%02d" % (start.year, start.month, start.day)
        _end = "%d%02d%02d" % (end.year, end.month, end.day)
        url += "?start=%s&end=%s" % (_start, _end)
        res = await self._get(url)

        return processer.historical(res[50000:], start, end, revert)

    async def recently(self, convert="USD"):
        convert = convert.lower()
        url = "https://coinmarketcap.com/new/"
        res = await self._get(url)
        return list(processer.recently(res, convert))
