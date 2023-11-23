module dast.async.selector.iocp;

version (Windows)  : import core.sys.windows.windows,
dast.async.socket,
dast.async.core,
dast.async.socket.iocp;

alias Selector = Iocp;

@safe class Iocp {
	this() @trusted {
		_eventHandle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
		if (!_eventHandle)
			throw new Exception("CreateIoCompletionPort failed");
	}

	/+ ~this() {
		.close(_eventHandle);
	} +/

	bool register(SocketChannel watcher) @trusted
	in (watcher.type <= WT.Event) {
		const fd = watcher.handle;
		const type = watcher.type;
		if (type == WT.TCP || type == WT.Accept) {
			debug (Log)
				trace("register on socket: ", fd);
			CreateIoCompletionPort(cast(HANDLE)fd, _eventHandle, cast(ulong)cast(void*)watcher, 0);
		} else {
			return false;
		}

		debug (Log)
			info("watcher(fd=", fd, ", type=", type, ')');
		_watchers ~= watcher;
		return true;
	}

	bool reregister(SocketChannel watcher) {
		// IOCP does not support reregister
		return false;
	}

	bool unregister(SocketChannel watcher) {
		// FIXME: Needing refactor or cleanup
		// https://stackoverflow.com/questions/6573218/removing-a-handle-from-a-i-o-completion-port-and-other-questions-about-iocp

		return true;
	}

	void weakUp() nothrow @trusted {
		IocpContext ctx = {operation: IocpOperation.event}; // TODO
		PostQueuedCompletionStatus(_eventHandle, 0, 0, &ctx.overlapped);
	}

	mixin Loop;

private:
	void handleEvents() @trusted {
		enum timeout = 250, N = 32;
		OVERLAPPED_ENTRY[N] entries = void;
		uint n = void;
		const ret = GetQueuedCompletionStatusEx(_eventHandle, entries.ptr, entries.length, &n, timeout, 0);
		if (ret == 0) {
			const err = GetLastError();
			if (err != WAIT_TIMEOUT) // && err != ERROR_OPERATION_ABORTED
				error("error occurred, code=", err);
			return;
		}
		foreach (i; 0 .. n) {
			auto entry = entries[i];
			const len = entry.dwNumberOfBytesTransferred;
			auto ev = cast(IocpContext*)entry.lpOverlapped;
			assert(ev, "ev is null");

			auto channel = cast(SocketChannel)cast(void*)entry.lpCompletionKey;
			switch (ev.operation) with (IocpOperation) {
			case accept:
				(cast(ListenerBase)channel).onRead();
				break;
			case read:
				if (len && !channel.isClosed) {
					auto io = cast(StreamBase)channel;
					assert(io);
					io.onRead(len);
				}
				break;
			case write:
				debug// (Log)
					info("finishing writing ", len, " bytes");
				(cast(StreamBase)channel).onWrite(len); // Notify the client about how many bytes actually sent
				break;
			case event:
				channel.onRead(); // TODO
				break;
			default:
			}
		}
	}

	HANDLE _eventHandle;
	SocketChannel[] _watchers;
}
