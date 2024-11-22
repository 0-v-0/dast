module dast.async.tcplistener;

import dast.async.core,
dast.async.eventloop,
dast.async.selector,
dast.async.tcpstream,
tame.meta;

version (Windows) import dast.async.iocp;

alias AcceptHandler = void delegate(Socket socket) @safe;

/** TCP Server */
@safe class TcpListener : SocketChannel {
	mixin Forward!"_socket";

	AcceptHandler onAccept;
	SimpleHandler onClosed;

	this(EventLoop loop, AddressFamily family = AddressFamily.INET) {
		super(loop, WT.Accept);
		flags |= WF.Read;
		socket = tcpSocket(family);
	}

	override void close() {
		super.close();
		if (onClosed)
			onClosed();
	}

	void start() {
		_loop.register(this);
		_isRegistered = true;
		version (Windows)
			accept();
	}

	override void onRead() {
		debug (Log)
			trace("start listening");
		if (!tryAccept((Socket socket) {
				debug (Log)
					info("new connection from ", socket.remoteAddress, ", fd=", socket.handle);

				if (onAccept)
					onAccept(socket);
				else
					new TcpStream(_loop, socket).start();
			})) {
			close();
		}
	}

private:
	bool tryAccept(scope AcceptHandler handler) {
		version (Posix) {
			import core.sys.posix.sys.socket : accept;

			const clientFd = accept(handle, null, null);
			if (clientFd < 0)
				return false;

			debug (Log)
				trace("listener fd=", handle, ", client fd=", clientFd);

			handler(Socket(clientFd, _socket.addressFamily));
			return true;
		}

		version (Windows) {
			import core.sys.windows.mswsock;

			debug (Log)
				trace("listener fd=", handle, ", client fd=", _clientSock.handle);
			socket_t[1] fd = [handle];
			_clientSock.setOption(SocketOptionLevel.SOCKET,
				cast(SocketOption)SO_UPDATE_ACCEPT_CONTENT, fd);
			handler(_clientSock);

			debug (Log)
				trace("accept next connection...");
			return _isRegistered && accept();
		}
	}

	version (Windows)  : bool accept() @trusted {
		_clientSock = tcpSocket(_socket.addressFamily);
		//_clientSock = new Socket(WSASocket(_socket.addressFamily, SocketType.STREAM,
		//ProtocolType.TCP, null, 0, WSA_FLAG_OVERLAPPED), _socket.addressFamily);
		uint dwBytesReceived = void;

		debug (Log)
			trace("client socket=", _clientSock.handle, ", server socket=", handle);
		return !checkErr(AcceptEx(handle, _clientSock.handle, _buf.ptr, 0, size, size,
				&dwBytesReceived, &_ctx.overlapped), "listener");
	}

	mixin checkErr;
	enum size = sockaddr_in.sizeof + 16;
	Socket _clientSock;
	IocpContext _ctx = {operation: IocpOperation.accept};
	ubyte[size * 4] _buf;
}

@property @safe:
bool reusePort(Socket socket) {
	int result = void;
	socket.getOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, result);
	return result != 0;
}

bool reusePort(Socket socket, bool enabled) {
	socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, enabled);

	version (Posix) {
		import core.sys.posix.sys.socket;

		socket.setOption(SocketOptionLevel.SOCKET, cast(SocketOption)SO_REUSEPORT, enabled);
	}

	version (Windows) {
		if (!enabled) {
			import core.sys.windows.winsock2;

			socket.setOption(SocketOptionLevel.SOCKET, cast(SocketOption)SO_EXCLUSIVEADDRUSE, true);
		}
	}

	return enabled;
}
