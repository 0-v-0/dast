module dast.uwsgi;

import core.thread,
dast.map,
std.array,
std.socket;

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

	protected Socket sock;
	size_t pos, stop;
	int requestId;

	@property socket() => sock;

	@property void socket(Socket socket) {
		pos = 0;
		stop = 0;
		params.data.clear();
		sock = socket;
		fillBuffer();
		parseParams();
	}

	protected bool fillBuffer() {
		while (pos >= stop) {
			auto readn = sock.receive(buffer[pos .. $]);
			if (readn <= 0) {
				if (sock.isAlive)
					sock.close();
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
	protected Socket sock = void;

	pure @nogc nothrow @safe {
		void initialize(Socket socket, int reqId) {
			sock = socket;
			requestId = reqId;
			headerSent = false;
			head.clear();
			buf.clear();
		}

		void writeHeader(in char[] header) {
			head ~= header;
			head ~= "\r\n";
		}

		void write(in char[] data) {
			buf ~= data;
		}
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
			sock.send(head.data);
			head.clear();
			headerSent = true;
		}
		sock.send(s);
	}

	void finish() {
		flush();
		sock.close();
	}

	protected void throwErr(string obj)(in char[]) {
		throw new Exception(obj ~ " too long");
	}
}

class Server {
	import std.concurrency;

	alias Handler = void delegate(Request req, Response resp);
	protected Handler handler;
	void delegate(Exception e) onError;
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
				if (onError)
					onError(e);
				resp.writeHeader("HTTP/1.1 500 Internal Server Error");
				resp.writeHeader("Content-Type: text/html; charset=UTF-8");
				resp.write(e.toString());
			}
			resp.finish();
		}
	}

	void start(ushort port = 3031, uint maxThread = 1) {
		listener = new TcpSocket;
		listener.bind(new InternetAddress(INADDR_LOOPBACK, port));
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
