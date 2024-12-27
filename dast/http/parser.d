// Modified from https://github.com/tchaloupka/httparsed
module dast.http.parser;

nothrow @safe @nogc:

/// Parser error codes
enum ParseError {
	ok, /// no error
	partial = 1, /// not enough data to parse message
	newLine, /// invalid character in new line
	headerName, /// invalid character in header name
	status, /// invalid character in response status
	token, /// invalid character in token
	noHeaderName, /// empty header name
	noMethod, /// no method in request line
	noVersion, /// no version in request line / response status line
	noUri, /// no URI in request line
	noStatus, /// no status code or text in status line
	invalidMethod, /// invalid method in request line
	invalidVersion, /// invalid version for the protocol message
}

/// Helper function to initialize message parser
auto initParser(MSG, Args...)(Args args)
	=> Parser!MSG(args);

/**
 *  HTTP/RTSP message parser.
 */
struct Parser(MSG) {
	import std.traits : ForeachType, isArray, Unqual;

	this(Args...)(Args args) {
		msg = MSG(args);
	}

	/**
		Parses message request (request line + headers).

		Params:
			buffer = buffer to parse message from
			lastPos = optional argument to store / pass previous position to which message was
						already parsed (speeds up parsing when message comes in parts)

		Returns:
		  * parsed message header length when parsed sucessfully
		  * `-ParseError.partial` on error (ie. -1 when message header is not comlete yet)
	 */
	int parseRequest(T)(T buffer, ref uint lastPos)
	if (isArray!T && (is(Unqual!(ForeachType!T) == char) || is(Unqual!(ForeachType!T) == ubyte))) {
		static if (is(Unqual!(ForeachType!T) == char))
			return parse!parseRequestLine(cast(const(ubyte)[])buffer, lastPos);
		else
			return parse!parseRequestLine(buffer, lastPos);
	}

	/// ditto
	int parseRequest(T)(T buffer)
	if (isArray!T && (is(Unqual!(ForeachType!T) == char) || is(Unqual!(ForeachType!T) == ubyte))) {
		uint lastPos;
		static if (is(Unqual!(ForeachType!T) == char))
			return parse!parseRequestLine(cast(const(ubyte)[])buffer, lastPos);
		else
			return parse!parseRequestLine(buffer, lastPos);
	}

	/**
		Parses message response (status line + headers).

		Params:
			buffer = buffer to parse message from
			lastPos = optional argument to store / pass previous position to which message was
						already parsed (speeds up parsing when message comes in parts)

		Returns:
		  * parsed message header length when parsed sucessfully
		  * `-ParseError.partial` on error (ie. -1 when message header is not comlete yet)
	 */
	int parseResponse(T)(T buffer, ref uint lastPos)
	if (isArray!T && (is(Unqual!(ForeachType!T) == char) || is(Unqual!(ForeachType!T) == ubyte))) {
		static if (is(Unqual!(ForeachType!T) == char))
			return parse!parseStatusLine(cast(const(ubyte)[])buffer, lastPos);
		else
			return parse!parseStatusLine(buffer, lastPos);
	}

	/// ditto
	int parseResponse(T)(T buffer)
	if (isArray!T && (is(Unqual!(ForeachType!T) == char) || is(Unqual!(ForeachType!T) == ubyte))) {
		uint lastPos;
		static if (is(Unqual!(ForeachType!T) == char))
			return parse!parseStatusLine(cast(const(ubyte)[])buffer, lastPos);
		else
			return parse!parseStatusLine(buffer, lastPos);
	}

	/// Gets provided structure used during parsing
	ref MSG msg() return  => m_msg;

	alias msg this;

private:

	// character map of valid characters for token, forbidden:
	//   0-SP, DEL, HT
	//   ()<>@,;:\"/[]?={}
	enum tokenRanges = "\0 \"\"(),,//:@[]{}\x7f\xff";
	enum tokenSSERanges = "\0 \"\"(),,//:@[]{\xff"; // merge of last range due to the SSE register size limit

	enum versionRanges = "\0-:@[`{\xff"; // allow only [A-Za-z./] characters

	MSG m_msg;

	int parse(alias pred)(const(ubyte)[] buf, ref uint lastPos)
	in (buf.length >= lastPos) {
		immutable l = buf.length;

		if (expect(!lastPos, true)) {
			if (expect(!buf.length, false))
				return err(ParseError.partial);

			// skip first empty line (some clients add CRLF after POST content)
			if (expect(buf[0] == '\r', false)) {
				if (expect(buf.length == 1, false))
					return err(ParseError.partial);
				if (expect(buf[1] != '\n', false))
					return err(ParseError.newLine);
				lastPos += 2;
				buf = buf[lastPos .. $];
			} else if (expect(buf[0] == '\n', false))
				buf = buf[++lastPos .. $];

			immutable res = pred(buf);
			if (expect(res < 0, false))
				return res;

			lastPos = cast(int)(l - buf.length); // store index of last parsed line
		} else
			buf = buf[lastPos .. $]; // skip already parsed lines

		immutable hdrRes = parseHeaders(buf);
		lastPos = cast(int)(l - buf.length); // store index of last parsed line

		if (expect(hdrRes < 0, false))
			return hdrRes;
		return lastPos; // finished
	}

