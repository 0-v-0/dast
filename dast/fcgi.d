module dast.fcgi;

// dfmt off
import
	dast.map,
	std.array,
	std.socket,
	std.string;

size_t align8(size_t n) => (n + 7) & ~7;

size_t intToStr(char* buf, size_t value) {
	char* p = buf;
	for (;;) {
		*(p++) = (value % 10) ^ '0';
		if (value < 10)
			break;
		value /= 10;
	}
	for(char* i = buf, j = p - 1; i < j; i++, j--) {
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
	assert(str[0..1] == "0", str);
	assert(intToStr(buf.ptr, 255));
	assert(str[0..3] == "255", str);
	assert(intToStr(buf.ptr, 20170), str);
	assert(str[0..5] == "20170", str);
	assert(intToStr(buf.ptr, 4294967295), str);
	assert(str == "4294967295", str);
}

enum {
	FCGI_LISTENSOCK_FILENO = 0,
	FCGI_KEEP_CONN = 1,
	FCGI_MAX_LENGTH = 0xffff,
	FCGI_HEADER_LEN = 8,
	FCGI_VERSION_1 = 1,
	FCGI_NULL_REQUEST_ID = 0
}

enum Role {
	unknown,
	responder	= 1,
	authorizer	= 2,
	filter 		= 3
}

enum RequestType {
	begin     = 1,
	Abort     = 2,
	End       = 3,
	Params    = 4,
	Stdin     = 5,
	Stdout    = 6,
	Stderr    = 7,
	Data      = 8,
	GetValues = 9,
	GetValuesResult = 10,
	UnknownType     = 11
}

struct Header {
	ubyte
		ver,
		type,
		requestIdB1,
		requestIdB0,
		contentLengthB1,
		contentLengthB0,
		paddingLength,
		reserved;

	this(RequestType reqType, size_t contentLength, int requestId, ubyte paddingLen)
	in (contentLength <= FCGI_MAX_LENGTH) {
		ver = FCGI_VERSION_1;
		type             = cast(ubyte) reqType;
		requestIdB1      = (requestId >> 8) & 0xff;
		requestIdB0      = (requestId     ) & 0xff;
		contentLengthB1  = (contentLength >> 8) & 0xff;
		contentLengthB0  = (contentLength     ) & 0xff;
		paddingLength    = paddingLen;
		//reserved         = 0;
	}
}

struct BeginRequestBody {
	ubyte roleB1, roleB0,
		  flags;
	ubyte[5] reserved;
}

// dfmt on

struct EndRequestBody {
	int appStatus;
	ubyte protocolStatus;
	ubyte[3] reserved;
}

class Request {
	enum bufferLen = 4 << 10;
	char[bufferLen] buffer = void;
	size_t contentLength;
	Map params;

	protected Socket sock;
	// dfmt off
	ubyte	paddingLength;
	size_t	next,
			contentStop,
			stop;
	int requestId;
	protected bool* ipcSockClosed;
	// dfmt on

	@property socket() => sock;

	ubyte initialize(Socket socket, bool* sockClosed) {
		params.data.clear();
		sock = socket;
		ipcSockClosed = sockClosed;
		next = 0;
		stop = 0;
		contentStop = 0;
		fillBuffer();
		return processProtocol();
	}

	protected bool fillBuffer() {
		if (next == stop) {
			auto readn = sock.receive(buffer[next .. $]);
			if (readn == Socket.ERROR)
				return false;
			if (readn == 0) {
				sock.close();
				*ipcSockClosed = true;
				return false;
			}
			stop += readn;
		}
		return true;
	}

	protected ubyte processProtocol() {
		ubyte keepConnection;
		loop: for (;;) {
			// process Header
			if (next == contentStop)
				fillBuffer();
			auto header = cast(Header*)(buffer.ptr + next);
			next += Header.sizeof;

			requestId = (header.requestIdB1 << 8) | header.requestIdB0;
			contentLength = (header.contentLengthB1 << 8) | header.contentLengthB0;

			contentStop = next + contentLength;
			paddingLength = header.paddingLength;
			// process Body
			switch (header.type) {
			case RequestType.begin:
				auto rbody = cast(BeginRequestBody*)(buffer.ptr + next);
				next += BeginRequestBody.sizeof;
				keepConnection = rbody.flags & FCGI_KEEP_CONN;
				int role = rbody.roleB1 << 8 | rbody.roleB0;
				switch (role) {
				case Role.responder:
					params.FCGI_ROLE = "RESPONDER";
					break;
				case Role.authorizer:
					params.FCGI_ROLE = "AUTHORIZER";
					break;
				case Role.filter:
					params.FCGI_ROLE = "FILTER";
					break;
				default:
					params.FCGI_ROLE = "UNKNOWN";
				}
				break;
			case RequestType.Params:
				while (next < contentStop) {
					size_t nameLen = (buffer[next] & 0x80) ?
						((buffer[next++] & 0x7f) << 24)
						| buffer[next++] << 16
						| buffer[next++] << 8
						| buffer[next++] : buffer[next++],

						valLen = (buffer[next] & 0x80) ?
						((buffer[next++] & 0x7f) << 24)
						| buffer[next++] << 16
						| buffer[next++] << 8
						| buffer[next++] : buffer[next++];

					auto name = buffer[next .. next + nameLen].idup;
					next += nameLen;
					params[name] = buffer[next .. next + valLen].idup;
					next += valLen;
				}
				next += header.paddingLength;
				goto default;
			default:
				break loop;
			}
		}
		return keepConnection;
	}

	int read(void[] buf) {
		if (next >= contentStop) {
			fillBuffer;
			processProtocol;
		}
		int len = cast(int)(contentStop - next);
		if (buf.length < len)
			len = cast(int)buf.length;
		buf[0 .. len] = buffer[next .. len + next];
		next += len;
		return len;
	}
}

class Response {
	enum {
		bufferLen = 1024,
		maxHeaderLen = 1024
	}
	bool headerSent;

	protected {
		import tame.buffer : Buffer = FixedBuffer;

		bool* ipcSockClosed;
	}
	Buffer!maxHeaderLen head;
	Buffer!bufferLen buf;

	this() {
		head = typeof(head)(&throwErr!"Headers");
		buf = typeof(buf)(&send);
	}

	int requestId;
	ubyte keepConnection;
	protected Socket sock;

	void initialize(Socket socket, bool* sockClosed, int reqId) pure @nogc nothrow @safe {
		sock = socket;
		ipcSockClosed = sockClosed;
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
			putstr(head.data);
			head.clear();
			headerSent = true;
		}
		putstr(s);
	}

	void finish() {
		buf.flush();
		auto endHeader = Header(RequestType.End, EndRequestBody.sizeof, requestId, 0);
		EndRequestBody endBody;
		buf ~= endHeader;
		buf ~= endBody;
		sock.send(buf.data);
		if (!keepConnection) {
			sock.close();
			*ipcSockClosed = true;
		}
	}

	protected void throwErr(string obj)(in char[]) {
		throw new Exception(obj ~ " too long");
	}

	protected int putstr(in char[] str) {
		size_t contentLength = str.length,
		alignLength = align8(contentLength);
		auto header = Header(RequestType.Stdout, contentLength, requestId, cast(ubyte)(
				alignLength - contentLength));
		return cast(int)(sock.send(
				(cast(char*)&header)[0 .. Header.sizeof]) +
				sock.send(str.ptr[0 .. alignLength]));
	}
}

