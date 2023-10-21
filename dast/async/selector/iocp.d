module dast.async.selector.iocp;

version (Windows)  : import core.sys.windows.windows,
dast.async.socket,
dast.async.core,
dast.async.socket.iocp,
std.socket;

alias Selector = Iocp;

@safe class Iocp : EventChannel {
	this() @trusted {
		super(this);
		_eventHandle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
	}

	/+ ~this() {
		.close(_eventHandle);
	} +/

	bool register(Channel watcher) @trusted
	in (watcher.type <= WT.Event) {
		const fd = watcher.handle;
		const type = watcher.type;
		if (type == WT.TCP || type == WT.Accept) {
			debug (Log)
				trace("register on socket: ", fd);
			CreateIoCompletionPort(cast(HANDLE)fd, _eventHandle, fd, 0);
		} else {
			return false;
		}

		debug (Log)
			info("watcher(fd=", fd, ", type=", type, ')');
		return true;
	}

	bool reregister(Channel watcher) {
		// IOCP does not support reregister
		return false;
	}

	bool unregister(Channel watcher) {
		// FIXME: Needing refactor or cleanup
		// https://stackoverflow.com/questions/6573218/removing-a-handle-from-a-i-o-completion-port-and-other-questions-about-iocp
		//trace("unregister fd=", fd);

		// IocpContext ctx;
		// ctx.watcher = watcher;
		// ctx.operation = IocpOperation.close;
		// PostQueuedCompletionStatus(_eventHandle, 0, 0, &ctx.overlapped);

		return true;
	}

	void weakUp() nothrow @trusted {
		IocpContext ctx = {operation: IocpOperation.event, watcher: this};
		PostQueuedCompletionStatus(_eventHandle, 0, 0, &ctx.overlapped);
	}

	void onLoop(scope void delegate() handler) @system {
		running = true;
		do {
			handler();
			handleEvents();
		}
		while (running);
	}

	void stop() {
		running = false;
		weakUp();
	}

	//void dispose() {
	//}

private:
	void handleEvents() @trusted {
		enum timeout = 250, N = 32;
		OVERLAPPED_ENTRY[N] entries;
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
			assert(ev && ev.watcher, "ev is null or ev.watcher is null");

			auto channel = ev.watcher;
			final switch (ev.operation) with (IocpOperation) {
			case accept:
				(cast(ListenerBase)channel).onRead();
				break;
			case connect:
				onSocketRead(channel, 0);
				break;
			case read:
				onSocketRead(channel, len);
				break;
			case write:
				debug (Log)
					trace("finishing data writing ", len, " bytes");
				(cast(StreamBase)channel).onWriteDone(len); // Notify the client about how many bytes actually sent
				break;
			case event:
				(cast(EventChannel)channel).onRead();
				break;
			case close:
				break;
			}
		}
	}

	void onSocketRead(Channel wt, uint len)
	in (wt) {
		if (len == 0 || wt.isClosed) {
			debug (Log)
				info("channel closed");
			return;
		}

		auto io = cast(SocketChannelBase)wt;
		assert(io, "The type of channel is: " ~ typeid(wt).name);

		io.readLen = len;
		io.onRead();
	}

	bool running;
	HANDLE _eventHandle;
}
