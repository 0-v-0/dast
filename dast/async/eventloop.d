module dast.async.eventloop;

import core.thread;
import dast.async.core;
import dast.async.selector;
import dast.async.task;
import std.parallelism;

class EventLoop : SelectorBase {
	void run() {
		if (isRuning)
			throw new Exception("The current eventloop is running");
		_thread = Thread.getThis();
		onLoop(&onWeakUp);
	}

	override void stop() {
		_thread = null;
		super.stop();
	}

	@property bool isRuning() const {
		return _thread !is null;
	}

	@property bool isInLoopThread() const {
		return isRuning && _thread is Thread.getThis();
	}

	EventLoop postTask(TaskBase task) {
		synchronized (this)
			_queue.enqueue(task);
		return this;
	}

	static TaskBase createTask(alias fun, Args...)(Args args) {
		return newTask!(fun, Args)(args);
	}

	static TaskBase createTask(F, Args...)(F delegateOrFp, Args args)
	if (is(typeof(delegateOrFp(args)))) {
		return newTask(F, Args)(delegateOrFp, args);
	}

	protected void onWeakUp() {
		TaskQueue queue = void;
		synchronized (this) {
			queue = _queue;
			_queue = TaskQueue();
		}
		while (!queue.empty)
			queue.dequeue().job();
	}

private:
	Thread _thread;
	TaskQueue _queue;
}

class EventLoopGroup {
	this(uint size = totalCPUs - 1)
	in (size <= totalCPUs) {
		size = size ? size : totalCPUs;
		foreach (i; 0 .. size) {
			auto loop = new EventLoop;
			_loops[loop] = new Thread(&loop.run);
		}
	}

	void start() {
		if (_started)
			return;
		foreach (ref t; _loops.values)
			t.start();
		_started = true;
	}

	void stop() {
		if (!_started)
			return;
		foreach (ref loop; _loops.keys)
			loop.stop();
		_started = false;
		wait();
	}

	@property size_t length() const {
		return _loops.length;
	}

	version (none) void addEventLoop(EventLoop lop) {
		auto loop = new GroupMember(lop);
		auto th = new Thread(&loop.start);
		_loops[loop] = th;
		if (_started)
			th.start();
	}

	EventLoop opIndex(size_t index) {
		return at(index);
	}

	EventLoop at(size_t index) {
		auto loops = _loops.keys;
		auto i = index % cast(size_t)loops.length;
		return loops[i];
	}

	void wait() {
		foreach (ref t; _loops.values) {
			t.join(false);
		}
	}

	int opApply(scope int delegate(EventLoop) dg) {
		int ret = 0;
		foreach (ref loop; _loops.keys) {
			ret = dg(loop);
			if (ret)
				break;
		}
		return ret;
	}

	private EventLoop _mainLoop;

private:
	bool _started;

	Thread[EventLoop] _loops;
}