class FCGIServer {
	import core.thread;
	import std.concurrency;

	alias Handler = void delegate(Request req, Response resp);
	protected Handler handler;
	bool running;
	Socket listener;
	Socket sock;
	alias ipcSockClosed = running;
	protected Tid mainTid;
	Thread[] threads;

	bool accept() {
		if (ipcSockClosed)
			synchronized (listener) {
				try
					sock = listener.accept();
				catch (SocketAcceptException)
					return false;
				ipcSockClosed = false;
			}

		return true;
	}

	this(Handler handler) {
		this.handler = handler;
	}

	this(void function(Request req, Response resp) func) {
		import std.functional;

		handler = toDelegate(func);
	}

	void mainLoop() {
		import std.logger;

		scope req = new Request;
		scope resp = new Response;

		while (accept()) {
			resp.keepConnection = req.initialize(sock, &ipcSockClosed);
			resp.initialize(sock, &ipcSockClosed, req.requestId);
			try
				handler(req, resp);
			catch (Exception e) {
				warning(e);
				resp.writeHeader("Status: 500");
				resp << e.toString;
			}
			resp.finish();
		}
	}

	void start(ushort port = 9001, uint maxThread = 1) {
		if (threads.length)
			return;

		listener = new TcpSocket;
		listener.bind(new InternetAddress("127.0.0.1", port));
		listener.listen(128);
		running = true;
		mainTid = thisTid;
		if (!maxThread)
			return mainLoop();

		threads = uninitializedArray!(Thread[])(maxThread);
		foreach (ref thread; threads) {
			thread = new Thread(&mainLoop);
			thread.start();
		}
	}
}
