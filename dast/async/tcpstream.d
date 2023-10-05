module dast.async.tcpstream;

import dast.async.core,
dast.async.selector,
dast.async.socket,
core.time,
std.format,
std.socket;

class TcpStream : StreamBase {
	ref auto opDispatch(string member, A...)(auto ref A args) {
		static if (A.length)
			mixin("return _socket.", member, "(", args, ");");
		else
			mixin("return _socket.", member, ";");
	}

	SimpleEventHandler onClosed;

	// for client side
	this(Selector loop, AddressFamily family = AddressFamily.INET, int bufferSize = 4096 * 2) {
		super(loop, family, bufferSize);
		socket = new Socket(family, SocketType.STREAM, ProtocolType.TCP);
	}

	// for server side
	this(Selector loop, Socket socket, size_t bufferSize = 4096 * 2) {
		super(loop, socket.addressFamily, bufferSize);
		this.socket = socket;
		_isConnected = true;
	}

	this(Socket socket) {
		_socket = socket;
		handle = socket.handle;
	}

	void connect(string ip, ushort port) {
		connect(parseAddress(ip, port));
	}

	void connect(Address addr) {
		if (_isConnected)
			return;

		try {
			scope Address a = socket.addressFamily == AddressFamily.INET6 ?
				new Internet6Address(0) : new InternetAddress(0);
			socket.bind(a);
			doConnect(addr);
			start();
			_isConnected = true;
		} catch (Exception e)
			error(e);

		if (onConnected)
			onConnected(_isConnected);
	}

	void reconnect(Address addr) {
		if (_isConnected)
			close();
		_isConnected = false;
		auto family = AddressFamily.INET;
		if (socket)
			family = socket.addressFamily;

		socket = new Socket(family, SocketType.STREAM, ProtocolType.TCP);
		connect(addr);
	}

	@property auto isConnected() const => _isConnected;

	override void start() {
		if (_isRegistered)
			return;
		_inLoop.register(this);
		_isRegistered = true;
		version (Windows)
			beginRead();
	}

	void write(StreamWriteBuffer* buffer)
	in (buffer) {
		if (!_isConnected)
			return warning("The connection has been closed!");

		_writeQueue.enqueue(buffer);

		version (Windows)
			tryWrite();
		else
			onWrite();
	}

	/// safe for big data sending
	void write(in void[] data, DataWrittenHandler handler = null) {
		if (data.length)
			write(new StreamWriteBuffer(data, handler));
	}

protected:
	ConnectionHandler onConnected;

	override void onRead() {
		debug (Log)
			trace("start to read");

		version (Posix)
			while (_isRegistered && !tryRead()) {
				debug (Log)
					trace("continue reading...");
			} else
			doRead();

		if (isError) {
			auto msg = "Socket error on write: fd=%d, message=%s".format(handle, erroString);
			error(msg);
			errorOccurred(msg);
		}
	}

	override void onClose() {
		debug (Log) {
			if (!_writeQueue.empty)
				warning("Some data has not been sent yet.");
		}

		_writeQueue.clear();
		super.onClose();
		_isConnected = false;
		socket.shutdown(SocketShutdown.BOTH);
		socket.close();

		if (onClosed)
			onClosed();
	}

	override void onWrite() {
		if (!_isConnected) {
			_isConnected = true;

			if (onConnected)
				onConnected(true);
			return;
		}

		// bool canWrite = true;
		debug (Log)
			trace("start to write");

		while (_isRegistered && !isWriteCancelling && !_writeQueue.empty) {
			debug (Log)
				trace("writting...");

			StreamWriteBuffer* writeBuffer = _writeQueue.front;
			auto data = writeBuffer.data;
			if (data.length == 0) {
				_writeQueue.dequeue().doFinish();
				continue;
			}

			clearError();
			size_t len = tryWrite(data);
			if (len > 0 && writeBuffer.popSize(len)) {
				debug (Log)
					trace("finishing data writing ", len, " bytes");
				_writeQueue.dequeue().doFinish();
			}

			if (isError) {
				auto msg = "Socket error on write: fd=%d, message=%s".format(handle, erroString);
				errorOccurred(msg);
				error(msg);
				break;
			}
		}
	}
}
