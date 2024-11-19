module dast.net.curl;

import dast.net.curlapi : C = Curl, CurlInf, curl = curlAPI;
public import etc.c.curl : CurlError, CurlOption, CurlProto, CURL, CURLcode;

struct Curl {
	C c;
	alias c this;

	this(CURL* h) {
		c = C(h);
	}

	this(C curl) {
		c = curl;
	}

	@disable this();

	@property void connTimeout(long secs) => set(CurlOption.connecttimeout, secs);

	@property void timeout(long secs) => set(CurlOption.timeout, secs);

	@property void nobody(bool v) => set(CurlOption.nobody, v);

	@property void maxredirs(long v) => set(CurlOption.maxredirs, v);

	@property long contentLength() => c.get(CurlInf.contentlengthdownload);

private:
	void* ch;
}

struct CurlSet {
	import etc.c.curl : CurlM, CurlMsg, CURLMsg;
	this(Curl[] cs) {
		mh = curl.multi_init();
		_rc = 1;
		msgLeft = -1;
		if (mh) {
			foreach (c; cs)
				curl.multi_add_handle(mh, c.handle);
		}
	}

	this(this) {
		++_rc;
	}

	~this() {
		if (mh) {
			if (--_rc == 0)
				curl.multi_cleanup(mh);
		}
	}

	@property handle() => mh;

	@property bool running() => _running > 0;

	@property empty() {
		if (msgLeft < 0)
			msg = curl.multi_info_read(mh, &msgLeft);
		return msgLeft == 0;
	}

	auto tryWait(int timeout_ms = 1000) => curl.multi_wait(mh, null, 0, timeout_ms, null);

	auto add(Curl c) => curl.multi_add_handle(mh, c.handle);

	auto remove(Curl c) => curl.multi_remove_handle(mh, c.handle);

	auto perform() => curl.multi_perform(mh, &_running);

	auto run() {
		while (_running > 0) {
			auto rc = perform();
			if (rc != CurlM.call_multi_perform)
				return rc;
		}
		return CurlM.ok;
	}

private:
	void* mh;
	uint _rc;
	int _running;
	CURLMsg* msg;
	int msgLeft;
}

version (unittest) private void testFunc(alias f)(in char[] src, string expected) {
	char[256] buf = void;
	assert(f(src, buf) == expected.length);
	assert(buf[0 .. expected.length] == expected);
}

// TODO: @nogc nothrow

/// URI编码
int escapeTo(in char[] src, scope char[] dst) @trusted
in (src.length <= int.max) {
	import etc.c.curl,
	core.stdc.string;

	dst[0 .. src.length] = src;
	dst[src.length] = 0;
	int len = -1;
	auto p = curl.easy_escape(null, dst.ptr, cast(int)src.length);
	if (p) {
		len = cast(int)strlen(p);
		if (len <= dst.length)
			dst[0 .. len] = p[0 .. len];
		else
			len = -1;
		curl.free(p);
	}
	return len;
}

@safe unittest {
	alias test = testFunc!escapeTo;
	test("ab", "ab");
	test("a b", "a%20b");
}

/// URI解码
int unescapeTo(in char[] src, scope char[] dst) @trusted
in (src.length <= int.max)
in (dst.length > src.length) {
	import etc.c.curl;

	if (src.ptr !is dst.ptr)
		dst[0 .. src.length] = src;
	dst[src.length] = 0;
	int len = -1;
	auto p = curl.easy_unescape(null, dst.ptr, cast(int)src.length, &len);
	if (p) {
		dst[0 .. len] = p[0 .. len];
		curl.free(p);
	}
	return len;
}

@safe unittest {
	alias test = testFunc!unescapeTo;

	test("ab", "ab");
	test("a%20b", "a b");
}