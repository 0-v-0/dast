module dast.async.socket.iocp;

version (Windows)  : import core.sys.windows.windows,
core.sys.windows.mswsock,
dast.async.core,
std.exception,
std.socket,
std.conv : text;

/** TCP Server */
@safe abstract class ListenerBase : SocketChannelBase {
	this(Selector loop, AddressFamily family = AddressFamily.INET, uint bufferSize = 4 * 1024) {
		import std.array;

		super(loop, WT.Accept);
		flags |= WF.Read;
		_buf = uninitializedArray!(ubyte[])(bufferSize);
		socket = new TcpSocket(family);
	}

	mixin checkErro;

	override void onClose() {
		// TODO
	}

protected:
	void doAccept() @trusted {
		_iocp.watcher = this;
		_iocp.operation = IocpOperation.accept;
		_clientSock = new TcpSocket(socket.addressFamily);
		uint dwBytesReceived = void;

		debug (Log)
			trace("client socket: accept=", _clientSock.handle, ", server socket=", handle);
		enum size = sockaddr_in.sizeof + 16;
		checkErro(AcceptEx(handle, _clientSock.handle, _buf.ptr, 0, size, size,
				&dwBytesReceived, &_iocp.overlapped));
	}

	bool onAccept(scope AcceptHandler handler) @trusted {
		_error = [];
		debug (Log)
			trace("handle=", handle, ", slink=", _clientSock.handle);
		_clientSock.setOption(SocketOptionLevel.SOCKET,
			cast(SocketOption)SO_UPDATE_ACCEPT_CONTENT, (&handle)[0 .. 1]);
		if (handler)
			handler(_clientSock);

		debug (Log)
			trace("accept next connection...");
		if (isRegistered)
			doAccept();
		return true;
	}

private:
	IocpContext _iocp;
	ubyte[] _buf;
	Socket _clientSock;
}

/** TCP Client */
@safe abstract class StreamBase : SocketChannelBase {
	RecvHandler onReceived;

	protected this() {
	}

	this(Selector loop, uint bufferSize = 4 * 1024) {
		import std.array;

		super(loop, WT.TCP);
		flags |= WF.Read | WF.Write;

		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_readBuf = uninitializedArray!(ubyte[])(bufferSize);
	}

	mixin checkErro;

	/**
	 * Called by selector after data sent
	*/
	void onWriteDone(uint len) {
		if (isWriteCancelling) {
			_isWriting = false;
			isWriteCancelling = false;
			_writeQueue.clear(); // clean the data buffer
			return;
		}

		if (writeBuf.popSize(len)) {
			writeBuf = [];
			_isWriting = false;

			debug (Log)
				trace("done with data writing ", len, " bytes");

			if (_writeQueue.empty)
				warning("_writeQueue is empty");
			else
				tryWrite();
		} else if (sendDataBuf.length > len) {
			debug (Log)
				trace("remaining nbytes: ", sendDataBuf.length - len);
			// FIXME: Needing refactor or cleanup
			// sendDataBuf corrupted
			// tracef("%(%02X %)", sendDataBuf);
			// send remaining
			len = write(sendDataBuf[len .. $]);
		}
	}

	SimpleHandler disconnectedHandler;

protected:
	final void beginRead() @trusted {
		_iocpRead.operation = IocpOperation.read;
		_iocpRead.watcher = this;
		uint dwReceived = void, dwFlags;

		debug (Log)
			trace("start receiving handle=", socket.handle);

		checkErro(WSARecv(socket.handle, cast(WSABUF*)&_readBuf, 1, &dwReceived, &dwFlags,
				&_iocpRead.overlapped, null), SOCKET_ERROR);
	}

	void doConnect(Address addr) @trusted {
		_iocpWrite.operation = IocpOperation.connect;
		_iocpWrite.watcher = this;
		checkErro(ConnectEx(socket.handle, addr.name(), addr.nameLen(), null, 0, null,
				&_iocpWrite.overlapped), ERROR_IO_PENDING);
	}

	// TODO
	/// Send a big block of data
	final size_t tryWrite(in void[] data) {
		if (_isWriting) {
			warning("Busy in writing on thread: ");
			return 0;
		}
		_isWriting = true;

		_error = [];
		return write(data);
	}

	final void tryWrite() {
		if (_isWriting) {
			debug (Log)
				warning("Busy in writing on thread: ");
			return;
		}

		assert(!_writeQueue.empty);
		_isWriting = true;
		_error = [];

		writeBuf = _writeQueue.front;
		const data = writeBuf;
		const len = write(data);
		if (len < data.length) { // to fix the corrupted data
			debug (Log)
				warning("remaining data: ", data.length - len);
			sendDataBuf = data[len .. $].dup;
		}
	}

	void onDisconnected() {
		_isRegistered = false;
		if (disconnectedHandler)
			disconnectedHandler();
	}

	WriteBufferQueue _writeQueue;
	bool isWriteCancelling;

	const(ubyte)[] _readBuf;
private:
	bool _isWriting;
	IocpContext _iocpRead, _iocpWrite;
	const(void)[] writeBuf, sendDataBuf;

