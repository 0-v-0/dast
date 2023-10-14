module dast.util;

import tame.meta;

version (Have_database_util) {
	public import database.util : as, ignore, snakeCase, camelCase, KeyName;
} else {
	struct as { // @suppress(dscanner.style.phobos_naming_convention)
		string name;
	}

	enum ignore; // @suppress(dscanner.style.phobos_naming_convention)

	import tame.ascii;

	S snakeCase(S)(S input, char sep = '_') {
		if (!input.length)
			return "";
		char[128] buffer;
		size_t length;

		auto pcls = classify(input[0]);
		foreach (ch; input) {
			auto cls = classify(ch);
			switch (cls) with (CharClass) {
			case UpperCase:
				if (pcls != UpperCase && pcls != Underscore)
					buffer[length++] = sep;
				buffer[length++] = ch | ' ';
				break;
			case Digit:
				if (pcls != Digit)
					buffer[length++] = sep;
				goto default;
			default:
				buffer[length++] = ch;
				break;
			}
			pcls = cls;

			if (length >= buffer.length - 1)
				break;
		}
		return cast(S)buffer[0 .. length].dup;
	}

	unittest {
		static void test(string str, string expected) {
			auto result = str.snakeCase;
			assert(result == expected, str ~ ": " ~ result);
		}

		test("AA", "aa");
		test("AaA", "aa_a");
		test("AaA1", "aa_a_1");
		test("AaA11", "aa_a_11");
		test("_AaA1", "_aa_a_1");
		test("_AaA11_", "_aa_a_11_");
		test("aaA", "aa_a");
		test("aaAA", "aa_aa");
		test("aaAA1", "aa_aa_1");
		test("aaAA11", "aa_aa_11");
		test("authorName", "author_name");
		test("authorBio", "author_bio");
		test("authorPortraitId", "author_portrait_id");
		test("authorPortraitID", "author_portrait_id");
		test("coverURL", "cover_url");
		test("coverImageURL", "cover_image_url");
	}

	S camelCase(S, bool upper = false)(S input, char sep = '_') {
		S output;
		bool upcaseNext = upper;
		foreach (c; input) {
			if (c != sep) {
				if (upcaseNext) {
					output ~= c.toUpper;
					upcaseNext = false;
				} else
					output ~= c.toLower;
			} else
				upcaseNext = true;
		}
		return output;
	}

	unittest {
		assert("c".camelCase == "c");
		assert("c".camelCase!true == "C");
		assert("c_a".camelCase == "cA");
		assert("ca".camelCase!true == "Ca");
		assert("camel".camelCase!true == "Camel");
		assert("Camel".camelCase!false == "camel");
		assert("camel_case".camelCase!true == "CamelCase");
		assert("camel_camel_case".camelCase!true == "CamelCamelCase");
		assert("caMel_caMel_caSe".camelCase!true == "CamelCamelCase");
		assert("camel2_camel2_case".camelCase!true == "Camel2Camel2Case");
		assert("get_http_response_code".camelCase == "getHttpResponseCode");
		assert("get2_http_response_code".camelCase == "get2HttpResponseCode");
		assert("http_response_code".camelCase!true == "HttpResponseCode");
		assert("http_response_code_xyz".camelCase!true == "HttpResponseCodeXyz");
	}

	/// Get the keyname of `T`
	template KeyName(alias T, string defaultName = T.stringof) {
		import std.traits;

		static if (hasUDA!(T, ignore))
			enum KeyName = "";
		else static if (hasUDA!(T, as))
			enum KeyName = getUDAs!(T, as)[0].name;
		else
			static foreach (attr; __traits(getAttributes, T))
			static if (is(typeof(KeyName) == void) && is(typeof(attr(""))))
				enum KeyName = attr(defaultName);
		static if (is(typeof(KeyName) == void))
			enum KeyName = defaultName;
	}

	alias SQLName = KeyName;
}

private alias getAttrs(alias symbol, string name) =
	__traits(getAttributes, __traits(getMember, symbol, name));

template getSymbols(alias attr, symbols...) {
	import std.meta;

	bool hasAttr(alias symbol, string name)() {
		static if (is(typeof(getAttrs!(symbol, name))))
			foreach (a; getAttrs!(symbol, name)) {
				static if (__traits(isSame, a, attr)) {
					if (__ctfe)
						return true;
				} else static if (__traits(isTemplate, attr)) {
					if (__ctfe && is(typeof(a) == attr!A, A...))
						return true;
				} else {
					if (__ctfe && is(typeof(a) == attr))
						return true;
				}
			}
		return false;
	}

	alias getSymbols = AliasSeq!();
	static foreach (symbol; symbols) {
		static foreach (name; __traits(derivedMembers, symbol))
			static if (hasAttr!(symbol, name))
				getSymbols = AliasSeq!(getSymbols, __traits(getMember, symbol, name));
	}
}

enum isStruct(T) = is(T == struct);

/// Get all structs with @as or @snakeCase
template getTables(T...) {
	import std.meta;

	alias getTables = Filter!(isStruct, getSymbols!(as, T), getSymbols!(snakeCase, T));
}

size_t intToStr(char* buf, size_t value) pure @nogc nothrow @trusted {
	char* p = buf;
	for (;;) {
		*p++ = value % 10 ^ '0';
		if (value < 10)
			break;
		value /= 10;
	}
	for (char* i = buf, j = p - 1; i < j; i++, j--) {
		char t = *i;
		*i = *j;
		*j = t;
	}
	return p - buf;
}

alias std = Import!"std";

long getST() @trusted {
	import std.datetime.systime;

	static last_st = 0L;
	long st = Clock.currStdTime;
	return st <= last_st ? (last_st += 100) : (last_st = st);
}

unittest {
	assert(getST() != getST());
}

auto toStr(inout(char)* ptr) => std.string.fromStringz(ptr).idup;
