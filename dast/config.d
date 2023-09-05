module dast.config;

import std.meta : AliasSeq;
import lyaml;

version (Have_ctfepp)
	private enum PP = true;
else
	private enum PP = false;

Node readyml(string content, bool preprocess = PP) {
	if (preprocess) {
		static if (PP) {
			import ctfepp;

			auto file = PPFile(content);
			executePPParser(file);
			auto edata = EvaluateData(file);
			static foreach (s; [
				"Windows", "Win32", "Win64", "linux", "OSX", "iOS", "TVOS",
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

void readcfgEnv(alias s)(string path = null, bool preprocess = PP) {
	import std.conv : to;
	import std.file : read;
	import std.process : environment;
	import dast.util;

	Node root;
	try {
		root = Node(string[string].init);
		if (path.length)
			root = readyml(cast(string)read(path), preprocess);

		foreach (i, ref f; s.tupleof) {
			enum key = KeyName!(s.tupleof[i]);
			auto var = environment.get(key);
			if (var)
				f = var.to!(typeof(f));
			else if (key in root)
				f = root[key].as!(typeof(f));
		}
	} catch (Exception e) {
		import std.stdio;

		try
			writeln(e);
		catch (Exception) {
		}
	}
}

void readcfg(alias s, S)(S path = null, bool preprocess = PP) {
	import std.conv : to;
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
