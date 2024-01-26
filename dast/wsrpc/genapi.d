module dast.wsrpc.genapi;
import dast.util,
dast.wsrpc,
std.meta,
std.traits;

struct type { // @suppress(dscanner.style.phobos_naming_convention)
	string name;
}

enum ignored(alias x) = hasUDA!(x, ignore);
enum hasName(alias x) = __traits(compiles, (string s) { s = x.name; });
enum isString(alias x) = is(typeof(x) : const(char)[]);

alias AllActions(T...) = Filter!(templateNot!ignored, getActions!T);

template AllActionNames(T...) {
	alias AllActionNames = AliasSeq!();
	static foreach (f; AllActions!T) {
		static foreach (attr; getUDAs!(f, Action)) {
			static if (hasName!attr)
				AllActionNames = AliasSeq!(AllActionNames, attr.name);
			else
				AllActionNames = AliasSeq!(AllActionNames, __traits(identifier, f));
		}
	}
}

void gendts(R, T...)(ref R sink) {
	foreach (f; AllActions!T) {
		foreach (attr; getUDAs!(f, Action)) {
			sink ~= "/**\n";
			getDoc!f(sink);
			sink ~= " */\n";
			static if (hasName!attr)
				sink ~= attr.name;
			else
				sink ~= __traits(identifier, f);
			sink ~= '(';
			getArgs!f(sink);
			sink ~= "): ";
			static if (hasUDA!(f, type))
				sink ~= getUDAs!(f, type)[0].name;
			else
				sink ~= getType!(ReturnType!f);
			sink ~= '\n';
		}
	}
}

void genTypeDef(R, T...)(ref R sink) {
	foreach (t; getTables!T) {
		sink ~= "export type ";
		sink ~= __traits(identifier, t);
		sink ~= " = {\n\t";
		foreach (i, alias f; t.tupleof) {
			alias loc = __traits(getLocation, f);
			const comment = getComment(loc[0], loc[1] - 1);
			if (comment) {
				sink ~= "/**";
				sink ~= comment;
				sink ~= " */\n\t";
			}
			sink ~= __traits(identifier, f);
			sink ~= ": ";
			static if (hasUDA!(f, type))
				sink ~= getUDAs!(f, type)[0].name;
			else
				sink ~= getType!(typeof(f));
			sink ~= '\n';
			static if (i + 1 < t.tupleof.length)
				sink ~= '\t';
		}
		sink ~= "}\n";
	}
}

unittest {
	import std.stdio;
	import std.array;

	alias mod = dast.wsrpc.genapi;
	writeln([AllActionNames!mod]);

	auto app = appender!string;
	gendts!(typeof(app), mod)(app);
	writeln(app[]);
}

void getDoc(alias f, R)(ref R sink) {
	alias loc = __traits(getLocation, f);
	if (loc[1] > 1) {
		sink ~= " *";
		sink ~= getComment(loc[0], loc[1] - 1);
		sink ~= '\n';
	}
	static if (is(FunctionTypeOf!f P == __parameters)) {
		alias PIT = ParameterIdentifierTuple!f;
		alias set = Filter!(isString, __traits(getAttributes, f));
		static foreach (i, T; P) {
			static if (!is(T : WSRequest)) {
				{
					alias p = P[i .. i + 1];
					sink ~= " * @param ";
					sink ~= KeyName!(p, PIT[i].length ? PIT[i] : "arg" ~ i.stringof);
					sink ~= ' ';
					static foreach (attr; __traits(getAttributes, p))
						static if (isString!attr && staticIndexOf!(attr, set) == -1)
							sink ~= attr;
					sink ~= '\n';
				}
			}
		}
		if (set.length)
			sink ~= " * @returns ";
		foreach (attr; set)
			static if (isString!attr)
				sink ~= attr;
		if (set.length)
			sink ~= '\n';
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

void getArgs(alias f, R)(ref R sink) {
	static if (is(typeof(f) P == __parameters)) {
		alias PIT = ParameterIdentifierTuple!f;
		static foreach (i, T; P) {
			static if (!is(T : WSRequest)) {
				{
					alias p = P[i .. i + 1];
					sink ~= KeyName!(p, PIT[i].length ? PIT[i] : "arg" ~ i.stringof);
					static if (!is(ParameterDefaults!f[i] == void))
						sink ~= '?';
					sink ~= ": ";
					alias a = getParamUDAs!(type, f, __traits(getAttributes, p));
					static if (a.length)
						sink ~= a[0].name;
					else
						sink ~= getType!p;
					static if (i + 1 < P.length)
						sink ~= ", ";
				}
			}
		}
	} else
		static assert(0, f.stringof ~ " is not a function");
}

template getType(T) {
	static if (hasUDA!(T, type) && hasName!(getUDAs!(T, type)[0]))
		enum getType = getUDAs!(T, type)[0].name;
	else static if (is(T == U[], U)) {
		static if (is(T : const(char)[]))
			enum getType = "string";
		else
			enum getType = getType!U ~ "[]";
	} else static if (isNumeric!T)
		enum getType = "number";
	else static if (isBoolean!T)
		enum getType = "boolean";
	else static if (isSomeChar!T)
		enum getType = "string";
	else static if (is(T == void))
		enum getType = "void";
	else static if (is(T : typeof(null)))
		enum getType = "null";
	else static if (is(T : Throwable))
		enum getType = "Error";
	else
		enum getType = "any";
}

/// Get the comment at the given line and column.
char[] getComment(string filename, uint line, uint col = 1) {
	import std.stdio,
	std.string;

	--line;
	--col;
	uint i;
	foreach (l; File(filename).byLine()) {
		if ((i + 1 == line || i == line) && l.length >= col) {
			l = l[col .. $].stripLeft;
			if (l.startsWith("///"))
				return l[3 .. $];
		}
		++i;
	}
	return null;
}

version (unittest) :
@Action:
@ignore void foo(int a) {
}

void func(int a, string b, double c) {
}

uint[] search(string query, string order = "relevance", uint offset = 0, @"max results"uint limit = 10) => null;
/// Get the user info.
@"user info"@type("User") Object getUserInfo(@"uid"long id, @type("false") bool details = false) => null;

uint count(@type("Uint32Array") uint[] ids) => 0;

uint countNums(uint[] arr, size_t start, size_t end) => 0;
