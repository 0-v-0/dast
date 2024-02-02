module dast.async.eventloop;

import dast.async.selector;

class EventLoop : Selector {
	void run() {
		onLoop(&onWeakUp);
	}

	protected void onWeakUp() {
	}

	private bool running;

	void onLoop(scope void delegate() handler) @system {
		running = true;
		do {
			handler();
			handleEvents();
		}
		while (running);
	}

	void stop() nothrow {
		running = false;
		static if (is(typeof(weakUp())))
			weakUp();
	}
}

class FiberEventLoop : EventLoop {
	import core.thread,
	dast.async.queue;

	private Queue!(Fiber, 64, true) tasks;

	void queueTask(Fiber fiber)
	in (fiber.state == Fiber.State.HOLD) {
		if (tasks.full)
			throw new Exception("FiberEventLoop: tasks queue is full");
		tasks.enqueue(fiber);
	}

	override void onWeakUp() {
		for (uint count = tasks.size; count--;) {
			auto t = tasks.dequeue();
			if (t.state == Fiber.State.HOLD) {
				t.call();
				if (t.state == Fiber.State.HOLD) {
					tasks.enqueue(t);
				}
			}
		}
	}
}
