module dast.async.core;

import dast.async.container,
std.socket;
public import dast.async.selector : Selector;

package import std.logger;

alias SimpleEventHandler = void delegate() nothrow;
alias ErrorEventHandler = void delegate(in char[] msg);
alias TickedEventHandler = void delegate(Object sender);
alias ReadCallback = void delegate(Object obj);
alias DataReceivedHandler = void delegate(in ubyte[] data);
alias DataWrittenHandler = void delegate(in void[] data, size_t size);
alias AcceptHandler = void delegate(Socket socket);
alias ConnectionHandler = void delegate(bool isSucceeded);
alias AcceptCallback = void delegate(Selector loop, Socket socket);

abstract class Channel {
	socket_t handle;
	ErrorEventHandler onError;

	protected bool _isRegistered;

	protected this() {
	}

	this(Selector loop, WatcherType type) {
		_inLoop = loop;
		_type = type;
	}

	@property @safe pure nothrow @nogc {
		bool isRegistered() const => _isRegistered;

		bool isClosed() const => _closed;

		WatcherType type() const => _type;
	}

	protected bool _closed;

	protected void onClose() nothrow {
		_isRegistered = false;
		_closed = true;
		version (Windows) {
		} else
			_inLoop.unregister(this);
		//  _inLoop = null;
	}

	protected void errorOccurred(in char[] msg) {
		if (onError)
			onError(msg);
	}

	void onRead() {
		assert(0, "unimplemented");
	}

	void onWrite() {
		assert(0, "unimplemented");
	}

nothrow:
	void close() {
		if (!_closed) {
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
	final void setFlag(WF index, bool enable = true) {
		if (enable)
			flags |= index;
		else
			flags &= ~index;
	}

	Selector _inLoop;

	package WF flags;
	private WatcherType _type;
}

class EventChannel : Channel {
	this(Selector loop) {
		super(loop, WatcherType.Event);
	}

	void call() {
		assert(0);
	}
}

struct StreamWriteBuffer {
@safe:
	this(const(void)[] data, DataWrittenHandler handler = null) {
		_data = data;
		_sentHandler = handler;
	}

	@property data() const => cast(const(ubyte)[])_data[_site .. $];

	/// add send offset and return is empty
	bool popSize(size_t size) {
		_site += size;
		return _site >= _data.length;
	}

	/// do send finish
	void doFinish() @system {
		if (_sentHandler)
			_sentHandler(_data, _site);
		_sentHandler = null;
		_data = null;
	}

	StreamWriteBuffer* next;

private:
	size_t _site;
	const(void)[] _data;
	DataWrittenHandler _sentHandler;
}

abstract class SocketChannelBase : Channel {
	protected this() {
	}

	this(Selector loop, WatcherType type) {
		super(loop, type);
	}

	@property final socket() @trusted => _socket;

	version (Windows) {
		package size_t readLen;
	}

	void start();

	void onWriteDone() {
		assert(0, "unimplemented");
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

	Socket _socket;
}

alias WriteBufferQueue = Queue!(StreamWriteBuffer*);

package template OverrideErro() {
	bool isError() => _error.length != 0;

	string erroString() => cast(string)_error;

	package const(char)[] _error;
}

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

package alias WF = WatchFlag;

final class BaseTypeObject(T) {
	T data;
}
