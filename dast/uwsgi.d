module dast.uwsgi;

// dfmt off
import core.thread,
	dast.map,
	std.array,
	std.socket;
// dfmt on

struct Header {
align(1):
	ubyte modifier1;
	ushort datasize;
	ubyte modifier2;
}

class Request {
	enum bufferLen = ushort.max + Header.sizeof;
	char[bufferLen] buffer = void;
	Map params;

	protected Socket ipcSock;
	size_t pos, stop;
	int requestId;

	@property auto socket() => ipcSock;

	@property void socket(Socket socket) {
		pos = 0;
		stop = 0;
		params.data.clear();
		ipcSock = socket;
		fillBuffer();
		parseParams();
	}

	protected bool fillBuffer() {
		while (pos >= stop) {
			auto readn = ipcSock.receive(buffer[pos .. $]);
			if (readn <= 0) {
				if (ipcSock.isAlive)
					ipcSock.close();
				return false;
			}
			stop += readn;
		}
		return true;
	}

	protected void parseParams() {
		static id = 0;
		requestId = id++;
		auto header = cast(Header*)(buffer.ptr + pos);
		pos += Header.sizeof;
		fillBuffer();
		if (header.modifier1 == 0 && header.modifier2 == 0) {
			auto p = buffer.ptr + pos;
			pos += header.datasize - 1;
			fillBuffer();
			for (const end = buffer.ptr + ++pos; p < end;) {
				auto size = *cast(ushort*)p;
				p += ushort.sizeof;
				auto name = p[0 .. size].idup;
				p += size;
				size = *cast(ushort*)p;
				p += ushort.sizeof;
				params[name] = p[0 .. size].idup;
				p += size;
			}
		}
	}

}

class Response {
	enum {
		bufferLen = 1024,
		maxHeaderLen = 1024
	}
	bool headerSent = void;

	protected import tame.buffer : Buffer = FixedBuffer;

	Buffer!maxHeaderLen head;
	Buffer!bufferLen buf;

	this() {
		head = typeof(head)(&throwErr!"Headers");
		buf = typeof(buf)(&send);
	}

	int requestId = void;
	protected Socket ipcSock = void;

	void initialize(Socket socket, int reqId) pure @nogc nothrow @safe {
		ipcSock = socket;
		requestId = reqId;
		headerSent = false;
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
			head ~= "\r\n";
			ipcSock.send(head.data);
			head.clear();
			headerSent = true;
		}
		ipcSock.send(s);
	}

	void finish() {
		flush();
		ipcSock.close();
	}

	protected void throwErr(string obj)(in char[]) {
		throw new Exception(obj ~ " too long");
	}
}

class Server {
	import std.concurrency;

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
			resp.initialize(sock, req.requestId);
			try
				handler(req, resp);
			catch (Exception e) {
				warningf("%s", e);
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
