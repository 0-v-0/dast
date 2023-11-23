module dast.ws.frame;

import dast.ws.server,
std.bitmanip,
std.algorithm : min;

enum Op : ubyte {
	CONT = 0,
	TEXT = 1,
	BINARY = 2,
	CLOSE = 8,
	PING = 9,
	PONG = 10
}

struct Frame {
	bool fin;
	Op op;
	bool masked;
	State state;

	ubyte[4] mask;
	ulong length;
	const(ubyte)[] data;

	invariant (op < 16);

pure nothrow:
	@property bool done() const @nogc => state == State.done;

	@property size_t remaining() const @nogc => cast(size_t)length - data.length;

	ubyte[] serialize() scope @trusted {
		ubyte[14] buf = void;
		auto p = buf.ptr;

		*p++ = fin << 7 | op;
		ubyte b2 = masked << 7;
		if (length < 126)
			*p++ = b2 | cast(ubyte)length;
		else if (length < 0xffff) {
			*p++ = b2 | 126;
			p[0 .. 2] = nativeToBigEndian(cast(ushort)length);
			p += 2;
		} else {
			*p++ = b2 | 127;
			p[0 .. 8] = nativeToBigEndian(length);
			p += 8;
		}

		if (masked) {
			p[0 .. 4] = mask;
			const U u = {a: mask};
			auto result = buf[0 .. p + 4 - buf.ptr];
			result.reserve(result.length + data.length);
			auto i = data.length & ~3;
			foreach (x; cast(const(uint)[])data[0 .. i])
				result ~= U(x ^ u.m).a;
			for (; i < data.length; i++)
				result ~= data[i] ^ mask[i & 3];
			return result;
		}
		return buf[0 .. p - buf.ptr] ~ data;
	}
}

private union U {
	uint m;
	ubyte[4] a;
}

auto read(size_t n = 1)(ref const(ubyte)[] data, size_t m = n)
in (data.length >= m, "Insufficient data") {
	static if (n == 1) {
		ubyte b = data[0];
		data = data[1 .. $];
	} else {
		auto b = data[0 .. m];
		data = data[m .. $];
	}
	return b;
}

enum State : ubyte {
	start,
	fin_rsv_opcode = 0,
	mask_len,
	len126_ext_len,
	len127_ext_len,
	maskOn_mask,
	message_extraction,
	done,
	prev_done
}

Frame parse(WSClient client, const(ubyte)[] data) nothrow {
	Frame f = client.frame;
	data = client.data ~ data;

	enum changeState(string state) =
		"{ f.state = " ~ state ~ "; goto case " ~ state ~ "; }";

	switch (f.state) with (State) {
	case start:
		if (!data.length)
			goto save;
		f = Frame.init;
		ubyte b = data.read; // read() modifies `data` by consuming the first byte
		if ((b >> 4) & 7)
			return f;
		f.fin = b >> 7;
		f.op = cast(Op)(b & 0xf);
		f.state = mask_len;
		goto case;
	case mask_len:
		if (!data.length)
			goto save;
		ubyte b = data.read;
		f.masked = b >> 7;
		f.length = b & 0x7f;
		if (f.length <= 125)
			mixin(changeState!"maskOn_mask");
		if (f.length == 127)
			mixin(changeState!"len127_ext_len");

		f.state = len126_ext_len;
		goto case;
	case len126_ext_len:
		if (data.length <= 1)
			goto save;
		f.length = bigEndianToNative!ushort(data[0 .. 2]);
		data = data[2 .. $];
		mixin(changeState!"maskOn_mask"); // edge case: length=127
	case len127_ext_len:
		if (data.length < 8)
			goto save;
		f.length = bigEndianToNative!ulong(data[0 .. 8]);
		data = data[8 .. $];
		f.state = maskOn_mask;
		goto case;
	case maskOn_mask:
		if (f.masked) {
			if (data.length < 4)
				goto save;
			f.mask = data.read!4; // read!n when n > 1 returns ubyte[]
		}
		f.state = message_extraction;
		goto case;
	case message_extraction:
		if (f.length && (!f.length || !data.length))
			goto save;
		auto len = min(f.remaining, data.length);
		if (f.masked) {
			auto i = f.data.length;
			for (; (i & 3) && f.remaining && data.length; i++, len--)
				f.data ~= data.read ^ f.mask[i & 3];
			const U u = {a: f.mask};
			foreach (x; cast(const(uint)[])data[0 .. len & ~3])
				f.data ~= U(x ^ u.m).a;
			for (data = data[len & ~3 .. $]; f.remaining && data.length; i++)
				f.data ~= data.read ^ f.mask[i & 3];
		} else
			f.data ~= data.read!2(len);

		f.state = done;
		goto case;
	case done:
		// to allow for streaming we have this changeState(..) loop
		if (f.remaining)
			mixin(changeState!"message_extraction");

		f.state = State.done;
		goto save_data;
	default:
		f.state = start;
		client.data = data;
	}
	return f;
save:
	client.frame = f;
save_data:
	client.data = data;
	return f;
}

