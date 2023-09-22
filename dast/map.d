module dast.map;

struct Map {
	string[string] data;
	alias data this;
@safe nothrow:
	auto opIndex(in char[] key) const {
		if (auto p = key in data)
			return *p;
		return null;
	}

	void opIndexAssign(in string value, in char[] key) pure {
		data[key] = value;
	}

	auto opDispatch(string key)() const => this[key];

	auto opDispatch(string key)(string value) => data[key] = value;
}
