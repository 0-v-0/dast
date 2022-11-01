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

/**
TCP Server
*/
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
			trace("AcceptEx is :  ", AcceptEx);
		int nRet = AcceptEx(handle, cast(SOCKET)_clientSocket.handle,
			_buffer.ptr, 0, sockaddr_in.sizeof + 16, sockaddr_in.sizeof + 16,
			&dwBytesReceived, &_iocp.overlapped);

		debug (Log)
			trace("do AcceptEx : the return is : ", nRet);
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
		// assert(0, "");
		// TODO: created by Administrator @ 2018-3-27 15:51:52
	}

	private IocpContext _iocp;
	private WSABUF _dataWriteBuffer;
	private ubyte[] _buffer;
	private Socket _clientSocket;
}

alias AcceptorBase = ListenerBase;

/**
TCP Client
*/
abstract class StreamBase : SocketChannelBase {
	DataReceivedHandler onDataReceived;
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

			if (onDataReceived)
				onDataReceived(_readBuffer[0 .. readLen]);
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
				_error = true;
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
			if (_writeQueue.dequeue() is null)
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

/**
UDP Socket
*/
abstract class DatagramSocketBase : SocketChannelBase {
	/// Constructs a blocking IPv4 UDP Socket.
	this(Selector loop, AddressFamily family = AddressFamily.INET) {
		import std.array;

		super(loop, WatcherType.UDP);
		setFlag(WatchFlag.Read, true);
		setFlag(WatchFlag.ETMode, false);

		socket = new UdpSocket(family);
		_readBuffer = new UdpDataObject;
		_readBuffer.data = uninitializedArray!(ubyte[])(4096 * 2);

		if (family == AddressFamily.INET)
			_bindAddress = new InternetAddress(InternetAddress.PORT_ANY);
		else if (family == AddressFamily.INET6)
			_bindAddress = new Internet6Address(Internet6Address.PORT_ANY);
		else
			_bindAddress = new UnknownAddress;
	}

	final void bind(Address addr) {
		if (_binded)
			return;
		_bindAddress = addr;
		socket.bind(_bindAddress);
		_binded = true;
	}

	@property @safe {
		final bool isBind() => _binded;

		Address bindAddr() => _bindAddress;
	}

	override void start() {
		if (!_binded) {
			socket.bind(_bindAddress);
			_binded = true;
		}
	}

	// abstract void doRead();

	private UdpDataObject _readBuffer;
	protected bool _binded;
	protected Address _bindAddress;

