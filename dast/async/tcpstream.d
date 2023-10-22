module dast.async.tcpstream;

import dast.async.core,
dast.async.selector,
dast.async.socket,
core.time,
std.socket,
std.conv : text;

@safe class TcpStream : StreamBase {
	import tame.meta;

	mixin Forward!"_socket";

	ConnectionHandler onConnected;
	SimpleHandler onClosed;

	// client side
	this(Selector loop, AddressFamily family = AddressFamily.INET, uint bufferSize = 4 * 1024) {
		super(loop, bufferSize);
		socket = new TcpSocket(family);
	}

	// server side
	this(Selector loop, Socket socket, uint bufferSize = 4 * 1024) {
		super(loop, bufferSize);
		this.socket = socket;
		_isConnected = true;
	}

	void connect(Address addr) @trusted {
		if (_isConnected)
			return;

		try {
			scope Address a = _socket.addressFamily == AddressFamily.INET6 ?
				new Internet6Address(0) : new InternetAddress(0);
			_socket.bind(a);
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
		socket = new TcpSocket(_socket ? _socket.addressFamily : AddressFamily.INET);
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

	/// safe for big data sending
	void write(const void[] data) {
		if (!_isConnected)
			return warning("The connection has been closed");
		if (data.length)
			_writeQueue.enqueue(data);
		version (Windows)
			tryWrite();
		else
			while (_isRegistered && !isWriteCancelling && !_writeQueue.empty) {
				const data = _writeQueue.front;
				if (!data.length) {
					_writeQueue.dequeue();
					continue;
				}

				_error = [];
				const len = tryWrite(data);
				if (data.length == len) {
					debug (Log)
						trace("finishing data writing ", len, " bytes");
					_writeQueue.dequeue();
				}

				if (isError) {
					errorOccurred(text("Socket error on write: fd=", handle, ", message=", _error));
					break;
				}
			}
	}

protected:
	bool _isConnected;

	override void onRead() {
		debug (Log)
			trace("start reading");

		while (_isRegistered && !tryRead()) {
			debug (Log)
				trace("continue reading...");
		}

		if (isError)
			errorOccurred(text("Socket error on write: fd=", handle, ", message=", _error));
	}

	override void onClose() {
		debug (Log) {
			if (!_writeQueue.empty)
				warning("Some data has not been sent yet");
		}

		_writeQueue.clear();
		super.onClose();
		_isConnected = false;
		_socket.shutdown(SocketShutdown.BOTH);
		_socket.close();

		if (onClosed)
			onClosed();
	}
}
