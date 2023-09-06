module dast.async.socket.iocp;

// dfmt off
version (Windows):
import core.sys.windows.windows,
	core.sys.windows.winsock2,
	core.sys.windows.mswsock,
	dast.async.core,
	std.format,
	std.conv,
	std.socket,
	std.exception,
	std.process;
// dfmt on

/** TCP Server */
abstract class ListenerBase : SocketChannelBase {
	this(Selector loop, AddressFamily family = AddressFamily.INET, size_t bufferSize = 4 * 1024) {
		import std.array;

		super(loop, WatcherType.Accept);
		setFlag(WatchFlag.Read, true);
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
			tracef("client socket:accept=%s  inner socket=%s", handle, _clientSocket.handle);
		debug (Log)
			trace("AcceptEx is: ", AcceptEx);
		int nRet = AcceptEx(handle, cast(SOCKET)_clientSocket.handle,
			_buffer.ptr, 0, sockaddr_in.sizeof + 16, sockaddr_in.sizeof + 16,
			&dwBytesReceived, &_iocp.overlapped);

		debug (Log)
			trace("do AcceptEx: the return is: ", nRet);
		checkErro(nRet);
	}

	protected bool onAccept(scope AcceptHandler handler) {
		debug (Log)
			trace("new connection coming...");
		clearError();
		auto slisten = cast(SOCKET)handle;
		auto slink = cast(SOCKET)_clientSocket.handle;
		// void[] value = (&slisten)[0..1];
		// setsockopt(slink, SocketOptionLevel.SOCKET, 0x700B, value.ptr,
		//                    cast(uint) value.length);
		debug (Log)
			tracef("slisten=%s, slink=%s", slisten, slink);
		setsockopt(slink, SocketOptionLevel.SOCKET, 0x700B, cast(void*)&slisten, slisten.sizeof);
		if (handler)
			handler(_clientSocket);

		debug (Log)
			trace("accept next connection...");
		if (isRegistered)
			doAccept();
		return true;
	}

	override void onClose() {
		// TODO: created by Administrator @ 2018-3-27 15:51:52
	}

	private IocpContext _iocp;
	private WSABUF _dataWriteBuffer;
	private ubyte[] _buffer;
	private Socket _clientSocket;
}

alias AcceptorBase = ListenerBase;

/** TCP Client */
abstract class StreamBase : SocketChannelBase {
	DataReceivedHandler onReceived;
	DataWrittenHandler sentHandler;

	protected this() {
	}

	this(Selector loop, AddressFamily family = AddressFamily.INET, size_t bufferSize = 4096 * 2) {
		import std.array;

		super(loop, WatcherType.TCP);
		setFlag(WatchFlag.Read, true);
		setFlag(WatchFlag.Write, true);

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
		DWORD dwReceived;
		DWORD dwFlags;

		debug (Log)
			tracef("start receiving handle=%d ", socket.handle);

		int nRet = WSARecv(cast(SOCKET)socket.handle, &_dataReadBuffer, 1u, &dwReceived, &dwFlags,
			&_iocpread.overlapped, cast(LPWSAOVERLAPPED_COMPLETION_ROUTINE)null);

		checkErro(nRet, SOCKET_ERROR);
	}

	protected void doConnect(Address addr) {
		_iocpwrite.watcher = this;
		_iocpwrite.operation = IocpOperation.connect;
		int nRet = ConnectEx(cast(SOCKET)socket.handle,
			cast(SOCKADDR*)addr.name(), addr.nameLen(), null, 0, null,
			&_iocpwrite.overlapped);
		checkErro(nRet, ERROR_IO_PENDING);
	}

	private uint doWrite() {
		_inWrite = true;
		DWORD dwFlags;
		DWORD dwSent;
		_iocpwrite.watcher = this;
		_iocpwrite.operation = IocpOperation.write;
		debug (Log) {
			size_t bufferLength = sendDataBuffer.length;
			trace("writing...handle=", socket.handle);
			trace("buffer content length: ", bufferLength);
			// trace(cast(string) data);
			if (bufferLength > 64)
				tracef("%(%02X %) ...", sendDataBuffer[0 .. 64]);
			else
				tracef("%(%02X %)", sendDataBuffer[0 .. $]);
		}

		WSASend(cast(SOCKET)socket.handle, &_dataWriteBuffer, 1, &dwSent,
			dwFlags, &_iocpwrite.overlapped, cast(LPWSAOVERLAPPED_COMPLETION_ROUTINE)null);

		debug (Log) {
			if (dwSent != _dataWriteBuffer.len)
				warningf("dwSent=%d, BufferLength=%d", dwSent, _dataWriteBuffer.len);
		}
		// FIXME: Needing refactor or cleanup -@Administrator at 2018-5-9 16:28:55
		// The buffer may be full, so what can do here?
		// checkErro(nRet, SOCKET_ERROR); // bug:

		if (isError) {
			errorf("Socket error on write: fd=%d, message=%s", handle, erroString);
			close();
		}

		return dwSent;
	}

