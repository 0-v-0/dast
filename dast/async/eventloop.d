module dast.async.eventloop;

import dast.async.selector;
@safe:

class EventLoop {
	mixin Selector;

	private bool running;

	void run() {
		running = true;
		do {
			onWeakUp();
		}
		while (running);
	}

	void stop() nothrow {
		running = false;
		static if (is(typeof(weakUp())))
			weakUp();
	}
}

class EventExecutor : EventLoop {
	import core.thread,
	tame.fixed.queue;

	private Queue!(Fiber, 64) tasks;
	private Fiber task;

	void queueTask(Fiber fiber) {
		if (tasks.full)
			throw new Exception("EventExecutor: tasks queue is full");
		tasks.push(fiber);
	}

	override void run() @trusted {
		task = new Fiber(&super.onWeakUp);
		super.run();
	}

	override void onWeakUp() @trusted {
		if (task.state == Fiber.State.TERM)
			task.reset();
		task.call();
		for (uint count = tasks.size; count--;) {
			auto t = tasks.pop();
			if (t.state == Fiber.State.HOLD) {
				t.call();
				if (t.state == Fiber.State.HOLD) {
					tasks.push(t);
				}
			}
		}
	}
}
