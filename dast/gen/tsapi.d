module dast.gen.tsapi;
import dast.util,
std.meta,
std.traits;

struct type { // @suppress(dscanner.style.phobos_naming_convention)
	string name;
}

/// The summary of the function.
struct summary { // @suppress(dscanner.style.phobos_naming_convention)
	string content;
}

private enum shouldInclude(alias x) = isCallable!x && !hasUDA!(x, ignore);
private enum hasName(alias x) = __traits(compiles, (string s) { s = x.name; });
private template getName(alias x, string defaultName = "") {
	static if (hasName!x)
		enum getName = x.name;
	else
		enum getName = defaultName;
}

enum isString(alias x) = is(typeof(x) : const(char)[]);

alias AllActions(alias attr, modules...) = Filter!(shouldInclude, getSymbols!(attr, modules));

template ForModules(modules...) {
	template allActionNames(alias attr) {
		alias allActionNames = AliasSeq!();
		static foreach (f; AllActions!(attr, modules)) {
			static foreach (attr; getUDAs!(f, Action)) {
				allActionNames = AliasSeq!(allActionNames, getName!(attr, __traits(identifier, f)));
			}
		}
	}

	void genAPIDef(alias attr, alias getType = TSTypeOf, R)(ref R sink) {
		foreach (f; AllActions!(attr, modules)) {
			foreach (attr; getUDAs!(f, Action)) {
				sink.put("/**\n");
				getDoc!(f, getType)(sink);
				sink.put(" */\n");
				sink.put(getName!(attr, __traits(identifier, f)));
				sink.put('(');
				getArgs!(f, getType)(sink);
				sink.put("): ");
				static if (hasUDA!(f, type))
					sink.put(getUDAs!(f, type)[0].name);
				else
					sink.put(getType!(ReturnType!f));
				sink.put('\n');
			}
		}
	}

	void genTypeDef(alias getType = TSTypeOf, R)(ref R sink) {
		foreach (t; modules) {
			sink.put("export type ");
			sink.put(__traits(identifier, t));
			sink.put(" = {\n\t");
			foreach (i, alias f; t.tupleof) {
				alias loc = __traits(getLocation, f);
				const comment = getComment(loc[0], loc[1] - 1);
				if (comment) {
					sink.put("/**");
					sink.put(comment);
					sink.put(" */\n\t");
				}
				sink.put(__traits(identifier, f));
				sink.put(": ");
				static if (hasUDA!(f, type))
					sink.put(getUDAs!(f, type)[0].name);
				else
					sink.put(getType!(typeof(f)));
				sink.put('\n');
				static if (i + 1 < t.tupleof.length)
					sink.put('\t');
			}
			sink.put("}\n");
		}
	}

	void genEnum(R)(ref R sink) {
		import std.string,
		std.conv : text;

		foreach (m; modules) {
			foreach (name; __traits(allMembers, m)) {
				alias Enum = __traits(getMember, m, name);
				static if (is(Enum == enum)) {
					sink.put("export type ");
					sink.put(Enum.stringof);
					sink.put(" = ");
					{
						alias toOriginal(alias x) = AliasSeq!(cast(OriginalType!Enum)x, " | ");
						sink.put(text(staticMap!(toOriginal, EnumMembers!Enum)[0 .. $ - 1]));
					}
					sink.put("\nexport const ");
					sink.put(Enum.stringof);
					sink.put(": Record<string, string> = {\n");
					foreach (member; __traits(allMembers, Enum)) {
						sink.put("\t'");
						alias f = __traits(getMember, Enum, member);
						sink.put(text(cast(OriginalType!Enum)f));
						sink.put("': '");
						alias loc = __traits(getLocation, f);
						sink.put(getComment(loc[0], loc[1] - 1).strip());
						sink.put("',\n");
					}
					sink.put("}\n");
				}
			}
		}
	}
}

unittest {
	import std.stdio;
	import std.array;

	alias m = ForModules!(dast.gen.tsapi);
	writeln([m.allActionNames!Action]);

	auto app = appender!string;
	m.genAPIDef!Action(app);
	writeln(app[]);
}

