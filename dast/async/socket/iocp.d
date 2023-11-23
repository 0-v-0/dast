module dast.async.socket.iocp;

version (Windows)  : import core.sys.windows.windows,
core.sys.windows.mswsock,
dast.async.core,
std.exception;

/** TCP Server */
@safe abstract class ListenerBase : SocketChannel {
	this(Selector loop, AddressFamily family = AddressFamily.INET) {
		super(loop, WT.Accept);
		flags |= WF.Read;
		socket = new TcpSocket(family);
	}

	mixin checkErro;

protected:
	bool doAccept() @trusted {
		_ctx.operation = IocpOperation.accept;
		_clientSock = new TcpSocket(_socket.addressFamily);
		//_clientSock = new Socket(WSASocket(_socket.addressFamily, SocketType.STREAM,
		//ProtocolType.TCP, null, 0, WSA_FLAG_OVERLAPPED), _socket.addressFamily);
		uint dwBytesReceived = void;

		debug (Log)
			trace("client socket: accept=", _clientSock.handle, ", server socket=", handle);
		return !checkErro(AcceptEx(handle, _clientSock.handle, _buf.ptr, 0, size, size,
				&dwBytesReceived, &_ctx.overlapped), "listener ");
	}

	bool onAccept(scope AcceptHandler handler) {
		debug (Log)
			trace("handle=", handle, ", slink=", _clientSock.handle);
		socket_t[1] fd = [handle];
		_clientSock.setOption(SocketOptionLevel.SOCKET,
			cast(SocketOption)SO_UPDATE_ACCEPT_CONTENT, fd);
		if (handler)
			handler(_clientSock);

		debug (Log)
			trace("accept next connection...");
		return _isRegistered && doAccept();
	}

private:
	enum size = sockaddr_in.sizeof + 16;
	IocpContext _ctx;
	ubyte[size * 4] _buf;
	Socket _clientSock;
}

/** TCP Client */
@safe abstract class StreamBase : SocketChannel {
	/**
	* Warning: The received data is stored a inner buffer. For a data safe,
	* you would make a copy of it.
	*/
	RecvHandler onReceived;
	SimpleHandler onDisconnected;

	this(Selector loop, uint bufferSize = 4 * 1024) {
		super(loop, WT.TCP);
		flags |= WF.Read | WF.Write;

		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_rBuf = BUF(bufferSize);
	}

	mixin checkErro;

	/**
	 * Called by selector after data sent
	*/
	final onWrite(uint len) {
		if (isWriteCancelling) {
			isWriteCancelling = false;
			_isWriting = false;
			_writeQueue.clear();
			return;
		}
		site += len;
		if (site >= _writeQueue.front.length) {
			_writeQueue.pop1();
			site = 0;
			_isWriting = false;
			debug (Log)
				info("written ", len, " bytes");

			if (!_writeQueue.empty)
				tryWrite();
		} else // if (sendDataBuf.length > len)
		{
			debug (Log)
				trace("remaining ", _wBuf.length - len, " bytes");
			// FIXME: sendDataBuf corrupted
			// tracef("%(%02X %)", sendDataBuf);
			// send remaining
			tryWrite();
		}
	}

	void onRead(uint len) {
		debug (Log)
			trace("data reading ", len, " bytes");

		if (len) {
			if (onReceived)
				onReceived(_rBuf[0 .. len]);
			debug (Log)
				trace("read ", len, " bytes");

			recv(); // continue reading
		} else {
			debug (Log)
				warning("connection broken: ", _socket.remoteAddress);
			_isRegistered = false;
			if (onDisconnected)
				onDisconnected();
			//	close();
		}
	}

	bool isWriteCancelling;

protected:
	final void recv() @trusted {
		_iocpRead.operation = IocpOperation.read;
		uint dwReceived = void, dwFlags;

		debug (Log)
			trace("start receiving handle=", handle);

		checkErro(WSARecv(handle, cast(WSABUF*)&_rBuf, 1, &dwReceived, &dwFlags,
				&_iocpRead.overlapped, null), "recv ");
	}

	void doConnect(Address addr) @trusted {
		_iocpWrite.operation = IocpOperation.connect;
		checkErro(ConnectEx(handle, addr.name(), addr.nameLen(), null, 0, null,
				&_iocpWrite.overlapped), "connect ");
	}

	final tryWrite() nothrow
	in (!_writeQueue.empty) {
		if (_isWriting) {
			debug (Log)
				warning("Busy in writing on thread: ");
			return 0;
		}
		_isWriting = true;
		const data = _writeQueue.front.data[site .. $];
		const len = write(data);
		if (len < data.length) { // to fix the corrupted data
			debug (Log)
				warning("remaining ", data.length - len, " bytes");
			_wBuf = data;
		}
		return len;
	}

	WriteBufferQueue _writeQueue;
private:
	IocpContext _iocpRead, _iocpWrite;
	const(ubyte)[] _rBuf;
	const(void)[] _wBuf;
	uint site;
	bool _isWriting;

	uint write(in void[] data) @trusted nothrow
	in (data.length) {
		_wBuf = data;
		uint dwSent = void;
		_iocpWrite.operation = IocpOperation.write;

		if (checkErro(WSASend(handle, cast(WSABUF*)&_wBuf, 1, &dwSent, 0,
				&_iocpWrite.overlapped, null), "write ")) {
			close();
		}

		return dwSent;
	}
}

private bool checkErro()(int ret, string prefix = null) nothrow {
	import core.sys.windows.winerror;

	const err = WSAGetLastError();
	if (ret != 0 || err == 0)
		return false;

	debug (Log)
		tracef("fd=", handle, ", dwLastError=", err);

	if (err != WSAEWOULDBLOCK && err != ERROR_IO_PENDING) {
		errorOccurred(text(prefix, " error: code=", err));
		return true;
	}
	return false;
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
}

alias LPWSAOVERLAPPED = OVERLAPPED*,
GROUP = uint;
private alias LPWSAPROTOCOL_INFO = void*;

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
enum WSA_FLAG_OVERLAPPED = 1;

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

SOCKET WSASocketW(int af, int type, int protocol, LPWSAPROTOCOL_INFO lpProtocolInfo, GROUP g, DWORD dwFlags);

alias WSASocket = WSASocketW;
alias LPOVERLAPPED_ENTRY = OVERLAPPED_ENTRY*;

struct OVERLAPPED_ENTRY {
	ULONG_PTR lpCompletionKey;
	LPOVERLAPPED lpOverlapped;
	ULONG_PTR Internal;
	DWORD dwNumberOfBytesTransferred;
}