	version (Windows) {
		mixin CheckIocpError;

		void doRead() {
			debug (Log)
				trace("Receiving......");

			_dataReadBuffer.len = cast(uint)_readBuffer.data.length;
			_dataReadBuffer.buf = cast(char*)_readBuffer.data.ptr;
			_iocpread.watcher = this;
			_iocpread.operation = IocpOperation.read;
			remoteAddrLen = cast(int)bindAddr.nameLen;

			DWORD dwReceived;
			DWORD dwFlags;

			int nRet = WSARecvFrom(cast(SOCKET)handle, &_dataReadBuffer,
				1, &dwReceived, &dwFlags, cast(SOCKADDR*)&remoteAddr, &remoteAddrLen,
				&_iocpread.overlapped, cast(LPWSAOVERLAPPED_COMPLETION_ROUTINE)null);
			checkErro(nRet, SOCKET_ERROR);
		}

		Address buildAddress() {
			Address tmpaddr;
			if (remoteAddrLen == 32) {
				sockaddr_in* addr = cast(sockaddr_in*)&remoteAddr;
				tmpaddr = new InternetAddress(*addr);
			} else {
				sockaddr_in6* addr = cast(sockaddr_in6*)&remoteAddr;
				tmpaddr = new Internet6Address(*addr);
			}
			return tmpaddr;
		}

		bool tryRead(scope ReadCallback read) {
			clearError();
			if (readLen == 0)
				read(null);
			else {
				auto data = _readBuffer.data;
				_readBuffer.data = data[0 .. readLen];
				_readBuffer.addr = buildAddress();
				scope (exit)
					_readBuffer.data = data;
				read(_readBuffer);
				_readBuffer.data = data;
				if (isRegistered)
					doRead();
			}
			return false;
		}

		IocpContext _iocpread;
		WSABUF _dataReadBuffer;

		sockaddr remoteAddr;
		int remoteAddrLen;
	}

}

mixin template CheckIocpError() {
	void checkErro(int ret, int erro = 0) {
		auto dwLastError = GetLastError();
		if (ret != 0 || dwLastError == 0)
			return;

		debug (Log)
			tracef("erro=%d, dwLastError=%d", erro, dwLastError);

		if (dwLastError != ERROR_IO_PENDING) {
			_error = true;
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
	auto listenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	scope (exit)
		closesocket(listenSocket);
	mixin(GET_FUNC_POINTER!("AcceptEx", "WSAID_ACCEPTEX"));
	mixin(GET_FUNC_POINTER!("ConnectEx", "WSAID_CONNECTEX"));
	/* mixin(GET_FUNC_POINTER("DisconnectEx", "WSAID_DISCONNECTEX"));
	mixin(GET_FUNC_POINTER("GetAcceptexSockAddrs", "WSAID_GETACCEPTEXSOCKADDRS", ));
	mixin(GET_FUNC_POINTER("TransmitFile", "WSAID_TRANSMITFILE", ));
	mixin(GET_FUNC_POINTER("TransmitPackets", "WSAID_TRANSMITPACKETS"));
	mixin(GET_FUNC_POINTER("WSARecvMsg", "WSAID_WSARECVMSG")); */
}

private {
	bool getFunctionPointer(FuncPointer)(SOCKET sock, ref FuncPointer pfn, GUID guid) {
		DWORD dwBytesReturned;
		if (WSAIoctl(sock, SIO_GET_EXTENSION_FUNCTION_POINTER, &guid, guid.sizeof,
				&pfn, pfn.sizeof, &dwBytesReturned, null, null) == SOCKET_ERROR) {
			error("Get function failed with error:", GetLastError());
			return false;
		}
		return true;
	}

	enum GET_FUNC_POINTER(string pft, string guid) =
		"errnoEnforce(getFunctionPointer(listenSocket, " ~ pft ~ ", " ~ guid ~ "), \"get function error!\");";
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

enum _WSAIO(int x, int y) = IOC_VOID | x | y;

enum _WSAIOR(int x, int y) = IOC_OUT | x | y;

enum _WSAIOW(int x, int y) = IOC_IN | x | y;

enum _WSAIORW(int x, int y) = IOC_INOUT | x | y;

enum {
	SIO_ASSOCIATE_HANDLE = _WSAIOW!(IOC_WS2, 1),
	SIO_ENABLE_CIRCULAR_QUEUEING = _WSAIO!(IOC_WS2, 2),
	SIO_FIND_ROUTE = _WSAIOR!(IOC_WS2, 3),
	SIO_FLUSH = _WSAIO!(IOC_WS2, 4),
	SIO_GET_BROADCAST_ADDRESS = _WSAIOR!(IOC_WS2, 5),
	SIO_GET_EXTENSION_FUNCTION_POINTER = _WSAIORW!(IOC_WS2, 6),
	SIO_GET_QOS = _WSAIORW!(IOC_WS2, 7),
	SIO_GET_GROUP_QOS = _WSAIORW!(IOC_WS2, 8),
	SIO_MULTIPOINT_LOOPBACK = _WSAIOW!(IOC_WS2, 9),
	SIO_MULTICAST_SCOPE = _WSAIOW!(IOC_WS2, 10),
	SIO_SET_QOS = _WSAIOW!(IOC_WS2, 11),
	SIO_SET_GROUP_QOS = _WSAIOW!(IOC_WS2, 12),
	SIO_TRANSLATE_HANDLE = _WSAIORW!(IOC_WS2, 13),
	SIO_ROUTING_INTERFACE_QUERY = _WSAIORW!(IOC_WS2, 20),
	SIO_ROUTING_INTERFACE_CHANGE = _WSAIOW!(IOC_WS2, 21),
	SIO_ADDRESS_LIST_QUERY = _WSAIOR!(IOC_WS2, 22),
	SIO_ADDRESS_LIST_CHANGE = _WSAIO!(IOC_WS2, 23),
	SIO_QUERY_TARGET_PNP_HANDLE = _WSAIOR!(IOC_WS2, 24),
	SIO_NSP_NOTIFY_CHANGE = _WSAIOW!(IOC_WS2, 25)
}

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
