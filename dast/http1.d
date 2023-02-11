module dast.http1;

// dfmt off
import core.thread,
	std.array,
	std.socket;
// dfmt on
public import dast.http : HTTPRequest = Request, Status;

class Request {
	enum bufferLen = 4 << 10;
	char[bufferLen] buffer = void;
	HTTPRequest request;
	alias request this;

	protected Socket ipcSock;
	size_t stop;
	int requestId;

	@property auto params() => headers;

	@property auto socket() => ipcSock;

	@property void socket(Socket socket) {
		static id = 0;
		stop = 0;
		params.data.clear();
		ipcSock = socket;
		if (fillBuffer())
			requestId = id++;
	}

	protected bool fillBuffer() {
		while (!request.tryParse(buffer[0 .. stop])) {
			auto readn = ipcSock.receive(buffer[stop .. $]);
			if (readn <= 0) {
				if (ipcSock.isAlive)
					ipcSock.close();
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
	protected Socket ipcSock = void;

	void initialize(Socket socket, int reqId, bool keepConn) pure @nogc nothrow @safe {
		ipcSock = socket;
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
			ipcSock.send(head.data);
			head.clear();
			headerSent = true;
		}
		char[18] b = void;
		auto p = intToHex(b.ptr, s.length);
		*p = '\r';
		*(p + 1) = '\n';
		ipcSock.send(b[0 .. p - b.ptr + 2]);
		ipcSock.send(s);
		ipcSock.send("\r\n");
	}

	void finish() {
		flush();
		ipcSock.send("0\r\n\r\n");
		if (keepConnection)
			ipcSock.close();
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
	assert(intToHex(buf.ptr, 0) - buf.ptr == 1);
	assert(str[0 .. 1] == "0", str);
	assert(intToHex(buf.ptr, 0xff) - buf.ptr == 2);
	assert(str[0 .. 2] == "ff", str);
	assert(intToHex(buf.ptr, 0x12345678) - buf.ptr == 8, str);
	assert(str[0 .. 8] == "12345678", str);
	assert(intToHex(buf.ptr, size_t.max) - buf.ptr == 16, str);
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
		import std.experimental.logger;
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
			resp.initialize(sock, req.requestId, icompare(req.params.connection, "close") == 0);
			try
				handler(req, resp);
			catch (Exception e) {
				warningf("%s", e);
				resp.head.clear();
				resp.buf.clear();
				resp.writeHeader("HTTP/1.1 500 Internal Server Error");
				resp.writeHeader("Content-Type: text/html; charset=UTF-8");
				resp << e.toString;
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