unittest { // test multiple frames in one go
	scope c = new WSClient(null, null);

	auto f1 = Frame(true, Op.TEXT, true, State.done, [0, 0, 0, 0],
		6, [0, 1, 2, 3, 4, 5]);
	auto f2 = Frame(false, Op.BINARY, true, State.done, [0, 1, 2, 3],
		3, [8, 7, 6]);
	auto f3 = Frame(false, Op.CLOSE, true, State.done, [0, 1, 2, 3],
		10, [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]);
	const d = f1.serialize ~ f2.serialize ~ f3.serialize;
	auto f4 = c.parse(d);
	auto f5 = c.parse([]);
	auto f6 = c.parse([]);
	assert(f1 == f4);
	assert(f2 == f5);
	assert(f3 == f6);
}

unittest { // test one splitted frame
	scope c = new WSClient(null, null);
	auto f = Frame(false, Op.BINARY, true, State.done, [47, 119, 231, 3],
		10, [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]);
	const d1 = f.serialize[0 .. 7];
	const d2 = f.serialize[7 .. $];
	auto f1 = c.parse(d1);
	assert(!f1.done);
	auto f2 = c.parse(d2);
	assert(f2.done);
	assert(f == f2);
}

unittest { // test streaming one byte at a time
	scope c = new WSClient(null, null);

	auto f = Frame(true, Op.TEXT, true, State.done, [1, 2, 3, 4],
		6, [0, 1, 2, 3, 4, 5]);
	const data = f.serialize;
	foreach (b; data[0 .. $ - 1]) {
		auto _f = c.parse([b]);
		assert(!_f.done);
	}
	auto _f = c.parse([data[$ - 1]]);
	assert(_f.done);
	assert(f == _f);
}

unittest { // test some funky streaming
	scope c = new WSClient(null, null);

	ubyte[] data;
	foreach (i; 0 .. 1 << 20)
		data ~= cast(ubyte)i;
	auto f = Frame(false, Op.BINARY, true, State.done, [0, 0, 0, 0], data.length, data);
	ubyte[] serialized = f.serialize;
	size_t i0 = 0, i1 = 0, t = 1;
	do {
		i0 = i1;
		i1 = i0 + (((i0 & i1 | 3) ^ t) & 0x3f);
		if (i1 >= serialized.length)
			i1 = serialized.length;
		t++;
		auto _f = c.parse(serialized[i0 .. i1]);
		if (i1 == serialized.length) {
			assert(_f.done);
			assert(_f == f);
		} else
			assert(!_f.done);
	}
	while (i1 < serialized.length);
}

unittest { // test edge-case length=127
	scope c = new WSClient(null, null);

	ubyte[127] data = void;
	for (size_t i; i < 127; i++)
		data[i] = cast(ubyte)i;
	auto f = Frame(true, Op.BINARY, false, State.done, [0, 0, 0, 0], data.length, data[]);
	auto _f = c.parse(f.serialize);
	assert(f == _f);
}

unittest { // test edge-case length=0
	scope c = new WSClient(null, null);

	auto f = Frame(true, Op.CLOSE, false, State.done, [0, 0, 0, 0], 0, []);
	auto _f = c.parse(f.serialize);
	assert(f == _f);
}
