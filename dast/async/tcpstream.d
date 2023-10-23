module dast.async.tcpstream;

import dast.async.core,
dast.async.selector,
dast.async.socket;

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
			recv();
	}

	/// safe for big data sending
	void write(const void[] data) {
		if (!_isConnected)
			return errorOccurred("The connection has been closed");
		if (data.length)
			_writeQueue.enqueue(data);
		version (Windows)
			tryWrite();
		else
			while (_isRegistered && !isWriteCancelling && !_writeQueue.empty) {
				const data = _writeQueue.front;
				assert(data.length);
				const len = tryWrite(data);
				if (!len) // error
					break;
				if (data.length == len) {
					debug (Log)
						trace("finishing data writing ", len, " bytes");
					_writeQueue.dequeue();
				}
			}
	}

protected:
	bool _isConnected;

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
