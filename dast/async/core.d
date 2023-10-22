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
	@property pure nothrow @nogc {
		protected this() {
		}

		final bool isClosed() const => !_isRegistered;

		final bool isRegistered() const => _isRegistered;
	}

	void onRead() {
		assert(0, "unimplemented");
	}

	mixin OverrideErro;

protected:
	bool _isRegistered;

	package WF flags;
}

alias EventChannel = Channel;

abstract class SocketChannelBase : Channel {
	socket_t handle;
	ErrorHandler onError;

	protected this() {
	}

	this(Selector loop, WatcherType type = WT.Event) {
		_inLoop = loop;
		_type = type;
	}

	@property final socket() => _socket;

	@property final type() const => _type;

	void start();

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

protected:
	@property void socket(Socket s) {
		handle = s.handle;
		version (Posix)
			s.blocking = false;
		_socket = s;
		debug (Log)
			trace("new socket fd: ", handle);
	}

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

	Selector _inLoop;
	Socket _socket;
	private WatcherType _type;
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
