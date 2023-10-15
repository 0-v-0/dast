module dast.async.selector.iocp;

version (Windows)  : import core.sys.windows.windows,
dast.async.socket,
dast.async.core,
dast.async.socket.iocp;

version (HaveTimer) import dast.async.timer;

alias Selector = Iocp;

class Iocp {
	this() {
		_eventHandle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
		_event = new EventChannel(this);
		version (HaveTimer)
			_timer.init();
	}

	/+ ~this() {
		.close(_eventHandle);
	} +/

	bool register(Channel watcher)
	in (watcher) {
		if (watcher.type == WatcherType.TCP
			|| watcher.type == WatcherType.Accept) {
			debug (Log)
				trace("register on socket: ", watcher.handle);
			CreateIoCompletionPort(cast(HANDLE)watcher.handle, _eventHandle,
				cast(size_t)cast(void*)watcher, 0);
		} else {
			version (HaveTimer)
				if (watcher.type == WatcherType.Timer) {
					auto wt = cast(TimerBase)watcher;
					assert(wt);
					if (!wt.setTimerOut())
						return false;
					_timer.timeWheel.addNewTimer(wt.timer, wt.wheelSize);
				}
		}

		debug (Log)
			info("watcher(fd=", watcher.handle, ", type=", watcher.type, ")");
		return true;
	}

	bool reregister(Channel watcher) {
		// IOCP does not support reregister
		return false;
	}

	bool unregister(Channel watcher) {
		// FIXME: Needing refactor or cleanup
		// https://stackoverflow.com/questions/6573218/removing-a-handle-from-a-i-o-completion-port-and-other-questions-about-iocp
		//trace("unregister fd=", watcher.handle);

		// IocpContext _data;
		// _data.watcher = watcher;
		// _data.operation = IocpOperation.close;
		// PostQueuedCompletionStatus(_eventHandle, 0, 0, &_data.overlapped);

		return true;
	}

	void weakUp() nothrow {
		IocpContext _data;
		_data.watcher = _event;
		_data.operation = IocpOperation.event;

		PostQueuedCompletionStatus(_eventHandle, 0, 0, &_data.overlapped);
	}

	void onLoop(scope void delegate() handler) {
		running = true;
		version (HaveTimer)
			_timer.init();
		do {
			handler();
			handleEvents();
		}
		while (running);
	}

	private void handleEvents() {
		version (HaveTimer)
			int timeout = _timer.doWheel();
		else
			int timeout = 250;
		OVERLAPPED* overlapped;
		ULONG_PTR key = void;
		DWORD bytes = void;

		debug {
			// const ret = GetQueuedCompletionStatus(_eventHandle, &bytes, &key, &overlapped, INFINITE);
			// trace("GetQueuedCompletionStatus, ret=", ret);

			// trace("timeout=", timeout);
		}
		const ret = GetQueuedCompletionStatus(_eventHandle, &bytes, &key, &overlapped, timeout);
		auto ev = cast(IocpContext*)overlapped;
		if (ret == 0) {
			const erro = GetLastError();
			if (erro == WAIT_TIMEOUT) // || erro == ERROR_OPERATION_ABORTED
				return;

			error("error occurred, code=", erro);
			if (ev) {
				Channel channel = ev.watcher;
				if (channel && !channel.isClosed())
					channel.close();
			}
			return;
		}

		if (!ev || !ev.watcher)
			warning("ev is null or ev.watche is null");
		else {
			const op = ev.operation;
			auto channel = ev.watcher;
			debug (Log)
				trace("ev.operation: ", op);

			switch (op) with (IocpOperation) {
			case accept:
				channel.onRead();
				break;
			case connect:
				onSocketRead(channel, 0);
				break;
			case read:
				onSocketRead(channel, bytes);
				break;
			case write:
				onSocketWrite(channel, bytes);
				break;
			case event:
				channel.onRead();
				break;
			case close:
				warning("close: ");
				break;
			default:
				warning("unsupported operation type: ", op);
			}
		}
	}

	void stop() {
		running = false;
		weakUp();
	}

	//void dispose() {
	//}

private:
	void onSocketRead(Channel wt, size_t len)
	in (wt) {
		if (len == 0 || wt.isClosed) {
			debug (Log)
				info("channel closed");
			return;
		}

		auto io = cast(SocketChannelBase)wt;
		// assert(io, "The type of channel is: " ~ typeid(wt).name);
		if (!io)
			return warning("The channel socket is null");

		io.readLen = len;
		wt.onRead();
	}

	void onSocketWrite(Channel wt, size_t len)
	in (cast(StreamBase)wt) {
		auto client = cast(StreamBase)wt;
		client.onWriteDone(len); // Notify the client about how many bytes actually sent.
	}

	bool running;
	HANDLE _eventHandle;
	EventChannel _event;
	version (HaveTimer) CustomTimer _timer;
}
