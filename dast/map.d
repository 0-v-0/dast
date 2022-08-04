module dast.map;

struct Map {
	string[string] data;
	alias data this;
@safe nothrow:
	auto opIndex(in string key) const {
		if (auto p = key in data)
			return *p;
		return null;
	}

	void opIndexAssign(in string value, in string key) pure {
		data[key] = value;
	}

	auto opDispatch(string key)() const {
		return this[key];
	}

	auto opDispatch(string key)(in string value) {
		return data[key] = value;
	}
}
