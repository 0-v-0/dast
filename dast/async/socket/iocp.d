module dast.async.socket.iocp;

version (Windows)  : import core.sys.windows.windows,
core.sys.windows.winsock2,
core.sys.windows.mswsock,
dast.async.core,
std.exception,
std.socket,
std.conv : text;

/** TCP Server */
abstract class ListenerBase : SocketChannelBase {
	this(Selector loop, AddressFamily family = AddressFamily.INET, size_t bufferSize = 4 * 1024) {
		import std.array;

		super(loop, WatcherType.Accept);
		setFlag(WF.Read);
		_buffer = uninitializedArray!(ubyte[])(bufferSize);
		socket = new TcpSocket(family);
	}

	mixin CheckIocpError;

	protected void doAccept() {
		_iocp.watcher = this;
		_iocp.operation = IocpOperation.accept;
		_clientSocket = new Socket(socket.addressFamily, SocketType.STREAM, ProtocolType.TCP);
		DWORD dwBytesReceived;

		debug (Log)
			trace("client socket: accept=", _clientSocket.handle, ", server socket=", handle);
		int nRet = AcceptEx(handle, _clientSocket.handle,
			_buffer.ptr, 0, sockaddr_in.sizeof + 16, sockaddr_in.sizeof + 16,
			&dwBytesReceived, &_iocp.overlapped);

		debug (Log)
			trace("do AcceptEx: the return is: ", nRet);
		checkErro(nRet);
	}

	protected bool onAccept(scope AcceptHandler handler) {
		_error = [];
		debug (Log)
			trace("handle=", handle, ", slink=", _clientSocket.handle);
		setsockopt(_clientSocket.handle, SocketOptionLevel.SOCKET, 0x700B, &handle, handle.sizeof);
		if (handler)
			handler(_clientSocket);

		debug (Log)
			trace("accept next connection...");
		if (isRegistered)
			doAccept();
		return true;
	}

	override void onClose() {
		// TODO
	}

private:
	IocpContext _iocp;
	WSABUF _dataWriteBuffer;
	ubyte[] _buffer;
	Socket _clientSocket;
}

/** TCP Client */
abstract class StreamBase : SocketChannelBase {
	DataReceivedHandler onReceived;

	protected this() {
	}

	this(Selector loop, AddressFamily family = AddressFamily.INET, size_t bufferSize = 4096 * 2) {
		import std.array;

		super(loop, WatcherType.TCP);
		setFlag(WF.Read);
		setFlag(WF.Write);

		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_readBuffer = uninitializedArray!(ubyte[])(bufferSize);
		socket = new TcpSocket(family);
	}

	mixin CheckIocpError;

	override void onRead() {
		debug (Log)
			trace("ready to read");
		_inRead = false;
		super.onRead();
	}

	override void onWrite() {
		_inWrite = false;
		super.onWrite();
	}

	protected void beginRead() {
		_inRead = true;
		_dataReadBuffer.len = cast(uint)_readBuffer.length;
		_dataReadBuffer.buf = cast(char*)_readBuffer.ptr;
		_iocpread.watcher = this;
		_iocpread.operation = IocpOperation.read;
		DWORD dwReceived = void;
		DWORD dwFlags = void;

		debug (Log)
			trace("start receiving handle=", socket.handle);

		int nRet = WSARecv(socket.handle, &_dataReadBuffer, 1u, &dwReceived, &dwFlags,
			&_iocpread.overlapped, cast(LPWSAOVERLAPPED_COMPLETION_ROUTINE)null);

		checkErro(nRet, SOCKET_ERROR);
	}

	protected void doConnect(Address addr) {
		_iocpwrite.watcher = this;
		_iocpwrite.operation = IocpOperation.connect;
		int nRet = ConnectEx(socket.handle,
			cast(SOCKADDR*)addr.name(), addr.nameLen(), null, 0, null,
			&_iocpwrite.overlapped);
		checkErro(nRet, ERROR_IO_PENDING);
	}

	private uint doWrite() {
		_inWrite = true;
		DWORD dwSent = void;
		_iocpwrite.watcher = this;
		_iocpwrite.operation = IocpOperation.write;
		debug (Log) {
			const bufferLength = sendDataBuffer.length;
			trace("writing...handle=", socket.handle);
			trace("buffer content length: ", bufferLength);
			if (bufferLength > 64)
				tracef("%(%02X %) ...", sendDataBuffer[0 .. 64]);
			else
				tracef("%(%02X %)", sendDataBuffer[0 .. $]);
		}

		WSASend(socket.handle, &_dataWriteBuffer, 1, &dwSent,
			0, &_iocpwrite.overlapped, cast(LPWSAOVERLAPPED_COMPLETION_ROUTINE)null);

		debug (Log) {
			if (dwSent != _dataWriteBuffer.len)
				warning("dwSent=", dwSent, ", BufferLength=", _dataWriteBuffer.len);
		}
		// FIXME: Needing refactor or cleanup
		// The buffer may be full, so what can do here?
		// checkErro(nRet, SOCKET_ERROR); // bug:

		if (isError) {
			error("Socket error on write: fd=", handle, ", message=", erroString);
			close();
		}

		return dwSent;
	}

