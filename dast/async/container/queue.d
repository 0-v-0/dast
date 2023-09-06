module dast.async.container.queue;

struct Queue(T, bool check = false) if (is(typeof(null) : T)) {
pure nothrow @safe:
	@property T front() => _first;

	@property bool empty() const => _first is null;

	void enqueue(T item)
	in (item) {
		if (_last)
			_last.next = item;
		else
			_first = item;
		item.next = null;
		_last = item;
	}

	T dequeue() {
		static if (check)
			assert(_first && _last);
		T item = _first;
		if (_first !is null)
			_first = _first.next;
		if (!_first)
			_last = null;
		return item;
	}

	void clear() {
		T current = _first;
		while (current) {
			_first = current.next;
			current.next = null;
			current = _first;
		}

		_first = null;
		_last = null;
	}

	private T _first, _last;
}
