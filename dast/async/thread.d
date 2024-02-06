module dast.async.thread;

import core.atomic,
core.thread;

struct TaskBase {
	void function(void*) run;
}

struct Task(alias fun, Args...) {
private:
	TaskBase base = TaskBase(&impl);
	public Args _args;

	static if (Args.length) {
		private this(Args args) {
			_args = args;
		}
	}

	static void impl(void* p) {
		fun((cast(typeof(this)*)p)._args);
	}
}

final class TaskThread : Thread {
	this(void delegate() dg) {
		super(dg);
	}

	void run() nothrow {
		running.atomicStore(true);
		super.start();
	}

	shared bool running;
}

final class ThreadPool {
	import core.sync,
	dast.async.queue,
	std.parallelism : totalCPUs;

	enum State : ubyte {
		running,
		done,
		stop
	}

	private {
		TaskThread[] pool;
		Mutex inMutex, outMutex;
		Condition full, empty;
		State status;
		Queue!(TaskBase*, 2048 / size_t.sizeof, true) queue;
		shared uint nWorkers;
	}
	immutable uint timeoutMs;

	this() @trusted {
		this(totalCPUs - 1);
	}

	this(uint size, uint timeout_ms = 0) {
		import std.array;

		timeoutMs = timeout_ms;
		pool = uninitializedArray!(TaskThread[])(size);
		nWorkers = size;
		inMutex = new Mutex(this);
		outMutex = new Mutex;
		full = new Condition(inMutex);
		empty = new Condition(outMutex);
		foreach (ref t; pool) {
			t = new TaskThread(&workLoop);
			t.run();
		}
	}

	~this() {
		finish(true);
	}

	@property size() const => pool.length;

	@property state() const @trusted => atomicLoad(status);

	void workLoop() {
		loop: while (atomicLoad(status) != State.stop) {
			TaskBase* task;
			while (status == State.running) {
				inMutex.lock_nothrow();
				scope (exit)
					inMutex.unlock_nothrow();
				if (!queue.empty) {
					task = queue.pop();
					{
						outMutex.lock_nothrow();
						scope (exit)
							outMutex.unlock_nothrow();
						empty.notify();
					}
					break;
				}
				if (timeoutMs) {
					if (!full.wait(timeoutMs.msecs))
						break loop;
				} else
					full.wait();
			}
			if (task)
				task.run(task);
		}
		auto tthis = Thread.getThis();
		foreach (t; pool) {
			if (t == tthis) {
				t.running.atomicStore(false);
				atomicStore(nWorkers, nWorkers - 1);
				break;
			}
		}
	}

	void finish(bool blocking = false) @trusted {
		{
			inMutex.lock_nothrow();
			scope (exit)
				inMutex.unlock_nothrow();
			cas(cast(shared)&status, State.running, State.done);
			full.notifyAll();
		}
		if (blocking) {
			foreach (t; pool) {
				t.join();
			}
		}
	}

	void stop() @trusted {
		inMutex.lock_nothrow();
		scope (exit)
			inMutex.unlock_nothrow();
		cas(cast(shared)&status, State.running, State.stop);
		full.notifyAll();
	}

	void run(alias fn, Args...)(Args args) {
		run(&new Task!(fn, Args)(args).base);
	}

	private void run(TaskBase* task)
	in (task) {
		inMutex.lock_nothrow();
		scope (exit)
			inMutex.unlock_nothrow();
		if (queue.full) {
			outMutex.lock_nothrow();
			scope (exit)
				outMutex.unlock_nothrow();
			empty.wait();
		}
		queue.push(task);
		if (timeoutMs && atomicLoad(nWorkers) < pool.length) {
			foreach (t; pool) {
				if (!atomicLoad(t.running)) {
					t.run();
					atomicStore(nWorkers, nWorkers + 1);
					break;
				}
			}
		}
		full.notify();
	}
}
