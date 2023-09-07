module dast.async.core;

import std.socket;
import std.exception;
import dast.async.container;

package import std.logger;

alias SimpleEventHandler = void delegate() nothrow;
alias ErrorEventHandler = void delegate(string message);
alias TickedEventHandler = void delegate(Object sender);
alias ReadCallback = void delegate(Object obj);
alias DataReceivedHandler = void delegate(in ubyte[] data);
alias DataWrittenHandler = void delegate(in void[] data, size_t size);
alias AcceptHandler = void delegate(Socket socket);
alias ConnectionHandler = void delegate(bool isSucceeded);
alias UDPReadCallback = void delegate(in ubyte[] data, Address addr);
alias AcceptCallback = void delegate(Selector loop, Socket socket);

interface Selector {
	bool register(Channel channel);

	bool reregister(Channel channel);

	bool unregister(Channel channel) nothrow;

	void stop();

	void dispose() nothrow;
}

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

	@property @safe {
		bool isRegistered() const => _isRegistered;

		bool isClosed() const => _isClosed;

		WatcherType type() const => _type;

		Selector eventLoop() => _inLoop;
	}

	protected bool _isClosed;

	protected void onClose() nothrow {
		_isRegistered = false;
		_isClosed = true;
		version (Windows) {
		} else
			_inLoop.unregister(this);
		//  _inLoop = null;
		clear();
	}

	protected void errorOccurred(string msg) {
		if (onError)
			onError(msg);
	}

	void onRead() {
		assert(0, "unimplemented");
	}

	void onWrite() {
		assert(0, "unimplemented");
	}

	final bool flag(WatchFlag index) => (_flags & index) != 0;

	void close() nothrow {
		if (!_isClosed) {
			debug (Log)
				trace("channel closing...", handle);
			onClose();
			debug (Log)
				trace("channel closed...", handle);
		} else
			debug warningf("The watcher(fd=%d) has already been closed", handle);
	}

	void setNext(Channel next) {
		if (next is this)
			return; // Can't set to self
		next._next = _next;
		next._priv = this;
		if (_next)
			_next._priv = next;
		_next = next;
	}

	void clear() nothrow {
		if (_priv)
			_priv._next = _next;
		if (_next)
			_next._priv = _priv;
		_next = null;
		_priv = null;
	}

	mixin OverrideErro;

protected:
	final void setFlag(WatchFlag index, bool enable) {
		if (enable)
			_flags |= index;
		else
			_flags &= ~index;
	}

	Selector _inLoop;

private:
	WatchFlag _flags;
	WatcherType _type;

	Channel _priv, _next;
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

	@property auto data() const => cast(const(ubyte)[])_data[_site .. $];

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

	pragma(inline) @property final socket() @trusted => _socket;

	version (Windows) {

		void setRead(size_t bytes) {
			readLen = bytes;
		}

		protected size_t readLen;
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

	string erroString() => _error;

	void clearError() {
		_error = "";
	}

	string _error;
}

enum WatcherType : ubyte {
	Accept,
	TCP,
	UDP,
	Timer,
	Event,
	File,
	None
}

enum WatchFlag {
	None,
	Read,
	Write,

	OneShot = 8,
	ETMode = 16
}

final class BaseTypeObject(T) {
	T data;
}
