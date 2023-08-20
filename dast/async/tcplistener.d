module dast.async.tcplistener;

// dfmt off
import dast.async.core,
	dast.async.eventloop,
	dast.async.selector,
	dast.async.socket,
	dast.async.tcpstream,
	core.time,
	std.socket,
	std.exception,
	std.logger;
// dfmt on

alias AcceptEventHandler = void delegate(TcpListener sender, TcpStream stream);
alias PeerCreateHandler = TcpStream delegate(TcpListener sender, Socket socket, size_t bufferSize);

class TcpListener : ListenerBase {
	private size_t _bufferSize = 4 * 1024;

	ref auto opDispatch(string member, Args...)(auto ref Args args) {
		static if (Args.length)
			mixin("return _socket.", member, "(", args, ");");
		else
			mixin("return _socket.", member, ";");
	}

	/// event handlers
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
					infof("new connection from %s, fd=%d", socket.remoteAddress, socket.handle);

				if (onAccepted) {
					TcpStream stream = void;
					if (onPeerCreating)
						stream = onPeerCreating(this, socket, _bufferSize);
					else
						stream = new TcpStream(_inLoop, socket, _bufferSize);

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
