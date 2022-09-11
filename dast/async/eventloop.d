module dast.async.eventloop;

import dast.async.selector;

class EventLoop : SelectorBase {
	void run() {
		onLoop(&onWeakUp);
	}

	protected void onWeakUp() {
	}
}
