module dast.async.eventloop;

import core.thread;
import dast.async.core;
import dast.async.selector;
import std.parallelism;

class EventLoop : SelectorBase {
	void run() {
		onLoop(&onWeakUp);
	}

	protected void onWeakUp() {
	}
}