	int parseHeaders(ref const(ubyte)[] buf) {
		bool hasHeader;
		size_t start, i;
		const(ubyte)[] name, value;
		while (true) {
			// check for msg headers end
			if (expect(buf.length == 0, false))
				return err(ParseError.partial);
			if (buf[0] == '\r') {
				if (expect(buf.length == 1, false))
					return err(ParseError.partial);
				if (expect(buf[1] != '\n', false))
					return err(ParseError.newLine);

				buf = buf[2 .. $];
				return 0;
			}
			if (expect(buf[0] == '\n', false)) {
				buf = buf[1 .. $];
				return 0;
			}

			if (!hasHeader || (buf[i] != ' ' && buf[i] != '\t')) {
				auto ret = parseToken!(tokenRanges, ':', tokenSSERanges)(buf, i);
				if (expect(ret < 0, false))
					return ret;
				if (expect(start == i, false))
					return err(ParseError.noHeaderName);
				name = buf[start .. i]; // store header name
				i++; // move index after colon

				// skip over SP and HT
				for (;; ++i) {
					if (expect(i == buf.length, false))
						return err(ParseError.partial);
					if (buf[i] != ' ' && buf[i] != '\t')
						break;
				}
				start = i;
			} else
				name = null; // multiline header

			// parse value
			auto ret = parseToken!("\0\010\012\037\177\177", "\r\n")(buf, i);
			if (expect(ret < 0, false))
				return ret;
			value = buf[start .. i];
			mixin(advanceNewline);
			hasHeader = true; // flag to define that we can now accept multiline header values
			static if (__traits(hasMember, m_msg, "onHeader")) {
				// remove trailing SPs and HTABs
				if (expect(value.length && (value[$ - 1] == ' ' || value[$ - 1] == '\t'), false)) {
					int j = cast(int)value.length - 2;
					for (; j >= 0; --j)
						if (!(value[j] == ' ' || value[j] == '\t'))
							break;
					value = value[0 .. j + 1];
				}

				static if (is(typeof(m_msg.onHeader("", "")) == void))
					m_msg.onHeader(cast(const(char)[])name, cast(const(char)[])value);
				else {
					auto r = m_msg.onHeader(cast(const(char)[])name, cast(const(char)[])value);
					if (expect(r < 0, false))
						return r;
				}
			}

			// header line completed -> advance buffer
			buf = buf[i .. $];
			start = i = 0;
		}
		assert(0);
	}

	auto parseRequestLine(ref const(ubyte)[] buf) {
		size_t start, i;

		// METHOD
		auto ret = parseToken!(tokenRanges, ' ', tokenSSERanges)(buf, i);
		if (expect(ret < 0, false))
			return ret;
		if (expect(start == i, false))
			return err(ParseError.noMethod);

		static if (__traits(hasMember, m_msg, "onMethod")) {
			static if (is(typeof(m_msg.onMethod("")) == void))
				m_msg.onMethod(cast(const(char)[])buf[start .. i]);
			else {
				auto r = m_msg.onMethod(cast(const(char)[])buf[start .. i]);
				if (expect(r < 0, false))
					return r;
			}
		}
		mixin(skipSpaces!(ParseError.noUri));
		start = i;

		// PATH
		ret = parseToken!("\000\040\177\177", ' ')(buf, i);
		if (expect(ret < 0, false))
			return ret;
		static if (__traits(hasMember, m_msg, "onUri")) {
			static if (is(typeof(m_msg.onUri("")) == void))
				m_msg.onUri(cast(const(char)[])buf[start .. i]);
			else {
				auto ur = m_msg.onUri(cast(const(char)[])buf[start .. i]);
				if (expect(ur < 0, false))
					return ur;
			}
		}
		mixin(skipSpaces!(ParseError.noVersion));
		start = i;

		// VERSION
		ret = parseToken!(versionRanges, "\r\n")(buf, i);
		if (expect(ret < 0, false))
			return ret;
		static if (__traits(hasMember, m_msg, "onVersion")) {
			static if (is(typeof(m_msg.onVersion("")) == void))
				m_msg.onVersion(cast(const(char)[])buf[start .. i]);
			else {
				auto vr = m_msg.onVersion(cast(const(char)[])buf[start .. i]);
				if (expect(vr < 0, false))
					return vr;
			}
		}
		mixin(advanceNewline);

		// advance buffer after the request line
		buf = buf[i .. $];
		return 0;
	}