	protected void doRead() {
		clearError();
		debug (Log)
			tracef("data reading...%d nbytes", readLen);

		if (readLen > 0) {
			// import std.stdio;
			// writefln("length=%d, data: %(%02X %)", readLen, _readBuffer[0 .. readLen]);

			if (onReceived)
				onReceived(_readBuffer[0 .. readLen]);
			debug (Log)
				tracef("done with data reading...%d nbytes", readLen);

			// continue reading
			beginRead();
		} else if (readLen == 0) {
			debug (Log)
				warning("connection broken: ", _socket.remoteAddress);
			onDisconnected();
			// if (_isClosed)
			//     close();
		} else {
			debug (Log) {
				warningf("undefined behavior on thread %d", getTid());
			} else {
				_erroString = "undefined behavior on thread";
			}
		}
	}

	// private ThreadID lastThreadID;

	// TODO: created by Administrator @ 2018-4-18 10:15:20
	/// Send a big block of data
	protected size_t tryWrite(in ubyte[] data) {
		if (_isWritting) {
			warning("Busy in writting on thread: ");
			return 0;
		}
		debug (Log)
			trace("start to write");
		_isWritting = true;

		clearError();
		setWriteBuffer(data);
		return doWrite();
	}

	protected void tryWrite() {
		if (_isWritting) {
			debug (Log)
				warning("Busy in writting on thread: ");
			return;
		}

		if (_writeQueue.empty)
			return;

		debug (Log)
			trace("start to write");
		_isWritting = true;

		clearError();

		writeBuffer = _writeQueue.front;
		auto data = writeBuffer.data;
		setWriteBuffer(data);
		size_t nBytes = doWrite();

		if (nBytes < data.length) { // to fix the corrupted data
			debug (Log)
				warningf("remaining data: %d / %d ", data.length - nBytes, data.length);
			sendDataBuffer = data.dup;
		}
	}

	private bool _isWritting;

	private void setWriteBuffer(in ubyte[] data) {
		debug (Log)
			trace("buffer content length: ", data.length);
		// trace(cast(string)data);
		// tracef("%(%02X %)", data);

		sendDataBuffer = data; //data[writeLen .. $]; // TODO: need more tests
		_dataWriteBuffer.buf = cast(char*)sendDataBuffer.ptr;
		_dataWriteBuffer.len = cast(uint)sendDataBuffer.length;
	}

	/**
	 * Called by selector after data sent
	 * Note: It's only for IOCP selector:
	*/
	void onWriteDone(size_t nBytes) {
		debug (Log)
			tracef("finishing data writting %d nbytes) ", nBytes);
		if (isWriteCancelling) {
			_isWritting = false;
			isWriteCancelling = false;
			_writeQueue.clear(); // clean the data buffer
			return;
		}

		if (writeBuffer.popSize(nBytes)) {
			if (!_writeQueue.dequeue())
				warning("_writeQueue is empty!");

			writeBuffer.doFinish();
			_isWritting = false;

			debug (Log)
				tracef("done with data writting %d nbytes) ", nBytes);

			tryWrite();
		} else // if (sendDataBuffer.length > nBytes)
		{
			// debug(Log)
			tracef("remaining nbytes: %d", sendDataBuffer.length - nBytes);
			// FIXME: Needing refactor or cleanup -@Administrator at 2018-6-12 13:56:17
			// sendDataBuffer corrupted
			// const(ubyte)[] data = writeBuffer.data;
			// tracef("%(%02X %)", data);
			// tracef("%(%02X %)", sendDataBuffer);
			setWriteBuffer(sendDataBuffer[nBytes .. $]); // send remaining
			nBytes = doWrite();
		}
	}

	void cancelWrite() {
		isWriteCancelling = true;
	}

	protected void onDisconnected() {
		_isConnected = false;
		_isClosed = true;
		if (disconnectionHandler)
			disconnectionHandler();
	}

	bool _isConnected; //if server side always true.
	SimpleEventHandler disconnectionHandler;

	protected WriteBufferQueue _writeQueue;
	protected bool isWriteCancelling;
private:
	const(ubyte)[] _readBuffer, sendDataBuffer;
	StreamWriteBuffer* writeBuffer;
	IocpContext _iocpread, _iocpwrite;
	WSABUF _dataReadBuffer, _dataWriteBuffer;
	bool _inWrite, _inRead;
}

mixin template CheckIocpError() {
	void checkErro(int ret, int erro = 0) {
		auto dwLastError = GetLastError();
		if (ret != 0 || dwLastError == 0)
			return;

		debug (Log)
			tracef("erro=%d, dwLastError=%d", erro, dwLastError);

		if (dwLastError != ERROR_IO_PENDING) {
			_erroString = "AcceptEx failed with error: code=%d".format(dwLastError);
		}
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
	DWORD dwBytesReturned;
	if (WSAIoctl(sock, SIO_GET_EXTENSION_FUNCTION_POINTER, &guid, guid.sizeof,
			&pfn, pfn.sizeof, &dwBytesReturned, null, null) == SOCKET_ERROR)
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