	uint write(in void[] data) @trusted {
		sendDataBuf = data;
		uint dwSent = void;
		_iocpWrite.operation = IocpOperation.write;
		_iocpWrite.watcher = this;
		WSASend(socket.handle, cast(WSABUF*)&sendDataBuf, 1, &dwSent, 0, &_iocpWrite.overlapped, null);

		// FIXME: Needing refactor or cleanup
		// The buffer may be full, so what can do here?
		// checkErro(ret, SOCKET_ERROR); // bug:

		if (isError) {
			error("Socket error on write: fd=", handle, ", message=", _error);
			close();
		}

		return dwSent;
	}
}

void checkErro()(int ret, int erro = 0) {
	import core.sys.windows.winerror;

	const err = WSAGetLastError();
	if (ret != 0 || err == 0)
		return;

	debug (Log)
		tracef("erro=%d, dwLastError=%d", erro, err);

	if (err != WSAEWOULDBLOCK && err != ERROR_IO_PENDING)
		_error = text("WSA error: code=", err);
}

enum IocpOperation {
	accept,
	connect,
	read,
	write,
	event,
	close
}

struct IocpContext {
	OVERLAPPED overlapped;
	IocpOperation operation;
	Channel watcher;
}

alias WSAOVERLAPPED = OVERLAPPED;
alias LPWSAOVERLAPPED = OVERLAPPED*;

immutable {
	LPFN_ACCEPTEX AcceptEx;
	LPFN_CONNECTEX ConnectEx;
	/*
	LPFN_DISCONNECTEX DisconnectEx;
	LPFN_GETACCEPTEXSOCKADDRS GetAcceptexSockAddrs;
	LPFN_TRANSMITFILE TransmitFile;
	LPFN_TRANSMITPACKETS TransmitPackets;
	LPFN_WSARECVMSG WSARecvMsg;
	LPFN_WSASENDMSG WSASendMsg;*/
}

shared static this() {
	auto sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	scope (exit)
		closesocket(sock);
	sock.getFuncPointer!AcceptEx(WSAID_ACCEPTEX);
	sock.getFuncPointer!ConnectEx(WSAID_CONNECTEX);
	/* sock.getFuncPointer!DisconnectEx(WSAID_DISCONNECTEX);
	sock.getFuncPointer!GetAcceptexSockAddrs(WSAID_GETACCEPTEXSOCKADDRS);
	sock.getFuncPointer!TransmitFile(WSAID_TRANSMITFILE);
	sock.getFuncPointer!TransmitPackets(WSAID_TRANSMITPACKETS);
	sock.getFuncPointer!WSARecvMsg(WSAID_WSARECVMSG); */
}

private void getFuncPointer(alias pfn)(SOCKET sock, GUID guid) {
	DWORD bytesReturned;
	if (WSAIoctl(sock, SIO_GET_EXTENSION_FUNCTION_POINTER, &guid, guid.sizeof,
			cast(void*)&pfn, pfn.sizeof, &bytesReturned, null, null) == SOCKET_ERROR)
		throw new ErrnoException("Get function failed", WSAGetLastError());
}

enum : DWORD {
	IOCPARAM_MASK = 0x7f,
	IOC_VOID = 0x20000000,
	IOC_OUT = 0x40000000,
	IOC_IN = 0x80000000,
	IOC_INOUT = IOC_IN | IOC_OUT
}

enum {
	IOC_UNIX = 0x00000000,
	IOC_WS2 = 0x08000000,
	IOC_PROTOCOL = 0x10000000,
	IOC_VENDOR = 0x18000000
}

enum _WSAIORW(int x, int y) = IOC_INOUT | x | y;

enum SIO_GET_EXTENSION_FUNCTION_POINTER = _WSAIORW!(IOC_WS2, 6);

extern (Windows) nothrow @nogc:

int WSARecv(SOCKET, LPWSABUF, DWORD, LPDWORD, LPDWORD, LPWSAOVERLAPPED,
	LPWSAOVERLAPPED_COMPLETION_ROUTINE);
int WSARecvDisconnect(SOCKET, LPWSABUF);
int WSARecvFrom(SOCKET, LPWSABUF, DWORD, LPDWORD, LPDWORD, SOCKADDR*, LPINT,
	LPWSAOVERLAPPED, LPWSAOVERLAPPED_COMPLETION_ROUTINE);

int WSASend(SOCKET, LPWSABUF, DWORD, LPDWORD, DWORD, LPWSAOVERLAPPED,
	LPWSAOVERLAPPED_COMPLETION_ROUTINE);
int WSASendDisconnect(SOCKET, LPWSABUF);
int WSASendTo(SOCKET, LPWSABUF, DWORD, LPDWORD, DWORD, const(SOCKADDR)*, int,
	LPWSAOVERLAPPED, LPWSAOVERLAPPED_COMPLETION_ROUTINE);

int GetQueuedCompletionStatusEx(HANDLE, LPOVERLAPPED_ENTRY, ULONG, PULONG,
	DWORD, BOOL);

alias LPOVERLAPPED_ENTRY = OVERLAPPED_ENTRY*;

struct OVERLAPPED_ENTRY {
	ULONG_PTR lpCompletionKey;
	LPOVERLAPPED lpOverlapped;
	ULONG_PTR Internal;
	DWORD dwNumberOfBytesTransferred;
}