	auto parseStatusLine(ref const(ubyte)[] buf) {
		size_t start, i;

		// VERSION
		auto ret = parseToken!(versionRanges, ' ')(buf, i);
		if (expect(ret < 0, false))
			return ret;
		if (expect(start == i, false))
			return err(ParseError.noVersion);
		static if (__traits(hasMember, m_msg, "onVersion")) {
			static if (is(typeof(m_msg.onVersion("")) == void))
				m_msg.onVersion(cast(const(char)[])buf[start .. i]);
			else {
				auto r = m_msg.onVersion(cast(const(char)[])buf[start .. i]);
				if (expect(r < 0, false))
					return r;
			}
		}
		mixin(skipSpaces!(ParseError.noStatus));
		start = i;

		// STATUS CODE
		if (expect(i + 3 >= buf.length, false))
			return err(ParseError.partial); // not enough data - we want at least [:digit:][:digit:][:digit:]<other char> to try to parse

		int code;
		foreach (j, m; [100, 10, 1]) {
			if (buf[i + j] < '0' || buf[i + j] > '9')
				return err(ParseError.status);
			code += (buf[start + j] - '0') * m;
		}
		i += 3;
		static if (__traits(hasMember, m_msg, "onStatus")) {
			static if (is(typeof(m_msg.onStatus(code)) == void))
				m_msg.onStatus(code);
			else {
				auto sr = m_msg.onStatus(code);
				if (expect(sr < 0, false))
					return sr;
			}
		}
		if (expect(i == buf.length, false))
			return err(ParseError.partial);
		if (expect(buf[i] != ' ' && buf[i] != '\r' && buf[i] != '\n', false))
			return err(ParseError.status); // Garbage after status

		start = i;

		// MESSAGE
		ret = parseToken!("\0\010\012\037\177\177", "\r\n")(buf, i);
		if (expect(ret < 0, false))
			return ret;
		static if (__traits(hasMember, m_msg, "onStatusMsg")) {
			// remove preceding space (we did't advance over spaces because possibly missing status message)
			if (i > start) {
				while (buf[start] == ' ' && start < i)
					start++;
				if (i > start) {
					static if (is(typeof(m_msg.onStatusMsg("")) == void))
						m_msg.onStatusMsg(cast(const(char)[])buf[start .. i]);
					else {
						auto smr = m_msg.onStatusMsg(cast(const(char)[])buf[start .. i]);
						if (expect(smr < 0, false))
							return smr;
					}
				}
			}
		}
		mixin(advanceNewline);

		// advance buffer after the status line
		buf = buf[i .. $];
		return 0;
	}

	/**
	 * Advances buffer over the token to the next character while checking for valid characters.
	 * On success, buffer index is left on the next character.
	 *
	 * Params:
	 *      ranges = ranges of characters to stop on
	 *      sseRanges = if null, same ranges is used, but they are limited to 8 ranges
	 *      next  = next character/s to stop on (must be present in the provided ranges too)
	 * Returns: 0 on success error code otherwise
	 */
	int parseToken(string ranges, alias next, string sseRanges = null)(
		const(ubyte)[] buf, ref size_t i) pure {
		version (DigitalMars) {
			static if (__VERSION__ >= 2094)
				pragma(inline, true); // older compilers can't inline this
		} else
			pragma(inline, true);

		immutable charMap = parseTokenCharMap!(ranges)();

		static if (LDC_with_SSE42) {
			// CT function to prepare input for SIMD vector enum
			static byte[16] padRanges()(string ranges) {
				byte[16] res;
				// res[0..ranges.length] = cast(byte[])ranges[]; - broken on macOS betterC tests
				foreach (i, c; ranges)
					res[i] = cast(byte)c;
				return res;
			}

			static if (sseRanges)
				alias usedRng = sseRanges;
			else
				alias usedRng = ranges;
			static assert(usedRng.length <= 16, "Ranges must be at most 16 characters long");
			static assert(usedRng.length % 2 == 0, "Ranges must have even number of characters");
			enum rangesSize = usedRng.length;
			enum byte16 rngE = padRanges(usedRng);

			if (expect(buf.length - i >= 16, true)) {
				size_t left = (buf.length - i) & ~15; // round down to multiple of 16
				byte16 ranges16 = rngE;

				do {
					byte16 b16 = () @trusted {
						return cast(byte16)_mm_loadu_si128(cast(int4*)&buf[i]);
					}();
					immutable r = _mm_cmpestri(
						ranges16, rangesSize,
						b16, 16,
						_SIDD_LEAST_SIGNIFICANT | _SIDD_CMP_RANGES | _SIDD_UBYTE_OPS
					);

					if (r != 16) {
						i += r;
						goto FOUND;
					}
					i += 16;
					left -= 16;
				}
				while (expect(left != 0, true));
			}
		} else {
			// faster unrolled loop to iterate over 8 characters
			while (expect(buf.length - i >= 8, true)) {
				static foreach (_; 0 .. 8) {
					if (expect(!charMap[buf[i]], false))
						goto FOUND;
					++i;
				}
			}
		}

		// handle the rest
		if (expect(i >= buf.length, false))
			return err(ParseError.partial);

		FOUND: while (true) {
			static if (is(typeof(next) == char)) {
				static assert(!charMap[next], "Next character is not in ranges");
				if (buf[i] == next)
					return 0;
			} else {
				static assert(next.length > 0, "Next character not provided");
				static foreach (c; next) {
					static assert(!charMap[c], "Next character is not in ranges");
					if (buf[i] == c)
						return 0;
				}
			}
			if (expect(!charMap[buf[i]], false))
				return err(ParseError.token);
			if (expect(++i == buf.length, false))
				return err(ParseError.partial);
		}
	}

