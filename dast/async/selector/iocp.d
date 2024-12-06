module dast.async.selector.iocp;

version (Windows)  : import dast.async.core,
dast.async.iocp,
dast.async.tcpclient;

alias Selector = Iocp;

template Iocp() {
	import dast.async.core,
	dast.async.iocp,
	dast.async.tcpclient,
	dast.async.thread,
	std.parallelism : totalCPUs;

@safe:
	ThreadPool* workerPool;
	this() @trusted {
		_eventHandle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
		if (!_eventHandle)
			throw new Exception("CreateIoCompletionPort failed");
		workerPool = new ThreadPool(totalCPUs - 1);
	}

	/+ ~this() {
		.close(_eventHandle);
	} +/

	bool register(SocketChannel watcher) @trusted nothrow
	in (watcher.type <= WT.Event) {
		const fd = watcher.handle;
		const type = watcher.type;
		if (type == WT.TCP || type == WT.Accept) {
			debug (Log)
				trace("register on socket: ", fd);
			CreateIoCompletionPort(cast(HANDLE)fd, _eventHandle, cast(ulong)cast(void*)watcher, 0);
		} else
			return false;

		debug (Log)
			info("watcher(fd=", fd, ", type=", type, ')');
		_watchers ~= watcher;
		return true;
	}

	void weakUp() nothrow @trusted {
		IocpContext ctx = {operation: IocpOperation.event}; // TODO
		PostQueuedCompletionStatus(_eventHandle, 0, 0, &ctx.overlapped);
	}

	void onWeakUp() @trusted {
		enum timeout = 250, N = 32;
		OVERLAPPED_ENTRY[N] entries = void;
		uint n = void;
		const ret = GetQueuedCompletionStatusEx(_eventHandle, entries.ptr, entries.length, &n, timeout, 0);
		if (ret == 0) {
			debug (Log) {
				const err = GetLastError();
				if (err != WAIT_TIMEOUT) // && err != ERROR_OPERATION_ABORTED
					error("error occurred, code=", err);
			}
			return;
		}
		foreach (i; 0 .. n) {
			auto entry = entries[i];
			if (workerPool)
				workerPool.run!handleEvent(entry);
			else
				handleEvent(entry);
		}
	}

private:
	HANDLE _eventHandle;
	SocketChannel[] _watchers;
}

package(dast.async) void handleEvent(OVERLAPPED_ENTRY entry) {
	import dast.async.tcpserver;

	const len = entry.dwNumberOfBytesTransferred;
	auto ev = cast(IocpContext*)entry.lpOverlapped;
	auto channel = cast(void*)entry.lpCompletionKey;
	switch (ev.operation) with (IocpOperation) {
	case accept:
		(cast(TCPServer)channel).onRead();
		break;
	case read:
		if (len && (cast(SocketChannel)channel).isRegistered)
			(cast(TCPClient)channel).onRead(len);
		break;
	case write:
		debug (Log)
			info("finishing writing ", len, " bytes");
		// Notify the client about how many bytes actually sent
		(cast(TCPClient)channel).onWrite(len);
		break;
		// TODO
		//case event:
		//break;
	default:
	}
}
