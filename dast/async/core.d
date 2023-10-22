module dast.async.core;

import dast.async.container,
std.array,
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

abstract class SocketChannel {
	ErrorHandler onError;

	bool isError() const => _error.length != 0;

	package(dast) string _error;

	package WF flags;

	@property pure nothrow @nogc {
		final handle() const => _socket.handle;

		final type() const => _type;

		final socket() => _socket;

		final bool isClosed() const => !_isRegistered;

		final bool isRegistered() const => _isRegistered;
	}

	this(Selector loop, WatcherType type = WT.Event) {
		_inLoop = loop;
		_type = type;
	}

	void start();

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

protected:
	@property void socket(Socket s) {
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
	bool _isRegistered;
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
WF = WatchFlag,
BUF = uninitializedArray!(ubyte[], size_t);

bool popSize(ref scope const(void)[] arr, size_t size) {
	arr = arr[size .. $];
	return arr.length == 0;
}