	// advances over new line
	enum advanceNewline = q{
			assert(i < buf.length);
			if (expect(buf[i] == '\r', true))
			{
				if (expect(i+1 == buf.length, false)) return err(ParseError.partial);
				if (expect(buf[i+1] != '\n', false)) return err(ParseError.newLine);
				i += 2;
			}
			else if (buf[i] == '\n') ++i;
			else assert(0);
		};

	// skips over spaces in the buffer
	template skipSpaces(ParseError err) {
		enum skipSpaces = `
			do {
				++i;
				if (expect(buf.length == i, false)) return err(ParseError.partial);
				if (expect(buf[i] == '\r' || buf[i] == '\n', false)) return err(`
			~ err.stringof ~ `);
			} while (buf[i] == ' ');
		`;
	}
}

///
@"example"unittest {
	// init parser
	auto reqParser = initParser!Msg(); // or `Parser!MSG reqParser;`
	auto resParser = initParser!Msg(); // or `Parser!MSG resParser;`

	// parse request
	string data = "GET /foo HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
	// returns parsed message header length when parsed sucessfully, -ParseError on error
	int res = reqParser.parseRequest(data);
	assert(res == data.length);
	assert(reqParser.method == "GET");
	assert(reqParser.uri == "/foo");
	assert(reqParser.minorVer == 1); // HTTP/1.1
	assert(reqParser.headers.length == 1);
	assert(reqParser.headers[0].name == "Host");
	assert(reqParser.headers[0].value == "127.0.0.1:8090");

	// parse response
	data = "HTTP/1.0 200 OK\r\n";
	uint lastPos; // store last parsed position for next run
	res = resParser.parseResponse(data, lastPos);
	assert(res == -ParseError.partial); // no complete message header yet
	data = "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nfoo";
	res = resParser.parseResponse(data, lastPos); // starts parsing from previous position
	assert(res == data.length - 3); // whole message header parsed, body left to be handled based on actual header values
	assert(resParser.minorVer == 0); // HTTP/1.0
	assert(resParser.status == 200);
	assert(resParser.statusMsg == "OK");
	assert(resParser.headers.length == 2);
	assert(resParser.headers[0].name == "Content-Type");
	assert(resParser.headers[0].value == "text/plain");
	assert(resParser.headers[1].name == "Content-Length");
	assert(resParser.headers[1].value == "3");
}

/**
 * Parses HTTP version from a slice returned in `onVersion` callback.
 *
 * Returns: minor version (0 for HTTP/1.0 or 1 for HTTP/1.1) on success or
 *          `-ParseError.invalidVersion` on error
 */
int parseHttpVersion(const(char)[] ver) pure {
	if (expect(ver.length != 8, false))
		return err(ParseError.invalidVersion);

	static foreach (i, c; "HTTP/1.")
		if (expect(ver[i] != c, false))
			return err(ParseError.invalidVersion);

	if (expect(ver[7] < '0' || ver[7] > '9', false))
		return err(ParseError.invalidVersion);
	return ver[7] - '0';
}

@"parseHttpVersion"unittest {
	assert(parseHttpVersion("FOO") < 0);
	assert(parseHttpVersion("HTTP/1.") < 0);
	assert(parseHttpVersion("HTTP/1.12") < 0);
	assert(parseHttpVersion("HTTP/1.a") < 0);
	assert(parseHttpVersion("HTTP/2.0") < 0);
	assert(parseHttpVersion("HTTP/1.00") < 0);
	assert(parseHttpVersion("HTTP/1.0") == 0);
	assert(parseHttpVersion("HTTP/1.1") == 1);
}

