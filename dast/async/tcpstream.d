module dast.async.tcpstream;

import dast.async.core,
dast.async.selector,
dast.async.socket,
core.time,
std.socket,
std.conv : text;

class TcpStream : StreamBase {
	import tame.meta;

	mixin Forward!"_socket";

	SimpleEventHandler onClosed;

	// client side
	this(Selector loop, AddressFamily family = AddressFamily.INET, int bufferSize = 4 * 1024) {
		super(loop, family, bufferSize);
		socket = new Socket(family, SocketType.STREAM, ProtocolType.TCP);
	}

	// server side
	this(Selector loop, Socket socket, size_t bufferSize = 4 * 1024) {
		super(loop, socket.addressFamily, bufferSize);
		this.socket = socket;
		_isConnected = true;
	}

	this(Socket socket) {
		_socket = socket;
		handle = socket.handle;
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

	@property isConnected() const => _isConnected;

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
			trace("start reading");

		version (Posix)
			while (_isRegistered && !tryRead()) {
				debug (Log)
					trace("continue reading...");
			} else
			doRead();

		if (isError) {
			const msg = text("Socket error on write: fd=", handle, ", message=", erroString);
			error(msg);
			errorOccurred(msg);
		}
	}

	override void onClose() {
		debug (Log) {
			if (!_writeQueue.empty)
				warning("Some data has not been sent yet");
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
		debug (Log)
			trace("start writing");

		while (_isRegistered && !isWriteCancelling && !_writeQueue.empty) {
			debug (Log)
				trace("writing...");

			StreamWriteBuffer* writeBuffer = _writeQueue.front;
			auto data = writeBuffer.data;
			if (data.length == 0) {
				_writeQueue.dequeue().doFinish();
				continue;
			}

			_error = [];
			const len = tryWrite(data);
			if (len > 0 && writeBuffer.popSize(len)) {
				debug (Log)
					trace("finishing data writing ", len, " bytes");
				_writeQueue.dequeue().doFinish();
			}

			if (isError) {
				const msg = text("Socket error on write: fd=", handle, ", message=", erroString);
				errorOccurred(msg);
				error(msg);
				break;
			}
		}
	}
}
