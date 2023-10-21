module dast.async.core;

import dast.async.container,
std.socket;
public import dast.async.selector : Selector;

package import std.logger;

@safe:
alias SimpleHandler = void delegate() nothrow,
ErrorHandler = void delegate(in char[] msg) nothrow,
TickedHandler = void delegate(Object sender),
RecvHandler = void delegate(in ubyte[] data),
AcceptHandler = void delegate(
	Socket socket),
ConnectionHandler = void delegate(bool success),
AcceptCallback = void delegate(Selector loop, Socket socket);

alias DataWrittenHandler = void delegate(in void[] data, size_t size);
class Channel {
	socket_t handle;
	ErrorHandler onError;
	@property pure nothrow @nogc {
		protected this() {
		}

		this(Selector loop, WatcherType type = WT.Event) {
			_inLoop = loop;
			_type = type;
		}

		final bool isClosed() const => !_isRegistered;

		final bool isRegistered() const => _isRegistered;

		final WatcherType type() const => _type;
	}

	void onRead() {
		assert(0, "unimplemented");
	}

nothrow:
	void close() {
		if (_isRegistered) {
			debug (Log)
				trace("channel closing...", handle);
			onClose();
			debug (Log)
				trace("channel closed...", handle);
		} else
			debug warning("The watcher(fd=", handle, ") has already been closed");
	}

	mixin OverrideErro;

protected:
	Selector _inLoop;
	bool _isRegistered;

	void onClose() {
		_isRegistered = false;
		version (Windows) {
		} else
			_inLoop.unregister(this);
		//  _inLoop = null;
	}

	void errorOccurred(in char[] msg) {
		try
			error(msg);
		catch (Exception) {
		}
		if (onError)
			onError(msg);
	}

	package WF flags;
	private WatcherType _type;
}

alias EventChannel = Channel;

abstract class SocketChannelBase : Channel {
	protected this() {
	}

	this(Selector loop, WatcherType type) {
		super(loop, type);
	}

	@property final socket() => _socket;

	version (Windows) package uint readLen;

	void start();

protected:
	@property void socket(Socket s) {
		handle = s.handle;
		version (Posix)
			s.blocking = false;
		_socket = s;
		debug (Log)
			trace("new socket fd: ", handle);
	}

	Socket _socket;
}

alias WriteBufferQueue = Queue!(const(void)[], true);

enum WatcherType : ubyte {
	None,
	Accept,
	TCP,
	//UDP,
	Timer = 4,
	Event,
}

enum WatchFlag {
	None,
	Read,
	Write,

	OneShot = 8,
	ETMode = 16
}

package:
alias WT = WatcherType,
WF = WatchFlag;

template OverrideErro() {
	bool isError() const => _error.length != 0;

	package(dast) string _error;
}

bool popSize(ref scope const(void)[] arr, size_t size) {
	arr = arr[size .. $];
	return arr.length > 0;
}
