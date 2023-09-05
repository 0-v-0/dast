module dast.lshttp;

/*
	A lightweight & simple HTTP server for static files.
*/
import std.datetime;
import std.socket : Address, Socket, TcpSocket, SocketShutdown;
import dast.ws.request : Request;

alias ReqHandler = void[]function(in Request);

struct LSServer {
	import std.concurrency : Tid, send;

	auto addr() const => _addr;

	void shutdown() {
		if (sock) {
			sock.shutdown(SocketShutdown.RECEIVE);
			sock.close();
		}
	}

	this(ushort port, ReqHandler hd = null) {
		import std.concurrency : spawn;
		import std.socket : INADDR_LOOPBACK, InternetAddress, TcpSocket;

		auto sock = new TcpSocket;
		sock.bind(new InternetAddress(INADDR_LOOPBACK, port));
		sock.listen(128);
		auto addr = sock.localAddress;
		auto tid = spawn(&loop, cast(shared)sock, cast(shared)hd);
		this(addr, tid, sock);
	}

	this(Address addr, Tid id, TcpSocket ts) {
		_addr = addr;
		tid = id;
		sock = ts;
	}

private:
	Address _addr;
	Tid tid;
	TcpSocket sock;
}

private enum httpContinue = "HTTP/1.1 100 Continue\r\n\r\n";

private void loop(shared TcpSocket listener, shared ReqHandler handler = null) {
	import core.stdc.stdio;
	import std.algorithm : min, find, canFind;
	import std.string;
	import std.uni : toLower;

	try
		while (true) {
			Socket s = (cast()listener).accept;

			ubyte[1024] tmp = void;
			ubyte[] buf;

			auto nbytes = s.receive(tmp[]);
			if (nbytes <= 0) {
				if (s.isAlive)
					s.close();
				continue;
			}

			immutable beg = buf.length > 3 ? buf.length - 3 : 0;
			buf ~= tmp[0 .. nbytes];
			auto bdy = buf[beg .. $].find(cast(ubyte[])"\r\n\r\n");
			auto req = Request.parse(buf);
			if (req.done) {
				bdy = bdy[4 .. $];
				// no support for chunked transfer-encoding
				if (auto p = "content-length" in req.headers) {
					size_t m = void;
					sscanf((*p).toStringz, "%llu", &m);
					if (auto expect = "expect" in req.headers)
						if ((*expect).toLower == "100-continue")
							s.send(httpContinue);

					for (auto remain = m - bdy.length; remain; remain -= nbytes) {
						nbytes = s.receive(tmp[0 .. min(remain, $)]);
						assert(nbytes >= 0);
						bdy ~= tmp[0 .. nbytes];
					}
				}
				if (handler && s.isAlive) {
					req.message = cast(string)bdy;
					s.send(handler(req));
					//if (auto p = "connection" in req.headers)
					//if ((*p).toLower == "close")
					s.close();
				}
			}
		} catch (Exception e)
		fprintf(stderr, "%s\n", e.toString.toStringz);
}

string dateStr(SysTime st) {
	import datefmt;

	return st.toUTC.format("%a, %d %b %Y %H:%M:%S GMT");
}

__gshared string[string] mimeTypes;

uint readMimeTypes(string s) {
	import std.string;
	import std.uni;

	auto lines = s.split('\n');
	uint n;
	foreach (line; lines) {
		auto l = line.strip;
		if (!l.length || l[0] == '#')
			continue;
		auto arr = l.split!isWhite;
		if (arr.length >= 2) {
			string mime = arr[0];
			for (size_t i = 1; i < arr.length; i++)
				if (arr[i].length)
					mimeTypes[arr[i]] = mime;
			n++;
		}
	}
	return n;
}

shared basepath = ".";

void[] handle(in Request req) {
	import std.array,
	std.base64,
	std.conv,
	std.file,
	std.path,
	std.string;

	ubyte[] buf;
	auto a = appender!string;
	a ~= "HTTP/1.1 ";
	string status = "200 OK", mimeType;
	SysTime modified;
	if (req.method != "GET")
		status = "405 Method Not Allowed";
	else {
		string path = req.path;
		auto i = path.indexOf('?');
		if (i > 0)
			path = path[0 .. i];
		path = basepath ~ (path == "/" ? "/index.html" : path);
		if (!path.exists)
			status = "404 Not Found";
		else
			try {
				if (path.isDir)
					status = "403 Forbidden";
				buf = cast(ubyte[])read(path);
				mimeType = path.extension;
				if (mimeType.length > 1 && mimeType[0] == '.')
					mimeType = mimeTypes.get(mimeType[1 .. $], "");
				if (mimeType.length == 0)
					mimeType = "application/octet-stream";
				modified = path.timeLastModified;
			} catch (Exception e) {
				status = "500 Internal Server Error";
				buf = cast(ubyte[])e.toString;
				mimeType = "text/plain";
			}
	}
	a ~= status;
	if (auto p = "connection" in req.headers) {
		a ~= "\r\nConnection: close";
	}
	a ~= "\r\nContent-Type: ";
	a ~= mimeType;
	a ~= "\r\nContent-Length: ";
	a ~= buf.length.to!string;
	a ~= "\r\nDate: ";
	a ~= Clock.currTime.dateStr;
	if (modified.stdTime) {
		union _Conv {
			long n;
			ubyte[8] b;
		}

		a ~= "\r\nLast-Modified: ";
		a ~= modified.dateStr;
		_Conv hash = {modified.stdTime};
		a ~= "\r\nETag: \"";
		a ~= Base64URLNoPadding.encode(hash.b[]);
		a ~= `"`;
	}
	if (mimeType == "text/html") {
		a ~= "\r\nCross-Origin-Embedder-Policy: require-corp" ~
			"\r\nCross-Origin-Opener-Policy: same-origin";
	}
	a ~= "\r\nServer: lshttp\r\n\r\n";

	return cast(ubyte[])a[] ~ buf;
}
