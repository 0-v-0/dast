module dast.util;

version (Have_database_util) {
	public import database.util : as, ignore, snakeCase, camelCase, KeyName;
} else {
	struct as { // @suppress(dscanner.style.phobos_naming_convention)
		string name;
	}

	enum ignore; // @suppress(dscanner.style.phobos_naming_convention)

	import tame.text.ascii;

	S snakeCase(S)(S input, char sep = '_') {
		if (!input.length)
			return [];
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
