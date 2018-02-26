
"""API wraper and web scraper module."""

# Standard Python modules
import re
from json import loads
from datetime import datetime
from time import time
from collections import OrderedDict
from urllib.request import urlretrieve
from urllib.error import HTTPError

# Internal Cython modules
from pymarketcap.curl import get_to_memory
from pymarketcap import processer
_is_symbol = processer._is_symbol

# Internal Python modules
from pymarketcap.consts import (
    DEFAULT_TIMEOUT,
    exceptional_coin_slugs
)
from pymarketcap.errors import (
    CoinmarketcapHTTPError,
    CoinmarketcapHTTPError404,
    CoinmarketcapTooManyRequestsError
)

# HTTP errors mapper
http_errors_map = {
    "429": CoinmarketcapTooManyRequestsError,
    "404": CoinmarketcapHTTPError404,
}

http_error_numbers = [int(number) for number in http_errors_map.keys()]


cdef class Pymarketcap:
    """Unique class for retrieve data from coinmarketcap.com

    Args:
        timeout (int, optional): Set timeout value for get requests.
            As default ``20``.
        debug: (bool, optional): Show low level data in get requests.
            As default, ``False``.
        cache (bool, optional): Enable or disable cache at instantiation
            time. If disabled, some methods couldn't be called, use
            this attribute with caution. As default, ``True``.
    """
    cdef readonly dict _correspondences
    cdef readonly dict _ids_correspondences
    cdef readonly list _symbols
    cdef readonly list _coins
    cdef readonly int  _total_currencies
    cdef readonly list _currencies_to_convert
    cdef readonly list _converter_cache
    cdef readonly list _exchange_names
    cdef readonly list _exchange_slugs

    cdef public long timeout
    cdef public object graphs
    cdef public bint debug

    def __init__(self, timeout=DEFAULT_TIMEOUT, debug=False):
        self.timeout = timeout
        self.debug = debug

        #: object: Initialization of graphs internal interface
        self.graphs = type("Graphs", (), self._graphs_interface)

    ######   UTILS   #######

    @property
    def _graphs_interface(self):
        return {
            "currency": self._currency,
            "global_cap": self._global_cap,
            "dominance": self._dominance
        }

    @property
    def correspondences(self):
        res = self._correspondences
        if res:
            return res
        else:
            main_cache = self._cache_symbols_ids()
            self._correspondences = main_cache[0]
            self._ids_correspondences = main_cache[1]
            return self._correspondences

    @property
    def ids_correspondences(self):
        res = self._ids_correspondences
        if res:
            return res
        else:
            main_cache = self._cache_symbols_ids()
            self._correspondences = main_cache[0]
            self._ids_correspondences = main_cache[1]
            return self._ids_correspondences

    cpdef _cache_symbols_ids(self):
        """Internal function for load in cache al symbols
        in coinmarketcap with their respectives currency names."""
        cdef bytes url
        url = b"https://files.coinmarketcap.com/generated/search/quick_search.json"
        res = loads(self._get(url))
        symbols, ids = {}, {}
        for currency in res:
            symbols[currency["symbol"]] = currency["slug"].replace(" ", "")
            ids[currency["symbol"]] = currency["id"]
        for original, correct in exceptional_coin_slugs.items():
            symbols[original] = correct
        return (symbols, ids)

    @property
    def symbols(self):
        """Symbols of currencies (in capital letters).

        Returns (list):
            All currency symbols provided by coinmarketcap.
        """
        res = self._symbols
        if res:
            return res
        else:
            self._symbols = sorted(list(self.correspondences.keys()))
            return self._symbols

    @property
    def coins(self):
        """Coins not formatted names for all currencies
        (in lowercase letters) used internally by urls.

        Returns (list):
            All currency coins names provided by coinmarketcap.
        """
        res = self._coins
        if res:
            return res
        else:
            self._coins = sorted(list(self.correspondences.values()))
            return self._coins

    @property
    def total_currencies(self):
        res = self._total_currencies
        if res:
            return res
        else:
            self._total_currencies = self.ticker()[-1]["rank"]
            return self._total_currencies

    @property
    def currencies_to_convert(self):
        res = self._currencies_to_convert
        if res:
            return res
        else:
            self._currencies_to_convert = self.__currencies_to_convert()
            return self._currencies_to_convert

    cpdef __currencies_to_convert(self):
        """Internal function for get currencies from and to convert
            values in convert() method. Don't use this, but cached
            ``currencies_to_convert`` instance attribute instead.

        Returns (list):
            All currencies that could be passed to convert() method.
        """
        res = self._get(b"https://coinmarketcap.com")
        currencies = re.findall(r'data-([a-z]+)="\d', res[-10000:-2000])
        response = [currency.upper() for currency in currencies]
        response.extend([str(currency["symbol"]) for currency in self.ticker()])
        return sorted(response)

    @property
    def exchange_names(self):
        """Get all exchange formatted names provided by coinmarketcap."""
        res = self._exchange_names
        if res:
            return res
        else:
            self._exchange_names = self.__exchange_names()
            return self._exchange_names

    cpdef __exchange_names(self):
        """Internal function for get all exchange names
            available currently in coinmarketcap. Check ``exchange_names``
            instance attribute for the cached method counterpart.

        Returns (list):
            All exchanges names formatted in coinmarketcap.
        """
        res = self._get(b"https://coinmarketcap.com/exchanges/volume/24-hour/all/")
        return re.findall(r'<a href="/exchanges/.+/">((?!View More).+)</a>', res)[5:]

    @property
    def exchange_slugs(self):
        """Get all exchange raw names provided by coinmarketcap."""
        res = self._exchange_slugs
        if res:
            return res
        else:
            self._exchange_slugs = self.__exchange_slugs()
            return self._exchange_slugs

    cpdef __exchange_slugs(self):
        """Internal function for obtain all exchanges slugs.

        Returns (list):
            All exchanges slugs from coinmarketcap.
        """
        res = self._get(b"https://coinmarketcap.com/exchanges/volume/24-hour/all/")
        parsed = re.findall(r'<a href="/exchanges/(.+)/">', res)[5:]
        return list(OrderedDict.fromkeys(parsed)) # Remove duplicates without change order

    @property
    def converter_cache(self):
        res = self._converter_cache
        if res:
            return res
        else:
            self._converter_cache = [self.currency_exchange_rates, time()]
            return self._converter_cache

    cdef _get(self, char *url):
        """Internal function to make and HTTP GET request
        using the curl Cython bridge to C library or urllib
        standard library, depending on the installation."""
        cdef int status
        req = get_to_memory(<char *>url, self.timeout, <bint>self.debug)
        status = req.status_code
        if status == 200:
            return req.text.decode()
        else:
            msg = "Status code -> %d | Url -> %s" % (status, url.decode())
            if status in http_error_numbers:
                raise http_errors_map[str(status)](msg)
            else:
                print("DEBUG: ")
                print(req.text)
                print(req.url)
                raise CoinmarketcapHTTPError(msg)

    # ====================================================================

                           #######   API   #######

    cpdef stats(self, convert="USD"):
        """ Get global cryptocurrencies statistics.

        Args:
            convert (str, optional): return 24h volume, and
                market cap in terms of another currency.
                See ticker_badges property to get valid values.
                As default ``"USD"``.

        Returns (dict):
            Global markets statistics.
        """
        return loads(self._get(
            b"https://api.coinmarketcap.com/v1/global/?convert=%s" % convert.encode()
        ))

    @property
    def ticker_badges(self):
        """Badges in wich you can convert prices in ``ticker()`` method."""
        return

    cpdef ticker(self, currency=None, limit=0, start=0, convert="USD"):
        """Get currencies with other aditional data.

        Args:
            currency (str, optional): Specify a currency to return data,
                that can be a symbol or coin slug (see ``symbols`` and ``coins``
                properties). In this case the method returns a dict, otherwise
                returns a list. If you dont specify a currency,
                returns data for all in coinmarketcap. As default, ``None``.
            limit (int, optional): Limit amount of coins on response.
                If ``limit == 0``, returns all coins in coinmarketcap.
                Only works if ``currency == None``. As default ``0``.
            start (int, optional): Rank of first currency to retrieve.
                The count starts at 0 for the first currency ranked.
                Only works if ``currency == None``. As default ``0``.
            convert (str, optional): Allows to convert prices, 24h volumes
                and market capitalizations in terms of one of badges
                returned by ``ticker_badges`` property. As default, ``"USD"``.

        Returns (dict/list):
            The type depends if currency param is provided or not.
        """
        cdef bytes url
        cdef short i, len_i
        if not currency:
            url = b"https://api.coinmarketcap.com/v1/ticker/?%s" % b"limit=%d" % limit
            url += b"&start=%d" % start
            url += b"&convert=%s" % convert.encode()
            res = self._get(url)
            response = loads(re.sub(r'"(-*\d+(?:\.\d+)?)"', r"\1", res))
            len_i = len(response)
            for i in range(len_i):
                response[i]["symbol"] = str(response[i]["symbol"])
        else:
            if _is_symbol(currency):
                currency = self.correspondences[currency]
            url = b"https://api.coinmarketcap.com/v1/ticker/%s" % currency.encode()
            url += b"?convert=%s" % convert.encode()
            res = self._get(url)
            response = loads(re.sub(r'"(-*\d+(?:\.\d+)?)"', r"\1", res))[0]
            response["symbol"] = str(response["symbol"])
        return response


    # ====================================================================

                       #######    WEB SCRAPER    #######

    @property
    def currency_exchange_rates(self):
        """Currency exchange rates against $ for all currencies (fiat + crypto).

        Returns (dict):
            All currencies rates used internally by coinmarketcap to calculate
            the prices shown.
        """
        res = self._get(b"https://coinmarketcap.com")
        rates = re.findall(r'data-([a-z]+)="(\d+\.*[\d|e|-]*)"', res[-10000:-2000])
        response = {currency.upper(): float(rate) for currency, rate in rates}
        for currency in self.ticker():
            try:
                response[currency["symbol"]] = float(currency["price_usd"])
            except TypeError:
                continue
        return response

    cpdef convert(self, value, unicode currency_in, unicode currency_out):
        """Convert prices between currencies. Provide a value, the currency
        of the value and the currency to convert it and get the value in
        currency converted rate. For see all available currencies to convert
        see ``currencies_to_convert`` property.

        Args:
            value (int/float): Value to convert betweeen two currencies.
            currency_in (str): Currency in which is expressed the value passed.
            currency_out (str): Currency to convert.

        Returns (float):
            Value expressed in currency_out parameter provided.
        """
        if time() - self.converter_cache[1] > 600:
            self.converter_cache[0] = self.currency_exchange_rates
        try:
            if currency_in == "USD":
                return value / self.converter_cache[0][currency_out]
            elif currency_out == "USD":
                return value * self.converter_cache[0][currency_in]
            else:
                rates = self.converter_cache[0]
                return value * rates[currency_in] / rates[currency_out]
        except KeyError:
            msg = "Invalid currency: '%s'. See currencies_to_convert instance attribute."
            for param in [currency_in, currency_out]:
                if param not in self.currencies_to_convert:
                    raise ValueError(msg % param)
            raise NotImplementedError

    cpdef currency(self, unicode name, convert="USD"):
        """Get currency metadata like total markets capitalization,
        websites, source code link, if mineable...

        Args:
            currency (str): Currency to get metadata.
            convert (str, optional): Currency to convert response
                fields ``total_markets_cap``, ``total_markets_volume_24h``
                and ``price`` between USD and BTC. As default ``"USD"``.

        Returns (dict):
            Aditional general metadata not supported by other methods.
        """
        response = {}
        if _is_symbol(name):
            response["symbol"] = name
            name = self.correspondences[name]
            response["slug"] = name
        else:
            response["slug"] = name
            for symbol, slug in self.correspondences.items():
                if slug == name:
                    response["symbol"] = symbol
                    break
        convert = convert.lower()

        try:
            res = self._get(
                b"https://coinmarketcap.com/currencies/%s/" % name.encode()
            )[20000:]
        except CoinmarketcapHTTPError404:
            if name not in self.coins:
                raise ValueError("%s is not a valid currency name. See 'symbols' or 'coins'" % name \
                                 + " properties for get all valid currencies.")
            else:
                raise NotImplementedError

        # Total market capitalization and volume 24h
        return processer.currency(res, convert)

    cpdef markets(self, unicode name, convert="USD"):
        """Get available coinmarketcap markets data.
        It needs a currency as argument.

        Args:
            currency (str): Currency to get market data.
            convert (str, optional): Currency to convert response
                fields ``volume_24h`` and ``price`` between USD
                and BTC. As default ``"USD"``.

        Returns (list):
            Markets on wich provided currency is currently tradeable.
        """
        if _is_symbol(name):
            name = self.correspondences[name]
        convert = convert.lower()

        try:
            res = self._get(
                b"https://coinmarketcap.com/currencies/%s/" % name.encode()
            )[20000:]
        except CoinmarketcapHTTPError404:
            if name not in self.coins:
                raise ValueError("%s is not a valid currrency name. See 'symbols'" % name \
                                 + " or 'coins' properties for get all valid currencies.")
            else:
                raise NotImplementedError

        return processer.markets(res, convert)

    cpdef ranks(self):
        """Returns gainers and losers for the periods 1h, 24h and 7d.

        Returns (dict):
            A dictionary with 2 keys (gainers and losers) whose values
            are the periods "1h", "24h" and "7d".
        """
        res = self._get(b"https://coinmarketcap.com/gainers-losers/")

        return processer.ranks(res)

    def historical(self, unicode name,
                   start=datetime(2008, 8, 18),
                   end=datetime.now(),
                   revert=False):
        """Get historical data for a currency.

        Args:
            name (str): Currency to scrap historical data.
            start (date, optional): Time to start scraping
                periods as datetime.datetime type.
                As default ``datetime(2008, 8, 18)``.
            end (date, optional): Time to end scraping periods
                as datetime.datetime type. As default ``datetime.now()``.
            revert (bool, optional): If ``False``, return first date
                first, in chronological order, otherwise returns
                reversed list of periods. As default ``False``.

        Returns (list):
            Historical dayly OHLC for a currency.
        """
        cdef bytes url, _start, _end
        response = {}

        if _is_symbol(name):
            response["symbol"] = name
            response["slug"] = self.correspondences[name]
            name = response["slug"]
        else:
            response["slug"] = name
            for symbol, slug in self.correspondences.items():
                if slug == name:
                    response["symbol"] = symbol
                    break

        url = b"https://coinmarketcap.com/currencies/%s/historical-data/" % name.encode()
        _start = b"%d" % start.year + b"%02d" % start.month + b"%02d" % start.day
        _end = b"%d" % end.year + b"%02d" % end.month + b"%02d" % end.day
        url += b"?start=%s" % _start + b"&" + b"end=%s" % _end

        try:
            res = self._get(url)[50000:]
        except CoinmarketcapHTTPError404:
            if name not in self.coins:
                raise ValueError("%s is not a valid currrency name. See 'symbols'" % name \
                                 + " or 'coins' properties for get all valid currencies.")
            else:
                raise NotImplementedError

        response["history"] = processer.historical(res, start, end, revert)
        return response

    def recently(self, convert="USD"):
        """Get recently added currencies along with other metadata.

        Args:
            convert (str, optional): Convert market_caps, prices,
                volumes and percent_changes between USD and BTC.
                As default ``"USD"``.

        Returns (list):
            Recently added currencies data.
        """
        convert = convert.lower()
        url = b"https://coinmarketcap.com/new/"
        res = self._get(url)

        return list(processer.recently(res, convert))

    cpdef exchange(self, unicode name, convert="USD"):
        """Obtain data from a exchange passed as argument. See ``exchanges_slugs``
        property for obtain all posibles values.

        Args:
            name (str): Exchange to retrieve data. Check ``exchange_slugs``
                instance attribute for get all posible values passed
                in this parameter.
            convert (str, optional): Convert prices and 24h volumes in
                return between USD and BTC. As default ``"USD"``.

        Returns (dict):
            Data from a exchange. Keys: ``"name"``, ``"website"``,
            ``"volume"`` (total), ``"social"`` and ``"markets"``.
        """
        cdef bytes url
        url = b"https://coinmarketcap.com/exchanges/%s/" % name.encode()
        try:
            res = self._get(url)[20000:]
        except CoinmarketcapHTTPError404:
            if name not in self.exchange_slugs:
                raise ValueError("%s is not a valid exchange name. See exchange_slugs" % name \
                                 + " property for get all valid exchanges.")
            else:
                raise NotImplementedError
        else:
            response = {"slug": name}
        convert = convert.lower()

        response.update(processer.exchange(res, convert))
        return response

    cpdef exchanges(self, convert="USD"):
        """Get all the exchanges in coinmarketcap ranked by volumes
        along with other metadata.

        Args:
            convert (str, optional): Convert volumes and prices
                between USD and BTC. As default ``"USD"``.

        Returns (list):
            Exchanges with markets and other data included.
        """
        cdef bytes url
        url = b"https://coinmarketcap.com/exchanges/volume/24-hour/all/"
        res = self._get(url)[45000:]
        convert = convert.lower()
        return processer.exchanges(res, convert)

    cpdef tokens(self, convert="USD"):
        """Get data from platforms tokens

        Args:
            convert (str, optional): Convert ``"market_cap"``,
                ``"price"`` and ``"volume_24h"`` values between
                USD and BTC. As default ``"USD"``.

        Returns (list):
            Platforms tokens data.
        """
        url = b"https://coinmarketcap.com/tokens/views/all/"
        res = self._get(url)[40000:]
        convert = convert.lower()

        return processer.tokens(res, convert)

    # ====================================================================

    ######   GRAPHS API   #######

    cpdef _currency(self, unicode name, start=None, end=None):
        """Get graphs data of a currency.

        Args:
            currency (str): Currency to retrieve graphs data.
            start (datetime, optional): Time to start retrieving
                graphs data in datetime. As default ``None``.
            end (datetime, optional): Time to end retrieving
                graphs data in datetime. As default ``None``.

        Returns (dict):
            Dict info with next keys: ``"market_cap_by_available_supply"``,
            ``"price_btc"``, ``"price_usd"``, ``"volume_usd":``
            and ``"price_platform"``.
            For each value, a list of lists where each one
            has two values [<datetime>, <value>]
        """
        if _is_symbol(name):
            name = self.correspondences[name]

        url = b"https://graphs2.coinmarketcap.com/currencies/%s/" % name.encode()
        res = loads(self._get(url))

        response = {}
        for key in list(res.keys()):
            group = []
            for _tmp, data in res[key]:
                tmp = datetime.fromtimestamp(int(_tmp/1000))
                try:
                    if tmp >= start and tmp <= end:
                        group.append([tmp, data])
                except TypeError:
                    group.append([tmp, data])
            response[key] = group
        return response

    cpdef _global_cap(self, bitcoin=True, start=None, end=None):
        """Get global market capitalization graphs, including
        or excluding Bitcoin.

        Args:
            bitcoin (bool, optional): Indicates if Bitcoin will
                be includedin global market capitalization graph.
                As default ``True``.
            start (int, optional): Time to start retrieving
                graphs data in microseconds unix timestamps.
                Only works with times provided by the times
                returned in graphs functions. As default ``None``.
            end (optional, datetime): Time to end retrieving
                graphs data in microseconds unix timestamps.
                Only works with times provided by the times
                returned in graphs functions. As default ``None``.

        Returns (dict):
            Whose values are lists of lists with timestamp and values,
            a data structure with the keys: ``"volume_usd"`` and
            ``"market_cap_by_available_supply"``.
        """
        if bitcoin:
            url = b"https://graphs2.coinmarketcap.com/global/marketcap-total/"
        else:
            url = b"https://graphs2.coinmarketcap.com/global/marketcap-altcoin/"

        if start and end:
            url += b"%s/%s/" % (str(start).encode(), str(end).encode())

        return loads(self._get(url))

    cpdef _dominance(self, start=None, end=None):
        """Get currencies dominance percentage graph

        Args:
            start (int, optional): Time to start retrieving
                graphs data in microseconds unix timestamps.
                Only works with times provided by the times
                returned in graphs functions. As default None.
            end (optional, datetime): Time to end retrieving
                graphs data in microseconds unix timestamps.
                Only works with times provided by the times
                returned in graphs functions. As default None.

        Returns (dict):
            Altcoins and dominance percentage values with timestamps.
        """
        url = b"https://graphs2.coinmarketcap.com/global/dominance/"

        if start and end:
            url += b"%s/%s/" % (str(start).encode(), str(end).encode())

        return loads(self._get(url))

    cpdef download_logo(self, unicode name, size=64, filename=None):
        """Download a currency image logo

        Args:
            currency (str): Currency name or symbol to download.
            size (int, optional): Size in pixels. Valid sizes are:
                [16, 32, 64, 128, 200]. As default 128.
            filename (str, optional): Filename for store the logo.
                Must be in .png extension. As default None.

        Returns (str):
            Filename of downloaded file if all was correct.
        """
        if _is_symbol(name):
            try:
                _name = self.ids_correspondences[name]
            except KeyError:
                if name not in list(self.ids_correspondences.keys()):
                    raise ValueError(
                        "The currency %s is not valid. See 'symbols' instance attribute." % name
                    )
        else:
            _name = name

        url_schema = "https://files.coinmarketcap.com/static/img/coins/%dx%d/%d.png"
        url = url_schema % (size, size, _name)
        if not filename:
            filename = "%s_%dx%d.png" % (self.correspondences[name], size, size)
        try:
            res = urlretrieve(url, filename)
        except HTTPError as e:
            if e.code == 403:
                valid_sizes = [16, 32, 64, 128, 200]
                if size in valid_sizes:
                    raise ValueError(
                        ("Seems that %s currency doesn't allows to be downloaded with " \
                        + "size %dx%d. Try with another size.") % (name, size, size)
                    )
                else:
                    raise ValueError("%dx%d is not a valid size." % (size, size))
            raise e
        else:
            return filename
