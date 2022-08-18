module dast.ws.frame;
import std.bitmanip;

enum Op : ubyte {
	CONT = 0,
	TEXT = 1,
	BINARY = 2,
	CLOSE = 8,
	PING = 9,
	PONG = 10
}

struct Frame {
	struct {
		bool fin;
		Op op;
		bool masked;
	}

	State state;
	ubyte[4] mask;
	ulong length;
	const(ubyte)[] data;

	invariant (op < 16);

pure nothrow:
	@property bool done() const @nogc {
		return state == State.done;
	}

	@property size_t remaining() const @nogc {
		return cast(size_t)length - data.length;
	}

	ubyte[] serialize() nothrow {
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

		ubyte[] result = void;
		if (masked) {
			p[0 .. 4] = mask;
			p += 4;
			result = buf[0 .. p - buf.ptr];
			result.reserve(result.length + data.length);
			for (size_t i; i < data.length; i++)
				result ~= data[i] ^ mask[i & 3];
		} else
			result = buf[0 .. p - buf.ptr] ~ data;

		return result;
	}
}

auto next(size_t n = 1)(ref const(ubyte)[] data, size_t m = n)
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
	prev_start,
	fin_rsv_opcode,
	prev_fin_rsv_opcode,
	mask_len,
	prev_mask_len,
	len126_ext_len,
	prev_len126_ext_len,
	len127_ext_len,
	prev_len127_ext_len,
	maskOn_mask,
	prev_maskOn_mask,
	message_extraction,
	prev_message_extraction,
	done,
	prev_done
}

package const(ubyte)[][int] dataBySource;
package Frame[int] frames;

Frame parse(int source, const(ubyte)[] data) nothrow {
	Frame frame;
	if (auto p = source in frames)
		frame = *p;
	if (auto p = source in dataBySource)
		data = (*p) ~ data;

	enum changeState(string state) =
		"{ frame.state = " ~ state ~ "; goto case " ~ state ~ "; }";

	switch (frame.state) with (State) {
	case prev_start:
	case start:
	case fin_rsv_opcode:
		if (data.length) {
			frame = Frame.init;
			ubyte b = data.next; // next() modifies `data` by consuming the first byte
			if ((b >>> 4) & 7)
				return frame;
			frame.fin = b >>> 7;
			frame.op = cast(Op)(b & 0xf);

			frame.state = prev_fin_rsv_opcode;
			goto case;
		}
		goto save;
	case prev_fin_rsv_opcode:
	case mask_len:
		if (!data.length)
			goto save;
		ubyte b = data.next;
		frame.masked = b >>> 7;
		frame.length = b & 0x7f;
		if (frame.length <= 125)
			mixin(changeState!"maskOn_mask");
		if (frame.length == 127)
			mixin(changeState!"len127_ext_len");

		frame.state = prev_mask_len;
		goto case;
	case prev_mask_len:
	case len126_ext_len:
		if (data.length <= 1)
			goto save;
		frame.length = bigEndianToNative!ushort(data[0 .. 2]);
		data = data[2 .. $];
		mixin(changeState!"maskOn_mask"); // edge case: length=127
	case prev_len126_ext_len:
	case len127_ext_len:
		if (data.length < 8)
			goto save;
		frame.length = bigEndianToNative!ulong(data[0 .. 8]);
		data = data[8 .. $];
		frame.state = prev_len127_ext_len;
		goto case;
	case prev_len127_ext_len:
	case maskOn_mask:
		if (data.length < (frame.masked << 2))
			goto save;
		if (frame.masked)
			frame.mask = data.next!4; // next!n when n > 1 returns ubyte[]
		frame.state = prev_maskOn_mask;
		goto case;
	case prev_maskOn_mask:
	case message_extraction:
		if ((frame.length && data.length) || frame.length == 0) {
			if (frame.masked) {
				auto i = frame.data.length;
				while (frame.remaining && data.length) {
					ubyte b = data.next;
					frame.data ~= b ^ frame.mask[i % 4];
					i++;
				}
			} else if (data.length >= frame.remaining)
				frame.data ~= data.next!2(frame.remaining);
			else
				frame.data ~= data.next!2(data.length);

			frame.state = prev_message_extraction;
			goto case;
		}
		goto save;
	case prev_message_extraction:
	case done:
		// to allow for streaming we have this changeState(..) loop
		if (frame.remaining)
			mixin(changeState!"message_extraction");

		frame.state = State.done;
		goto save_data;
	case prev_done:
	default:
		frame.state = start;
		dataBySource[source] = data;
	}
	return frame;
save:
	frames[source] = frame;
save_data:
	dataBySource[source] = data;
	return frame;
}

unittest { // test multiple frames in one go
	auto f1 = Frame(true, Op.TEXT, true, State.done, [0, 0, 0, 0], 6, [
			0, 1, 2, 3, 4, 5
		]);
	auto f2 = Frame(false, Op.BINARY, true, State.done, [0, 1, 2, 3], 3, [
			8, 7, 6
		]);
	auto f3 = Frame(false, Op.CLOSE, true, State.done, [0, 1, 2, 3], 10, [
			9, 8, 7, 6, 5, 4, 3, 2, 1, 0
		]);
	auto d = f1.serialize ~ f2.serialize ~ f3.serialize;
	auto f4 = 0.parse(d);
	auto f5 = 0.parse([]);
	auto f6 = 0.parse([]);
	assert(f1 == f4);
	assert(f2 == f5);
	assert(f3 == f6);
}

unittest { // test streaming one byte at a time
	auto f = Frame(true, Op.TEXT, true, State.done, [1, 2, 3, 4], 6, [
			0, 1, 2, 3, 4, 5
		]);
	ubyte[] data = f.serialize;
	foreach (b; data[0 .. $ - 1]) {
		auto _f = 1.parse([b]);
		assert(!_f.done);
	}
	auto _f = 1.parse([data[$ - 1]]);
	assert(_f.done);
	assert(f == _f);
}

unittest { // test some funky streaming
	ubyte[] data;
	foreach (i; 0 .. (1 << 20))
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
		auto _f = 2.parse(serialized[i0 .. i1]);
		if (i1 == serialized.length) {
			assert(_f.done);
			assert(_f == f);
		} else
			assert(!_f.done);
	}
	while (i1 < serialized.length);
}

unittest { // test edge-case length=127
	ubyte[] data;
	for (size_t i = 0; i < 127; i++)
		data ~= cast(ubyte)i;
	auto f = Frame(true, Op.BINARY, false, State.done, [0, 0, 0, 0], data.length, data);
	auto _f = 3.parse(f.serialize);
	assert(f == _f);
}

unittest { // test edge-case length=0

	auto f = Frame(true, Op.CLOSE, false, State.done, [0, 0, 0, 0], 0, []);
	auto _f = 4.parse(f.serialize);
	assert(f == _f);
}
