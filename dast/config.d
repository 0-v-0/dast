module dast.config;

import tame.data.yaml,
std.traits : isNumeric;

version (Have_ctfepp)
	private enum PP = true;
else
	private enum PP = false;

public import tame.data.yaml : Node;

Node readyml(string content, bool preprocess = PP) {
	if (preprocess) {
		static if (PP) {
			import ctfepp;

			auto file = PPFile(content);
			executePPParser(file);
			auto edata = EvaluateData(file);
			static foreach (s; [
				"Windows", "Win32", "Win64", "linux", "OSX", "iOS", "TVOS",
				"VisionOS",
				"Posix", "Android", "Emscripten", "PlayStation",
				"PlayStation4",
				"Cygwin", "MinGW", "X86", "X86_64", "ARM", "AArch64",
				"LittleEndian", "BigEndian", "D_SIMD", "D_AVX", "D_AVX2"
			]) {
				mixin("version(", s, `) edata.defineValues[s] = "1";`);
			}
			executeEvaulator(edata);
			content = edata.output;
		} else
			throw new Exception("Preprocess is not supported");
	}
	return loadyml(content);
}

Exception readcfgEnv(alias s)(string path = null, bool preprocess = PP) {
	import std.array;
	import std.conv : to;
	import dast.util;
	import tame.io.file;

	Node root;
	try {
		root = Node(string[string].init);
		if (path.length) {
			auto buf = uninitializedArray!(ubyte[])(getSize(path));
			auto file = File(path);
			if (!file.isOpen)
				return new Exception("Open file failed: " ~ path);
			scope (exit)
				file.close();
			file.read(buf);
			if (file.error)
				return new Exception("Read file failed: " ~ path);
			root = readyml(cast(string)buf, preprocess);
		}

		foreach (i, ref f; s.tupleof) {
			enum key = KeyName!(s.tupleof[i]);
			auto var = getEnv!key;
			if (var) {
				alias T = typeof(f);
				static if (is(T : string))
					f = var;
				else static if (is(T : bool))
					f = var == "1";
				else static if (isNumeric!T)
					f = var.to!T;
				else
					static assert(0, "Unsupported type: " ~ T.stringof);
			} else if (key in root)
				f = root[key].as!(T);
		}
	} catch (Exception e)
		return e;
	return null;
}

void readcfg(alias s, S)(S path = null, bool preprocess = PP) {
	import std.file : read;
	import dast.util;

	Node root = Node(string[string].init);
	if (path.length)
		root = readyml(cast(string)read(path), preprocess);

	foreach (i, ref f; s.tupleof) {
		enum key = KeyName!(s.tupleof[i]);
		if (key in root)
			f = root[key].as!(typeof(f));
	}
}
