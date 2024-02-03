module dast.async.queue;

struct Queue(T, uint N = 4096 / T.sizeof, bool check = false) {
	enum capacity = N;
pure nothrow @safe @nogc:
	@property ref front()
	in (!empty) => arr[_head];

	@property bool empty() const => _head == _tail;
	@property bool full() const => (_tail + 1) % N == _head;
	@property uint size() const => _tail >= _head ? _tail - _head : N - _head + _tail;
	alias length = size;

	void enqueue(T item) {
		static if (check)
			assert(!full);
		arr[_tail] = item;
		if (_tail < N - 1)
			++_tail;
		else
			_tail = 0;
	}

	T dequeue() {
		static if (check)
			assert(!empty);
		T x = arr[_head];
		arr[_head] = T.init;
		if (_head < N - 1)
			++_head;
		else
			_head = 0;
		return x;
	}

	alias push = enqueue;
	alias pop = dequeue;

	void clear() {
		_head = _tail = 0;
	}

private:
	package uint _head, _tail;
	T[N] arr;
}

unittest {
	alias Q = Queue!(int, 10, true);
	Q q;
	assert(q.empty);
	assert(!q.full);
	assert(q.size == 0);
	q.enqueue(1);
	assert(!q.empty);
	assert(!q.full);
	assert(q.size == 1);
	assert(q.front == 1);
	assert(q.dequeue == 1);
	assert(q.empty);
}
