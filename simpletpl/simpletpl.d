module simpletpl;

import std.range : isOutputRange;
import core.stdc.string;

version (WASI) {
	version (LDC) {
		pragma(LDC_no_moduleinfo);
		pragma(LDC_no_typeinfo);
		pragma(LDC_alloca)
		void* alloca(size_t size) pure;
	}
}

private:

enum Error(string s) = s;

extern (C):

bool isAllowedChar(char c) =>
	('0' <= c && c <= '9') ||
	('a' <= c && c <= 'z') ||
	('A' <= c && c <= 'Z') ||
	c == '_' || c == '.';
// || c == '[' || c == ']';

/++
	Params: c = The character to test.
	Returns: Whether or not `c` is a whitespace character. That includes the
	space, tab, vertical tab, form feed, carriage return, and linefeed
	characters.
 +/
bool isWhite(dchar c) @safe pure nothrow @nogc
	=> c == ' ' || (c >= 0x09 && c <= 0x0D);

size_t search(string s, char c) {
	size_t i;
	for (; i < s.length; i++)
		if (s[i] == c)
			return i;
	return i;
}

bool isTrue(string str) {
	size_t i;
	while (i < str.length && str[i].isWhite)
		i++;
	str = str[i .. $];
	for (i = str.length; i;)
		if (!str[--i].isWhite)
			break;
	if (!str.length)
		return false;
	str = str[0 .. i + 1];
	if (str.length == 5 && str[4] == 'e') {
		auto p = cast(int*)str.ptr;
		if (*p == 1936482662)
			return false;
	}
	return str.length != 1 || str[0] != '0';
}

unittest {
	assert(!"".isTrue);
	assert(!"0".isTrue);
	assert(!"false".isTrue);
	assert("2".isTrue);
	assert("str".isTrue);
}

bool findSplit(ref string str, ref string slice, char c) {
	size_t i;
	for (; i < str.length; i++) {
		if (str[i] == c) {
			slice = str[0 .. i];
			str = str[i + 1 .. $];
			return true;
		}
	}
	if (i == 0)
		return false;
	slice = str;
	str = "";
	return true;
}

unittest {
	auto str = "x\0yaa\0c\0d";
	string ele;
	assert(str.findSplit(ele, '\0'), str);
	assert(ele == "x", ele);
	assert(str.findSplit(ele, '\0'), str);
	assert(ele == "yaa", ele);
	assert(str.findSplit(ele, '\0'), str);
	assert(ele == "c", ele);
	str = "\0";
	assert(str.findSplit(ele, '\0'), str);
}

size_t intToStr(char* buf, size_t value) {
	char* p = buf;
	for (;;) {
		*p++ = (value % 10) ^ '0';
		if (value < 10)
			break;
		value /= 10;
	}
	for (char* i = buf, j = p - 1; i < j; i++, j--) {
		char t = *i;
		*i = *j;
		*j = t;
	}
	return p - buf;
}

unittest {
	char[10] buf = void;
	auto str = buf[];
	assert(intToStr(buf.ptr, 0));
	assert(str[0 .. 1] == "0", str);
	assert(intToStr(buf.ptr, 255));
	assert(str[0 .. 3] == "255", str);
	assert(intToStr(buf.ptr, 20170), str);
	assert(str[0 .. 5] == "20170", str);
	assert(intToStr(buf.ptr, 4294967295), str);
	assert(str == "4294967295", str);
}

// get start pos & end pos of contents inside [ … ]
// start == end means not found
void getBlock(char bs = '[', char be = ']', C)(const(C[]) str, ref size_t start, ref size_t end) {
	end = start;
	size_t j = start;
	while (j < str.length) {
		if (str[j].isWhite)
			j++;
		else {
			if (str[j] != bs)
				return;
			break;
		}
	}
	if (++j >= str.length)
		return;
	start = j;
	for (uint level; j < str.length; j++) {
		if (str[j] == bs)
			level++;
		else if (str[j] == be) {
			if (level == 0)
				break;
			else
				level--;
		}
	}
	end = j < str.length ? j : start;
}

/+
syntax: \$(var)?:(key )?(value)?\?\{\}

max variable name: 256
max inputlength: 24kb
max variable value length: 24kb

output
	$var

raw output
	$:var

condition
	$cond?[ … ]
	$cond?[ … ]:[ … ]

loop
	$map:value[ … ]
	$map:key value[ … ]

expression evaluation
	${expr}

returns: error message (empty if succeed)
+/

