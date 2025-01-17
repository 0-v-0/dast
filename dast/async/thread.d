module dast.async.thread;

import core.atomic,
core.thread;

private struct TaskBase {
	void function(void*) run;
}

struct Task(alias fun, Args...) {
private:
	TaskBase base = TaskBase(&impl);
	Args _args;

	static if (Args.length) {
		this(Args args) {
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

struct ThreadPool {
	import core.memory,
	core.sync,
	tame.fixed.queue;

	enum State : ubyte {
		running,
		done,
		stop
	}

	private {
		TaskThread[] pool;
		Mutex mutex;
		Condition cond;
		shared State status;
		Queue!(TaskBase*, 2048 / size_t.sizeof) queue;
		shared uint nWorkers;
	}
	immutable uint timeoutMs;

	this(uint size, uint timeout_ms = 0) @trusted {
		timeoutMs = timeout_ms;
		pool = (cast(TaskThread*)pureMalloc(size * TaskThread.sizeof))[0 .. size];
		// TODO: check pool is null
		nWorkers = size;
		mutex = new Mutex();
		cond = new Condition(mutex);
		foreach (ref t; pool) {
			t = new TaskThread(&workLoop);
			t.run();
		}
	}

	~this() @trusted {
		pureFree(pool.ptr);
		finish(true);
	}

	@property size() const => pool.length;

	@property state() const @trusted => atomicLoad(status);

	void workLoop() {
		loop: while (atomicLoad(status) != State.stop) {
			mutex.lock_nothrow();
			while (queue.empty) {
				if (timeoutMs) {
					if (!cond.wait(timeoutMs.msecs)) {
						mutex.unlock_nothrow();
						break loop;
					}
				} else
					cond.wait();
			}
			auto task = queue.pop();
			cond.notify();
			mutex.unlock_nothrow();
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
			mutex.lock_nothrow();
			scope (exit)
				mutex.unlock_nothrow();
			cas(&status, State.running, State.done);
			cond.notifyAll();
		}
		if (blocking) {
			foreach (t; pool) {
				t.join();
			}
		}
	}

	void stop() @trusted {
		mutex.lock_nothrow();
		scope (exit)
			mutex.unlock_nothrow();
		cas(&status, State.running, State.stop);
		cond.notifyAll();
	}

	void run(alias fn, Args...)(auto ref Args args) {
		run(&new Task!(fn, Args)(args).base);
	}

	private void run(TaskBase* task)
	in (task) {
		mutex.lock_nothrow();
		scope (exit)
			mutex.unlock_nothrow();
		if (queue.full)
			cond.wait();
		if (atomicLoad(status) != State.running)
			return;
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
		cond.notify();
	}
}
