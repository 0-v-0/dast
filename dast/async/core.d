module dast.async.core;

import dast.async.queue,
std.array;
public import dast.async.eventloop : EventLoop;

@safe:
alias SimpleHandler = void delegate() nothrow,
ErrorHandler = void delegate(in char[] msg) nothrow,
RecvHandler = void delegate(in ubyte[] data),
DataSentHandler = void delegate(in void[] data) nothrow;

abstract class SocketChannel {
	ErrorHandler onError;

	package WF flags;
	private WatcherType _type;
	protected bool _isRegistered;
	pure nothrow @nogc {
		@property {
			final handle() const => _socket.handle;

			final type() const => _type;

			final socket() => _socket;

			final bool isClosed() const => !_isRegistered;

			final bool isRegistered() const => _isRegistered;
		}

		this(EventLoop loop, WatcherType type = WT.Event) {
			_loop = loop;
			_type = type;
			onError = (msg) {
				debug (Log) {
					try
						error(msg);
					catch (Exception) {
					}
				}
			};
		}
	}

	void onRead() {
		assert(0, "unimplemented");
	}

nothrow:
	void close() {
		if (!_isRegistered)
			assert(0, text("The watcher(fd=", handle, ") has already been closed"));
		_isRegistered = false;
		_loop.unregister(this);
		_loop = EventLoop.init;
		debug (Log)
			trace("channel closed...", handle);
	}

protected:
	@property final void socket(Socket s) {
		version (Posix) {
			s.blocking = false;
		}
		_socket = s;
		debug (Log)
			trace("new socket fd: ", handle);
	}

	EventLoop _loop;
	Socket _socket;
}

alias WriteQueue = Queue!(const(void)[], 32, true);

enum WatcherType : ubyte {
	None,
	Accept,
	TCP,
	//UDP,
	Timer = 4,
	Event,
}

enum WatchFlag : uint {
	None,
	Read = 0x001,
	Write = 0x004,
	ReadWrite = Read | Write,

	OneShot = 0x0010,
	ETMode = 0x0020,
	OneShotET = OneShot | ETMode,
}

package:
debug (Log) import std.logger;
import tame.net.socket,
std.conv : text;

alias WT = WatcherType,
WF = WatchFlag,
BUF = uninitializedArray!(ubyte[], size_t);