void getDoc(alias f, alias getType = TSTypeOf, R)(ref R sink) {
	alias loc = __traits(getLocation, f);
	if (loc[1] > 1) {
		sink.put(" *");
		foreach (attr; getUDAs!(f, summary)) {
			sink.put(attr.content);
		}
		sink.put(getComment(loc[0], loc[1] - 1));
		sink.put('\n');
	}
	static if (is(FunctionTypeOf!f P == __parameters)) {
		alias PIT = ParameterIdentifierTuple!f;
		alias set = Filter!(isString, __traits(getAttributes, f));
		static foreach (i, T; P) {
			{
				alias p = P[i .. i + 1];
				alias a = getParamUDAs!(type, f, __traits(getAttributes, p));
				static if (a.length) {
					enum typeName = a[0].name;
				} else {
					enum typeName = getType!p;
				}
				static if (typeName.length) {
					sink.put(" * @param ");
					sink.put(KeyName!(p, PIT[i].length ? PIT[i] : "arg" ~ i.stringof));
					sink.put(' ');
					static foreach (attr; __traits(getAttributes, p))
						static if (isString!attr && staticIndexOf!(attr, set) == -1)
							sink.put(attr);
					sink.put('\n');
				}
			}
		}
		if (set.length)
			sink.put(" * @returns ");
		foreach (attr; set)
			static if (isString!attr)
				sink.put(attr);
		if (set.length)
			sink.put('\n');
	} else
		static assert(0, f.stringof ~ " is not a function");
}

template getParamUDAs(alias attr, alias f, attrs...) {
	alias fAttr = __traits(getAttributes, f);
	alias getParamUDAs = AliasSeq!();
	static foreach (a; attrs) {
		static if (staticIndexOf!(a, fAttr) == -1) {
			static if (__traits(isSame, a, attr))
				getParamUDAs = AliasSeq!(getParamUDAs, a);
			else static if (is(typeof(a)))
				static if (is(typeof(a) == attr))
					getParamUDAs = AliasSeq!(getParamUDAs, a);
		}
	}
}

void getArgs(alias f, alias getType = TSTypeOf, R)(ref R sink) {
	static if (is(typeof(f) P == __parameters)) {
		alias PIT = ParameterIdentifierTuple!f;
		static foreach (i, T; P) {
			{
				alias p = P[i .. i + 1];
				alias a = getParamUDAs!(type, f, __traits(getAttributes, p));
				static if (a.length) {
					enum typeName = a[0].name;
				} else {
					enum typeName = getType!p;
				}
				static if (typeName.length) {
					sink.put(KeyName!(p, PIT[i].length ? PIT[i] : "arg" ~ i.stringof));
					static if (!is(ParameterDefaults!f[i] == void))
						sink.put('?');
					sink.put(": ");
					sink.put(typeName);
					static if (i + 1 < P.length)
						sink.put(", ");
				}
			}
		}
	} else
		static assert(0, f.stringof ~ " is not a function");
}

/// Get the type name of the given type, empty string if to omit.
template TSTypeOf(T) {
	static if (hasUDA!(T, type) && hasName!(getUDAs!(T, type)[0]))
		enum TSTypeOf = getUDAs!(T, type)[0].name;
	else static if (is(T == U[], U)) {
		static if (is(T : const(char)[]))
			enum TSTypeOf = "string";
		else
			enum TSTypeOf = TSTypeOf!U ~ "[]";
	} else static if (isNumeric!T)
		enum TSTypeOf = "number";
	else static if (isBoolean!T)
		enum TSTypeOf = "boolean";
	else static if (isSomeChar!T)
		enum TSTypeOf = "string";
	else static if (is(T == void))
		enum TSTypeOf = "void";
	else static if (is(T : typeof(null)))
		enum TSTypeOf = "null";
	else static if (is(T : Throwable))
		enum TSTypeOf = "Error";
	else
		enum TSTypeOf = "any";
}

/// Get the comment at the given line and column.
char[] getComment(string filename, uint line, uint col = 1) {
	import std.stdio,
	std.string;

	--line;
	--col;
	uint i;
	char[] result;
	try {
		foreach (l; File(filename).byLine) {
			if ((i + 1 == line || i == line) && l.length >= col) {
				l = l[col .. $].stripLeft;
				if (l.startsWith("///")) {
					if (result.length)
						result ~= "\n *";
					result ~= l[3 .. $];
				} else
					result = null;
			}
			++i;
		}
	} catch (Exception) {
	}
	return result;
}

version (unittest):
struct Action {
	string name;
}

@Action:
@ignore void foo(int a) {
}

void func(int a, string b, double c) {
}

uint[] search(string query, string order = "relevance", uint offset = 0, @"max results"uint limit = 10) => null;
/// Get the user info.
@"user info"@type("User") Object getUserInfo(@"uid"long id, @type("false") bool details = false) => null;

uint count(@type("Uint32Array") uint[] ids) => 0;
/// multiline
/// comment
uint countNums(uint[] arr, size_t start, size_t end) => 0;
