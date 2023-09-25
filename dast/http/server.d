module dast.http.server;

import core.thread,
std.array,
std.socket;
public import dast.http : HTTPRequest = Request, Status;

class Request {
	enum bufferLen = 4 << 10;
	ubyte[bufferLen] buffer = void;
	HTTPRequest request;

	protected Socket sock;
	size_t stop;
	int requestId;

	@property auto headers() => request.headers;

	@property auto socket() => sock;

	@property void socket(Socket socket) {
		static id = 0;
		stop = 0;
		headers.data.clear();
		sock = socket;
		if (fillBuffer())
			requestId = id++;
	}

	protected bool fillBuffer() {
		while (!request.tryParse(buffer[0 .. stop])) {
			auto readn = sock.receive(buffer[stop .. $]);
			if (readn <= 0) {
				if (sock.isAlive)
					sock.close();
				return false;
			}
			stop += readn;
		}
		return true;
	}
}

class Response {
	enum {
		bufferLen = 1024,
		maxHeaderLen = 1024
	}
	bool headerSent = void;
	bool keepConnection = void;

	protected import tame.buffer : Buffer = FixedBuffer;

	Buffer!maxHeaderLen head;
	Buffer!bufferLen buf;

	this() {
		head = typeof(head)(&throwErr!"Headers");
		buf = typeof(buf)(&send);
	}

	int requestId = void;
	protected Socket sock = void;

	void initialize(Socket socket, int reqId, bool keepConn) pure @nogc nothrow @safe {
		sock = socket;
		requestId = reqId;
		headerSent = false;
		keepConnection = keepConn;
		head.clear();
		buf.clear();
	}

	Response opBinary(string op : "<<", T)(T content) {
		write(content);
		return this;
	}

	void writeHeader(T...)(T args) {
		static foreach (arg; args)
			head ~= arg; //.to!string;
		head ~= "\r\n";
	}

	void write(T...)(T args) {
		static foreach (arg; args)
			buf ~= arg;
	}

	alias put = write;

	void flush() {
		buf.flush();
	}

	void send(in char[] s) {
		if (!headerSent) {
			if (!head.length)
				writeHeader("Content-Type: text/html");
			head ~= "Transfer-Encoding: chunked\r\n\r\n";
			sock.send(head.data);
			head.clear();
			headerSent = true;
		}
		char[18] b = void;
		auto p = intToHex(b.ptr, s.length);
		*p = '\r';
		*(p + 1) = '\n';
		sock.send(b[0 .. p - b.ptr + 2]);
		sock.send(s);
		sock.send("\r\n");
	}

	void finish() {
		flush();
		sock.send("0\r\n\r\n");
		if (keepConnection)
			sock.close();
	}

	protected void throwErr(string obj)(in char[]) {
		throw new Exception(obj ~ " too long");
	}
}

private char* intToHex(char* buf, size_t value) {
	char* p = buf;
	for (;;) {
		int n = cast(int)value & 0xf ^ '0';
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

class Server {
	alias Handler = void delegate(Request req, Response resp);
	protected Handler handler;
	bool running;
	Socket listener;
	Thread[] threads;

	this(Handler dg) {
		handler = dg;
	}

	this(void function(Request req, Response resp) fn) {
		import std.functional;

		handler = toDelegate(fn);
	}

	void mainLoop() {
		import std.logger;
		import tame.ascii;

		scope req = new Request;
		scope resp = new Response;

		while (running) {
			Socket sock = void;
			synchronized (listener)
				try
					sock = listener.accept();
				catch (SocketAcceptException) {
					running = false;
					break;
				}
			req.socket = sock;
			resp.initialize(sock, req.requestId, req.headers.connection == "close");
			try
				handler(req, resp);
			catch (Exception e) {
				warningf("%s", e);
				resp.head.clear();
				resp.buf.clear();
				resp.writeHeader("HTTP/1.1 500 Internal Server Error");
				resp.writeHeader("Content-Type: text/html; charset=UTF-8");
				resp << e.toString();
			}
			resp.finish();
		}
	}

	void start(ushort port = 3031, uint maxThread = 1) {
		listener = new TcpSocket;
		listener.bind(new InternetAddress("127.0.0.1", port));
		listener.listen(128);

		running = true;
		if (!maxThread)
			return mainLoop();

		threads = uninitializedArray!(Thread[])(maxThread);
		foreach (ref thread; threads) {
			thread = new Thread(&mainLoop);
			thread.start();
		}
	}
}