	protected void doRead() {
		_error = [];
		debug (Log)
			trace("data reading ", readLen, " bytes");

		if (readLen > 0) {
			// import std.stdio;
			// writefln("length=%d, data: %(%02X %)", readLen, _readBuffer[0 .. readLen]);

			if (onReceived)
				onReceived(_readBuffer[0 .. readLen]);
			debug (Log)
				trace("done with data reading ", readLen, " bytes");

			// continue reading
			beginRead();
		} else if (readLen == 0) {
			debug (Log)
				warning("connection broken: ", _socket.remoteAddress);
			onDisconnected();
			// if (_closed)
			//     close();
		} else {
			debug (Log) {
				warning("undefined behavior on thread ", getTid());
			} else {
				_error = "undefined behavior on thread";
			}
		}
	}

	// TODO
	/// Send a big block of data
	protected size_t tryWrite(in ubyte[] data) {
		if (_isWriting) {
			warning("Busy in writing on thread: ");
			return 0;
		}
		debug (Log)
			trace("start writing");
		_isWriting = true;

		_error = [];
		setWriteBuffer(data);
		return doWrite();
	}

	protected void tryWrite() {
		if (_isWriting) {
			debug (Log)
				warning("Busy in writing on thread: ");
			return;
		}

		if (_writeQueue.empty)
			return;

		debug (Log)
			trace("start writing");
		_isWriting = true;
		_error = [];

		writeBuffer = _writeQueue.front;
		auto data = writeBuffer.data;
		setWriteBuffer(data);
		const len = doWrite();

		if (len < data.length) { // to fix the corrupted data
			debug (Log)
				warning("remaining data: ", data.length - len);
			sendDataBuffer = data.dup;
		}
	}

	private void setWriteBuffer(in ubyte[] data) {
		debug (Log)
			trace("buffer content length: ", data.length);
		// trace(cast(string)data);
		// tracef("%(%02X %)", data);

		sendDataBuffer = data; //data[writeLen .. $]; // TODO: need more tests
		_dataWriteBuffer.len = cast(uint)sendDataBuffer.length;
		_dataWriteBuffer.buf = cast(char*)sendDataBuffer.ptr;
	}

	/**
	 * Called by selector after data sent
	 * Note: It's only for IOCP selector:
	*/
	void onWriteDone(size_t len) {
		debug (Log)
			trace("finishing data writing ", len, " bytes");
		if (isWriteCancelling) {
			_isWriting = false;
			isWriteCancelling = false;
			_writeQueue.clear(); // clean the data buffer
			return;
		}

		if (writeBuffer.popSize(len)) {
			if (!_writeQueue.dequeue())
				warning("_writeQueue is empty!");

			writeBuffer.doFinish();
			_isWriting = false;

			debug (Log)
				trace("done with data writing ", len, " bytes");

			tryWrite();
		} else // if (sendDataBuffer.length > len)
		{
			// debug(Log)
			trace("remaining nbytes: ", sendDataBuffer.length - len);
			// FIXME: Needing refactor or cleanup
			// sendDataBuffer corrupted
			// const(ubyte)[] data = writeBuffer.data;
			// tracef("%(%02X %)", data);
			// tracef("%(%02X %)", sendDataBuffer);
			setWriteBuffer(sendDataBuffer[len .. $]); // send remaining
			len = doWrite();
		}
	}

	bool _isConnected; // if server side always true
	SimpleEventHandler disconnectionHandler;

protected:
	void onDisconnected() {
		_isConnected = false;
		_closed = true;
		if (disconnectionHandler)
			disconnectionHandler();
	}

	WriteBufferQueue _writeQueue;
	bool isWriteCancelling;

private:
	bool _isWriting;
	const(ubyte)[] _readBuffer, sendDataBuffer;
	StreamWriteBuffer* writeBuffer;
	IocpContext _iocpread, _iocpwrite;
	WSABUF _dataReadBuffer, _dataWriteBuffer;
	bool _inWrite, _inRead;
}

mixin template CheckIocpError() {
	void checkErro(int ret, int erro = 0) {
		auto err = GetLastError();
		if (ret != 0 || err == 0)
			return;

		debug (Log)
			tracef("erro=%d, dwLastError=%d", erro, err);

		if (err != ERROR_IO_PENDING)
			_error = text("AcceptEx failed with error: code=", err);
	}
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

__gshared {
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
			&pfn, pfn.sizeof, &bytesReturned, null, null) == SOCKET_ERROR)
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