version (CI_MAIN) {
	// workaround for dub not supporting unittests with betterC
	version (D_BetterC) {
		extern (C) void main() {
			import core.stdc.stdio;

			static foreach (u; __traits(getUnitTests, httparsed)) {
				debug printf("testing '" ~ __traits(getAttributes, u)[0] ~ "'\n");
				u();
			}
			debug printf("All unit tests have been run successfully.\n");
		}
	} else {
		void main() {
			version (unittest) {
			}  // run automagically
			else {
				import core.stdc.stdio;

				// just a compilation test
				auto reqParser = initParser!Msg();
				auto resParser = initParser!Msg();

				string data = "GET /foo HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
				int res = reqParser.parseRequest(data);
				assert(res == data.length);

				data = "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nfoo";
				res = resParser.parseResponse(data);
				assert(res == data.length - 3);
				() @trusted { printf("Test app works\n"); }();
			}
		}
	}
}

private:

int err(ParseError e) pure {
	pragma(inline, true);
	return -(cast(int)e);
}

/// Builds valid char map from the provided ranges of invalid ones
bool[256] buildValidCharMap()(string invalidRanges) {
	assert(invalidRanges.length % 2 == 0, "Uneven ranges");
	bool[256] res = true;

	for (int i = 0; i < invalidRanges.length; i += 2)
		for (int j = invalidRanges[i]; j <= invalidRanges[i + 1]; ++j)
			res[j] = false;
	return res;
}

@"buildValidCharMap"unittest {
	string ranges = "\0 \"\"(),,//:@[]{{}}\x7f\xff";
	assert(buildValidCharMap(ranges) ==
		cast(bool[])[
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
			0,1,0,1,1,1,1,1,0,0,1,1,0,1,1,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,
			0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,1,1,
			1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,0,1,0,
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
			0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
		]);
}

immutable(bool[256]) parseTokenCharMap(string invalidRanges)() {
	static immutable charMap = buildValidCharMap(invalidRanges);
	return charMap;
}

version (unittest)
	version = WITH_MSG;
else version (CI_MAIN)
	version = WITH_MSG;

version (WITH_MSG) {
	// define our message content handler
	struct Header {
		const(char)[] name;
		const(char)[] value;
	}

	// Just store slices of parsed message header
	struct Msg {
	@safe pure nothrow @nogc:
		void onMethod(const(char)[] method) {
			this.method = method;
		}

		void onUri(const(char)[] uri) {
			this.uri = uri;
		}

		int onVersion(const(char)[] ver) {
			minorVer = parseHttpVersion(ver);
			return minorVer >= 0 ? 0 : minorVer;
		}

		void onHeader(const(char)[] name, const(char)[] value) {
			this.m_headers[m_headersLength].name = name;
			this.m_headers[m_headersLength++].value = value;
		}

		void onStatus(int status) {
			this.status = status;
		}

		void onStatusMsg(const(char)[] statusMsg) {
			this.statusMsg = statusMsg;
		}

		const(char)[] method;
		const(char)[] uri;
		int minorVer;
		int status;
		const(char)[] statusMsg;

		private {
			Header[32] m_headers;
			size_t m_headersLength;
		}

		Header[] headers() return {
			return m_headers[0 .. m_headersLength];
		}
	}

	enum Test {
		err,
		complete,
		partial
	}
}

// Tests from https://github.com/h2o/picohttpparser/blob/master/test.c

