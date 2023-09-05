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
	string[string] data;
	alias data this;

	auto opIndex(in string key) const {
		if (auto p = key in data)
			return *p;
		return null;
	}

	void opIndexAssign(in string value, in string key) pure @trusted nothrow {
		import core.stdc.stdlib;

		auto s = toLower((cast(char*)alloca(key.length))[0 .. key.length]);
		data[s.idup] = value;
	}

	auto opDispatch(string key)() const => this[key];

	auto opDispatch(string key)(string value) => data[key] = value;
}

struct Request {
	const(char)[] method, path, httpVersion;
	Headers headers;
	const(char)[] message;

@safe pure nothrow @nogc:
	void onMethod(const char[] m) {
		method = m;
	}

	void onUri(const char[] uri) {
		path = uri;
	}

	bool tryParse(const ubyte[] data) nothrow {
		import httparsed;

		MsgParser!Request parser;
		int res = parser.parseRequest(data);
		this = parser.msg;
		return res <= data.length;
	}
}
