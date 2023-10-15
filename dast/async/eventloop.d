module dast.async.eventloop;

import dast.async.selector;

class EventLoop : Selector {
	void run() {
		onLoop(&onWeakUp);
	}

	protected void onWeakUp() {
	}
}
