module dast.async.tcplistener;

import dast.async.core,
dast.async.eventloop,
dast.async.selector,
dast.async.socket,
dast.async.tcpstream,
std.logger;

alias AcceptHandler = void delegate(TcpListener sender, TcpStream stream) @safe,
PeerCreateHandler = TcpStream delegate(TcpListener sender, Socket socket) @safe;

class TcpListener : ListenerBase {
	import tame.meta;

	uint bufferSize = 4 * 1024;

	mixin Forward!"_socket";

	AcceptHandler onAccepted;
	SimpleHandler onClosed;
	PeerCreateHandler onPeerCreating;

	this(EventLoop loop, AddressFamily family = AddressFamily.INET) {
		super(loop, family);
	}

	override void start() {
		_inLoop.register(this);
		_isRegistered = true;
		version (Windows)
			doAccept();
	}

	override void close() {
		super.close();
		if (onClosed)
			onClosed();
	}

	protected override void onRead() {
		debug (Log)
			trace("start listening");
		if (!onAccept((Socket socket) {
				debug (Log)
					info("new connection from ", socket.remoteAddress, ", fd=", socket.handle);

				auto stream = onPeerCreating ?
				onPeerCreating(this, socket) : new TcpStream(_inLoop, socket, bufferSize);

				if (onAccepted)
					onAccepted(this, stream);
				stream.start();
			})) {
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