string renderImpl(alias getContent, String, Sink)(ref Sink sink, String tpl, uint maxDepth = 5)
if (isOutputRange!(Sink, String))
in (maxDepth < 24) {
	do {
		auto i = tpl.search('$');
		if (i + 1 >= tpl.length) {
			sink.put(tpl);
			break;
		}
		sink.put(tpl[0 .. i]);
		i++;
		size_t bs, be, j = void;
		String var = void;
		bool flag;
		if (tpl[i] == '{') { // expr
			bs = i;
			getBlock!('{', '}')(tpl, bs, be);
			if (bs == be) {
				sink.put(tpl[i .. $]);
				return null;
			}
			if (maxDepth == 0)
				return Error!"MaxDepth exceeded";
			push();
			renderImpl!getContent(sink, getContent(tpl[bs .. be]), maxDepth - 1);
			popFront();
			i = be + 1;
			goto next;
		}
		j = i + (i < tpl.length && tpl[i] == ':');
		while (j < tpl.length && tpl[j].isAllowedChar)
			j++;
		var = tpl[i .. j];
		i = j;
		while (j < tpl.length && tpl[j].isWhite)
			j++;
		if (j + 3 < tpl.length) {
			if (tpl[j] == '?') { // cond
				bs = ++j;
				getBlock(tpl, bs, be);
				if (bs == be)
					goto output;
				alias cond = flag;
				cond = getVal(var).isTrue;
				if (cond) {
					renderImpl!getContent(sink, tpl[bs .. be], maxDepth);
				}
				j = be + 1;
				while (j < tpl.length && tpl[j].isWhite)
					j++;
				if (j == tpl.length)
					return null;
				if (tpl[j] == ':') {
					bs = j + 1;
					getBlock(tpl, bs, be);
					if (bs == be) {
						i = j;
						goto next;
					}
					if (!cond) {
						renderImpl!getContent(sink, tpl[bs .. be], maxDepth);
					}
				}
				i = be + 1;
				goto next;
			}
			if (tpl[j] == ':') { // loop
				++j;
				while (j < tpl.length && tpl[j].isWhite)
					j++;
				if (j == tpl.length)
					goto output;
				auto str = var;
				alias mapname = str;
				auto map = cast(String)getVal(mapname);
				if (mapname.length > 254)
					return Error!"Name too long";
				version (WASI) {
					auto mbuf = cast(char*)alloca(map.length);
					memcpy(mbuf, map.ptr, map.length);
					map = cast(String)mbuf[0 .. map.length];
				}
				auto k = j;
				while (j < tpl.length && tpl[j].isAllowedChar)
					j++;
				auto keyname = tpl[k .. j];
				while (j < tpl.length && tpl[j].isWhite)
					j++;
				if (j == tpl.length)
					goto output;
				k = j;
				while (j < tpl.length && tpl[j].isAllowedChar)
					j++;
				bs = j;
				getBlock(tpl, bs, be);
				if (bs == be)
					goto output;
				if (k < j) {
					var = tpl[k .. j];
				} else {
					var = keyname;
					keyname = null;
				}
				if (map.length) {
					auto block = tpl[bs .. be];
					char[256] buf = void;
					auto p = buf.ptr;
					alias isArray = flag;
					isArray = map[0] == '\0';
					if (isArray)
						map = map[1 .. $];
					else {
						memcpy(p, mapname.ptr, mapname.length);
						p += mapname.length;
						*(p++) = '.';
					}
					if (map.length) {
						push();
						alias index = k,
						keystr = str;
						for (index = 0; map.findSplit(keystr, '\0'); index++) {
							if (isArray) {
								if (keyname.length) {
									auto keylen = intToStr(p, index);
									assert(keylen <= 10);
									setValue(keyname, cast(string)buf[0 .. keylen]);
								}
								if (var.length)
									setValue(var, keystr);
							} else {
								memcpy(p, keystr.ptr, keystr.length);
								auto keylen = p - buf.ptr + keystr.length;
								if (keylen > 256)
									return Error!"Name too long";
								auto fullkey = cast(string)buf[0 .. keylen];
								if (keyname.length)
									setValue(keyname, fullkey);
								if (var.length)
									setValue(var, getVal(fullkey));
							}
							renderImpl!getContent(sink, block, maxDepth);
						}
						popFront();
					}
				}
				i = be + 1;
				goto next;
			}
		}
	output:
		auto value = cast(String)getVal(var);
		if (!value.length) {
			sink.put("$");
			value = var;
		}
		sink.put(value);
	next:
		tpl = tpl[i .. $];
	}
	while (tpl.length);
	return null;
}

public:

