module dast.async.tcplistener;

import dast.async.core,
dast.async.eventloop,
dast.async.selector,
dast.async.socket,
dast.async.tcpstream,
core.time,
std.socket,
std.logger;

alias AcceptHandler = void delegate(TcpListener sender, TcpStream stream) @safe,
PeerCreateHandler = TcpStream delegate(TcpListener sender, Socket socket) @safe;

class TcpListener : ListenerBase {
	import tame.meta;

	private uint _bufferSize = 4 * 1024;

	mixin Forward!"_socket";

	AcceptHandler onAccepted;
	SimpleHandler onClosed;
	PeerCreateHandler onPeerCreating;

	this(EventLoop loop, AddressFamily family = AddressFamily.INET, uint bufferSize = 4 * 1024) {
		_bufferSize = bufferSize;
		version (Windows)
			super(loop, family);
		else
			super(loop, bufferSize);
	}

	override void start() {
		_inLoop.register(this);
		_isRegistered = true;
		version (Windows)
			doAccept();
	}

	override void close() {
		if (onClosed)
			onClosed();
		onClose();
	}

	protected override void onRead() {
		//bool canRead = true;
		debug (Log)
			trace("start to listen");
		debug (Log)
			trace("listening...");
		//canRead =
		onAccept((Socket socket) {
			debug (Log)
				info("new connection from ", socket.remoteAddress, ", fd=", socket.handle);

			if (onAccepted) {
				auto stream = onPeerCreating ?
					onPeerCreating(this, socket) : new TcpStream(_inLoop, socket, _bufferSize);

				onAccepted(this, stream);
				stream.start();
			}
		});

		if (isError) {
			//canRead = false;
			error("listener error: ", _error);
			close();
		}
	}
}

@property:
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
