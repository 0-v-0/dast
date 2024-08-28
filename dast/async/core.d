module dast.async.core;

import dast.async.queue,
std.array;
public import dast.async.selector : Selector;

@safe:
alias SimpleHandler = void delegate() nothrow,
ErrorHandler = void delegate(in char[] msg) nothrow,
TickedHandler = void delegate(Object sender),
RecvHandler = void delegate(in ubyte[] data),
AcceptHandler = void delegate(
	Socket socket),
ConnectionHandler = void delegate(bool success),
DataSentHandler = void delegate(in void[] data) nothrow;

abstract class SocketChannel {
	ErrorHandler onError;

	package WF flags;
	pure nothrow {
		@property @nogc {
			final handle() const => _socket.handle;

			final type() const => _type;

			final socket() => _socket;

			final bool isClosed() const => !_isRegistered;

			final bool isRegistered() const => _isRegistered;
		}

		this(Selector loop, WatcherType type = WT.Event) {
			_inLoop = loop;
			_type = type;
			onError = (msg) {
				try
					error(msg);
				catch (Exception) {
				}
			};
		}
	}

	void start();

	void onRead() {
		assert(0, "unimplemented");
	}

nothrow:
	void close() {
		if (!_isRegistered)
			assert(0, text("The watcher(fd=", handle, ") has already been closed"));
		_isRegistered = false;
		version (Windows) {
		} else
			_inLoop.unregister(this);
		//  _inLoop = null;
		debug (Log)
			trace("channel closed...", handle);
	}

protected:
	@property final void socket(Socket s) {
		version (Posix) {
			try
				s.blocking = false;
			catch (Exception) {
			}
		}
		_socket = s;
		debug (Log)
			trace("new socket fd: ", handle);
	}

	Selector _inLoop;
	Socket _socket;
	private WatcherType _type;
	bool _isRegistered;
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

enum WatchFlag {
	None,
	Read,
	Write,

	OneShot = 8,
	ETMode = 16
}

package:
import std.logger,
std.socket,
std.conv : text;

alias WT = WatcherType,
WF = WatchFlag,
BUF = uninitializedArray!(ubyte[], size_t);
