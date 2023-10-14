module dast.async.selector.iocp;

version (Windows)  : import core.sys.windows.windows,
dast.async.socket,
dast.async.core,
dast.async.socket.iocp;
version (HaveTimer) import dast.async.timer;

class SelectorBase : Selector {
	this() {
		_iocpHandle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
		_event = new EventChannel(this);
		version (HaveTimer)
			_timer.init();
	}

	/+ ~this() {
		.close(_iocpHandle);
	} +/

	override bool register(Channel watcher)
	in (watcher) {
		if (watcher.type == WatcherType.TCP
			|| watcher.type == WatcherType.Accept
			|| watcher.type == WatcherType.UDP) {
			debug (Log)
				trace("Run CreateIoCompletionPort on socket: ", watcher.handle);
			CreateIoCompletionPort(cast(HANDLE)watcher.handle, _iocpHandle,
				cast(size_t)cast(void*)watcher, 0);
		} else {
			version (HaveTimer)
				if (watcher.type == WatcherType.Timer) {
					auto wt = cast(TimerBase)watcher;
					assert(wt);
					if (wt is null || !wt.setTimerOut())
						return false;
					_timer.timeWheel.addNewTimer(wt.timer, wt.wheelSize);
				}
		}

		debug (Log)
			info("register, watcher(fd=", watcher.handle, ", type=", watcher.type, ")");
		_event.setNext(watcher);
		return true;
	}

	override bool reregister(Channel watcher) {
		// IOCP does not support reregister
		return false;
	}

	override bool unregister(Channel watcher) {
		// FIXME: Needing refactor or cleanup
		// https://stackoverflow.com/questions/6573218/removing-a-handle-from-a-i-o-completion-port-and-other-questions-about-iocp
		//trace("unregister fd=", watcher.handle);

		// IocpContext _data;
		// _data.watcher = watcher;
		// _data.operation = IocpOperation.close;
		// PostQueuedCompletionStatus(_iocpHandle, 0, 0, &_data.overlapped);

		return true;
	}

	void weakUp() nothrow {
		IocpContext _data;
		_data.watcher = _event;
		_data.operation = IocpOperation.event;

		PostQueuedCompletionStatus(_iocpHandle, 0, 0, &_data.overlapped);
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
		ULONG_PTR key;
		DWORD bytes;

		debug {
			// const ret = GetQueuedCompletionStatus(_iocpHandle, &bytes, &key, &overlapped, INFINITE);
			// trace("GetQueuedCompletionStatus, ret=", ret);

			// trace("timeout=", timeout);
		}
		const ret = GetQueuedCompletionStatus(_iocpHandle, &bytes, &key, &overlapped, timeout);
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
		else
			handleIocpOperation(ev.operation, ev.watcher, bytes);
	}

	private void handleIocpOperation(IocpOperation op, Channel channel, DWORD bytes) {

		debug (Log)
			trace("ev.operation: ", op);

		switch (op) {
		case IocpOperation.accept:
			channel.onRead();
			break;
		case IocpOperation.connect:
			onSocketRead(channel, 0);
			break;
		case IocpOperation.read:
			onSocketRead(channel, bytes);
			break;
		case IocpOperation.write:
			onSocketWrite(channel, bytes);
			break;
		case IocpOperation.event:
			channel.onRead();
			break;
		case IocpOperation.close:
			warning("close: ");
			break;
		default:
			warning("unsupported operation type: ", op);
		}
	}

	override void stop() {
		running = false;
		weakUp();
	}

	void dispose() {
	}

private:
	void onSocketRead(Channel wt, size_t len) {
		debug if (!wt)
			return warning("channel is null");

		if (len == 0 || wt.isClosed) {
			debug (Log)
				info("channel closed");
			return;
		}

		auto io = cast(SocketChannelBase)wt;
		// assert(io, "The type of channel is: " ~ typeid(wt).name);
		if (!io)
			return warning("The channel socket is null: ");

		io.setRead(len);
		wt.onRead();
	}

	void onSocketWrite(Channel wt, size_t len) {
		debug if (wt is null) {
			warning("channel is null");
			return;
		}
		auto client = cast(StreamBase)wt;
		if (client is null) {
			warning("The channel socket is null: ");
			return;
		}
		client.onWriteDone(len); // Notify the client about how many bytes actually sent.
	}

	bool running;
	HANDLE _iocpHandle;
	EventChannel _event;
	version (HaveTimer) CustomTimer _timer;
}
