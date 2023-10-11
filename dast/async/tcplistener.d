module dast.async.tcplistener;

import dast.async.core,
dast.async.eventloop,
dast.async.selector,
dast.async.socket,
dast.async.tcpstream,
core.time,
std.socket,
std.logger;

alias AcceptEventHandler = void delegate(TcpListener sender, TcpStream stream),
PeerCreateHandler = TcpStream delegate(TcpListener sender, Socket socket);

class TcpListener : ListenerBase {
	import tame.meta;

	private size_t _bufferSize = 4 * 1024;

	mixin Forward!"_socket";

	AcceptEventHandler onAccepted;
	SimpleEventHandler onClosed;
	PeerCreateHandler onPeerCreating;

	this(EventLoop loop, AddressFamily family = AddressFamily.INET, size_t bufferSize = 4 * 1024) {
		_bufferSize = bufferSize;
		version (Windows)
			super(loop, family, bufferSize);
		else
			super(loop, family);
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
		bool canRead = true;
		debug (Log)
			trace("start to listen");
		// while(canRead && isRegistered) // why?
		{
			debug (Log)
				trace("listening...");
			canRead = onAccept((Socket socket) {
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
				canRead = false;
				error("listener error: ", erroString);
				close();
			}
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
