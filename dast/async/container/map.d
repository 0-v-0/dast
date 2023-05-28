module dast.async.container.map;

import core.sync.mutex;
import tame.meta;

class Map(TKey, TValue) {
nothrow:
	this() { mutex = new Mutex; }

	ref auto opIndex(in TKey key) {
		import std.traits : isArray;

		lock();
		scope (exit)
			unlock();
		if (key !in data) {
			static if (isArray!TValue)
				data[key] = [];
			else
				return TValue.init;
		}

		return data[key];
	}

	void opIndexAssign(TValue value, in TKey key) {
		lock();
		data[key] = value;
		unlock();
	}

	@property bool empty() const pure @safe @nogc => data.length == 0;

	bool remove(TKey key) {
		lock();
		scope (exit)
			unlock();
		return data.remove(key);
	}

	void clear() @trusted {
		lock();
		data.clear();
		unlock();
	}

@safe:
	final lock() => mutex.lock_nothrow();

	final unlock() => mutex.unlock_nothrow();

	TValue[TKey] data;
	mixin Forward!"data";

	auto opBinaryRight(string op : "in", R)(in R rhs) const {
		return rhs in data;
	}

	protected Mutex mutex;
}
