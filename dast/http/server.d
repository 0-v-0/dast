module dast.http.server;

import dast.async,
std.socket;

public import dast.async : EventLoop, EventExecutor;
public import dast.http : Request, Status, ServerSettings;

alias NextHandler = void delegate(),
ReqHandler = void function(HTTPServer server, HTTPClient client, scope NextHandler next);

///
@safe class HTTPClient : TcpStream {
	Request request;
	bool keepConnection;

nothrow:
	@property id() const => cast(int)handle;
	/// Whether the header has been sent
	@property headerSent() const => _headerSent;
	private bool tryParse() => request.tryParse(data);

	this(Selector loop, Socket socket, uint bufferSize = 4 * 1024) @trusted {
		super(loop, socket, bufferSize);
		p = _rBuf.ptr;
	}

	void writeHeader(T...)(T args) {
		foreach (arg; args)
			header ~= arg;
		header ~= "\r\n";
	}

	void send(in char[] msg) @trusted {
		if (!_headerSent) {
			if (!header.length)
				writeHeader("Content-Type: text/html");
			header ~= "Transfer-Encoding: chunked\r\n\r\n";
			write(header);
			header.length = 0;
			_headerSent = true;
		}
		char[18] b = void;
		auto p = intToHex(b.ptr, msg.length);
		*p = '\r';
		*(p + 1) = '\n';
		write(b[0 .. p - b.ptr + 2].dup);
		write(msg);
		write("\r\n");
	}

	private void clear() {
		clearQueue();
		header.length = 0;
		_headerSent = false;
	}

	void finish() {
		write("0\r\n\r\n");
		flush();
		reset();
		if (!keepConnection)
			close();
	}

	void reset() @trusted {
		_headerSent = false;
		_rBuf = p[0 .. _rBuf.ptr - p + _rBuf.length];
	}

protected:
	@property data() const @trusted => p[0 .. _rBuf.ptr - p];

	bool put(size_t len) @trusted {
		if (_rBuf.ptr - p + len >= bufferSize)
			return false;
		_rBuf = _rBuf[len .. $];
		return true;
	}

	typeof(_rBuf.ptr) p;
	char[] header;
	bool _headerSent;
}

class HTTPServer : TcpListener {
	private ReqHandler[] handlers;
	ServerSettings settings;
	uint connections;

	this(AddressFamily family = AddressFamily.INET) {
		super(new EventLoop, family);
	}

	this(Selector loop, AddressFamily family = AddressFamily.INET) {
		super(loop, family);
	}

	void run() {
		bindAndListen(_socket, settings);
		if (!onAccept)
			onAccept = (Socket socket) {
			if (settings.maxConnections && connections >= settings.maxConnections) {
				socket.close();
				return;
			}
			auto client = new HTTPClient(_inLoop, socket, settings.bufferSize);
			connections++;
			client.onReceived = (in ubyte[] data) @trusted {
				if (!client.put(data.length))
					client.close();
				if (!client.tryParse())
					return;
				client.keepConnection = client.request.headers.connection != "close";
				try {
					size_t i;
					scope NextHandler next;
					next = () {
						if (i < handlers.length)
							handlers[i++](this, client, next);
					};
					next();
				} catch (Exception e) {
					error(e);
					client.clear();
					client.writeHeader("HTTP/1.1 " ~ Status.Error);
					client.writeHeader("Content-Type: text/html; charset=UTF-8");
					client.send(e.toString());
				}
				client.finish();
			};
			client.onClosed = () { connections--; };
			client.start();
		};
		start();
		(cast(EventLoop)_inLoop).run();
	}

nothrow:
	void use(ReqHandler handler)
	in (handler) {
		handlers ~= handler;
	}
}

package(dast) void bindAndListen(Socket socket, in ServerSettings settings) @safe {
	import tame.string;

	socket.reusePort = settings.reusePort;
	foreach (host; splitter(settings.listen, ';')) {
		host = host.stripLeft();
		const(char)[] port;
		const i = host.indexOf(':');
		if (~i) {
			port = host[i + 1 .. $];
			host = host[0 .. i];
		}
		foreach (addr; getAddress(host.length ? host : "localhost", port)) {
			if (addr.addressFamily == socket.addressFamily)
				socket.bind(addr);
		}
	}
	socket.listen(settings.connectionQueueSize);
}

private auto intToHex(char* buf, size_t value) {
	char* p = buf;
	for (;;) {
		const n = cast(int)value & 0xf ^ '0';
		*p++ = cast(char)(n < 58 ? n : n + 39);
		if (value < 16)
			break;
		value >>= 4;
	}
	for (char* i = buf, j = p - 1; i < j; i++, j--) {
		char t = *i;
		*i = *j;
		*j = t;
	}
	return p;
}

unittest {
	char[16] buf = void;
	auto str = buf[];
	auto p = buf.ptr;
	assert(intToHex(p, 0) - p == 1);
	assert(str[0 .. 1] == "0", str);
	assert(intToHex(p, 0xff) - p == 2);
	assert(str[0 .. 2] == "ff", str);
	assert(intToHex(p, 0x12345678) - p == 8, str);
	assert(str[0 .. 8] == "12345678", str);
	assert(intToHex(p, size_t.max) - p == 16, str);
	assert(str == "ffffffffffffffff", str);
}
