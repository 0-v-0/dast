module dast.http.server;

import dast.async,
std.logger,
std.socket;

public import dast.async : EventLoop;
public import dast.http : Request, Status, ServerSettings;

alias NextHandler = void delegate(),
ReqHandler = void function(HTTPServer server, HTTPClient client, in Request req, scope NextHandler next);

class HTTPClient : TcpStream {
	bool keepConnection;

@safe nothrow:
	@property id() const => cast(int)handle;
	@property headerSent() const => _headerSent;
	@property Request* request()
		=> req.tryParse(buf) ? &req : null;

	this(Selector loop, Socket socket, uint bufferSize = 4 * 1024) {
		super(loop, socket, bufferSize);
	}

	override void start() {
		super.start();
		buf.reserve(bufferSize);
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
		write(b[0 .. p - b.ptr + 2]);
		write(msg);
		write("\r\n");
	}

	private bool put(in ubyte[] data) {
		if (buf.length + data.length > bufferSize)
			return false;
		buf ~= data;
		return true;
	}

	private void clear() {
		clearQueue();
		header.length = 0;
		_headerSent = false;
	}

	void finish() {
		write("0\r\n\r\n");
		_headerSent = false;
		if (!keepConnection)
			close();
	}
protected:
	const(ubyte)[] buf;
	char[] header;
	Request req;
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
		import std.conv,
		tame.string;

		_socket.reusePort = settings.reusePort;
		auto addr = settings.address;
		ushort port = 80;
		const i = addr.indexOf(':');
		if (~i) {
			port = addr[i + 1 .. $].to!ushort;
			addr = addr[0 .. i];
		}
		socket.bind(new InternetAddress(addr, port));
		socket.listen(settings.connectionQueueSize);
		onAccept = (Socket socket) {
			if (settings.maxConnections && connections >= settings.maxConnections) {
				socket.close();
				return;
			}
			auto client = new HTTPClient(_inLoop, socket, settings.bufferSize);
			connections++;
			client.onReceived = (in ubyte[] data) @trusted {
				if (!client.put(data))
					client.close();
				auto req = client.request;
				if (!req)
					return;
				client.keepConnection = req.headers.connection != "close";
				try {
					size_t i;
					scope NextHandler next;
					next = () {
						if (i < handlers.length)
							handlers[i++](this, client, *req, next);
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
