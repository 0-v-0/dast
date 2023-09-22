module dast.http.common;

import tame.ascii;

enum Status {
	OK = "200 OK",
	NoContent = "204 No Content",
	Unauthorized = "401 Unauthorized",
	Forbidden = "403 Forbidden",
	NotFound = "404 Not Found",
	MethodNotAllowed = "405 Method Not Allowed",
	Error = "500 Internal Server Error"
}

struct Headers {
	const(char)[][const(char)[]] data;
	alias data this;

	auto opIndex(in char[] key) const {
		if (auto p = key in data)
			return *p;
		return null;
	}

	void opIndexAssign(in char[] value, in char[] key) pure @trusted nothrow {
		data[cast(string)toLower(key.dup)] = value;
	}

	auto opDispatch(string key)() const => this[key];

	auto opDispatch(string key)(in char[] value) => data[key] = value;
}

struct Request {
	const(char)[] method, path, httpVersion;
	Headers headers;
	const(char)[] message;

@safe pure nothrow:
	void onMethod(const char[] m) @nogc {
		method = m;
	}

	void onUri(const char[] uri) @nogc {
		path = uri;
	}

	void onHeader(const char[] name, const char[] value) {
		headers[name] = value;
	}

	bool tryParse(const ubyte[] data) nothrow {
		import httparsed;

		MsgParser!Request parser;
		int res = parser.parseRequest(data);
		this = parser.msg;
		return res <= data.length;
	}
}