@"Request"unittest {
	auto parse(string data, Test test = Test.complete, int additional = 0) @safe nothrow @nogc {
		auto parser = initParser!Msg();
		auto res = parser.parseRequest(data);
		// if (res < 0) writeln("Err: ", cast(ParseError)(-res));
		final switch (test) {
		case Test.err:
			assert(res < -ParseError.partial);
			break;
		case Test.partial:
			assert(res == -ParseError.partial);
			break;
		case Test.complete:
			assert(res == data.length - additional);
			break;
		}

		return parser.msg;
	}

	// simple
	{
		auto req = parse("GET / HTTP/1.0\r\n\r\n");
		assert(req.headers.length == 0);
		assert(req.method == "GET");
		assert(req.uri == "/");
		assert(req.minorVer == 0);
	}

	// parse headers
	{
		auto req = parse("GET /hoge HTTP/1.1\r\nHost: example.com\r\nCookie: \r\n\r\n");
		assert(req.method == "GET");
		assert(req.uri == "/hoge");
		assert(req.minorVer == 1);
		assert(req.headers.length == 2);
		assert(req.headers[0] == Header("Host", "example.com"));
		assert(req.headers[1] == Header("Cookie", ""));
	}

	// multibyte included
	{
		auto req = parse(
			"GET /hoge HTTP/1.1\r\nHost: example.com\r\nUser-Agent: \343\201\262\343/1.0\r\n\r\n");
		assert(req.method == "GET");
		assert(req.uri == "/hoge");
		assert(req.minorVer == 1);
		assert(req.headers.length == 2);
		assert(req.headers[0] == Header("Host", "example.com"));
		assert(req.headers[1] == Header("User-Agent", "\343\201\262\343/1.0"));
	}

	//multiline
	{
		auto req = parse("GET / HTTP/1.0\r\nfoo: \r\nfoo: b\r\n  \tc\r\n\r\n");
		assert(req.method == "GET");
		assert(req.uri == "/");
		assert(req.minorVer == 0);
		assert(req.headers.length == 3);
		assert(req.headers[0] == Header("foo", ""));
		assert(req.headers[1] == Header("foo", "b"));
		assert(req.headers[2] == Header(null, "  \tc"));
	}

	// header name with trailing space
	parse("GET / HTTP/1.0\r\nfoo : ab\r\n\r\n", Test.err);

	// incomplete
	assert(parse("\r", Test.partial).method == null);
	assert(parse("\r\n", Test.partial).method == null);
	assert(parse("\r\nGET", Test.partial).method == null);
	assert(parse("GET", Test.partial).method == null);
	assert(parse("GET ", Test.partial).method == "GET");
	assert(parse("GET /", Test.partial).uri == null);
	assert(parse("GET / ", Test.partial).uri == "/");
	assert(parse("GET / HTTP/1.1", Test.partial).minorVer == 0);
	assert(parse("GET / HTTP/1.1\r", Test.partial).minorVer == 1);
	assert(parse("GET / HTTP/1.1\r\n", Test.partial).minorVer == 1);
	parse("GET / HTTP/1.0\r\n\r", Test.partial);
	parse("GET / HTTP/1.0\r\n\r\n", Test.complete);
	parse(" / HTTP/1.0\r\n\r\n", Test.err); // empty method
	parse("GET  HTTP/1.0\r\n\r\n", Test.err); // empty request target
	parse("GET / \r\n\r\n", Test.err); // empty version
	parse("GET / HTTP/1.0\r\n:a\r\n\r\n", Test.err); // empty header name
	parse("GET / HTTP/1.0\r\n :a\r\n\r\n", Test.err); // empty header name (space only)
	parse("G\0T / HTTP/1.0\r\n\r\n", Test.err); // NUL in method
	parse("G\tT / HTTP/1.0\r\n\r\n", Test.err); // tab in method
	parse("GET /\x7f HTTP/1.0\r\n\r\n", Test.err); // DEL in uri
	parse("GET / HTTP/1.0\r\na\0b: c\r\n\r\n", Test.err); // NUL in header name
	parse("GET / HTTP/1.0\r\nab: c\0d\r\n\r\n", Test.err); // NUL in header value
	parse("GET / HTTP/1.0\r\na\033b: c\r\n\r\n", Test.err); // CTL in header name
	parse("GET / HTTP/1.0\r\nab: c\033\r\n\r\n", Test.err); // CTL in header value
	parse("GET / HTTP/1.0\r\n/: 1\r\n\r\n", Test.err); // invalid char in header value
	parse("GET   /   HTTP/1.0\r\n\r\n", Test.complete); // multiple spaces between tokens

	// accept MSB chars
	{
		auto res = parse("GET /\xa0 HTTP/1.0\r\nh: c\xa2y\r\n\r\n");
		assert(res.method == "GET");
		assert(res.uri == "/\xa0");
		assert(res.minorVer == 0);
		assert(res.headers.length == 1);
		assert(res.headers[0] == Header("h", "c\xa2y"));
	}

	parse("GET / HTTP/1.0\r\n\x7b: 1\r\n\r\n", Test.err); // disallow '{'

	// exclude leading and trailing spaces in header value
	{
		auto req = parse("GET / HTTP/1.0\r\nfoo:  a \t \r\n\r\n");
		assert(req.headers[0].value == "a");
	}

	// leave the body intact
	parse("GET / HTTP/1.0\r\n\r\nfoo bar baz", Test.complete, "foo bar baz".length);

	// realworld
	{
		auto req = parse("GET /cookies HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nConnection: keep-alive\r\nCache-Control: max-age=0\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17\r\nAccept-Encoding: gzip,deflate,sdch\r\nAccept-Language: en-US,en;q=0.8\r\nAccept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.3\r\nCookie: name=wookie\r\n\r\n");
		assert(req.method == "GET");
		assert(req.uri == "/cookies");
		assert(req.minorVer == 1);
		assert(req.headers[0] == Header("Host", "127.0.0.1:8090"));
		assert(req.headers[1] == Header("Connection", "keep-alive"));
		assert(req.headers[2] == Header("Cache-Control", "max-age=0"));
		assert(req.headers[3] == Header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"));
		assert(req.headers[4] == Header("User-Agent", "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17"));
		assert(req.headers[5] == Header("Accept-Encoding", "gzip,deflate,sdch"));
		assert(req.headers[6] == Header("Accept-Language", "en-US,en;q=0.8"));
		assert(req.headers[7] == Header("Accept-Charset", "ISO-8859-1,utf-8;q=0.7,*;q=0.3"));
		assert(req.headers[8] == Header("Cookie", "name=wookie"));
	}

	// newline
	{
		auto req = parse("GET / HTTP/1.0\nfoo: a\n\n");
	}
}

@"Response" // Tests from https://github.com/h2o/picohttpparser/blob/master/test.c
unittest {
	auto parse(string data, Test test = Test.complete, int additional = 0) @safe nothrow {
		auto parser = initParser!Msg();

		auto res = parser.parseResponse(data);
		// if (res < 0) writeln("Err: ", cast(ParseError)(-res));
		final switch (test) {
		case Test.err:
			assert(res < -ParseError.partial);
			break;
		case Test.partial:
			assert(res == -ParseError.partial);
			break;
		case Test.complete:
			assert(res == data.length - additional);
		}

		return parser.msg;
	}

	// simple
	{
		auto res = parse("HTTP/1.0 200 OK\r\n\r\n");
		assert(res.headers.length == 0);
		assert(res.status == 200);
		assert(res.minorVer == 0);
		assert(res.statusMsg == "OK");
	}

	parse("HTTP/1.0 200 OK\r\n\r", Test.partial); // partial

	// parse headers
	{
		auto res = parse("HTTP/1.1 200 OK\r\nHost: example.com\r\nCookie: \r\n\r\n");
		assert(res.headers.length == 2);
		assert(res.minorVer == 1);
		assert(res.status == 200);
		assert(res.statusMsg == "OK");
		assert(res.headers[0] == Header("Host", "example.com"));
		assert(res.headers[1] == Header("Cookie", ""));
	}

	// parse multiline
	{
		auto res = parse("HTTP/1.0 200 OK\r\nfoo: \r\nfoo: b\r\n  \tc\r\n\r\n");
		assert(res.headers.length == 3);
		assert(res.minorVer == 0);
		assert(res.status == 200);
		assert(res.statusMsg == "OK");
		assert(res.headers[0] == Header("foo", ""));
		assert(res.headers[1] == Header("foo", "b"));
		assert(res.headers[2] == Header(null, "  \tc"));
	}

	// internal server error
	{
		auto res = parse("HTTP/1.0 500 Internal Server Error\r\n\r\n");
		assert(res.headers.length == 0);
		assert(res.minorVer == 0);
		assert(res.status == 500);
		assert(res.statusMsg == "Internal Server Error");
	}

	parse("H", Test.partial); // incomplete 1
	parse("HTTP/1.", Test.partial); // incomplete 2
	assert(parse("HTTP/1.1", Test.partial).minorVer == 0); // incomplete 3 - differs from picohttpparser as we don't parse exact version
	assert(parse("HTTP/1.1 ", Test.partial).minorVer == 1); // incomplete 4
	parse("HTTP/1.1 2", Test.partial); // incomplete 5
	assert(parse("HTTP/1.1 200", Test.partial).status == 0); // incomplete 6
	assert(parse("HTTP/1.1 200 ", Test.partial).status == 200); // incomplete 7
	assert(parse("HTTP/1.1 200\r", Test.partial).status == 200); // incomplete 7.1
	parse("HTTP/1.1 200 O", Test.partial); // incomplete 8
	assert(parse("HTTP/1.1 200 OK\r", Test.partial).statusMsg == "OK"); // incomplete 9 - differs from picohttpparser
	assert(parse("HTTP/1.1 200 OK\r\n", Test.partial).statusMsg == "OK"); // incomplete 10
	assert(parse("HTTP/1.1 200 OK\n", Test.partial).statusMsg == "OK"); // incomplete 11
	assert(parse("HTTP/1.1 200 OK\r\nA: 1\r", Test.partial).headers.length == 0); // incomplete 11
	parse("HTTP/1.1   200   OK\r\n\r\n", Test.complete); // multiple spaces between tokens

	// incomplete 12
	{
		auto res = parse("HTTP/1.1 200 OK\r\nA: 1\r\n", Test.partial);
		assert(res.headers.length == 1);
		assert(res.headers[0] == Header("A", "1"));
	}

	// slowloris (incomplete)
	{
		auto parser = initParser!Msg();
		assert(parser.parseResponse("HTTP/1.0 200 OK\r\n") == -ParseError.partial);
		assert(parser.parseResponse("HTTP/1.0 200 OK\r\n\r") == -ParseError.partial);
		assert(parser.parseResponse(
				"HTTP/1.0 200 OK\r\n\r\nblabla") == "HTTP/1.0 200 OK\r\n\r\n".length);
	}

	parse("HTTP/1. 200 OK\r\n\r\n", Test.err); // invalid http version
	parse("HTTP/1.2z 200 OK\r\n\r\n", Test.err); // invalid http version 2
	parse("HTTP/1.1  OK\r\n\r\n", Test.err); // no status code

	assert(parse("HTTP/1.1 200\r\n\r\n").statusMsg == ""); // accept missing trailing whitespace in status-line
	parse("HTTP/1.1 200X\r\n\r\n", Test.err); // garbage after status 1
	parse("HTTP/1.1 200X \r\n\r\n", Test.err); // garbage after status 2
	parse("HTTP/1.1 200X OK\r\n\r\n", Test.err); // garbage after status 3

	assert(parse("HTTP/1.1 200 OK\r\nbar: \t b\t \t\r\n\r\n").headers[0].value == "b"); // exclude leading and trailing spaces in header value
}

@"Incremental"unittest {
	string req = "GET /cookies HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nConnection: keep-alive\r\nCache-Control: max-age=0\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17\r\nAccept-Encoding: gzip,deflate,sdch\r\nAccept-Language: en-US,en;q=0.8\r\nAccept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.3\r\nCookie: name=wookie\r\n\r\n";
	auto parser = initParser!Msg();
	uint parsed;
	auto res = parser.parseRequest(
		req[0 .. "GET /cookies HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nConn".length], parsed);
	assert(res == -ParseError.partial);
	assert(parser.msg.method == "GET");
	assert(parser.msg.uri == "/cookies");
	assert(parser.msg.minorVer == 1);
	assert(parser.msg.headers.length == 1);
	assert(parser.msg.headers[0] == Header("Host", "127.0.0.1:8090"));

	res = parser.parseRequest(req, parsed);
	assert(res == req.length);
	assert(parser.msg.method == "GET");
	assert(parser.msg.uri == "/cookies");
	assert(parser.msg.minorVer == 1);
	assert(parser.msg.headers[0] == Header("Host", "127.0.0.1:8090"));
	assert(parser.msg.headers[1] == Header("Connection", "keep-alive"));
	assert(parser.msg.headers[2] == Header("Cache-Control", "max-age=0"));
	assert(parser.msg.headers[3] == Header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"));
	assert(parser.msg.headers[4] == Header("User-Agent", "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17"));
	assert(parser.msg.headers[5] == Header("Accept-Encoding", "gzip,deflate,sdch"));
	assert(parser.msg.headers[6] == Header("Accept-Language", "en-US,en;q=0.8"));
	assert(parser.msg.headers[7] == Header("Accept-Charset", "ISO-8859-1,utf-8;q=0.7,*;q=0.3"));
	assert(parser.msg.headers[8] == Header("Cookie", "name=wookie"));
}

// used intrinsics

version (LDC) {
	public import core.simd;
	public import ldc.intrinsics;
	import ldc.gccbuiltins_x86;

	enum LDC_with_SSE42 = __traits(targetHasFeature, "sse4.2");

	// These specify the type of data that we're comparing.
	enum {
		_SIDD_UBYTE_OPS = 0x00,
		_SIDD_UWORD_OPS = 0x01,
		_SIDD_SBYTE_OPS = 0x02,
		_SIDD_SWORD_OPS = 0x03,

		// These specify the type of comparison operation.
		_SIDD_CMP_EQUAL_ANY = 0x00,
		_SIDD_CMP_RANGES = 0x04,
		_SIDD_CMP_EQUAL_EACH = 0x08,
		_SIDD_CMP_EQUAL_ORDERED = 0x0c,

		// These are used in _mm_cmpXstri() to specify the return.
		_SIDD_LEAST_SIGNIFICANT = 0x00,
		_SIDD_MOST_SIGNIFICANT = 0x40,

		// These macros are used in _mm_cmpXstri() to specify the return.
		_SIDD_BIT_MASK = 0x00,
		_SIDD_UNIT_MASK = 0x40,
	}

	// some used methods aliases
	alias expect = llvm_expect;
	alias _mm_loadu_si128 = loadUnaligned!int4;
	alias _mm_cmpestri = __builtin_ia32_pcmpestri128;
} else {
	enum LDC_with_SSE42 = false;

	T expect(T)(T val, T expected_val) if (__traits(isIntegral, T)) {
		pragma(inline, true);
		return val;
	}
}

pragma(msg, "SSE: ", LDC_with_SSE42);