version (WASI) {
	export byte[24 << 10] buf, inbuf;
	byte[8 << 10] outbuf;
	size_t pos;

	private void put(void[], string s) {
		auto remain = pos + s.length;
		for (;;) {
			auto outlen = remain < outbuf.length ? remain : outbuf.length;
			outlen -= pos;
			memcpy(outbuf.ptr + pos, s.ptr, outlen);
			s = s[outlen .. $];
			if (outlen + pos != outbuf.length)
				break;
			pos = 0;
			remain -= outbuf.length;
			flushBuffer(outbuf[]);
		}
		pos = remain;
	}
	// get variable value
	size_t getValue(in string key);
	string getVal(in string key) {
		size_t len = getValue(key);
		return cast(string)inbuf[0 .. len];
	}

	void setValue(in string key, in string value);
	size_t evalExpr(in string expr);
	string getContent(in string expr) {
		auto len = evalExpr(expr);
		return cast(string)inbuf[0 .. len];
	}
	//size_t inputBuffer(byte[] buf);
	void flushBuffer(void[] buf);
	void push();
	void popFront();
	export const(char*) render(string tpl, uint maxDepth) {
		auto arr = cast(char[])outbuf[];
		auto errmsg = renderImpl!getContent(arr, tpl, maxDepth);
		if (pos) {
			flushBuffer(outbuf[0 .. pos]);
			pos = 0;
		}
		return errmsg.ptr;
	}
} else {
	alias
	getVal = getValue,
	render = renderImpl;

	struct Context {
		string[string] data;
		alias data this;

		auto opIndex(const string key) {
			if (auto p = key in data)
				return *p;
			return null;
		}

		void opIndexAssign(const string value, const string key) pure {
			data[key] = value;
		}

		auto opDispatch(string key)() => this[key];

		auto opDispatch(string key)(const string value) => data[key] = value;

		void free() nothrow @nogc {
			destroy!false(data);
		}
	}

	Context[] data;

	// helper for HTML escape(original function from std.xml.encode)
	void escape(String, Sink)(const String text, ref Sink sink)
	if (isOutputRange!(Sink, String)) {
		size_t index;

		foreach (i, c; text) {
			String temp = void;
			// dfmt off
			switch (c) {
			case '&': temp = "&amp;";  break;
			case '"': temp = "&quot;"; break;
			case '<': temp = "&lt;";   break;
			case '>': temp = "&gt;";   break;
			default: continue;
			}
			// dfmt on

			sink.put(text[index .. i]);
			sink.put(temp);
			index = i + 1;
		}

		sink.put(text[index .. $]);
	}

	string getValue(scope const(char)[] key) {
		import std.array;

		string value;
		if (!key.length)
			return value;

		bool flag = key[0] == ':';
		if (flag)
			key = key[1 .. $];

		foreach_reverse (x; data)
			if (auto p = cast(string)key in x) {
				value = *p;
				break;
			}
		if (flag)
			return value;

		auto app = appender!string;
		escape(value, app);
		return app[];
	}

	void setValue(scope const(char[]) key, scope const(char[]) value)
	in (data.length) {
		data[$ - 1][cast(string)key] = cast(string)value;
	}

	void push() {
		data ~= Context();
	}

	void popFront() {
		data.length--;
	}

	T render(alias getContent, T)(T tpl, Context data, uint maxDepth = 5) {
		import std.array;

		auto app = appender!T;

		

		.data = [data];
		renderImpl!getContent(app, tpl, maxDepth);
		return app[];
	}
}

unittest {
	void test(string tpl, string expected) {
		auto result = tpl.render!getVal(data[0]);
		assert(result == expected, tpl ~ ": " ~ result);
	}

	Context data; // @suppress(dscanner.suspicious.label_var_same_name)
	data.a = "55";
	data.b = "<";
	data.m = "x\0y\0n";
	data.l = "\0b\0c\0d\0e";
	data["m.x"] = "a";
	data["m.y"] = "foo";
	data["m.n"] = "bar";

	

	.data = [data];
	test("a $a $n $b $:b", "a 55 $n &lt; <");
	test("$a?bcd", "55?bcd");
	test("$a?[x]:bcd", "x:bcd");
	test("$a?[foo]:[bar]", "foo");
	test("$x?[foo]:[bar]", "bar");
	test("$l:k v[$k=$v ]", "0=b 1=c 2=d 3=e ");
	test("$a:[bcd]", "bcd");
	test("$a:x foo", "55:x foo");
	test("u$m:k v[$k=$v ]123", "um.x=a m.y=foo m.n=bar 123");
	test("w$m:k v[$k=$v $l:k v[$k=$v ]]",
		"wm.x=a 0=b 1=c 2=d 3=e m.y=foo 0=b 1=c 2=d 3=e m.n=bar 0=b 1=c 2=d 3=e ");
}
